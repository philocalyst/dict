#!/usr/bin/env python3
"""Materialize exact 64 KiB candidate inputs and matched bzip3 controls.

This preflight intentionally does not import or run the weighted-emission
candidate.  It freezes the seven development prefixes and, when no exact
input-hash control already exists, runs the retained bzip3 baseline once per
prefix.  Raw bzip3 output is retained, but timing fields are ignored.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
BZ4 = HERE.parents[1] / "bz4"
DATA = BZ4 / "data"
BZ3_BIN = BZ4 / "bin/bz3base"
PREFIX_BYTES = 65536


SOURCES = [
    ("web2", Path("/usr/share/dict/web2")),
    ("freedict-eval8", DATA / "freedict.eval8.bin"),
    ("gcide-eval8", DATA / "gcide.eval8.bin"),
    ("omw-eval8", DATA / "omw.eval8.bin"),
    ("ud-fi-test-form", HERE / "corpora/ud-fi-test/form.txt"),
    ("ud-tr-test-form", HERE / "corpora/ud-tr-test/form.txt"),
    ("ud-ar-test-form", HERE / "corpora/ud-ar-test/form.txt"),
]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": sha256(path)}


def parse_bzip3(raw: bytes) -> dict[str, Any]:
    fields = raw.decode("utf-8", "strict").strip().split("\t")
    if len(fields) < 5:
        raise ValueError("short bzip3 output")
    return {
        "input_name": fields[0],
        "block_bytes": int(fields[1]),
        "blocks": int(fields[2]),
        "payload": int(fields[3]),
        "total": int(fields[4]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output-root", type=Path, default=HERE / "runs")
    args = parser.parse_args()
    if not BZ3_BIN.is_file():
        raise SystemExit(f"missing bzip3 control binary: {BZ3_BIN}")
    run_dir = args.output_root / args.run_id
    if run_dir.exists():
        raise SystemExit(f"refusing to overwrite existing run: {run_dir}")
    input_dir = run_dir / "inputs"
    baseline_dir = run_dir / "bzip3"
    input_dir.mkdir(parents=True)
    baseline_dir.mkdir()

    rows: list[dict[str, Any]] = []
    for name, source in SOURCES:
        if not source.is_file():
            raise SystemExit(f"missing source: {source}")
        source_bytes = source.read_bytes()
        if len(source_bytes) < PREFIX_BYTES:
            raise SystemExit(f"source shorter than 64 KiB: {source}")
        prefix = source_bytes[:PREFIX_BYTES]
        prefix_path = input_dir / f"{name}.prefix65536.bin"
        prefix_path.write_bytes(prefix)
        stdout_path = baseline_dir / f"{name}.stdout"
        stderr_path = baseline_dir / f"{name}.stderr"
        command = [str(BZ3_BIN), str(prefix_path), str(PREFIX_BYTES), "1"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        stdout_path.write_bytes(result.stdout)
        stderr_path.write_bytes(result.stderr)
        row: dict[str, Any] = {
            "name": name,
            "kind": "development_prefix65536",
            "source": {"path": str(source.resolve()), "bytes": len(source_bytes), "sha256": sha256_bytes(source_bytes)},
            "prefix": file_record(prefix_path),
            "prefix_rule": "first 65536 bytes exactly; no normalization",
            "bzip3_binary": file_record(BZ3_BIN),
            "command": command,
            "returncode": result.returncode,
            "stdout": file_record(stdout_path),
            "stderr": file_record(stderr_path),
        }
        if result.returncode == 0:
            try:
                control = parse_bzip3(result.stdout)
                if control["block_bytes"] != PREFIX_BYTES:
                    raise ValueError("control block size mismatch")
                row["bzip3"] = control
                row["ok"] = True
            except (UnicodeDecodeError, ValueError) as exc:
                row["parse_error"] = str(exc)
                row["ok"] = False
        else:
            row["ok"] = False
        rows.append(row)
        print(f"{name}: ok={row['ok']}", flush=True)

    manifest = {
        "schema": 1,
        "purpose": "Exact 64 KiB development-prefix preflight for weighted-emission candidate screen.",
        "run_id": args.run_id,
        "input_policy": "seven exact first-65536-byte prefixes; same bytes must feed MAP, marginal, and bzip3 controls",
        "candidate_policy_frozen": {
            "max_piece": 8,
            "min_occ": 2,
            "max_vocab": 256,
            "em_rounds": 2,
            "modes": ["map", "marginal"],
        },
        "confirmation_policy": "TRAIN confirmation-20 resources are not listed, read, or benchmarked by this run.",
        "timing_policy": "No harness clocks; bzip3 raw timing fields are retained but ignored.",
        "bzip3_binary": file_record(BZ3_BIN),
        "sample_count": len(rows),
        "successful_samples": sum(bool(row["ok"]) for row in rows),
    }
    (run_dir / "samples.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if not all(bool(row["ok"]) for row in rows):
        raise SystemExit("one or more bzip3 preflight controls failed")
    print(run_dir)


if __name__ == "__main__":
    main()
