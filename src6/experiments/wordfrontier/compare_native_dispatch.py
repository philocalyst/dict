#!/usr/bin/env python3
"""Paired full-command latency: original Python adapter versus native dispatch.

Both commands decode the same frozen frame and publish the same exact source.
This measures reader command overhead, not a change to entropy/grammar decoding.
Run only in a coordinated quiet window; source/output hashing is outside clocks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
GATE = "WORD-FRONTIER-DISPATCH-QUIET"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def environment() -> dict:
    paths = ("/proc/sys/kernel/random/boot_id", "/sys/fs/cgroup/cpu.max",
             "/sys/fs/cgroup/memory.max")
    return {"platform": platform.platform(), "python": platform.python_version(),
            "runtime": {name: Path(name).read_text().strip()
                        for name in paths if Path(name).is_file()}}


def run(command: list[str], output: Path, expected: str, size: int) -> dict:
    output.unlink(missing_ok=True)
    began = time.perf_counter_ns()
    result = subprocess.run(command, capture_output=True, check=True)
    wall = time.perf_counter_ns() - began
    # Integrity checking is identical and outside the full-command clock.
    if output.stat().st_size != size or digest(output) != expected:
        raise ValueError("source output differs from the frozen oracle")
    event = json.loads(result.stdout)
    if not isinstance(event, dict):
        raise ValueError("reader did not return its JSON event")
    return {"wall_ns": wall, "full_source_exact": True,
            "output_bytes": size, "native_or_adapter_event": event}


def compare(binary: Path, reference: Path, backend: Path) -> dict:
    before_env = environment()
    reference_hash = digest(reference)
    original = json.loads(reference.read_bytes())
    lanes = {row["corpus"]["name"]: row["corpus"]
             for row in original["storage"]["per_lane"]}
    cells = [row for row in original["storage"]["cells"]
             if row["candidate"] == "wordfrontier-quality"]
    if len(cells) != len(lanes) or len({r["corpus"] for r in cells}) != len(cells):
        raise ValueError("quality matrix has missing or duplicate lanes")
    paths = {binary, HERE / "wordfrontier.py", Path(__file__).resolve()}
    # Adapter readers, included source dependencies and linked static library
    # are separate provenance from the standalone executable's SHA-256.
    gate = json.loads((HERE / "evidence/native-dispatch-gate-20261001.json").read_bytes())
    if digest(binary) != gate["binary_sha256"]:
        raise ValueError("native executable differs from the full dispatch gate")
    for name, record in gate["reader_dependencies"].items():
        path = HERE.parents[2] / name
        if digest(path) != record["sha256"]:
            raise ValueError("gated reader source or library changed")
        paths.add(path)
    from wordfrontier import dependency_paths
    for family in ("WPG2", "GWT1"):
        paths.update(dependency_paths(backend, "decode", family))
    hashes = {str(p): digest(p) for p in sorted(paths)}
    records = []
    with tempfile.TemporaryDirectory(prefix="wordfrontier-dispatch-pairs-") as name:
        temporary = Path(name)
        for row in sorted(cells, key=lambda r: r["corpus"]):
            frame = Path(row["frame_path"])
            source = Path(lanes[row["corpus"]]["path"])
            if digest(frame) != row["frame_sha256"] or digest(source) != row["source_sha256"]:
                raise ValueError("frozen source/frame changed")
            out = {"adapter": temporary / "adapter.raw", "native": temporary / "native.raw"}
            commands = {
                "adapter": [sys.executable, str(HERE / "wordfrontier.py"), "decode",
                            str(frame), str(out["adapter"]), "--backend-dir", str(backend)],
                "native": [str(binary), "decode", str(frame), str(out["native"])],
            }
            samples = []
            for trial in range(6):
                order = ["adapter", "native"] if trial % 2 == 0 else ["native", "adapter"]
                pair = {kind: run(commands[kind], out[kind], row["source_sha256"], source.stat().st_size)
                        for kind in order}
                samples.append({"trial": trial, "warmup": trial == 0, "order": order,
                                "samples": pair,
                                "native_speedup": pair["adapter"]["wall_ns"] / pair["native"]["wall_ns"]})
            measured = samples[1:]
            records.append({"corpus": row["corpus"], "source_bytes": source.stat().st_size,
                            "source_sha256": row["source_sha256"], "frame_bytes": frame.stat().st_size,
                            "frame_sha256": row["frame_sha256"], "samples": samples,
                            "median_paired_native_speedup": statistics.median(s["native_speedup"] for s in measured),
                            "median_adapter_wall_ns": statistics.median(s["samples"]["adapter"]["wall_ns"] for s in measured),
                            "median_native_wall_ns": statistics.median(s["samples"]["native"]["wall_ns"] for s in measured)})
    for name, expected in hashes.items():
        if digest(Path(name)) != expected:
            raise ValueError("reader dependency changed during comparison")
    if digest(reference) != reference_hash or environment() != before_env:
        raise ValueError("reference/runtime changed during comparison")
    return {"protocol": "WORD-FRONTIER-NATIVE-DISPATCH-PAIRED/1", "status": "complete",
            "scope": "fresh full-command wall: file read, preparation, unchanged native full decode, publication; adapter also pays Python startup, dependency hashing and child dispatch",
            "limitations": "resident filesystem after warmup; no cold-cache claim; no entropy-kernel improvement; comparisons are within this new runtime, not historical-clock cross-boot ratios",
            "environment": before_env, "reference_sha256": reference_hash,
            "dependency_sha256": hashes, "warmups_per_lane": 1, "paired_trials": 5,
            "operations": len(records) * 12, "records": records}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("reference", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--backend-dir", type=Path, required=True)
    parser.add_argument("--quiet-gate", required=True)
    args = parser.parse_args()
    if args.quiet_gate != GATE:
        parser.error("requires coordinated quiet gate " + GATE)
    result = compare(args.binary.resolve(), args.reference.resolve(), args.backend_dir.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "lanes": len(result["records"]),
                      "operations": result["operations"]}))
