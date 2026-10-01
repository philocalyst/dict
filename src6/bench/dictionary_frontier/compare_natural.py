#!/usr/bin/env python3
"""Compare admitted natural dictionary access on already verified artifacts.

The complete-verified storage report supplies five held-out dictionaries and
matching 64 KiB raw/adaptive archives. No archives or expected query answers
are built here. Full semantic admission stays a separately timed setup phase.
"""
from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import statistics
import subprocess
from pathlib import Path

from compare import capture, dependencies_record, file_record, formats, source_record, text_of

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
GATE = "ROOT-EXPLICIT-QUIET-GATE"
PROTOCOL = "LEX6-NATURAL-PROJECTION/1"
U64_MAX = (1 << 64) - 1
NATIVE = {"native_samepage_reader_init", "native_samepage_access",
          "native_mixed_reader_init", "native_mixed_access"}
WIRE = {name.replace("native_", "wire_") for name in NATIVE}
COMMON = {"open", "full_semantic_verification"} | NATIVE
PHASE_FIELDS = ("ns", "checksum", "consumed_bytes", "operations", "page_loads")


def integer(row: dict, field: str, *, positive: bool = False, maximum: int | None = None) -> int:
    value = row.get(field)
    if type(value) is not int or value < (1 if positive else 0) or (maximum is not None and value > maximum):
        raise ValueError(f"invalid {field}")
    return value


def observation(row: dict) -> tuple[int, int]:
    return row["checksum"], row["consumed_bytes"]


def parse(text: str, artifact: dict, entries: int, operations: int, *, wire: bool,
          codec: str, oracle_bytes: dict | None = None) -> dict:
    if codec not in ("raw", "adaptive"):
        raise ValueError("unknown archive compression mode")
    rows = [json.loads(line) for line in text.splitlines() if line.strip()]
    if not rows or any(not isinstance(row, dict) for row in rows):
        raise ValueError("missing or non-object client records")
    header = rows[0]
    if (header.get("protocol") != PROTOCOL or header.get("archive") != artifact["path"]
            or integer(header, "archive_bytes", positive=True) != artifact["bytes"]
            or integer(header, "entries", positive=True) != entries
            or integer(header, "operations", positive=True) != operations):
        raise ValueError("wrong client protocol, archive or workload")
    pages = integer(header, "pages", positive=True, maximum=entries)
    if (header.get("workload") != "natural source projection: headword plus complete single-definition Inline.text"
            or header.get("shape_gate") != "all entries; exactly one definition containing exactly one Inline.text"
            or header.get("cold") != "fresh application page cache; memory-resident previously touched bytes"
            or header.get("allocation_accounting") != "none; this client reports time, page loads, consumed bytes, and checksum"):
        raise ValueError("wrong declared workload or accounting")
    phases, gates = {}, []
    for row in rows[1:]:
        if "gate" in row:
            if "phase" in row or row["gate"] != "all_entries_validated":
                raise ValueError("unknown or ambiguous gate")
            integer(row, "entries", positive=True)
            integer(row, "checksum", maximum=U64_MAX)
            integer(row, "consumed_bytes")
            gates.append(row)
            continue
        name = row.get("phase")
        if not isinstance(name, str) or name in phases:
            raise ValueError("missing or duplicate phase")
        for field in PHASE_FIELDS:
            integer(row, field, maximum=U64_MAX if field == "checksum" else None)
        phases[name] = row
    if len(gates) != 1 or gates[0]["entries"] != entries:
        raise ValueError("missing, duplicate or partial all-entry gate")
    if set(phases) != COMMON | (WIRE if wire else set()):
        raise ValueError("missing or unexpected client phase")
    for name, ops, loads in (("open", 0, 0), ("full_semantic_verification", entries, pages)):
        row = phases[name]
        if (observation(row) != (entries, 0) or row["operations"] != ops or row["page_loads"] != loads):
            raise ValueError(f"invalid {name} setup observation")
    for name, row in phases.items():
        if name.endswith("_reader_init"):
            if observation(row) != (0, 0) or row["operations"] or row["page_loads"]:
                raise ValueError("reader initialization includes access work")
        elif name.endswith("_access"):
            limit = 1 if "samepage" in name else min(operations, pages)
            if row["operations"] != operations or row["page_loads"] > limit:
                raise ValueError("incorrect access operation or page-load count")
            if name == "native_samepage_access" and row["page_loads"] != 1:
                raise ValueError("native same-page batch must load one page")
            if name == "native_mixed_access" and row["page_loads"] < (2 if operations > 1 and pages > 1 else 1):
                raise ValueError("native mixed batch did not span the endpoint pages")
            if name.startswith("wire_") and codec == "raw" and row["page_loads"]:
                raise ValueError("raw prepared projection unexpectedly loads a page")
    for workload in ("samepage", "mixed"):
        native = phases[f"native_{workload}_access"]
        if wire and observation(native) != observation(phases[f"wire_{workload}_access"]):
            raise ValueError("native/wire selected observations disagree")
        if oracle_bytes is not None and native["consumed_bytes"] != oracle_bytes[workload]:
            raise ValueError("selected consumed bytes disagree with independent projection")
    if operations == 1 and observation(phases["native_samepage_access"]) != observation(phases["native_mixed_access"]):
        raise ValueError("one-operation batches must select the same entry")
    if oracle_bytes is not None and gates[0]["consumed_bytes"] != oracle_bytes["all"]:
        raise ValueError("all-entry consumed bytes disagree with independent projection")
    return {"header": header, "gate": gates[0], "phases": phases}


def compare_observations(before: dict, after: dict) -> None:
    if before["gate"] != after["gate"]:
        raise ValueError("before/after complete entry observations disagree")
    for name in COMMON:
        left, right = before["phases"][name], after["phases"][name]
        if observation(left) != observation(right) or left["operations"] != right["operations"]:
            raise ValueError(f"before/after {name} selected observations disagree")


def distribution(values: list[int]) -> dict:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def summarize(samples: list[dict]) -> dict:
    first = samples[0]
    phases = {}
    for sample in samples:
        if sample["header"] != first["header"] or sample["gate"] != first["gate"] or set(sample["phases"]) != set(first["phases"]):
            raise ValueError("nondeterministic archive metadata or complete observations")
    for name in first["phases"]:
        rows = [sample["phases"][name] for sample in samples]
        if len({(observation(row), row["operations"]) for row in rows}) != 1:
            raise ValueError("nondeterministic selected observations")
        phases[name] = {field: rows[0][field] for field in ("checksum", "consumed_bytes", "operations")}
        for field in ("ns", "page_loads"):
            phases[name][field] = distribution([row[field] for row in rows])
    prepared = {}
    for workload in ("samepage", "mixed"):
        name = f"wire_{workload}_reader_init"
        if name in first["phases"]:
            prepared[workload] = {
                "full_verification_and_reader_init_ns": distribution([
                    sample["phases"]["full_semantic_verification"]["ns"] + sample["phases"][name]["ns"]
                    for sample in samples]),
                "open_full_verification_and_reader_init_ns": distribution([
                    sample["phases"]["open"]["ns"] + sample["phases"]["full_semantic_verification"]["ns"] + sample["phases"][name]["ns"]
                    for sample in samples]),
            }
    return {"phases": phases, "prepared_setup": prepared}


def checked_file(record: dict, *, required: bool = True) -> dict | None:
    if (not isinstance(record, dict) or not isinstance(record.get("path"), str)
            or not Path(record["path"]).is_absolute()
            or type(record.get("bytes")) is not int or record["bytes"] < 0
            or not isinstance(record.get("sha256"), str) or not re.fullmatch("[0-9a-f]{64}", record["sha256"])):
        raise ValueError("invalid file provenance record")
    path = Path(record["path"])
    if not required and not path.exists():
        return None
    actual = file_record(path)
    if any(actual[field] != record[field] for field in ("path", "bytes", "sha256")):
        raise ValueError(f"file disagrees with artifacts report: {path}")
    return actual


def projection_bytes(path: Path, entries: int, operations: int) -> dict:
    oracle = formats.read_projection(path)
    if len(oracle.records) != entries:
        raise ValueError("projection/report entry count mismatch")
    lengths = [len(record.keys[0]) + len(record.content) for record in oracle.records]
    return {"all": sum(lengths), "samepage": lengths[0] * operations,
            "mixed": sum(lengths[0 if operations == 1 else index * (entries - 1) // (operations - 1)]
                         for index in range(operations))}


def artifact_lanes(report: dict, operations: int) -> list[dict]:
    if type(report.get("schema")) is not int or report["schema"] != 1 or report.get("status") != "complete-verified":
        raise ValueError("a complete-verified compare.py report is required")
    corpora = report.get("corpora")
    if not isinstance(corpora, list) or len(corpora) != 5:
        raise ValueError("exactly five held-out dictionary corpora are required")
    names, paths, projections, result = set(), set(), set(), []
    for corpus in corpora:
        name = corpus.get("name")
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name)
                or name in names or name in (".", "..")):
            raise ValueError("invalid or duplicate corpus name")
        names.add(name)
        entries = integer(corpus, "records", positive=True)
        projection = corpus.get("projection")
        actual_projection = checked_file(projection, required=False)
        if projection["path"] in projections:
            raise ValueError("duplicate source projection")
        projections.add(projection["path"])
        if Path(projection["path"]).parent.name != "final":
            raise ValueError("artifacts must come from fixed final dictionary projections")
        oracle = projection_bytes(Path(projection["path"]), entries, operations) if actual_projection else None
        lineage_path = Path(projection["path"]).with_name("projection-manifest.json")
        lineage = file_record(lineage_path) if lineage_path.is_file() else None
        lanes = corpus.get("lanes")
        if not isinstance(lanes, list) or len(lanes) != 2 or {lane.get("codec") for lane in lanes} != {"raw", "adaptive"}:
            raise ValueError("each corpus requires exactly raw and adaptive lanes")
        for codec in ("raw", "adaptive"):
            lane = next(lane for lane in lanes if lane["codec"] == codec)
            sizes = lane.get("sizes")
            if not isinstance(sizes, list):
                raise ValueError("missing archive size sweep")
            selected = [size for size in sizes if size.get("target_page_bytes") == 65536]
            if len(selected) != 2 or {size.get("lane") for size in selected} != {"before", "after"}:
                raise ValueError("missing or duplicate matching 64 KiB artifacts")
            artifacts, admissions = {}, {}
            for size in selected:
                artifact = checked_file(size.get("artifact"))
                if artifact["bytes"] == 0 or artifact["bytes"] > 512 * 1024 * 1024 or artifact["path"] in paths:
                    raise ValueError("empty, oversized or reused archive artifact")
                paths.add(artifact["path"])
                validated = size.get("validated", {})
                if (validated.get("status") != "smoke-ok" or integer(validated, "entries", positive=True) != entries
                        or integer(validated, "loaded_entries", positive=True) != entries):
                    raise ValueError("artifacts report lacks complete independent entry admission")
                for digest in ("all_hit_digest", "loaded_content_digest"):
                    if not isinstance(validated.get(digest), str) or not re.fullmatch("[0-9a-f]{64}", validated[digest]):
                        raise ValueError("missing independent artifact digest")
                for count in ("hits", "key_bytes", "content_bytes", "query_checks"):
                    integer(validated, count)
                if oracle is not None and validated["content_bytes"] > oracle["all"]:
                    raise ValueError("independent content count exceeds headword-plus-content count")
                artifacts[size["lane"]] = artifact
                admissions[size["lane"]] = validated
            if admissions["before"] != admissions["after"]:
                raise ValueError("before/after independent artifact observations disagree")
            result.append({"name": name, "codec": codec, "entries": entries,
                           "projection": projection, "projection_available": actual_projection is not None,
                           "projection_manifest": lineage, "oracle_consumed_bytes": oracle,
                           "artifacts": artifacts, "independent_admission": admissions["after"]})
    return result


def runtime_dependencies(binaries: dict[str, Path]) -> dict:
    tool = shutil.which("ldd")
    if tool is None:
        raise RuntimeError("ldd is required to record native runtime dependencies")
    paths = set()
    for binary in binaries.values():
        completed = subprocess.run([tool, str(binary)], capture_output=True, text=True, check=False)
        if completed.returncode and "not a dynamic executable" not in completed.stderr and "statically linked" not in completed.stdout:
            raise RuntimeError(f"cannot record runtime dependencies for {binary}: {completed.stderr.strip()}")
        if "not found" in completed.stdout:
            raise RuntimeError(f"missing native runtime dependency for {binary}")
        paths.update(Path(path).resolve() for path in re.findall(r"(/[\S]+?)(?=\s|$)", completed.stdout))
    return {"tool": file_record(Path(tool).resolve()), "files": [file_record(path) for path in sorted(paths)]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-report", required=True, type=Path)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--before-source", required=True, type=Path)
    parser.add_argument("--after-source", type=Path, default=REPO)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--operations", type=int, default=1024)
    parser.add_argument("--quiet-gate", required=True)
    args = parser.parse_args()
    if args.quiet_gate != GATE or args.pairs < 5 or not 1 <= args.operations <= 1_000_000:
        parser.error("explicit measurement gate, at least five pairs and valid operations required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    artifacts_path = args.artifacts_report.resolve()
    if output / "results.json" == artifacts_path:
        parser.error("output must not overwrite the artifacts report")
    artifact_report_record = file_record(artifacts_path)
    artifact_report = json.loads(artifacts_path.read_text())
    binaries = {"before": args.before.resolve(), "after": args.after.resolve()}
    roots = {"before": args.before_source.resolve(), "after": args.after_source.resolve()}
    initial = {lane: source_record(root) for lane, root in roots.items()}
    dependencies = dependencies_record()
    client_paths = sorted((REPO / "src6/experiments/dictionary_frontier").glob("*.zig"))
    shared = [file_record(path) for path in client_paths]
    runtime = runtime_dependencies(binaries)
    report = {
        "schema": 1, "protocol": PROTOCOL, "status": "in-progress", "platform": platform.platform(),
        "artifacts_report": artifact_report_record, "sources": initial,
        "dependencies": dependencies, "runtime_dependencies": runtime,
        "shared_client_sources": shared,
        "binaries": {lane: file_record(binary) for lane, binary in binaries.items()},
        "schedule": {"pairs": args.pairs, "operations": args.operations, "order": "AB,BA alternating",
                     "target_page_bytes": 65536, "codecs": ["raw", "adaptive"],
                     "fresh_process": True, "warmup": "one fresh untimed process per lane/corpus/codec"},
        "workload": "fixed natural source projection; consume headword and complete single-definition Inline.text",
        "validation": "prior independent full artifact content digests; all-entry native shape/observation gate in every process; oracle byte totals when projection is available",
        "prepared_setup": "full semantic verification timed separately; include open plus full verification plus wire reader initialization for startup; access timings exclude that setup",
        "cold_definition": "empty application page cache, warm memory-resident bytes; no OS cache eviction",
        "accounting": "all archive bytes from artifact report; time/page loads/consumed bytes only; no allocation or RSS claim",
        "lanes": [],
    }
    try:
        if artifact_report.get("sources") != initial:
            raise ValueError("artifact source snapshots do not match the frozen comparison cores")
        if artifact_report.get("dependencies") != dependencies:
            raise ValueError("artifact dependencies do not match this frozen benchmark")
        lanes = artifact_lanes(artifact_report, args.operations)
        for lane_info in lanes:
            comparison = {**lane_info, "warmups": {}, "samples": {lane: [] for lane in binaries}}
            report["lanes"].append(comparison)
            prefix = output / lane_info["name"] / lane_info["codec"]
            def run(lane: str, suffix: str) -> dict:
                artifact = lane_info["artifacts"][lane]
                result = capture([str(binaries[lane]), artifact["path"], str(args.operations)],
                                 prefix / suffix)
                return {"capture": result, **parse(text_of(result), artifact, lane_info["entries"],
                        args.operations, wire=lane == "after", codec=lane_info["codec"],
                        oracle_bytes=lane_info["oracle_consumed_bytes"])}
            for lane in binaries:
                comparison["warmups"][lane] = run(lane, f"warmup-{lane}")
            compare_observations(comparison["warmups"]["before"], comparison["warmups"]["after"])
            for pair in range(args.pairs):
                order = ("before", "after") if pair % 2 == 0 else ("after", "before")
                for lane in order:
                    sample = run(lane, f"pair{pair}-{lane}")
                    compare_observations(comparison["warmups"][lane], sample)
                    comparison["samples"][lane].append({"pair": pair, "order": list(order), **sample})
                compare_observations(*(comparison["samples"][lane][-1] for lane in ("before", "after")))
            comparison["summary"] = {lane: summarize(samples) for lane, samples in comparison["samples"].items()}
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"checked natural-projection/{lane_info['name']}/{lane_info['codec']}", flush=True)
        if initial != {lane: source_record(root) for lane, root in roots.items()}:
            raise ValueError("source changed during comparison")
        if shared != [file_record(path) for path in client_paths]:
            raise ValueError("shared client changed during comparison")
        if dependencies_record() != dependencies or runtime_dependencies(binaries) != runtime:
            raise ValueError("benchmark dependencies changed during comparison")
        if file_record(artifacts_path) != artifact_report_record:
            raise ValueError("artifacts report changed during comparison")
        for lane_info in lanes:
            for artifact in lane_info["artifacts"].values():
                checked_file(artifact)
            checked_file(lane_info["projection"], required=lane_info["projection_available"])
            if lane_info["projection_manifest"] is not None:
                checked_file(lane_info["projection_manifest"])
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
