#!/usr/bin/env python3
"""Gated, serial final-capture harness for frontier candidates and controls.

This file intentionally does not run a matrix on import.  ``--prepare`` makes
an immutable source checkpoint and prints the exact jobs; ``--run`` requires
``--quiet-lane`` before it will start the CPU-heavy child processes.  Every
child encodes once, writes one complete frame, then decodes that saved frame
three times with a retained decoder.  First-block and deterministic middle
block restart checks are recorded separately.

The BWT context, grammar, symbol-BWT, and native lanes remain explicit and
separate.  ``grammar_input`` and ``symbol_bwt`` are input-fit diagnostics:
their model discovery sees the evaluation bytes and the complete model is
serialized in the frame, with no held-out training claim.  The native lane is
the ctypes bzip3 control and is kept visibly separate from candidates.  The
parent process captures child stdout, stderr, and return status before parsing
any JSON.
"""

from __future__ import annotations

import argparse
import binascii
import json
import os
from pathlib import Path
import platform
import resource
import sys
import time
from typing import Any, Iterable


FRONTIER_ROOT = Path(__file__).resolve().parents[2]
REPO = FRONTIER_ROOT.parents[3]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from src6.experiments.bzip4.frontier_python.common import (  # noqa: E402
    FINAL_END,
    FINAL_START,
    TRAIN_BYTES,
    UNTOUCHED_END,
    UNTOUCHED_START,
    corpus_hashes,
    corpus_spec,
    load_corpus,
    partition_bounds,
)
from src6.experiments.bzip4.frontier_python.protocol.capture import (  # noqa: E402
    run_and_save,
    sha256_bytes,
    snapshot_sources,
    verify_snapshot_sources,
)


DEFAULT_CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
BASE_DEFAULT_VARIANTS = ("A", "E", "grammar_input", "native")
BWT_VARIANTS = {"A", "E", "F"}
ALL_VARIANTS = BWT_VARIANTS | {"grammar_input", "symbol_bwt", "native"}
DEFAULT_BLOCKS = (16 * 1024, 64 * 1024)
DEFAULT_LANES = ("final", "untouched")
DECODE_TRIALS = 3
BLOCK_TRIALS = 3
GRAMMAR_MAX_RULES = 4096
GRAMMAR_MAX_PASSES = 10
GRAMMAR_MIN_COUNT = 4
GRAMMAR_PAIR_POLICY = "overlap_greedy"


def _default_variants() -> tuple[str, ...]:
    """Include BWT-F automatically once its codec API is present."""

    try:
        from src6.experiments.bzip4.frontier_python.bwt_context import codec  # noqa: PLC0415
    except Exception:
        return BASE_DEFAULT_VARIANTS
    if "F" in getattr(codec, "VARIANT_NAMES", {}):
        return ("A", "E", "F", "grammar_input", "native")
    return BASE_DEFAULT_VARIANTS


def _rss_peak() -> dict[str, Any]:
    """Return child max RSS with units, or an explicit unavailable record."""

    try:
        value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except (AttributeError, OSError, ValueError):
        return {"value": None, "units": None, "source": "unavailable"}
    # Darwin reports bytes; Linux and the other common Unix implementations
    # report KiB.  Keeping the unit beside the value prevents false precision.
    units = "bytes" if sys.platform == "darwin" else "KiB"
    return {"value": value, "units": units, "source": "resource.RUSAGE_SELF"}


def _crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def _write_exclusive(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def _partition(corpus: str, lane: str) -> tuple[bytes, bytes, dict[str, Any]]:
    data = load_corpus(corpus)
    start, end = partition_bounds(lane)
    if len(data) < end:
        raise ValueError(f"{corpus}: {lane} needs {end} bytes, got {len(data)}")
    training = data[:TRAIN_BYTES]
    evaluation = data[start:end]
    input_record = corpus_hashes(corpus, data=data)
    input_record.update(
        {
            "training_start": 0,
            "training_end": TRAIN_BYTES,
            "training_bytes": len(training),
            "training_sha256": sha256_bytes(training),
            "evaluation_start": start,
            "evaluation_end": end,
            "evaluation_bytes": len(evaluation),
            "evaluation_sha256": sha256_bytes(evaluation),
        }
    )
    return training, evaluation, input_record


def _native_encode(data: bytes, block_bytes: int) -> tuple[bytes, dict[str, Any]]:
    """Encode exactly once with retained native state and complete framing."""

    from src6.experiments.bzip4.frontier_python.protocol.framing import frame_blocks  # noqa: PLC0415
    from src6.experiments.bzip4.frontier_python.protocol.native_bzip3 import (  # noqa: PLC0415
        Bzip3Session,
        MAX_RAW_BYTES,
        _split_blocks,
        control_library_record,
    )

    if len(data) > MAX_RAW_BYTES:
        raise ValueError("native control input exceeds protocol bound")
    raw_blocks = _split_blocks(data, block_bytes)
    startup_started = time.perf_counter_ns()
    library = control_library_record()
    control_startup_ns = time.perf_counter_ns() - startup_started
    codec_started = time.perf_counter_ns()
    session_purpose = "encode"
    retained_state_count = 0
    if raw_blocks:
        with Bzip3Session(block_bytes, purpose="encode") as session:
            scratch = session.scratch_bytes
            retained_state_count = session.retained_state_count
            encoded = [session.encode_block(raw) for raw in raw_blocks]
    else:
        scratch = 0
        encoded = []
    codec_elapsed = time.perf_counter_ns() - codec_started
    frame_started = time.perf_counter_ns()
    frame = frame_blocks(encoded, raw_blocks, block_bytes)
    frame_elapsed = time.perf_counter_ns() - frame_started
    total_elapsed = codec_elapsed + frame_elapsed
    return frame, {
        "control_only": "ctypes-native-bzip3",
        "control_library": library,
        "control_startup_ns": control_startup_ns,
        "conservative_scratch_bytes": scratch,
        "session_purpose": session_purpose,
        "retained_state_count": retained_state_count,
        # ``encode_ns`` is complete-frame work for cross-lane accounting;
        # codec and framing components remain explicit for auditability.
        "encode_ns": total_elapsed,
        "encode_total_ns": total_elapsed,
        "encode_codec_ns": codec_elapsed,
        "frame_build_ns": frame_elapsed,
        "framing_included": True,
        "encode_total_includes_model_prep": False,
        "block_count": len(raw_blocks),
        "payload_bytes": len(frame) - 32 - 16 * len(raw_blocks),
        "framing_bytes": 32 + 16 * len(raw_blocks),
    }


def _native_retained_decode(parsed: Any, session: Any) -> bytes:
    """Decode a complete native frame with an already-prepared session."""

    from src6.experiments.bzip4.frontier_python.protocol.framing import block_crc32  # noqa: PLC0415

    output = bytearray()
    for index, record in enumerate(parsed.records):
        raw = session.decode_block(parsed.block_encoded(index), record.raw_bytes)
        if block_crc32(raw) != record.crc32:
            raise ValueError(f"native directory checksum mismatch at block {index}")
        output.extend(raw)
    return bytes(output)


def _native_restart_block(frame: bytes, index: int) -> bytes:
    from src6.experiments.bzip4.frontier_python.protocol.native_bzip3 import bzip3_decode_block  # noqa: PLC0415

    return bzip3_decode_block(frame, index)


def _child(args: argparse.Namespace) -> int:
    """Run one isolated job and emit exactly one JSON record."""

    started_ns = time.perf_counter_ns()
    training, evaluation, input_record = _partition(args.corpus, args.lane)
    frame_path = Path(args.frame).resolve()
    if frame_path.exists():
        raise FileExistsError(f"refusing to overwrite frame {frame_path}")

    model_prep_ns: int | None = None
    model_bytes: int | None = None
    encode_metadata: dict[str, Any]
    if args.variant == "native":
        frame, encode_metadata = _native_encode(evaluation, args.block_bytes)
    elif args.variant in BWT_VARIANTS:
        from src6.experiments.bzip4.frontier_python.bwt_context import encode, train  # noqa: PLC0415

        model_started = time.perf_counter_ns()
        model = train(training, args.variant, args.block_bytes)
        model_prep_ns = time.perf_counter_ns() - model_started
        model_bytes = len(model.wire())
        encode_started = time.perf_counter_ns()
        frame = encode(evaluation, model, args.block_bytes)
        frame_encode_ns = time.perf_counter_ns() - encode_started
        encode_total_ns = model_prep_ns + frame_encode_ns
        # The candidate API returns a complete frame; its internal block
        # transform and framing are intentionally not split here.  This is
        # reported explicitly instead of comparing it to native codec-only
        # work.
        encode_metadata = {
            "encode_ns": encode_total_ns,
            "encode_total_ns": encode_total_ns,
            "frame_encode_ns": frame_encode_ns,
            "model_prep_ns": model_prep_ns,
            "model_discovery_included": False,
            "encode_total_includes_model_prep": True,
            "encode_codec_ns": None,
            "frame_build_ns": None,
            "framing_included": True,
            "model_variant": args.variant,
            "fit_scope": "training",
        }
    elif args.variant == "grammar_input":
        from src6.experiments.bzip4.frontier_python import grammar as grammar_codec  # noqa: PLC0415

        # Input-fit grammar is a deliberately separate diagnostic family:
        # model discovery sees this evaluation lane, and the complete model is
        # serialized in the frame.  There is no disjoint training phase; the
        # single encode clock includes discovery, coding, and complete framing.
        encode_started = time.perf_counter_ns()
        frame = grammar_codec.encode(
            evaluation,
            args.block_bytes,
            variant="input_huff",
            max_rules=args.grammar_max_rules,
            max_passes=args.grammar_max_passes,
            min_count=GRAMMAR_MIN_COUNT,
            pair_policy=args.grammar_pair_policy,
        )
        encode_total_ns = time.perf_counter_ns() - encode_started
        input_metrics = grammar_codec.metrics()
        model_bytes = int(input_metrics.get("model_bytes", 0))
        encode_metadata = {
            "encode_ns": encode_total_ns,
            "encode_total_ns": encode_total_ns,
            "frame_encode_ns": encode_total_ns,
            "model_discovery_ns": encode_total_ns,
            "model_discovery_included": True,
            "encode_total_includes_model_prep": True,
            "encode_codec_ns": None,
            "frame_build_ns": None,
            "framing_included": True,
            "fit_scope": "input",
            "model_discovery_ns_inclusive": encode_total_ns,
            "model_discovery_separate_clock": False,
            "grammar_defaults": {
                "max_rules": args.grammar_max_rules,
                "max_passes": args.grammar_max_passes,
                "min_count": GRAMMAR_MIN_COUNT,
                "pair_policy": args.grammar_pair_policy,
            },
            "encode_metrics": input_metrics,
        }
    elif args.variant == "symbol_bwt":
        from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_codec  # noqa: PLC0415

        # Symbol-BWT is input-fit by design here.  Its complete grammar-root
        # and event models are serialized by codec.encode into every frame;
        # this is ordinary two-pass input compression, not held-out training.
        model_started = time.perf_counter_ns()
        model = symbol_codec.train(
            evaluation,
            block_bytes=args.block_bytes,
            max_rules=args.grammar_max_rules,
            max_passes=args.grammar_max_passes,
            min_count=GRAMMAR_MIN_COUNT,
            pair_policy=args.grammar_pair_policy,
            input_fit=True,
        )
        model_prep_ns = time.perf_counter_ns() - model_started
        model_bytes = model.grammar_bytes + model.event_model_bytes
        encode_started = time.perf_counter_ns()
        frame = symbol_codec.encode(evaluation, model, args.block_bytes)
        frame_encode_ns = time.perf_counter_ns() - encode_started
        encode_total_ns = model_prep_ns + frame_encode_ns
        encode_metadata = {
            "encode_ns": encode_total_ns,
            "encode_total_ns": encode_total_ns,
            "frame_encode_ns": frame_encode_ns,
            "model_discovery_ns": model_prep_ns,
            "model_discovery_included": True,
            "encode_total_includes_model_prep": True,
            "encode_codec_ns": None,
            "frame_build_ns": None,
            "framing_included": True,
            "fit_scope": "input",
            "model_stored_in_frame": True,
            "grammar_defaults": {
                "max_rules": args.grammar_max_rules,
                "max_passes": args.grammar_max_passes,
                "min_count": GRAMMAR_MIN_COUNT,
                "pair_policy": args.grammar_pair_policy,
            },
            "encode_metrics": symbol_codec.metrics(),
        }
    else:
        raise ValueError(f"unknown final variant {args.variant}")

    _write_exclusive(frame_path, frame)
    # All decode work starts from the exact bytes persisted on disk.  This
    # also makes a partial/write corruption visible before any timing record
    # is emitted.
    frame_read_started = time.perf_counter_ns()
    saved_frame = frame_path.read_bytes()
    frame_read_ns = time.perf_counter_ns() - frame_read_started
    if saved_frame != frame:
        raise IOError("saved frame differs from encoder output")
    frame = saved_frame
    frame_sha256 = sha256_bytes(saved_frame)

    # Decoder startup/model preparation is deliberately separate from the
    # three retained full-decode trials.  The saved frame is read once here,
    # and every trial uses that exact byte sequence.
    decode_prep_started = time.perf_counter_ns()
    native_decode_session: Any = None
    if args.variant == "native":
        from src6.experiments.bzip4.frontier_python.protocol.framing import open_frame  # noqa: PLC0415
        from src6.experiments.bzip4.frontier_python.protocol.native_bzip3 import Bzip3Session  # noqa: PLC0415

        parsed = open_frame(saved_frame)
        decode_prepared: Any = parsed
        # Session construction is charged in decode_model_prep_ns; all three
        # full trials below reuse this same decoder state over independent
        # blocks, matching the retained-state control definition.
        native_decode_session = Bzip3Session(parsed.block_bytes, purpose="decode")
        decode_scratch_bytes = native_decode_session.scratch_bytes
    else:
        if args.variant in BWT_VARIANTS:
            from src6.experiments.bzip4.frontier_python.bwt_context import prepare  # noqa: PLC0415
        elif args.variant == "grammar_input":
            from src6.experiments.bzip4.frontier_python.grammar import grammar as grammar_codec  # noqa: PLC0415

            prepare = grammar_codec.prepare
        else:
            from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_codec  # noqa: PLC0415

            prepare = symbol_codec.prepare
        # ``prepare`` is intentionally fresh and timed only after the frame
        # has been written and re-read.  No pre-save validation is reused as
        # a falsely near-zero startup/model-prep claim.
        decode_prepared = prepare(saved_frame)
        decode_scratch_bytes = None
    decode_prep_ns = time.perf_counter_ns() - decode_prep_started

    if args.variant == "native":
        frame_metrics_record: dict[str, Any] = {
            "header_bytes": 32,
            "directory_bytes": 16 * int(decode_prepared.block_count),
            "payload_bytes": len(frame) - 32 - 16 * int(decode_prepared.block_count),
            "complete_bytes": len(frame),
            "raw_bytes": len(evaluation),
            "block_count": int(decode_prepared.block_count),
        }
    else:
        if args.variant in BWT_VARIANTS:
            from src6.experiments.bzip4.frontier_python.bwt_context import frame_metrics  # noqa: PLC0415
        elif args.variant == "grammar_input":
            from src6.experiments.bzip4.frontier_python.grammar import grammar as grammar_codec  # noqa: PLC0415

            frame_metrics = grammar_codec.frame_metrics
        else:
            from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_codec  # noqa: PLC0415

            frame_metrics = symbol_codec.frame_metrics
        frame_metrics_record = frame_metrics(decode_prepared)

    # One explicit warmup is excluded from the three retained measurements.
    # It verifies that the saved frame and decoder state are usable before
    # collecting the requested samples.
    try:
        warmup_started = time.perf_counter_ns()
        if args.variant == "native":
            warmup = _native_retained_decode(decode_prepared, native_decode_session)
        else:
            warmup = decode_prepared.decode_all()
        warmup_elapsed_ns = time.perf_counter_ns() - warmup_started
        if warmup != evaluation:
            raise AssertionError(f"{args.variant} unmeasured warmup: exact roundtrip mismatch")
        warmup_record = {
            "measured": False,
            # Timed for lazy model/table startup diagnostics, but excluded
            # from the retained three-trial distribution below.
            "first_full_decode_ns": warmup_elapsed_ns,
            "decoded_bytes": len(warmup),
            "decoded_sha256": sha256_bytes(warmup),
        }

        decode_trials: list[dict[str, Any]] = []
        for trial in range(1, DECODE_TRIALS + 1):
            trial_started = time.perf_counter_ns()
            if args.variant == "native":
                decoded = _native_retained_decode(decode_prepared, native_decode_session)
            else:
                decoded = decode_prepared.decode_all()
            trial_ns = time.perf_counter_ns() - trial_started
            if decoded != evaluation:
                raise AssertionError(f"{args.variant} trial {trial}: exact roundtrip mismatch")
            decode_trials.append(
                {
                    "trial": trial,
                    "decode_ns": trial_ns,
                    "decoded_bytes": len(decoded),
                    "decoded_sha256": sha256_bytes(decoded),
                }
            )
    finally:
        if native_decode_session is not None:
            native_decode_session.close()

    if args.variant == "native":
        block_count = int(decode_prepared.block_count)
        first_decode = _native_restart_block
    else:
        if args.variant in BWT_VARIANTS:
            from src6.experiments.bzip4.frontier_python.bwt_context import decode_block  # noqa: PLC0415
        elif args.variant == "grammar_input":
            from src6.experiments.bzip4.frontier_python.grammar import grammar as grammar_codec  # noqa: PLC0415

            decode_block = grammar_codec.decode_block
        else:
            from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_codec  # noqa: PLC0415

            decode_block = symbol_codec.decode_block

        def first_decode(saved: bytes, index: int) -> bytes:
            # Fresh prepare for both first and middle-block checks; the
            # decode_model_prep field above covers the retained trial setup.
            return decode_block(saved, index)

    from src6.experiments.bzip4.frontier_python.protocol.framing import open_frame  # noqa: PLC0415

    # Candidate and native frames both expose an independently addressable
    # directory.  The deterministic middle index is the same rule as the
    # control helper; empty lanes are rejected by the partition protocol.
    parsed_frame = open_frame(saved_frame) if args.variant == "native" else None
    if args.variant == "native":
        block_count = parsed_frame.block_count
    else:
        block_count = int(frame_metrics_record["block_count"])
    if block_count <= 0:
        raise AssertionError("final/untouched lane unexpectedly encoded zero blocks")
    random_index = (block_count - 1) // 2
    block_checks: dict[str, Any] = {}
    for label, index in (("first", 0), ("random", random_index)):
        block_trials: list[dict[str, Any]] = []
        expected_start = index * args.block_bytes
        expected = evaluation[expected_start : expected_start + args.block_bytes]
        for trial in range(1, BLOCK_TRIALS + 1):
            block_started = time.perf_counter_ns()
            if args.variant == "native":
                block = _native_restart_block(frame, index)
            else:
                block = first_decode(frame, index)
            block_ns = time.perf_counter_ns() - block_started
            if block != expected:
                raise AssertionError(f"{args.variant} {label} block {index} trial {trial}: exact roundtrip mismatch")
            block_trials.append(
                {
                    "trial": trial,
                    "decode_ns": block_ns,
                    "bytes": len(block),
                    "sha256": sha256_bytes(block),
                }
            )
        block_checks[label] = {
            "index": index,
            "decode_trials": block_trials,
            "restart_decoder": True,
        }

    result = {
        "schema": "bzip4-final-serial-child-2",
        "status": 0,
        "corpus": args.corpus,
        "lane": args.lane,
        "variant": args.variant,
        "block_bytes": args.block_bytes,
        "fit_scope": encode_metadata.get("fit_scope"),
        "grammar_options": {
            "max_rules": args.grammar_max_rules,
            "max_passes": args.grammar_max_passes,
            "min_count": GRAMMAR_MIN_COUNT,
            "pair_policy": args.grammar_pair_policy,
        },
        "frame_path": str(frame_path),
        "frame_bytes": len(frame),
        "frame_sha256": frame_sha256,
        "input": input_record,
        "model_prep_ns": model_prep_ns,
        "model_bytes": model_bytes,
        "encode": encode_metadata,
        "frame_read_ns": frame_read_ns,
        "decode_model_prep_ns": decode_prep_ns,
        "decode_warmup": warmup_record,
        "decode_trials": decode_trials,
        "first_block": block_checks["first"],
        "random_block": block_checks["random"],
        "metrics": frame_metrics_record,
        "memory": {
            "process_rss_peak": _rss_peak(),
            "rss_scope": "whole child: pinned corpus load, training, encode, frame save, and decode",
            "decoder_analytic": {
                "saved_frame_bytes": len(saved_frame),
                "model_wire_bytes": model_bytes,
                "initialization_bytes": frame_metrics_record.get("initialization_bytes"),
                "prepared_setup_ns": frame_metrics_record.get("prepared_setup_ns"),
                "grammar_preexpanded_bytes": frame_metrics_record.get(
                    "rule_expansion_bytes",
                    frame_metrics_record.get("grammar_preexpanded_bytes"),
                ),
                "prepared_state_bytes_estimate": frame_metrics_record.get("prepared_state_bytes_estimate"),
                "prepared_huffman_tree_bytes_estimate": frame_metrics_record.get("prepared_huffman_tree_bytes_estimate"),
                "prepared_mtf_scratch_bytes_estimate": frame_metrics_record.get("prepared_mtf_scratch_bytes_estimate"),
                "conservative_native_scratch_bytes": decode_scratch_bytes,
                "native_retained_states": 1 if args.variant == "native" else None,
            },
        },
        "startup": {
            "child_enter_ns": started_ns,
            "python": sys.version,
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
    }
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0


def _source_paths() -> tuple[Path, ...]:
    """Explicit files needed to reconstruct this final harness revision."""

    root = FRONTIER_ROOT
    return (
        root / "common.py",
        root / "bwt_context" / "__init__.py",
        root / "bwt_context" / "codec.py",
        root / "protocol" / "__init__.py",
        root / "protocol" / "builder.py",
        root / "protocol" / "capture.py",
        root / "protocol" / "framing.py",
        root / "protocol" / "native_bzip3.py",
        root / "grammar" / "__init__.py",
        root / "grammar" / "grammar.py",
        root / "symbol_bwt" / "__init__.py",
        root / "symbol_bwt" / "codec.py",
        root / "evidence" / "controls" / "final_serial.py",
        REPO / "vendor" / "bzip3" / "src" / "libbz3.c",
        REPO / "vendor" / "bzip3" / "include" / "libbz3.h",
        REPO / "vendor" / "bzip3" / "include" / "common.h",
        REPO / "vendor" / "bzip3" / "include" / "libsais.h",
        root / "protocol" / "vendor" / "build-manifest.json",
    )


def _source_names() -> tuple[str, ...]:
    """Stable flat snapshot names, including package-qualified init files."""

    return (
        "common.py",
        "bwt_context__init__.py",
        "bwt_context__codec.py",
        "protocol__init__.py",
        "protocol__builder.py",
        "protocol__capture.py",
        "protocol__framing.py",
        "protocol__native_bzip3.py",
        "grammar__init__.py",
        "grammar__grammar.py",
        "symbol_bwt__init__.py",
        "symbol_bwt__codec.py",
        "final_serial.py",
        "vendor_bzip3__src__libbz3.c",
        "vendor_bzip3__include__libbz3.h",
        "vendor_bzip3__include__common.h",
        "vendor_bzip3__include__libsais.h",
        "protocol_vendor__build-manifest.json",
    )


def _control_artifact_record() -> dict[str, Any]:
    """Verify/retrieve the isolated native control artifact provenance."""

    from src6.experiments.bzip4.frontier_python.protocol.native_bzip3 import control_library_record  # noqa: PLC0415

    return dict(control_library_record())


def _jobs(
    corpora: Iterable[str],
    variants: Iterable[str],
    lanes: Iterable[str],
    blocks: Iterable[int],
    *,
    grammar_options: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    for corpus in corpora:
        for lane in lanes:
            for variant in variants:
                for block_bytes in blocks:
                    job: dict[str, Any] = {
                        "corpus": corpus,
                        "lane": lane,
                        "variant": variant,
                        "block_bytes": block_bytes,
                    }
                    if grammar_options is not None:
                        job["grammar_options"] = dict(grammar_options)
                    jobs.append(job)
    return jobs


def _parse_csv(value: str, *, allowed: set[str], label: str) -> tuple[str, ...]:
    values = tuple(part.strip() for part in value.split(",") if part.strip())
    if not values or any(part not in allowed for part in values):
        raise ValueError(f"{label} must contain only {sorted(allowed)}")
    return values


def _validate_grammar_options(args: argparse.Namespace) -> None:
    if not 0 <= args.grammar_max_rules <= 8192:
        raise SystemExit("--grammar-max-rules must be between 0 and 8192")
    if args.grammar_max_passes < 0:
        raise SystemExit("--grammar-max-passes must be non-negative")


def _run(args: argparse.Namespace) -> int:
    if not args.quiet_lane:
        raise SystemExit("refusing final matrix: pass --quiet-lane after the coordinating gate")
    output_root = Path(args.output_root).resolve()
    if output_root.exists():
        raise FileExistsError(f"refusing to reuse final evidence directory {output_root}")
    output_root.mkdir(parents=True, exist_ok=False)
    raw_root = output_root / "raw"
    frame_root = output_root / "frames"
    raw_root.mkdir()
    frame_root.mkdir()

    native_control_before = _control_artifact_record()
    sources = _source_paths()
    snapshot_manifest = snapshot_sources(
        sources,
        output_root / "source-snapshot",
        destination_names=_source_names(),
    )
    grammar_options = {
        "max_rules": args.grammar_max_rules,
        "max_passes": args.grammar_max_passes,
        "min_count": GRAMMAR_MIN_COUNT,
        "pair_policy": args.grammar_pair_policy,
    }
    jobs = _jobs(
        args.corpora,
        args.variants,
        args.lanes,
        args.blocks,
        grammar_options=grammar_options,
    )
    records: list[dict[str, Any]] = []
    for job in jobs:
        stem = f"{job['corpus']}.{job['lane']}.{job['variant']}.b{job['block_bytes']}"
        frame_path = frame_root / f"{stem}.frame"
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "--child",
            "--corpus",
            job["corpus"],
            "--lane",
            job["lane"],
            "--variant",
            job["variant"],
            "--block-bytes",
            str(job["block_bytes"]),
            "--grammar-max-rules",
            str(args.grammar_max_rules),
            "--grammar-max-passes",
            str(args.grammar_max_passes),
            "--grammar-pair-policy",
            args.grammar_pair_policy,
            "--frame",
            str(frame_path),
        ]
        capture = run_and_save(command, cwd=REPO, raw_root=raw_root, stem=stem, timeout=args.timeout)
        status = json.loads((raw_root / f"{stem}.status.json").read_text(encoding="utf-8"))
        record: dict[str, Any] = {"job": job, "capture": status}
        if capture.returncode == 0:
            if capture.stderr:
                raise RuntimeError(f"successful job {stem} wrote stderr; inspect raw capture")
            try:
                rows = capture.stdout.decode("utf-8").splitlines()
                if len(rows) != 1:
                    raise ValueError(f"expected exactly one JSON row, got {len(rows)}")
                record["result"] = json.loads(rows[0])
            except Exception as exc:
                raise RuntimeError(f"cannot parse successful child {stem} after raw save: {exc}") from exc
        else:
            record["result"] = None
            records.append(record)
            _write_exclusive(output_root / "results.partial.json", (json.dumps(records, indent=2, sort_keys=True) + "\n").encode())
            raise RuntimeError(f"final child failed: {stem} returncode={capture.returncode}")
        records.append(record)
        _write_exclusive(output_root / f"{stem}.record.json", (json.dumps(record, indent=2, sort_keys=True) + "\n").encode())

    native_control_after = _control_artifact_record()
    if native_control_after != native_control_before:
        raise RuntimeError(
            "isolated native control artifact changed during final matrix: "
            f"before={native_control_before}, after={native_control_after}"
        )
    drift = verify_snapshot_sources(snapshot_manifest)
    summary = {
        "schema": "bzip4-final-serial-summary-1",
        "status": 0 if drift["ok"] else 1,
        "quiet_lane_authorized": True,
        "jobs": jobs,
        "records": records,
        "grammar_options": grammar_options,
        "source_snapshot": snapshot_manifest,
        "source_drift": drift,
        "native_control_before": native_control_before,
        "native_control_after": native_control_after,
        "native_control_unchanged": native_control_after == native_control_before,
        "raw_capture_policy": "stdout/stderr/status persisted before JSON parsing; serial no-retry",
    }
    _write_exclusive(output_root / "results.json", (json.dumps(summary, indent=2, sort_keys=True) + "\n").encode())
    if not drift["ok"]:
        raise RuntimeError(f"source drift after final matrix: {drift}")
    print(json.dumps({"output_root": str(output_root), "jobs": len(jobs), "status": 0}, sort_keys=True))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--prepare", action="store_true", help="print the gated matrix and source list")
    parser.add_argument("--run", action="store_true", help="run the matrix; requires --quiet-lane")
    parser.add_argument("--quiet-lane", action="store_true", help="explicit coordinating gate for CPU-heavy final work")
    parser.add_argument("--output-root", default=str(FRONTIER_ROOT / "evidence" / "controls" / "final"), help="new evidence directory")
    parser.add_argument("--corpora", default=",".join(DEFAULT_CORPORA))
    parser.add_argument("--variants", default=",".join(_default_variants()))
    parser.add_argument("--lanes", default=",".join(DEFAULT_LANES))
    parser.add_argument("--blocks", default="16384,65536")
    parser.add_argument("--grammar-max-rules", type=int, default=GRAMMAR_MAX_RULES)
    parser.add_argument("--grammar-max-passes", type=int, default=GRAMMAR_MAX_PASSES)
    parser.add_argument("--grammar-pair-policy", choices=("overlap_greedy", "consistent"), default=GRAMMAR_PAIR_POLICY)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--corpus")
    parser.add_argument("--lane")
    parser.add_argument("--variant")
    parser.add_argument("--block-bytes", type=int)
    parser.add_argument("--frame")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    _validate_grammar_options(args)
    if args.child:
        if not all((args.corpus, args.lane, args.variant, args.block_bytes, args.frame)):
            raise SystemExit("--child requires --corpus --lane --variant --block-bytes --frame")
        if args.variant not in ALL_VARIANTS:
            raise SystemExit("--child variant must be A, E, F, grammar_input, symbol_bwt, or native")
        return _child(args)
    if args.prepare:
        corpora = _parse_csv(args.corpora, allowed=set(DEFAULT_CORPORA), label="--corpora")
        variants = _parse_csv(args.variants, allowed=ALL_VARIANTS, label="--variants")
        lanes = _parse_csv(args.lanes, allowed=set(DEFAULT_LANES), label="--lanes")
        blocks = tuple(int(part.strip()) for part in args.blocks.split(",") if part.strip())
        if not blocks or any(block not in DEFAULT_BLOCKS for block in blocks):
            raise SystemExit("--blocks must contain only 16384 and/or 65536")
        grammar_options = {
            "max_rules": args.grammar_max_rules,
            "max_passes": args.grammar_max_passes,
            "min_count": GRAMMAR_MIN_COUNT,
            "pair_policy": args.grammar_pair_policy,
        }
        print(
            json.dumps(
                {
                    "jobs": _jobs(corpora, variants, lanes, blocks, grammar_options=grammar_options),
                    "grammar_options": grammar_options,
                    "source_paths": [str(path) for path in _source_paths()],
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.run:
        args.corpora = _parse_csv(args.corpora, allowed=set(DEFAULT_CORPORA), label="--corpora")
        args.variants = _parse_csv(args.variants, allowed=ALL_VARIANTS, label="--variants")
        args.lanes = _parse_csv(args.lanes, allowed=set(DEFAULT_LANES), label="--lanes")
        args.blocks = tuple(int(part.strip()) for part in args.blocks.split(",") if part.strip())
        if not args.blocks or any(block not in DEFAULT_BLOCKS for block in args.blocks):
            raise SystemExit("--blocks must contain only 16384 and/or 65536")
        return _run(args)
    raise SystemExit("choose --prepare, --run, or hidden --child")


if __name__ == "__main__":
    raise SystemExit(main())
