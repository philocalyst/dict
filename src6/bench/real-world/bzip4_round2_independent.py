#!/usr/bin/env python3
"""Independent, lossless capture of the frozen bzip4 round-2 matrix.

The helper deliberately owns the process boundary: it captures bytes and the
actual return code before parsing any runner output, writes those bytes to
per-process files, and never retries or drops a scheduled process.  It does
not read the prior round's field transcription as measurement evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[3]
GATE = "BZIP4-EXPERIMENT-QUIET-GATE"
BINARY = Path("/tmp/bzip4-install/bin/bzip4-experiment")
EXPECTED_BINARY_SHA256 = "a0ff2f567e9eed41f00f0365c7d2a5538f020bd020fd994e420ba0c45436cf8f"
EXPECTED_BINARY_BYTES = 539104
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
BLOCKS = (16384, 65536)
SAMPLES = (1, 2, 3)
TRAINING_BYTES = 1_048_576
EVALUATION_BYTES = 8_388_608

EXPECTED_INPUTS = {
    "freedict-eng-spa": (90_123_314, "687008296b727878d26472bca5315beca8136a64365f2ac819e9e1f7f22f3865"),
    "gcide-054": (123_479_075, "4cddd7f0d23d7ef5dd923ef97b1894f7fff86cc26dbda1a9621653c1338c635b"),
    "omw-ja-20": (229_392_768, "ff9b2f1e56912bf3874cb77377a6f97949206a3efdff7739a10f61e1f0c43c75"),
}

TIME_SUFFIX = "_ns"
REQUIRED_FIELDS = {
    "schema", "timing", "candidate", "input_format", "source_file_bytes", "input_bytes",
    "training_partition_bytes", "held_out_available_bytes", "held_out_evaluated_bytes",
    "block_bytes", "block_count", "dictionary_bytes", "stored_model_bytes", "arithmetic_predictor",
    "header_bytes", "directory_restart_bytes", "bzip4_payload_bytes", "bzip4_total_bytes",
    "raw_framed_total_bytes", "bzip3_controls", "bzip3_matched_payload_bytes", "bzip3_matched_total_bytes",
    "bzip3_64k_payload_bytes", "bzip3_64k_total_bytes", "train_ns", "bzip4_encode_ns",
    "bzip4_decode_all_ns", "bzip3_matched_encode_ns", "bzip3_matched_decode_all_ns",
    "bzip3_retained_setup_ns", "bzip3_retained_encode_ns", "bzip3_retained_decode_all_ns",
    "bzip3_64k_encode_ns", "bzip3_64k_decode_all_ns", "bzip4_random_access_conservative_accounted_bytes",
    "bzip4_decode_all_conservative_accounted_bytes", "bzip3_accounted_scratch_budget",
    "first_block_raw_bytes", "first_block_encoded_bytes", "first_block_warm_access_amplification_milli",
    "first_block_cold_dictionary_access_amplification_milli", "roundtrip",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def file_record(path: Path, *, relative_to: Path | None = REPO) -> dict[str, Any]:
    if not path.is_file():
        raise RuntimeError(f"missing file: {path}")
    display = str(path.relative_to(relative_to)) if relative_to is not None and path.is_relative_to(relative_to) else str(path)
    return {"path": display, "absolute_path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def verify_file(path: Path, expected_bytes: int | None, expected_sha256: str | None, label: str) -> dict[str, Any]:
    record = file_record(path)
    if expected_bytes is not None and record["bytes"] != expected_bytes:
        raise RuntimeError(f"{label} byte count changed: expected {expected_bytes}, got {record['bytes']}")
    if expected_sha256 is not None and record["sha256"] != expected_sha256:
        raise RuntimeError(f"{label} SHA-256 changed: expected {expected_sha256}, got {record['sha256']}")
    return record


def source_records() -> list[dict[str, Any]]:
    paths = [
        *sorted((REPO / "src6" / "experiments" / "bzip4").glob("*.zig")),
        REPO / "src6" / "compression.zig",
        REPO / "vendor" / "bzip3" / "src" / "libbz3.c",
        REPO / "vendor" / "bzip3" / "include" / "libbz3.h",
        REPO / "vendor" / "bzip3" / "include" / "libsais.h",
        REPO / "vendor" / "bzip3" / "include" / "common.h",
    ]
    return [file_record(path) for path in paths]


def parse_runner_stdout(raw: bytes) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    fields: dict[str, Any] = {}
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        return {}, [f"stdout is not strict UTF-8: {exc}"]
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        pieces = line.split("\t")
        if len(pieces) != 2:
            errors.append(f"line {line_number}: expected key<TAB>value")
            continue
        key, value = pieces
        if key in fields:
            errors.append(f"line {line_number}: duplicate field {key}")
            continue
        try:
            fields[key] = int(value, 10)
        except ValueError:
            fields[key] = value
    missing = sorted(REQUIRED_FIELDS - fields.keys())
    if missing:
        errors.append("missing required fields: " + ", ".join(missing))
    return fields, errors


def validate_fields(fields: dict[str, Any], corpus: str, block_bytes: int) -> list[str]:
    errors: list[str] = []
    expected = {
        "schema": "bzip4-experiment-1",
        "timing": "gated-provisional",
        "candidate": "bwt",
        "input_format": "projection_content",
        "training_partition_bytes": TRAINING_BYTES,
        "held_out_evaluated_bytes": EVALUATION_BYTES,
        "block_bytes": block_bytes,
        "dictionary_bytes": 0,
        "stored_model_bytes": 512,
        "arithmetic_predictor": "not-applicable",
        "bzip3_controls": "run",
        "roundtrip": "ok",
    }
    for key, value in expected.items():
        if fields.get(key) != value:
            errors.append(f"{key}: expected {value!r}, got {fields.get(key)!r}")
    expected_blocks = (EVALUATION_BYTES + block_bytes - 1) // block_bytes
    if fields.get("block_count") != expected_blocks:
        errors.append(f"block_count: expected {expected_blocks}, got {fields.get('block_count')!r}")
    for key, value in fields.items():
        if key.endswith(TIME_SUFFIX) and (not isinstance(value, int) or value < 0):
            errors.append(f"{key}: expected nonnegative integer, got {value!r}")
    for key in ("bzip4_payload_bytes", "bzip4_total_bytes", "bzip3_matched_total_bytes", "bzip3_64k_total_bytes"):
        if not isinstance(fields.get(key), int) or fields[key] <= 0:
            errors.append(f"{key}: expected positive integer, got {fields.get(key)!r}")
    framing = fields.get("header_bytes", 0) + fields.get("stored_model_bytes", 0) + fields.get("directory_restart_bytes", 0) + fields.get("bzip4_payload_bytes", 0)
    if fields.get("bzip4_total_bytes") != framing:
        errors.append(f"bzip4_total_bytes framing mismatch: expected {framing}, got {fields.get('bzip4_total_bytes')!r}")
    if fields.get("held_out_available_bytes", 0) < EVALUATION_BYTES:
        errors.append(f"{corpus}: held-out input is shorter than evaluation prefix")
    return errors


def deterministic_projection(fields: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in fields.items() if not key.endswith(TIME_SUFFIX)}


def run_one(binary: Path, corpus: str, block_bytes: int, sample: int, raw_root: Path) -> dict[str, Any]:
    input_path = REPO / "src6" / "bench" / "real-world" / "evidence" / "corpora" / corpus / "projection.tsv"
    label = f"{corpus}-{block_bytes}-{sample}"
    stem = raw_root / label
    argv = [
        str(binary),
        "--input", str(input_path.relative_to(REPO)),
        "--input-format", "projection_content",
        "--candidate", "bwt",
        "--training-bytes", str(TRAINING_BYTES),
        "--max-eval-bytes", str(EVALUATION_BYTES),
        "--block-bytes", str(block_bytes),
        "--measure",
        "--quiet-gate", GATE,
    ]
    started = time.perf_counter_ns()
    timeout_error: str | None = None
    try:
        completed = subprocess.run(
            argv,
            cwd=REPO,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
            timeout=600,
        )
        stdout = completed.stdout
        stderr = completed.stderr
        returncode: int | None = completed.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, bytes) else (exc.stdout or "").encode("utf-8", "replace")
        stderr = exc.stderr if isinstance(exc.stderr, bytes) else (exc.stderr or "").encode("utf-8", "replace")
        returncode = None
        timeout_error = "TimeoutExpired(600s)"
    except OSError as exc:
        stdout = b""
        stderr = str(exc).encode("utf-8", "replace")
        returncode = None
        timeout_error = f"{type(exc).__name__}: {exc}"

    stdout_path = stem.with_name(stem.name + ".stdout.bin")
    stderr_path = stem.with_name(stem.name + ".stderr.bin")
    stdout_path.write_bytes(stdout)
    stderr_path.write_bytes(stderr)

    fields, parse_errors = parse_runner_stdout(stdout)
    errors = list(parse_errors)
    if timeout_error is not None:
        errors.append(timeout_error)
    if returncode != 0:
        errors.append(f"process returncode: {returncode}")
    errors.extend(validate_fields(fields, corpus, block_bytes))
    return {
        "corpus": corpus,
        "block_bytes": block_bytes,
        "sample": sample,
        "argv": argv,
        "cwd": str(REPO),
        "returncode": returncode,
        "harness_wall_ns": time.perf_counter_ns() - started,
        "stdout": {"path": str(stdout_path.relative_to(REPO)), "bytes": len(stdout), "sha256": sha256_bytes(stdout)},
        "stderr": {"path": str(stderr_path.relative_to(REPO)), "bytes": len(stderr), "sha256": sha256_bytes(stderr)},
        "fields": fields,
        "validation_errors": errors,
        "status": "ok" if not errors else "failed",
    }


def median_field(runs: list[dict[str, Any]], key: str) -> int | None:
    values = [run["fields"].get(key) for run in runs if run.get("status") == "ok" and isinstance(run["fields"].get(key), int)]
    return int(statistics.median(values)) if len(values) == len(runs) and values else None


def render_report(result: dict[str, Any], output_path: Path, json_path: Path) -> str:
    lines = [
        "# Independent bzip4 round-2 BWT validation",
        "",
        f"Status: `{result['status']}`; scheduled processes: **{len(result['runs'])}/18**; failures: **{len(result['failures'])}**.",
        "",
        "This is an independent, lossless subprocess capture of the frozen protocol. It does not use the prior field transcription as evidence. Each scheduled process's exact stdout/stderr bytes and actual return code were saved before parsing; no process was selected, discarded, or rerun.",
        "",
        f"Ledger: `{json_path.relative_to(REPO)}`; report: `{output_path.relative_to(REPO)}`.",
        "",
        "## Matrix results",
        "",
        "| corpus | block | samples | BWT total bytes | matched bzip3 total | BWT encode median (ns) | BWT decode median (ns) | matched bzip3 decode median (ns) | retained bzip3 decode median (ns) | 64 KiB bzip3 decode median (ns) | deterministic |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for corpus in CORPORA:
        for block in BLOCKS:
            lane = [run for run in result["runs"] if run["corpus"] == corpus and run["block_bytes"] == block]
            totals = {run["fields"].get("bzip4_total_bytes") for run in lane if run.get("status") == "ok"}
            deterministic = len(lane) == 3 and all(run.get("status") == "ok" for run in lane) and len(totals) == 1
            values = [median_field(lane, key) for key in ("bzip4_encode_ns", "bzip4_decode_all_ns", "bzip3_matched_decode_all_ns", "bzip3_retained_decode_all_ns", "bzip3_64k_decode_all_ns")]
            bwt_total = next(iter(totals), None) if deterministic else None
            bzip3_total = lane[0]["fields"].get("bzip3_matched_total_bytes") if deterministic else None
            lines.append(
                f"| {corpus} | {block} | {len(lane)}/3 | {bwt_total if bwt_total is not None else '—'} | {bzip3_total if bzip3_total is not None else '—'} | "
                + " | ".join(str(value) if value is not None else "—" for value in values)
                + f" | {'yes' if deterministic else 'no'} |"
            )
    lines.extend([
        "",
        "The byte columns are deterministic encoded-size outputs from the runner; timing columns are medians of exactly the three designated samples only when all three passed. BWT total includes its 40-byte header, 512-byte model, restart directory, and payload.",
        "",
        "## Frozen provenance",
        "",
        f"- Binary pre-run: `{result['binary_pre']['sha256']}` ({result['binary_pre']['bytes']} bytes).",
        f"- Binary post-run: `{result['binary_post']['sha256']}` ({result['binary_post']['bytes']} bytes); unchanged: `{result['binary_pre']['sha256'] == result['binary_post']['sha256']}`.",
        f"- Protocol SHA-256: `{result['protocol']['sha256']}`; round-2 hash ledger SHA-256: `{result['round2_hashes']['sha256']}`.",
        "- Training partition: 1,048,576 decoded normalized-content bytes; held-out evaluation prefix: 8,388,608 bytes.",
        "- Controls: matched bzip3 at each requested boundary, retained-state bzip3 at each requested boundary, and production bzip3 at 64 KiB; all are emitted by the runner and validated as present.",
        "- Fresh process does not imply cold OS cache; no cache eviction was attempted.",
        "",
        "## Captured output files",
        "",
        f"Raw stdout/stderr files are under `{result['raw_root']}`. Their byte counts and SHA-256 values are recorded per run in the JSON ledger. The prior transcription is neither read nor copied into this result.",
    ])
    if result["failures"]:
        lines.extend(["", "## Failures", "", "```json", json.dumps(result["failures"], indent=2), "```"])
    return "\n".join(lines) + "\n"


def main(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    raw_root = args.raw_root.resolve()
    if output.exists() or raw_root.exists() and any(raw_root.iterdir()):
        print(f"refusing to overwrite existing independent evidence: {output} or {raw_root}", file=sys.stderr)
        return 2
    binary = args.binary.resolve()
    try:
        binary_pre = verify_file(binary, EXPECTED_BINARY_BYTES, EXPECTED_BINARY_SHA256, "frozen runner binary")
        protocol = verify_file(REPO / "src6" / "experiments" / "bzip4" / "results" / "round2-protocol.txt", None, None, "round2 protocol")
        round2_hashes = verify_file(REPO / "src6" / "experiments" / "bzip4" / "results" / "round2-hashes.tsv", None, None, "round2 hash ledger")
        sources = source_records()
        inputs: dict[str, dict[str, Any]] = {}
        for corpus in CORPORA:
            path = REPO / "src6" / "bench" / "real-world" / "evidence" / "corpora" / corpus / "projection.tsv"
            expected_bytes, expected_sha256 = EXPECTED_INPUTS[corpus]
            inputs[corpus] = verify_file(path, expected_bytes, expected_sha256, f"{corpus} projection")
    except (OSError, RuntimeError) as exc:
        print(f"bzip4_round2_independent.py: preflight failed before timing: {exc}", file=sys.stderr)
        return 2

    raw_root.mkdir(parents=True, exist_ok=False)
    result: dict[str, Any] = {
        "schema": 1,
        "status": "bzip4-round2-independent-results",
        "timing": "gated-provisional",
        "gate": GATE,
        "schedule": {
            "corpora": list(CORPORA),
            "block_bytes": list(BLOCKS),
            "samples": list(SAMPLES),
            "order": "corpus, block size, sample; serial",
            "processes": 18,
            "retries": 0,
            "os_cache": "not forcibly evicted; fresh process is not cold disk",
        },
        "platform": platform.platform(),
        "binary_pre": binary_pre,
        "protocol": protocol,
        "round2_hashes": round2_hashes,
        "sources": sources,
        "inputs": inputs,
        "raw_root": str(raw_root.relative_to(REPO)),
        "runs": [],
        "failures": [],
    }

    for corpus in CORPORA:
        for block_bytes in BLOCKS:
            for sample in SAMPLES:
                run = run_one(binary, corpus, block_bytes, sample, raw_root)
                result["runs"].append(run)
                if run["status"] != "ok":
                    result["failures"].append({"corpus": corpus, "block_bytes": block_bytes, "sample": sample, "errors": run["validation_errors"]})

    binary_post = file_record(binary)
    result["binary_post"] = binary_post
    if binary_post["sha256"] != binary_pre["sha256"] or binary_post["bytes"] != binary_pre["bytes"]:
        result["failures"].append({"scope": "binary-post-run", "error": "frozen binary changed during matrix"})

    for corpus in CORPORA:
        for block_bytes in BLOCKS:
            lane = [run for run in result["runs"] if run["corpus"] == corpus and run["block_bytes"] == block_bytes]
            projections = [deterministic_projection(run["fields"]) for run in lane if run["status"] == "ok"]
            if len(projections) == 3 and any(projection != projections[0] for projection in projections[1:]):
                result["failures"].append({"corpus": corpus, "block_bytes": block_bytes, "error": "deterministic encoded/control fields differ across samples"})
    if result["failures"]:
        result["status"] = "bzip4-round2-independent-results-with-failures"

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(render_report(result, report_path, output), encoding="utf-8")
    print(json.dumps({"status": result["status"], "runs": len(result["runs"]), "failures": len(result["failures"]), "output": str(output), "report": str(report_path)}, indent=2))
    return 0 if not result["failures"] else 2


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet-gate", required=True)
    parser.add_argument("--binary", type=Path, default=BINARY)
    parser.add_argument("--raw-root", type=Path, default=ROOT / "evidence" / "runs" / "bzip4-round2-independent" / "raw")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "bzip4-round2-independent.json")
    parser.add_argument("--report", type=Path, default=ROOT / "evidence" / "reports" / "bzip4-round2-independent.md")
    return parser.parse_args(argv)


if __name__ == "__main__":
    args = parse_args()
    if args.quiet_gate != GATE:
        print(f"bzip4_round2_independent.py: refusing timing: expected literal {GATE!r}", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(args))
