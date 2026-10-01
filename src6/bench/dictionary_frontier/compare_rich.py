#!/usr/bin/env python3
"""Paired, fully consumed native-rich dictionary operations.

This is a synthetic ownership/access workload, not natural-text compression.
The client checks complete native equality before timing selected-field access.
Semantic verification and prepared wire projections are reported separately.
"""
from __future__ import annotations

import argparse
import json
import platform
import statistics
from pathlib import Path

from compare import capture, dependencies_record, file_record, source_record, text_of

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
GATE = "ROOT-EXPLICIT-QUIET-GATE"
COMMON = {
    "packet_encode", "packet_owned_decode", "build_plain", "open", "reader_init",
    "prepare_links", "cold_admitted_load", "cached_admitted_load",
    "full_semantic_verification",
}
ACCESS = {
    "cold_admitted_load", "cached_admitted_load", "cold_admitted_inspection",
    "prepared_uncached_wire_projection", "prepared_cached_wire_projection",
}
REPEATED_SINGLE = {
    "packet_owned_decode", "packet_borrowed_decode", "retained_wire_field_projection",
}


def parse(text: str, entries: int, mode: str) -> dict:
    rows = [json.loads(line) for line in text.splitlines() if line.strip()]
    header = rows[0]
    if (header.get("protocol") != "LEX6-RICH-FRONTIER/1"
            or header.get("entries") != entries or header.get("mode") != mode):
        raise ValueError("wrong client protocol or workload")
    phases = {}
    for row in rows[1:]:
        name = row.get("phase")
        if not isinstance(name, str) or name in phases:
            raise ValueError("missing or duplicate phase")
        for field in ("ns", "alloc_calls", "allocated_bytes", "peak_delta_bytes", "checksum", "page_loads"):
            if type(row.get(field)) is not int or row[field] < 0:
                raise ValueError(f"invalid {name}/{field}")
        phases[name] = row
    if not COMMON <= phases.keys():
        raise ValueError("incomplete comparison client")
    for group in (ACCESS, REPEATED_SINGLE):
        if len({phases[name]["checksum"] for name in group & phases.keys()}) != 1:
            raise ValueError("observations disagree between access paths")
    for name in ("open", "prepare_links", "full_semantic_verification"):
        if phases[name]["checksum"] != entries:
            raise ValueError("entry-count observation mismatch")
    return {"header": header, "phases": phases}


def summarize(samples: list[dict]) -> dict:
    summary = {}
    for name in samples[0]["phases"]:
        rows = [sample["phases"][name] for sample in samples]
        if len({row["checksum"] for row in rows}) != 1:
            raise ValueError("nondeterministic result observation")
        summary[name] = {"checksum": rows[0]["checksum"]}
        for field in ("ns", "alloc_calls", "allocated_bytes", "peak_delta_bytes", "page_loads"):
            values = [row[field] for row in rows]
            summary[name][field] = {
                "median": statistics.median(values), "min": min(values), "max": max(values),
            }
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--before-source", required=True, type=Path)
    parser.add_argument("--after-source", type=Path, default=REPO)
    parser.add_argument("--entries", type=int, default=4096)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--quiet-gate", required=True)
    args = parser.parse_args()
    if args.quiet_gate != GATE or not 1 <= args.entries <= 65536 or args.pairs < 3:
        parser.error("explicit measurement gate, valid count and at least three pairs required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {"before": args.before.resolve(), "after": args.after.resolve()}
    roots = {"before": args.before_source.resolve(), "after": args.after_source.resolve()}
    source_paths = sorted((REPO / "src6/experiments/dictionary_frontier").glob("*.zig"))
    source_paths += [HERE / "compare.py", HERE / "compare_rich.py"]
    initial = {lane: source_record(root) for lane, root in roots.items()}
    shared = [file_record(path) for path in source_paths]
    dependencies = dependencies_record()
    report = {
        "schema": 1, "status": "in-progress", "platform": platform.platform(),
        "entries": args.entries, "pairs": args.pairs, "order": "AB,BA alternating",
        "binaries": {lane: file_record(binary) for lane, binary in binaries.items()},
        "sources": initial, "shared_client_sources": shared,
        "dependencies": dependencies,
        "accounting": "Zig allocator requests only; native bzip3 C allocations excluded",
        "workload": "fixed rich multilingual synthetic documents; equal headword and first-sense-label observations",
        "validation": "complete native equality outside access timers; full semantic verification timed separately",
        "startup": "fresh process per sample; explicit untimed warmup process per lane/mode; memory-resident and previously touched bytes",
        "archive_policy": "baseline plain; candidate optional identity index selected for access, both plain and indexed builds charged",
        "cold_definition": "no application page cache; previously touched RAM/CPU data, no OS cache eviction",
        "lanes": [],
    }
    try:
        for mode in ("raw", "adaptive"):
            comparison = {"compression": mode, "samples": {lane: [] for lane in binaries}}
            report["lanes"].append(comparison)
            for lane in binaries:
                warmup = capture([str(binaries[lane]), str(args.entries), mode], output / f"{mode}-warmup-{lane}")
                parse(text_of(warmup), args.entries, mode)
            for pair in range(args.pairs):
                order = ("before", "after") if pair % 2 == 0 else ("after", "before")
                for lane in order:
                    result = capture([str(binaries[lane]), str(args.entries), mode], output / f"{mode}-pair{pair}-{lane}")
                    parsed = parse(text_of(result), args.entries, mode)
                    comparison["samples"][lane].append({"pair": pair, "order": list(order), "capture": result, **parsed})
                before, after = (comparison["samples"][lane][-1]["phases"] for lane in ("before", "after"))
                for name in COMMON - {"build_plain", "packet_encode"}:
                    if before[name]["checksum"] != after[name]["checksum"]:
                        raise ValueError(f"before/after {name} observation mismatch")
            comparison["summary"] = {lane: summarize(samples) for lane, samples in comparison["samples"].items()}
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"checked rich/{mode}", flush=True)
        if initial != {lane: source_record(root) for lane, root in roots.items()}:
            raise ValueError("source changed during comparison")
        if shared != [file_record(path) for path in source_paths]:
            raise ValueError("shared client changed during comparison")
        if dependencies_record() != dependencies:
            raise ValueError("benchmark dependencies changed during comparison")
        if any(file_record(binaries[lane]) != value for lane, value in report["binaries"].items()):
            raise ValueError("binary changed during comparison")
        report["status"] = "complete-verified"
    except Exception as exc:
        report["status"], report["error"] = "failed", str(exc)
        raise
    finally:
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
