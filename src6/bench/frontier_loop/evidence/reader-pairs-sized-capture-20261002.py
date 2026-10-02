#!/usr/bin/env python3
"""Quiet fresh-process complete-book reader comparisons, with exact oracles."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

import loop

GATE = "BOOK-READERS-QUIET"


def runtime():
    return {"platform": platform.platform(), **{
        str(p): p.read_text().strip() for p in map(Path, (
            "/proc/sys/kernel/random/boot_id", "/sys/fs/cgroup/cpu.max",
            "/sys/fs/cgroup/memory.max")) if p.is_file()}}


def measured(argv, directory, output, source, stdout_output=False):
    output.unlink(missing_ok=True)
    start = time.perf_counter_ns()
    with (output if stdout_output else directory / "event.json").open("wb") as sink, \
         (directory / "stderr.txt").open("wb") as error:
        child = subprocess.Popen(argv, stdout=sink, stderr=error,
                                 env=loop.child_environment({}, directory))
        _, status, usage = os.wait4(child.pid, 0)
        child.returncode = os.waitstatus_to_exitcode(status)
    wall = time.perf_counter_ns() - start
    if child.returncode:
        raise ValueError(f"reader failed: {argv}: {child.returncode}")
    if output.stat().st_size != source["bytes"] or loop.digest(output) != source["sha256"]:
        raise ValueError("reader returned different complete source bytes")
    return {"argv": argv, "wall_ns": wall, "linux_peak_rss_kib": usage.ru_maxrss,
            "user_cpu_seconds": usage.ru_utime, "system_cpu_seconds": usage.ru_stime,
            "full_source_exact": True, "output_bytes": source["bytes"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bzip3-frames", type=Path,
                        help="Audited alternative one-block workspace control report")
    parser.add_argument("--quiet-gate", choices=(GATE,), required=True)
    args = parser.parse_args()
    before = runtime()
    report_hash = loop.digest(args.report)
    registry_hash = loop.digest(args.cases)
    report = loop.load_json(args.report)
    registry = loop.load_json(args.cases)
    if report["stage"] != "development" or not report["scores"]["all_cases_passed"]:
        raise ValueError("requires exact complete development round")
    cases = loop.select_cases(loop.validate_registry(registry), "development")
    if report["expected_case_ids"] != [c["id"] for c in cases]:
        raise ValueError("report coverage differs from registry")
    specifications = report["specs"]
    sized = loop.load_json(args.bzip3_frames) if args.bzip3_frames else None
    sized_hash = loop.digest(args.bzip3_frames) if sized else None
    sized_rows = {row["case"]: row for row in sized["rows"]} if sized else {}
    deps = {role: loop.check_deps(spec) for role, spec in specifications.items()}
    for role, value in deps.items():
        if value != report["pins"][role + "_dependencies"]:
            raise ValueError("round dependencies changed before timing")
    native = specifications["candidate"]["decode_argv"][0]
    bzip3 = specifications["baseline"]["decode_argv"][4]
    if sized and loop.digest(Path(bzip3)) != sized["binary_sha256"]:
        raise ValueError("alternative baseline used a different binary")
    records = []
    with tempfile.TemporaryDirectory(prefix="book-reader-pairs-") as name:
        directory = Path(name)
        for case in cases:
            source = case["source"]
            loop.require_file(source, "source", length=True)
            frames = {}
            for role in ("candidate", "baseline"):
                row = report["trials"][case["id"]][role]
                frame = Path(row["artifact_dir"]) / "decode_job" / "frame.bin"
                if loop.digest(frame) != row["frame_sha256"] or frame.stat().st_size != row["frame_bytes"]:
                    raise ValueError("round frame changed")
                frames[role] = frame
            if sized:
                row = sized_rows[case["id"]]
                frame = Path(row["frame"])
                if (row["source"]["sha256"] != source["sha256"]
                        or row["source"]["bytes"] != source["bytes"]
                        or not row["exact_decode"]
                        or frame.stat().st_size != row["frame_bytes"]
                        or loop.digest(frame) != row["frame_sha256"]
                        or frame.read_bytes()[9:] != frames["baseline"].read_bytes()[9:]):
                    raise ValueError("alternative baseline differs beyond workspace header")
                frames["baseline"] = frame
            samples = []
            for trial in range(6):
                order = ("bzip3", "wordfrontier") if trial % 2 == 0 else ("wordfrontier", "bzip3")
                pair = {}
                for role in order:
                    output = directory / (role + ".raw")
                    argv = ([bzip3, "-d", "-c", str(frames["baseline"])] if role == "bzip3" else
                            [native, "decode", str(frames["candidate"]), str(output)])
                    pair[role] = measured(argv, directory, output, source, role == "bzip3")
                samples.append({"trial": trial, "warmup": trial == 0, "order": order,
                                "samples": pair, "wordfrontier_speedup":
                                pair["bzip3"]["wall_ns"] / pair["wordfrontier"]["wall_ns"]})
            records.append({"case": case["id"], "source": source,
                            "samples": samples, "median_paired_speedup": statistics.median(
                                x["wordfrontier_speedup"] for x in samples[1:]),
                            "median_wall_ns": {role: statistics.median(
                                x["samples"][role]["wall_ns"] for x in samples[1:])
                                for role in ("bzip3", "wordfrontier")},
                            "median_linux_peak_rss_kib": {role: statistics.median(
                                x["samples"][role]["linux_peak_rss_kib"] for x in samples[1:])
                                for role in ("bzip3", "wordfrontier")}})
            loop.require_file(source, "source", length=True)
            for role, frame in frames.items():
                expected = (sized_rows[case["id"]]["frame_sha256"] if sized and role == "baseline"
                            else report["trials"][case["id"]][role]["frame_sha256"])
                if loop.digest(frame) != expected:
                    raise ValueError("frame changed during paired timing")
    if runtime() != before or loop.digest(args.report) != report_hash or loop.digest(args.cases) != registry_hash:
        raise ValueError("runtime or reference changed")
    if any(loop.check_deps(spec) != deps[role] for role, spec in specifications.items()):
        raise ValueError("dependency changed during timing")
    if sized and loop.digest(args.bzip3_frames) != sized_hash:
        raise ValueError("alternative baseline report changed during timing")
    result = {"protocol": "BOOK-READERS-QUIET/1", "operations": len(records) * 12,
              "warmups_per_case": 1, "paired_trials": 5, "runtime": before,
              "report_sha256": report_hash, "registry_sha256": registry_hash,
              "harness_sha256": loop.digest(Path(__file__)), "dependencies": deps,
              "bzip3_frame_policy": sized["policy"] if sized else "fixed 32 MiB whole-file block",
              "bzip3_control_report_sha256": sized_hash,
              "scope": "Fresh direct native command wall including input, preparation, complete decode and output; resident files after warmup. bzip3 writes stdout redirected to a file; WordFrontier publishes its output file. Exact output hash is checked outside the clock. Linux per-process wait4 peak RSS includes runtime/input/output/model allocations.",
              "limitations": "No cold-cache or isolated kernel claim; five paired observations per case; unchanged frames that lose bzip3 size. A latency improvement does not satisfy the compression goal.",
              "records": records}
    loop.atomic_json(args.output, result)
    print(json.dumps({"operations": result["operations"], "speedups": {
        x["case"]: x["median_paired_speedup"] for x in records}}, sort_keys=True))


if __name__ == "__main__":
    main()
