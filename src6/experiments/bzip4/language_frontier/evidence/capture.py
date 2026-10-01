#!/usr/bin/env python3
"""Run bounded, storage-only Bzip4 v4 baseline captures.

The driver is intentionally serial.  It does not read a clock, does not run
parallel decode workers, and never picks a best result after observing sizes.
Each candidate frame is checked by the Zig driver and then decoded again by a
separate ``bz4 d`` process.  Raw subprocess bytes are persisted before any
field parsing so a failure remains auditable.
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
CAPTURE = HERE / "bin/capture_frame"
BZ4_BIN = V3 / "zig-out/bin/bz4"
BZ3_BIN = BZ4 / "bin/bz3base"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": sha256(path)}


def parse_fields(raw: bytes, *, tag: str) -> dict[str, str]:
    text = raw.decode("utf-8", "strict")
    lines = [line for line in text.splitlines() if line.startswith(tag)]
    if len(lines) != 1:
        raise ValueError(f"expected one {tag!r} line, got {len(lines)}")
    fields: dict[str, str] = {}
    for field in lines[0].split("\t")[1:]:
        key, sep, value = field.partition("=")
        if not sep or key in fields:
            raise ValueError(f"malformed or duplicate field {field!r}")
        fields[key] = value
    return fields


def run(argv: list[str], *, stdout: Path, stderr: Path) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    stdout.write_bytes(result.stdout)
    stderr.write_bytes(result.stderr)
    return result


def check_external_decode(
    sample_dir: Path,
    frame: Path,
    source: Path,
    *,
    sample_id: str,
) -> dict[str, Any]:
    decoded = sample_dir / "external-decoded.bin"
    stdout = sample_dir / f"{sample_id}.decode.stdout"
    stderr = sample_dir / f"{sample_id}.decode.stderr"
    result = run([str(BZ4_BIN), "d", str(frame), str(decoded), "1"], stdout=stdout, stderr=stderr)
    out: dict[str, Any] = {
        "command": [str(BZ4_BIN), "d", str(frame), str(decoded), "1"],
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
    }
    if decoded.is_file():
        out["output"] = file_record(decoded)
        out["exact_hash"] = (
            result.returncode == 0
            and decoded.stat().st_size == source.stat().st_size
            and sha256(decoded) == sha256(source)
        )
    else:
        out["exact_hash"] = False
    return out


def capture_v4(
    run_dir: Path,
    sample_id: str,
    source: Path,
    *,
    dump: Path | None,
    block_bytes: int,
    classes: int,
) -> dict[str, Any]:
    sample_dir = run_dir / "samples" / sample_id
    sample_dir.mkdir(parents=True)
    frame = sample_dir / "frame.b4"
    stdout = sample_dir / "encode.stdout"
    stderr = sample_dir / "encode.stderr"
    if dump is None:
        command = [str(CAPTURE), "raw", str(source), str(frame), str(block_bytes)]
        kind = "end_to_end"
    else:
        command = [str(CAPTURE), "saved", str(source), str(dump), str(frame), str(classes)]
        kind = "saved_parse"
    result = run(command, stdout=stdout, stderr=stderr)
    sample: dict[str, Any] = {
        "id": sample_id,
        "codec": "bzip4-v4",
        "kind": kind,
        "block_bytes": block_bytes,
        "classes_requested": classes if dump is not None else None,
        "input": file_record(source),
        "dump": file_record(dump) if dump is not None else None,
        "binary": file_record(CAPTURE),
        "command": command,
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
    }
    ok = result.returncode == 0 and frame.is_file()
    if frame.is_file():
        sample["frame"] = file_record(frame)
    if ok:
        try:
            fields = parse_fields(result.stderr, tag="ok")
            sample["storage"] = {key: int(value) for key, value in fields.items() if key in {
                "classes", "block_bytes", "total", "header", "delta", "payload", "framing", "blocks", "raw_len"
            }}
            if sample["storage"]["total"] != frame.stat().st_size:
                raise ValueError("driver total does not match frame length")
        except (ValueError, UnicodeDecodeError, KeyError) as exc:
            sample["parse_error"] = str(exc)
            ok = False
    if frame.is_file():
        sample["external_decode"] = check_external_decode(sample_dir, frame, source, sample_id=sample_id)
        ok = ok and bool(sample["external_decode"]["exact_hash"])
    sample["ok"] = ok
    return sample


def capture_bzip3(run_dir: Path, sample_id: str, source: Path, *, block_bytes: int) -> dict[str, Any]:
    sample_dir = run_dir / "samples" / sample_id
    sample_dir.mkdir(parents=True)
    stdout = sample_dir / "control.stdout"
    stderr = sample_dir / "control.stderr"
    command = [str(BZ3_BIN), str(source), str(block_bytes), "1"]
    result = run(command, stdout=stdout, stderr=stderr)
    sample: dict[str, Any] = {
        "id": sample_id,
        "codec": "bzip3-control",
        "kind": "matched_block_control",
        "block_bytes": block_bytes,
        "input": file_record(source),
        "binary": file_record(BZ3_BIN),
        "command": command,
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
    }
    ok = result.returncode == 0
    if ok:
        try:
            # file, block, block_count, payload, total, then timing fields.
            fields = result.stdout.decode("utf-8", "strict").strip().split("\t")
            if len(fields) < 5:
                raise ValueError("short bzip3 line")
            sample["storage"] = {
                "input_name": fields[0],
                "block_bytes": int(fields[1]),
                "blocks": int(fields[2]),
                "payload": int(fields[3]),
                "total": int(fields[4]),
            }
            if sample["storage"]["block_bytes"] != block_bytes:
                raise ValueError("bzip3 block size mismatch")
        except (ValueError, UnicodeDecodeError, IndexError) as exc:
            sample["parse_error"] = str(exc)
            ok = False
    sample["ok"] = ok
    return sample


def workload_sources() -> list[tuple[str, Path, Path | None]]:
    sources: list[tuple[str, Path, Path | None]] = []
    for name in ("freedict", "gcide", "omw"):
        source = DATA / f"{name}.eval8.bin"
        dump = DUMPS / f"m_{name}.eval8.65536.b4sd"
        sources.append((f"{name}-eval8-saved", source, dump))
        sources.append((f"{name}-eval8-end-to-end", source, None))
    for corpus in ("ud-fi-test", "ud-tr-test", "ud-ar-test"):
        directory = HERE / "corpora" / corpus
        for workload in ("form", "text"):
            sources.append((f"{corpus}-{workload}", directory / f"{workload}.txt", None))
    return sources


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True, help="new run directory name; existing runs are never overwritten")
    parser.add_argument("--block-bytes", type=int, default=65536)
    parser.add_argument("--classes", type=int, default=0, help="saved-parse classes; 0 uses current auto-fit search")
    parser.add_argument("--output-root", type=Path, default=HERE / "runs")
    args = parser.parse_args()
    if not CAPTURE.is_file() or not BZ4_BIN.is_file() or not BZ3_BIN.is_file():
        raise SystemExit("missing capture_frame, v3 bz4, or bzip3 binary; build/check inventory first")
    run_dir = args.output_root / args.run_id
    if run_dir.exists():
        raise SystemExit(f"refusing to overwrite existing run: {run_dir}")
    run_dir.mkdir(parents=True)

    samples: list[dict[str, Any]] = []
    for source_id, source, dump in workload_sources():
        sample = capture_v4(
            run_dir,
            source_id,
            source,
            dump=dump,
            block_bytes=args.block_bytes,
            classes=args.classes,
        )
        samples.append(sample)
        print(f"{source_id}: v4 ok={sample['ok']}", flush=True)
        control = capture_bzip3(run_dir, f"{source_id}-bzip3", source, block_bytes=args.block_bytes)
        samples.append(control)
        print(f"{source_id}: bzip3 ok={control['ok']}", flush=True)

    (run_dir / "samples.json").write_text(json.dumps(samples, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary: list[dict[str, Any]] = []
    for source_id, _, _ in workload_sources():
        pair = [sample for sample in samples if sample["id"] in {source_id, f"{source_id}-bzip3"}]
        summary.append({
            "source": source_id,
            "ok": all(bool(sample["ok"]) for sample in pair),
            "v4": next((sample for sample in pair if sample["codec"] == "bzip4-v4"), None),
            "bzip3": next((sample for sample in pair if sample["codec"] == "bzip3-control"), None),
        })
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest = {
        "schema": 1,
        "purpose": "Storage-only Bzip4 v4 baseline screen; no timing claims.",
        "run_id": args.run_id,
        "block_bytes": args.block_bytes,
        "classes_policy": "saved parses use plan.fit auto-search when classes=0; fixed classes are explicit separate runs.",
        "decoder_policy": "one in-process serial decode plus one external bz4 d process, exact input hash comparison.",
        "timing_policy": "no clocks read by this harness; bzip3 raw output timing fields retained but ignored.",
        "binaries": {
            "capture_frame": file_record(CAPTURE),
            "bz4": file_record(BZ4_BIN),
            "bz3base": file_record(BZ3_BIN),
        },
        "sample_count": len(samples),
        "successful_samples": sum(bool(sample["ok"]) for sample in samples),
    }
    (run_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if not all(bool(sample["ok"]) for sample in samples):
        raise SystemExit("one or more storage captures failed; inspect samples.json and raw subprocess files")
    print(run_dir)


if __name__ == "__main__":
    main()
