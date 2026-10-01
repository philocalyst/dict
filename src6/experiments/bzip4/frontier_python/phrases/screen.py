"""Fixed development screen for the flat phrase family.

The default screen follows the shared bzip4 protocol: concatenate projection
field three, train on [0, 1 MiB), and evaluate [1 MiB, 1.25 MiB).  It is
intentionally bounded and does not claim to be the final 8 MiB serial gate.
The process emits one JSON object per variant; the caller can capture stdout,
stderr, exit status, command, and environment as the raw audit envelope.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time
from pathlib import Path

import phrases


TRAIN_BYTES = 1 << 20
DEV_BYTES = 256 << 10
DEFAULT_BLOCK = 16 << 10


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def projection_prefix(path: Path, limit: int) -> bytes:
    """Read only enough complete projection rows to reach ``limit`` bytes."""
    output = bytearray()
    with path.open("rb") as handle:
        for line in handle:
            fields = line.rstrip(b"\n\r").split(b"\t")
            if len(fields) < 3:
                raise ValueError(f"projection row has fewer than 3 fields: {path}")
            try:
                content = bytes.fromhex(fields[2].decode("ascii"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise ValueError(f"invalid content hex in {path}") from exc
            output.extend(content)
            if len(output) >= limit:
                break
    if len(output) < limit:
        raise ValueError(f"projection has only {len(output)} bytes; need {limit}")
    return bytes(output[:limit])


def one_variant(
    *,
    name: str,
    train_data: bytes,
    eval_data: bytes,
    block_bytes: int,
    source_path: Path,
    source_sha256: str,
    code_sha256: str,
    fit_scope: str = "training",
) -> dict:
    variant = name
    if fit_scope == "input":
        # This is deliberately labelled leakage: the model sees the fixed
        # development prefix in addition to the first-MiB training prefix.
        model_training = train_data + eval_data
        variant = "input_lex_huff"
    else:
        model_training = train_data
    phrases.clear_metrics()
    train_started = time.perf_counter_ns()
    model = phrases.train(
        model_training,
        variant=variant,
        max_phrases=1024,
        max_phrase_bytes=48,
        min_count=3,
        scope=fit_scope,
    )
    train_ns = time.perf_counter_ns() - train_started
    phrases.clear_metrics()
    encode_started = time.perf_counter_ns()
    frame = phrases.encode(eval_data, model, block_bytes=block_bytes)
    encode_ns = time.perf_counter_ns() - encode_started
    encode_metrics = phrases.metrics()
    phrases.clear_metrics()
    decode_started = time.perf_counter_ns()
    decoded = phrases.decode(frame)
    decode_ns = time.perf_counter_ns() - decode_started
    decode_metrics = phrases.metrics()
    if decoded != eval_data:
        raise AssertionError(f"roundtrip failed for {name}")
    # Exercise every restart record on a separate prepared reader.  This is a
    # correctness audit, not a timing claim.
    prepared = phrases.prepare(frame)
    block_digest = hashlib.sha256()
    block_started = time.perf_counter_ns()
    for index in range(len(prepared.records)):
        block_digest.update(prepared.decode_block(index))
    block_ns = time.perf_counter_ns() - block_started
    if block_digest.hexdigest() != sha256(eval_data):
        raise AssertionError(f"independent block walk failed for {name}")
    frame_metrics = {
        "frame_bytes": len(frame),
        "raw_bytes": len(eval_data),
        "model_bytes": encode_metrics.get("model_bytes", len(model.serialize())),
        "header_bytes": encode_metrics.get("header_bytes", 0),
        "directory_bytes": encode_metrics.get("directory_bytes", 0),
        "payload_bytes": encode_metrics.get("payload_bytes", 0),
        "coded_blocks": encode_metrics.get("coded_blocks", 0),
        "raw_blocks": encode_metrics.get("raw_blocks", 0),
        "phrase_symbols": encode_metrics.get("phrase_symbols", 0),
        "literal_symbols": encode_metrics.get("literal_symbols", 0),
        "entropy_bits": encode_metrics.get("entropy_bits", 0),
        "padding_bits": encode_metrics.get("padding_bits", 0),
        "phrase_count": model.phrase_count,
        "phrase_bytes": sum(map(len, model.phrases)),
        "id_width": model.id_width,
    }
    return {
        "variant": name,
        "actual_variant": model.variant,
        "scope": model.scope,
        "coder": model.coder,
        "block_bytes": block_bytes,
        "source_projection": str(source_path),
        "source_projection_sha256": source_sha256,
        "code_sha256": code_sha256,
        "training_bytes": len(train_data),
        "training_sha256": sha256(train_data),
        "evaluation_bytes": len(eval_data),
        "evaluation_sha256": sha256(eval_data),
        "model_training_bytes": len(model_training),
        "model_training_sha256": sha256(model_training),
        "frame_sha256": sha256(frame),
        "train_ns": train_ns,
        "encode_ns": encode_ns,
        "decode_ns": decode_ns,
        "independent_block_walk_ns": block_ns,
        "prepared_setup_ns": prepared.setup_ns,
        "decode_output_sha256": sha256(decoded),
        "independent_block_sha256": block_digest.hexdigest(),
        "frame": frame_metrics,
        "decoder_metrics": decode_metrics,
        "status": "ok",
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", action="append", type=Path, required=True)
    parser.add_argument("--block-bytes", type=int, default=DEFAULT_BLOCK)
    parser.add_argument("--train-bytes", type=int, default=TRAIN_BYTES)
    parser.add_argument("--eval-bytes", type=int, default=DEV_BYTES)
    args = parser.parse_args(argv)
    if args.train_bytes != TRAIN_BYTES or args.eval_bytes != DEV_BYTES:
        raise SystemExit("screen protocol is fixed at 1MiB train and 256KiB eval")
    code_paths = [Path(__file__), Path(phrases.__file__)]
    code_hash = hashlib.sha256()
    for path in code_paths:
        code_hash.update(path.read_bytes())
    for source_path in args.corpus:
        source_sha = file_sha256(source_path)
        prefix = projection_prefix(source_path, TRAIN_BYTES + DEV_BYTES)
        train_data = prefix[:TRAIN_BYTES]
        eval_data = prefix[TRAIN_BYTES:]
        envelope = {
            "kind": "frontier-python-phrases-development-screen",
            "command": [sys.executable, str(Path(__file__).resolve()), *argv],
            "cwd": os.getcwd(),
            "protocol": {
                "train_range": [0, TRAIN_BYTES],
                "evaluation_range": [TRAIN_BYTES, TRAIN_BYTES + DEV_BYTES],
                "holdout_range": [9 << 20, 10 << 20],
                "boundary": args.block_bytes,
            },
            "source": str(source_path),
            "source_sha256": source_sha,
            "code_sha256": code_hash.hexdigest(),
            "python": sys.version,
            "platform": platform.platform(),
            "pid": os.getpid(),
        }
        print(json.dumps(envelope, sort_keys=True), flush=True)
        # Greedy lexical, DP-refined lexical, generic n-grams, and fixed-width
        # direct expansion are independent storage/decode controls.  The
        # input-fit run is intentionally retained as a leakage diagnostic only.
        for name, scope in (
            ("lex_huff", "training"),
            ("lex_dp_huff", "training"),
            ("ngram_huff", "training"),
            ("lex_fixed", "training"),
            ("input_lex_huff", "input"),
        ):
            try:
                row = one_variant(
                    name=name,
                    train_data=train_data,
                    eval_data=eval_data,
                    block_bytes=args.block_bytes,
                    source_path=source_path,
                    source_sha256=source_sha,
                    code_sha256=code_hash.hexdigest(),
                    fit_scope=scope,
                )
            except Exception as exc:  # retain exact negative results in JSON
                row = {
                    "variant": name,
                    "status": "failure",
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                }
            print(json.dumps(row, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
