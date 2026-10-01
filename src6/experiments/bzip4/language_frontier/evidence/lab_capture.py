#!/usr/bin/env python3
"""Replicate the three published m_* lab scores with ``--stats``.

This is a storage capture, not a timing benchmark.  Each invocation is
serial (``--workers 1``), and the raw lab stderr is retained verbatim because
the v3 lab prints timing diagnostics there.  The JSON summary parses only
frame byte fields and the per-stream ``bytes=`` counters from ``--stats``.
The timing fields are deliberately not copied into the reported storage
record.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
BZ4 = HERE.parents[1] / "bz4"
V3 = BZ4 / "v3"
DATA = BZ4 / "data"
DUMPS = BZ4 / "dumps"
LAB = V3 / "zig-out/bin/lab"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    return {
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def parse_final_line(raw: bytes) -> tuple[dict[str, str], str]:
    """Return the final frame fields and preserve the exact line."""

    text = raw.decode("utf-8", "strict")
    candidates = [line for line in text.splitlines() if "\tclasses=" in line and "\ttotal=" in line]
    if len(candidates) != 1:
        raise ValueError(f"expected one final storage line, got {len(candidates)}")
    line = candidates[0]
    fields: dict[str, str] = {}
    for field in line.split("\t"):
        key, sep, value = field.partition("=")
        if not sep:
            continue
        if key in fields:
            raise ValueError(f"duplicate final field {key!r}")
        fields[key] = value
    required = {"classes", "total", "header", "delta", "payload", "framing", "buckets", "blocks"}
    if not required <= fields.keys():
        raise ValueError(f"missing final fields: {sorted(required - fields.keys())}")
    return fields, line


STATS_RE = re.compile(
    r"^\s*(delta|payload)\s+(\S+)\s+events=\s*(\d+)\s+"
    r"coded=\s*([^ ]+)\s+raw=\s*([^ ]+)\s+bits/event\s+bytes=([0-9.]+)\s*$"
)


def parse_stats(raw: bytes) -> list[dict[str, Any]]:
    """Parse only event counts and byte totals; ignore timing diagnostics."""

    text = raw.decode("utf-8", "strict")
    rows: list[dict[str, Any]] = []
    for line in text.splitlines():
        match = STATS_RE.match(line)
        if match is None:
            continue
        stream, kind, events, coded, raw_bits, bytes_text = match.groups()
        rows.append(
            {
                "stream": stream,
                "kind": kind,
                "events": int(events),
                "coded_bits_per_event": float(coded),
                "raw_bits_per_event": float(raw_bits),
                "bytes": float(bytes_text),
            }
        )
    if not rows:
        raise ValueError("--stats emitted no delta/payload rows")
    return rows


def targets() -> list[tuple[str, Path, Path]]:
    return [
        (
            name,
            DATA / f"{name}.eval8.bin",
            DUMPS / f"m_{name}.eval8.65536.b4sd",
        )
        for name in ("freedict", "gcide", "omw")
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True, help="new run directory; existing runs are never overwritten")
    parser.add_argument(
        "--classes",
        type=int,
        default=None,
        help="fixed class count; omit for the current plan.fit auto-search",
    )
    parser.add_argument("--output-root", type=Path, default=HERE / "runs")
    args = parser.parse_args()

    if not LAB.is_file():
        raise SystemExit(f"missing current v3 lab binary: {LAB}")
    run_dir = args.output_root / args.run_id
    if run_dir.exists():
        raise SystemExit(f"refusing to overwrite existing run: {run_dir}")
    run_dir.mkdir(parents=True)

    samples: list[dict[str, Any]] = []
    for name, data, dump in targets():
        stdout_path = run_dir / f"{name}.stdout"
        stderr_path = run_dir / f"{name}.stderr"
        command = [str(LAB), str(data), str(dump), "--workers", "1", "--stats"]
        if args.classes is not None:
            command += ["--classes", str(args.classes)]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        stdout_path.write_bytes(result.stdout)
        stderr_path.write_bytes(result.stderr)
        sample: dict[str, Any] = {
            "name": name,
            "codec": "bzip4-v4-lab",
            "class_policy": "fixed" if args.classes is not None else "plan.fit_auto",
            "input": file_record(data),
            "dump": file_record(dump),
            "binary": file_record(LAB),
            "command": command,
            "returncode": result.returncode,
            "stdout": file_record(stdout_path),
            "stderr": file_record(stderr_path),
        }
        if result.returncode == 0:
            try:
                fields, exact_line = parse_final_line(result.stderr)
                storage_keys = ("classes", "total", "header", "delta", "payload", "framing", "buckets", "blocks")
                sample["storage"] = {key: int(fields[key]) for key in storage_keys}
                sample["storage_line"] = exact_line
                sample["stats"] = parse_stats(result.stderr)
                sample["ok"] = True
            except (ValueError, UnicodeDecodeError) as exc:
                sample["parse_error"] = str(exc)
                sample["ok"] = False
        else:
            sample["ok"] = False
        samples.append(sample)
        print(f"{name}: ok={sample['ok']}", flush=True)

    (run_dir / "samples.json").write_text(
        json.dumps(samples, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    manifest = {
        "schema": 1,
        "purpose": "Fresh serial replication of the three strongest saved m_* parses with v3 lab --stats.",
        "run_id": args.run_id,
        "class_policy": "fixed class count" if args.classes is not None else "classes omitted: current plan.fit auto-search",
        "command_policy": "one lab process at a time; --workers 1; --stats included",
        "timing_policy": "raw lab stderr is retained, but timing fields are not parsed or reported as evidence",
        "storage_policy": "report complete frame header/delta/payload/framing and --stats event/byte counters",
        "binary": file_record(LAB),
        "sample_count": len(samples),
        "successful_samples": sum(bool(sample["ok"]) for sample in samples),
    }
    (run_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(run_dir)


if __name__ == "__main__":
    main()
