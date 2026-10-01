#!/usr/bin/env python3
"""Run the bounded latent-belief screen and retain auditable artifacts.

The screen has two phases.  ``dev`` trains on frozen train slices and measures
all six old/new language workloads; it never reads old ``untouched`` files.
After inspecting the aggregate dev table, invoke ``final --k K --mode MODE``
with one explicit policy.  That phase is the first one allowed to read the
untouched slices.  There is no per-corpus candidate selection.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
BZ4 = HERE.parents[1] / "bz4"
DATA = BZ4 / "data"
EVIDENCE = HERE.parent / "evidence"
CAPTURE = EVIDENCE / "bin" / "capture_frame"
BZ4_BIN = BZ4 / "v3" / "zig-out" / "bin" / "bz4"
BZ3_BIN = BZ4 / "bin" / "bz3base"
sys.path.insert(0, str(HERE))
from belief_codec import (  # noqa: E402
    Compiled,
    FrameError,
    compile_model,
    compiled_cross_entropy,
    decode_frame,
    encode_frame,
    frame_sha256,
    model_sha256,
    teacher_cross_entropy,
    train_hmm,
)


TRAIN_LIMIT_OLD = 65536
DEV_LIMIT_OLD = 65536
TRAIN_LIMIT_UD = 16384
DEV_LIMIT_UD = 16384
FINAL_LIMIT = 65536
RESTART = 4096
K_VALUES = (2, 4, 8)
MODES = ("observed", "balanced")


@dataclass(frozen=True)
class Case:
    name: str
    train_path: Path
    train_start: int
    train_length: int
    dev_path: Path
    dev_start: int
    dev_length: int
    final_path: Path
    final_start: int
    final_length: int


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def old_case(name: str) -> Case:
    return Case(
        name=f"{name}-eval8-64k",
        train_path=DATA / f"{name}.train.bin",
        train_start=0,
        train_length=TRAIN_LIMIT_OLD,
        dev_path=DATA / f"{name}.eval8.bin",
        dev_start=0,
        dev_length=DEV_LIMIT_OLD,
        final_path=DATA / f"{name}.untouched.bin",
        final_start=0,
        final_length=FINAL_LIMIT,
    )


def ud_case(name: str, projection: str) -> Case:
    source = EVIDENCE / "corpora" / name / f"{projection}.txt"
    return Case(
        name=f"{name}-{projection}",
        train_path=source,
        train_start=0,
        train_length=TRAIN_LIMIT_UD,
        dev_path=source,
        dev_start=TRAIN_LIMIT_UD,
        dev_length=DEV_LIMIT_UD,
        final_path=source,
        final_start=TRAIN_LIMIT_UD + DEV_LIMIT_UD,
        final_length=FINAL_LIMIT,
    )


def cases() -> list[Case]:
    result = [old_case(name) for name in ("freedict", "gcide", "omw")]
    for language in ("ud-fi-test", "ud-tr-test", "ud-ar-test"):
        for projection in ("form", "text"):
            result.append(ud_case(language, projection))
    return result


def slice_bytes(path: Path, start: int, length: int) -> bytes:
    with path.open("rb") as stream:
        stream.seek(start)
        return stream.read(length)


def record_bytes(path: Path, raw: bytes) -> dict[str, Any]:
    return {"path": str(path.resolve()), "bytes": len(raw), "sha256": sha256_bytes(raw)}


def record_file(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    return record_bytes(path, raw)


def run_process(argv: list[str], stdout_path: Path, stderr_path: Path) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    stdout_path.write_bytes(result.stdout)
    stderr_path.write_bytes(result.stderr)
    return result


def parse_ok_fields(stderr: bytes) -> dict[str, int]:
    text = stderr.decode("utf-8", "strict")
    line = next((line for line in text.splitlines() if line.startswith("ok\t")), None)
    if line is None:
        raise ValueError(f"baseline did not report ok: {text[-500:]}")
    fields: dict[str, int] = {}
    for field in line.split("\t")[1:]:
        key, sep, value = field.partition("=")
        if sep and value.isdigit():
            fields[key] = int(value)
    if "total" not in fields:
        raise ValueError("baseline missing total")
    return fields


def baseline_v4(sample_dir: Path, source: Path) -> dict[str, Any]:
    """Capture complete old v4 bytes on the exact target slice."""

    frame = sample_dir / "v4.b4"
    stdout = sample_dir / "v4.encode.stdout"
    stderr = sample_dir / "v4.encode.stderr"
    command = [str(CAPTURE), "raw", str(source), str(frame), "65536"]
    result = run_process(command, stdout, stderr)
    record: dict[str, Any] = {
        "codec": "bz4-v4-end-to-end",
        "command": command,
        "returncode": result.returncode,
        "stdout": record_file(stdout),
        "stderr": record_file(stderr),
        "binary": record_file(CAPTURE),
    }
    if result.returncode != 0 or not frame.is_file():
        record["ok"] = False
        return record
    record["frame"] = record_file(frame)
    try:
        record["storage"] = parse_ok_fields(result.stderr)
    except ValueError as exc:
        record["ok"] = False
        record["error"] = str(exc)
        return record

    decoded = sample_dir / "v4.external-decoded.bin"
    decode_stdout = sample_dir / "v4.decode.stdout"
    decode_stderr = sample_dir / "v4.decode.stderr"
    decode_command = [str(BZ4_BIN), "d", str(frame), str(decoded), "1"]
    decoded_result = run_process(decode_command, decode_stdout, decode_stderr)
    record["external_decode"] = {
        "command": decode_command,
        "returncode": decoded_result.returncode,
        "stdout": record_file(decode_stdout),
        "stderr": record_file(decode_stderr),
        "output": record_file(decoded) if decoded.is_file() else None,
    }
    record["ok"] = (
        decoded_result.returncode == 0
        and decoded.is_file()
        and decoded.read_bytes() == source.read_bytes()
    )
    return record


def baseline_bzip3(sample_dir: Path, source: Path) -> dict[str, Any]:
    """Retain the matched-block bzip3 control when the local binary exists."""

    stdout = sample_dir / "bzip3.stdout"
    stderr = sample_dir / "bzip3.stderr"
    command = [str(BZ3_BIN), str(source), "65536", "1"]
    if not BZ3_BIN.is_file():
        return {"codec": "bzip3-control", "ok": False, "error": "binary missing", "command": command}
    result = run_process(command, stdout, stderr)
    record: dict[str, Any] = {
        "codec": "bzip3-control",
        "command": command,
        "returncode": result.returncode,
        "stdout": record_file(stdout),
        "stderr": record_file(stderr),
        "binary": record_file(BZ3_BIN),
    }
    if result.returncode == 0:
        fields = result.stdout.decode("utf-8", "strict").strip().split("\t")
        if len(fields) >= 5:
            record["storage"] = {
                "input": fields[0],
                "block_bytes": int(fields[1]),
                "blocks": int(fields[2]),
                "payload": int(fields[3]),
                "total": int(fields[4]),
            }
    record["ok"] = result.returncode == 0 and "storage" in record
    return record


def write_teacher(path: Path, hmm: Any) -> None:
    payload = {
        "warning": "Teacher parameters are encode-time evidence only; they are not in the LBEL frame.",
        "states": hmm.states,
        "initial": list(hmm.initial),
        "transition": [list(row) for row in hmm.transition],
        "emission": [list(row) for row in hmm.emission],
    }
    path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")


def candidate_record(
    sample_dir: Path,
    case: Case,
    train: bytes,
    target: bytes,
    hmm: Any,
    compiled: Compiled,
    k: int,
    mode: str,
    split: str,
) -> dict[str, Any]:
    frame, stats = encode_frame(target, compiled, RESTART)
    frame_path = sample_dir / f"lbel-k{k}-{mode}.lbel"
    decoded_path = sample_dir / f"lbel-k{k}-{mode}.decoded.bin"
    frame_path.write_bytes(frame)
    # First decoder invocation is in-process; second is a fresh process below.
    decoded = decode_frame(frame)
    if decoded != target:
        raise AssertionError("in-process LBEL round trip mismatch")
    decoded_path.write_bytes(decoded)
    external_stdout = sample_dir / f"lbel-k{k}-{mode}.decode.stdout"
    external_stderr = sample_dir / f"lbel-k{k}-{mode}.decode.stderr"
    command = [sys.executable, str(HERE / "decode_verify.py"), str(frame_path), str(decoded_path)]
    result = run_process(command, external_stdout, external_stderr)
    if result.returncode != 0 or decoded_path.read_bytes() != target:
        raise AssertionError(f"independent LBEL decode failed: {result.stderr!r}")
    teacher_bits = teacher_cross_entropy(hmm, target)
    compiled_bits = compiled_cross_entropy(compiled, target)
    teacher_path = sample_dir / f"teacher-k{k}.json"
    if not teacher_path.exists():
        write_teacher(teacher_path, hmm)
    return {
        "case": case.name,
        "split": split,
        "k_teacher": k,
        "k_compiled": compiled.states,
        "clustering": mode,
        "train": record_bytes(case.train_path, train),
        "target": record_bytes(case.dev_path if split == "dev" else case.final_path, target),
        "frame": record_file(frame_path),
        "decoded": record_file(decoded_path),
        "external_decode": {
            "command": command,
            "returncode": result.returncode,
            "stdout": record_file(external_stdout),
            "stderr": record_file(external_stderr),
        },
        "model_table_sha256": model_sha256(compiled),
        "teacher_artifact": record_file(teacher_path),
        "teacher_params_in_frame": False,
        "teacher_cross_entropy_bits": teacher_bits,
        "compiled_cross_entropy_bits": compiled_bits,
        "teacher_cross_entropy_bps": teacher_bits / max(1, len(target)),
        "compiled_cross_entropy_bps": compiled_bits / max(1, len(target)),
        "frame_bytes": stats.total,
        "frame_bits_per_input_byte": 8.0 * stats.total / max(1, len(target)),
        "frame_breakdown": {
            "header": stats.header,
            "tables": stats.tables,
            "restart_records": stats.restarts,
            "payload": stats.payload,
            "checksum": stats.checksum,
            "segments": stats.segments,
            "output": stats.output,
        },
        "frame_sha256": frame_sha256(frame),
        "round_trip": True,
    }


def invalid_fixture() -> bytes:
    return b"\x00\xff\xfe\xc3\x28\xe2\x82\x00\n\r\t" + bytes(range(256)) + "A\u0301\u65e5\u672c".encode("utf-8")


def run_phase(output_root: Path, phase: str, selected_k: int | None, selected_mode: str | None) -> Path:
    if phase not in {"dev", "final"}:
        raise ValueError("phase must be dev or final")
    if phase == "final" and (selected_k not in K_VALUES or selected_mode not in MODES):
        raise ValueError("final requires one explicit frozen --k in {2,4,8} and --mode")
    run_id = f"latent-belief-{phase}-20260926"
    if selected_k is not None:
        run_id += f"-k{selected_k}-{selected_mode}"
    run_dir = output_root / run_id
    if run_dir.exists():
        raise FileExistsError(f"refusing to overwrite {run_dir}")
    run_dir.mkdir(parents=True)

    manifest: dict[str, Any] = {
        "schema": 1,
        "purpose": "Compiled latent-belief HMM screen with complete LBEL frames.",
        "phase": phase,
        "policy": {
            "train_policy": "input-local frozen train slice; teacher absent from frame",
            "old_train_bytes": TRAIN_LIMIT_OLD,
            "ud_train_bytes": TRAIN_LIMIT_UD,
            "old_dev_bytes": DEV_LIMIT_OLD,
            "ud_dev_bytes": DEV_LIMIT_UD,
            "final_bytes": FINAL_LIMIT,
            "restart_interval": RESTART,
            "teacher_states": list(K_VALUES),
            "compiled_states": "equal to teacher state count",
            "clustering_candidates": list(MODES),
            "alphabet": "256 bytes + EOS",
            "range_total": 16384,
            "phase_final_policy": {"k": selected_k, "mode": selected_mode},
        },
        "command": sys.argv,
        "python": sys.version,
        "platform": platform.platform(),
        "cases": [],
    }
    results: list[dict[str, Any]] = []
    for case in cases():
        train = slice_bytes(case.train_path, case.train_start, case.train_length)
        if phase == "dev":
            target = slice_bytes(case.dev_path, case.dev_start, case.dev_length)
        else:
            # The old untouched paths are first read only after the explicit
            # policy argument has been supplied and the dev run is complete.
            target = slice_bytes(case.final_path, case.final_start, case.final_length)
        if not train or not target:
            continue
        case_dir = run_dir / case.name
        case_dir.mkdir(parents=True)
        train_path = case_dir / "train.bin"
        target_path = case_dir / f"{phase}.target.bin"
        train_path.write_bytes(train)
        target_path.write_bytes(target)
        baseline = baseline_v4(case_dir, target_path)
        bzip3 = baseline_bzip3(case_dir, target_path)
        case_result: dict[str, Any] = {
            "case": case.name,
            "phase": phase,
            "train": record_bytes(case.train_path, train),
            "target": record_bytes(case.dev_path if phase == "dev" else case.final_path, target),
            "baseline_v4": baseline,
            "baseline_bzip3": bzip3,
            "candidates": [],
        }
        policy_ks = (selected_k,) if phase == "final" else K_VALUES
        policy_modes = (selected_mode,) if phase == "final" else MODES
        for k in policy_ks:
            assert k is not None
            hmm = train_hmm(train, k, iterations=6)
            for mode in policy_modes:
                assert mode is not None
                compiled = compile_model(hmm, train, k, mode)
                result = candidate_record(case_dir, case, train, target, hmm, compiled, k, mode, phase)
                if baseline.get("storage", {}).get("total"):
                    result["v4_frame_bytes"] = baseline["storage"]["total"]
                    result["v4_frame_ratio"] = result["frame_bytes"] / baseline["storage"]["total"]
                if bzip3.get("storage", {}).get("total"):
                    result["bzip3_frame_bytes"] = bzip3["storage"]["total"]
                    result["bzip3_frame_ratio"] = result["frame_bytes"] / bzip3["storage"]["total"]
                case_result["candidates"].append(result)
                results.append(result)
        manifest["cases"].append(case_result)
        (case_dir / f"{phase}.json").write_text(json.dumps(case_result, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary: dict[str, Any] = {"phase": phase, "cases": len(manifest["cases"]), "candidates": {}}
    for result in results:
        key = f"k{result['k_teacher']}-{result['clustering']}"
        bucket = summary["candidates"].setdefault(key, {"rows": 0, "frame_bytes": 0, "input_bytes": 0, "v4_bytes": 0, "bzip3_bytes": 0, "teacher_bits": 0.0, "compiled_bits": 0.0})
        bucket["rows"] += 1
        bucket["frame_bytes"] += result["frame_bytes"]
        bucket["input_bytes"] += result["frame_breakdown"]["output"]
        bucket["teacher_bits"] += result["teacher_cross_entropy_bits"]
        bucket["compiled_bits"] += result["compiled_cross_entropy_bits"]
        bucket["v4_bytes"] += result.get("v4_frame_bytes", 0)
        bucket["bzip3_bytes"] += result.get("bzip3_frame_bytes", 0)
    for bucket in summary["candidates"].values():
        bucket["frame_bpb"] = 8.0 * bucket["frame_bytes"] / max(1, bucket["input_bytes"])
        bucket["teacher_bpb"] = bucket["teacher_bits"] / max(1, bucket["input_bytes"])
        bucket["compiled_bpb"] = bucket["compiled_bits"] / max(1, bucket["input_bytes"])
        bucket["frame_vs_v4"] = bucket["frame_bytes"] / max(1, bucket["v4_bytes"])
        bucket["frame_vs_bzip3"] = bucket["frame_bytes"] / max(1, bucket["bzip3_bytes"])
    (run_dir / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest["successful_candidates"] = len(results)
    (run_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return run_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("dev", "final"))
    parser.add_argument("--output-root", type=Path, default=HERE / "runs")
    parser.add_argument("--k", type=int, choices=K_VALUES)
    parser.add_argument("--mode", choices=MODES)
    args = parser.parse_args()
    path = run_phase(args.output_root, args.phase, args.k, args.mode)
    print(path)


if __name__ == "__main__":
    main()
