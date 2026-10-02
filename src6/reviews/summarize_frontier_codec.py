#!/usr/bin/env python3
"""Summarize a complete frozen capture, retaining losses and timing scopes."""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import zlib
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text())


def read_rows(path: Path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def fingerprint(document) -> str:
    return hashlib.sha256(json.dumps(document, sort_keys=True).encode()).hexdigest()


def phase_environment(directory: Path, prefix: str = ""):
    start = read_json(directory / (prefix + "environment-start.json"))
    end = read_json(directory / (prefix + "environment-end.json"))
    if start != end:
        raise ValueError(f"changed {prefix or 'size '}environment")
    return start, fingerprint(start)


def verify_environment_files(environment):
    """Recheck the actual frozen dependencies, not just equal snapshot JSON."""
    for name, identity in environment["files"].items():
        path = Path(name)
        if (not path.is_file() or path.stat().st_size != identity["bytes"] or
                digest(path) != identity["sha256"]):
            raise ValueError(f"frozen dependency changed: {path}")


def verification(row):
    proof = row["verification"]
    if "prior_verification" in proof:
        if proof.get("reused_verified_frame_sha256") != row["frame_sha256"]:
            raise ValueError("reused verification belongs to another frame")
        if proof.get("source_sha256") != row["corpus"]["sha256"]:
            raise ValueError("reused verification belongs to another source")
        proof = proof["prior_verification"]
    if proof.get("fresh_full_exact") is not True:
        raise ValueError("missing exact full source oracle")
    if proof.get("frame_sha256") != row["frame_sha256"]:
        raise ValueError("verification frame mismatch")
    minimum = 1 if row["block_mode"] == "whole" else (row["corpus"]["bytes"] + 65535) // 65536
    if proof.get("fresh_restart_oracle_exact", -1) < minimum:
        raise ValueError("incomplete restart validation")
    return proof


def distribution(values):
    if not values or any(value is None or value <= 0 for value in values):
        raise ValueError("missing or nonpositive measured clock")
    return {"samples": values, "median": statistics.median(values),
            "min": min(values), "max": max(values)}


def delta(candidate, baseline):
    return 100 * (candidate / baseline - 1)


def check_automatic_choice(row):
    event = row["native_encoder_event"]
    source = row["corpus"]
    parameters = event["policy_parameters"]
    if event["policy"] != "wordfrontier-global/1":
        raise ValueError("automatic policy changed")
    policy_sha = hashlib.sha256(json.dumps(
        {"parameters": parameters, "runtime_sha256": event["runtime_sha256"]},
        sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if policy_sha != event["policy_fingerprint"]:
        raise ValueError("automatic policy fingerprint mismatch")
    if (event["frame_sha256"], event["frame_bytes"], event["source_sha256"], event["source_bytes"], event["accounting"]) != (
        row["frame_sha256"], row["frame_bytes"], source["sha256"], source["bytes"], row["accounting"]):
        raise ValueError("automatic encode event disagrees with its captured artifact")
    if parameters["profile"] != row["candidate"].removeprefix("wordfrontier-"):
        raise ValueError("automatic profile mismatch")
    if event["tie_order"] != ["WPG2", "GWT1"] or parameters["tie_order"] != event["tie_order"]:
        raise ValueError("automatic tie policy changed")
    candidates = event["candidates"]
    if [candidate["format"] for candidate in candidates] != ["WPG2", "GWT1"]:
        raise ValueError("incomplete automatic family search")
    selected = min(candidates, key=lambda candidate: candidate["frame_bytes"])
    if (event["format"], row["frame_bytes"]) != (selected["format"], selected["frame_bytes"]):
        raise ValueError("automatic codec did not select its complete minimum")
    encoded = selected["encoder"]
    if encoded.get("archive_sha256", encoded.get("frame_sha256")) != row["frame_sha256"]:
        raise ValueError("selected family frame hash mismatch")
    if event["fresh_native_full_decode_exact"] is not True or event["fresh_native_all_original_pages_exact"] != (source["bytes"] + 65535) // 65536:
        raise ValueError("automatic publication lacked complete native source/page gates")


def check_runtime1_counterpart(row, baseline):
    parity = row.get("runtime1_frame_parity", {})
    if baseline is None:
        if parity.get("status") != "no-complete-runtime1-counterpart":
            raise ValueError("unmatched runtime-2 cell lacks explicit runtime-1 status")
        return
    if (row["corpus"]["sha256"], row["frame_sha256"], row["frame_bytes"]) != (
            baseline["corpus"]["sha256"], baseline["frame_sha256"], baseline["frame_bytes"]):
        raise ValueError("resource-only runtime changed source or complete frame")
    if (parity.get("status"), parity.get("runtime1_frame_sha256"),
            parity.get("runtime1_frame_bytes")) != (
            "byte-identical", baseline["frame_sha256"], baseline["frame_bytes"]):
        raise ValueError("missing or inconsistent runtime-1 equality evidence")


def summarize_runtime1_parity(sizes, environment):
    files = environment["files"]
    if not any(Path(path).name == "access_capture_runtime2.py" for path in files):
        return None
    results_paths = [Path(path) for path in files if Path(path).name == "results.jsonl"]
    if len(results_paths) != 1:
        raise ValueError("runtime-2 environment lacks unique immutable runtime-1 results")
    results = results_paths[0]
    if digest(results) != files[str(results)]["sha256"]:
        raise ValueError("runtime-1 results changed")
    baseline = {}
    for row in read_rows(results):
        if row.get("phase") == "size" and row.get("status") == "complete":
            key = (row["corpus"]["name"], row["candidate"], row["block_mode"])
            if key in baseline and baseline[key]["frame_sha256"] != row["frame_sha256"]:
                raise ValueError("conflicting runtime-1 frame history")
            baseline[key] = row
    matched = []
    for row in sizes.values():
        key = (row["corpus"]["name"], row["candidate"], row["block_mode"])
        old = baseline.get(key)
        check_runtime1_counterpart(row, old)
        if old is None:
            continue
        frame = Path(old["frame_path"])
        if (str(frame) not in files or files[str(frame)]["sha256"] != old["frame_sha256"] or
                frame.stat().st_size != old["frame_bytes"] or digest(frame) != old["frame_sha256"]):
            raise ValueError("runtime-1 comparison artifact changed or was not frozen")
        matched.append({"corpus": key[0], "candidate": key[1], "block_mode": key[2],
                        "source_sha256": old["corpus"]["sha256"],
                        "frame_bytes": old["frame_bytes"], "frame_sha256": old["frame_sha256"],
                        "runtime1_frame_path": str(frame), "status": "byte-identical"})
    if len(matched) != len(baseline):
        raise ValueError("runtime-2 matrix omitted a completed runtime-1 counterpart")
    return {"runtime1_results": str(results), "runtime1_results_sha256": digest(results),
            "matched_cells": len(matched), "new_cells": len(sizes) - len(matched),
            "counterparts": matched,
            "scope": "complete frame and exact source identity; every prior successful cell is checked, failed or unrun runtime-1 cells have no equality claim"}


def summarize_sizes(rows, registry, environment_sha, pinned_sources, *, check_artifacts=True):
    latest = {}
    for row in rows:
        if row.get("phase") != "size":
            continue
        if row.get("status") != "complete":
            raise ValueError("failed or incomplete size cell in final capture")
        if row.get("capture_scope") != "final-storage":
            raise ValueError("development rows cannot enter a final report")
        key = (row["corpus"]["name"], row["candidate"])
        if key in latest:
            raise ValueError("duplicate size cell in final capture")
        latest[key] = row
    lanes = sorted({lane for lane, _ in latest})
    names = registry["size_candidates"] + [name + "-whole" for name in registry["whole_control_candidates"]]
    expected = {(lane, name) for lane in lanes for name in names}
    if len(lanes) != registry["final_lane_count"] or set(lanes) != set(pinned_sources) or set(latest) != expected:
        raise ValueError("incomplete final size matrix")
    cells = []
    sources = {}
    for key in sorted(latest):
        row = latest[key]
        source = row["corpus"]
        if source != pinned_sources[source["name"]]:
            raise ValueError("source differs from pinned corpus manifest")
        if source["split"] != "final":
            raise ValueError("non-final source")
        if sources.setdefault(source["name"], source) != source:
            raise ValueError("inconsistent source identity across candidates")
        if row["frozen_fingerprint_sha256"] != environment_sha:
            raise ValueError("size row environment mismatch")
        if row["accounting"]["sum_bytes"] != row["frame_bytes"]:
            raise ValueError("unpaid frame bytes")
        if row["block_mode"] == "64k" and row["block_bytes"] != 65536:
            raise ValueError("wrong independent page size")
        proof = verification(row)
        if check_artifacts:
            frame = Path(row["frame_path"])
            raw = Path(source["path"])
            if frame.stat().st_size != row["frame_bytes"] or digest(frame) != row["frame_sha256"]:
                raise ValueError("frame artifact changed")
            if raw.stat().st_size != source["bytes"] or digest(raw) != source["sha256"]:
                raise ValueError("source artifact changed")
        event = row["native_encoder_event"]
        cell = {field: row[field] for field in (
            "candidate", "kind", "block_mode", "block_bytes", "frame_bytes",
            "frame_sha256", "frame_path", "accounting", "encode_wall_ns", "verified_utc")}
        cell.update({"corpus": source["name"], "source_sha256": source["sha256"],
                     "verification": proof,
                     "native_encoder_event": event,
                     "encode_clock_scope": "single fully paid search; concurrent screen clock, no speed rank"})
        if "runtime1_frame_parity" in row:
            cell["runtime1_frame_parity"] = row["runtime1_frame_parity"]
        if row["kind"] == "wordfrontier":
            check_automatic_choice(row)
            if check_artifacts:
                with Path(row["frame_path"]).open("rb") as stream:
                    if stream.read(4).decode("ascii") != event["format"]:
                        raise ValueError("selected format differs from artifact magic")
            cell["automatic_choice"] = {field: event[field] for field in (
                "format", "profile", "policy", "policy_fingerprint", "policy_parameters",
                "all_family_search_wall_ns", "all_search_native_codec_ns") if field in event}
            cell["automatic_choice"]["family_frames"] = [
                {"format": candidate["format"], "frame_bytes": candidate["frame_bytes"]}
                for candidate in event["candidates"]]
        cells.append(cell)
    by_lane = []
    for lane in lanes:
        sizes = {name: latest[(lane, name)]["frame_bytes"] for name in names}
        comparisons = {}
        for profile in ("quality", "access"):
            chosen = sizes[f"wordfrontier-{profile}"]
            comparisons[profile] = {baseline: delta(chosen, sizes[baseline]) for baseline in (
                "laneA-plus-M-quality-raw", "laneA-plus-M-hoisted-raw",
                "bzip3-1.5.1", "bzip3-1.5.1-whole", "bzip2-9-whole", "xz-9-extreme-whole", "zstd-19-whole")}
        by_lane.append({"corpus": sources[lane], "complete_frame_bytes": sizes,
                        "wordfrontier_change_percent": comparisons})
    aggregates = []
    groups = {"all-22": lanes, "core-17": registry["timing_lanes"]}
    for kind in sorted({source["kind"] for source in sources.values()}):
        groups[kind] = [lane for lane in lanes if sources[lane]["kind"] == kind]
    for group, selected in groups.items():
        sizes = {name: sum(latest[(lane, name)]["frame_bytes"] for lane in selected) for name in names}
        aggregates.append({"group": group, "lanes": selected,
                           "raw_bytes": sum(sources[lane]["bytes"] for lane in selected),
                           "complete_frame_bytes": sizes,
                           "wordfrontier_change_percent": {profile: {
                               name: delta(sizes[f"wordfrontier-{profile}"], size)
                               for name, size in sizes.items()} for profile in ("quality", "access")},
                           "definition": "ratio of complete byte sums; no mean of per-lane percentages"})
    return {"cells": cells, "per_lane": by_lane, "aggregates": aggregates}, latest


def full_clock_scope(kind):
    if kind == "wordfrontier":
        return "native decode including full output writes, close and atomic publication; excludes native preparation"
    return "native codec decode; excludes output file publication; may include different setup work"


def query_clock_scope(kind):
    if kind == "wsb2":
        return "sum of 256 native decode_block calls, each including stored page CRC; external source-page CRC and fold are outside the timer"
    if kind == "raw-m":
        return "sum of 256 logical range reads plus source-page CRC; each job checks native CRC; batch fold is outside the timer"
    if kind == "native-control":
        return "continuous 256-page decode/allocation/free loop including page CRC and frame/oracle CRC checks; batch fold is outside the timer"
    return "continuous 256-page decode/allocation/free loop including format-native and outer/source CRC checks plus source-page CRC fold"


def query_oracle(raw):
    pages = (len(raw) + 65535) // 65536
    if not pages:
        raise ValueError("empty timed source")
    selected = (0, pages // 2, pages - 1)
    crc_values = [zlib.crc32(raw[index * 65536:(index + 1) * 65536]) & 0xffffffff for index in selected]
    folded = 1469598103934665603
    for access in range(256):
        folded = ((folded ^ crc_values[access % 3]) * 1099511628211) & ((1 << 64) - 1)
    return folded


def summarize_timing(rows, registry, sizes, environment_sha):
    latest = {}
    for row in rows:
        if row.get("phase") != "timing":
            continue
        if row.get("status") != "complete":
            raise ValueError("failed or incomplete timing operation in final capture")
        key = (row["corpus"], row["candidate"], row["operation"], row["sample_index"])
        if key in latest:
            raise ValueError("duplicate timing operation in final capture")
        latest[key] = row
    samples = list(range(-1, registry["paired_fresh_process_samples"]))
    expected = {(lane, name, operation, sample)
                for lane in registry["timing_lanes"] for name in registry["size_candidates"]
                for operation in ("full", "query") for sample in samples}
    if set(latest) != expected:
        raise ValueError("incomplete paired timing matrix")
    result = []
    for lane in registry["timing_lanes"]:
        oracle = query_oracle(Path(sizes[(lane, registry["size_candidates"][0])]["corpus"]["path"]).read_bytes())
        for name in registry["size_candidates"]:
            size = sizes[(lane, name)]
            entry = {"corpus": lane, "candidate": name, "frame_sha256": size["frame_sha256"],
                     "source_sha256": size["corpus"]["sha256"], "frame_bytes": size["frame_bytes"]}
            for operation in ("full", "query"):
                measured = []
                for sample in samples:
                    row = latest[(lane, name, operation, sample)]
                    if (row["source_sha256"], row["frame_sha256"], row["frozen_fingerprint_sha256"]) != (
                        size["corpus"]["sha256"], size["frame_sha256"], environment_sha):
                        raise ValueError("timing artifact/environment mismatch")
                    m = row["measurement"]
                    if operation == "full" and m["full_output_sha256"] != size["corpus"]["sha256"]:
                        raise ValueError("timed full source mismatch")
                    if operation == "query" and (m["query_count"], m["query_checksum"]) != (256, oracle):
                        raise ValueError("mismatched timed query work")
                    if sample >= 0:
                        measured.append(m)
                clocks = {"process_wall_ns": distribution([m["process_wall_ns"] for m in measured])}
                clocks["discarded_warmup_measurement"] = latest[(lane, name, operation, -1)]["measurement"]
                clocks["measured_native_records"] = measured
                if operation == "full":
                    clocks["native_full_decode_ns"] = distribution([m["native_full_decode_ns"] for m in measured])
                    clocks["native_clock_scope"] = full_clock_scope(size["kind"])
                    clocks["process_scope"] = "fresh output-producing process including launch, preparation and I/O; driver overhead differs"
                else:
                    checksums = {m["query_checksum"] for m in measured}
                    peers = {latest[(lane, peer, "query", 0)]["measurement"]["query_checksum"]
                             for peer in registry["size_candidates"]}
                    if len(checksums | peers) != 1:
                        raise ValueError("query checksums differ across candidates")
                    clocks.update({"prepare_ns": distribution([m["prepare_ns"] for m in measured]),
                                   "query_native_ns": distribution([m["query_native_ns"] for m in measured]),
                                   "query_count": 256, "query_checksum": checksums.pop(),
                                   "native_clock_scope": query_clock_scope(size["kind"]),
                                   "preparation_scope": "reader-specific model setup; raw-M includes source-frame file read, other read scopes differ",
                                   "process_scope": "fresh prepared-query process; native controls additionally read the independent raw oracle inside this process",
                                   "query_scope": "256 uncached first/middle/last source pages after one preparation; exact common source oracle, no decoded-page cache"})
                entry[operation] = clocks
            result.append(entry)
    by_key = {(row["corpus"], row["candidate"]): row for row in result}
    comparisons = []
    for lane in registry["timing_lanes"]:
        for profile in ("quality", "access"):
            candidate = by_key[(lane, f"wordfrontier-{profile}")]
            for baseline_name in registry["size_candidates"]:
                baseline = by_key[(lane, baseline_name)]
                ratios = {}
                for operation, fields in (("query", ("query_native_ns", "prepare_ns", "process_wall_ns")),
                                          ("full", ("process_wall_ns",))):
                    for field in fields:
                        ratios[f"{operation}.{field}"] = distribution([
                            before / after for before, after in zip(
                                baseline[operation][field]["samples"], candidate[operation][field]["samples"])])
                comparisons.append({"corpus": lane, "profile": profile, "baseline": baseline_name,
                                    "baseline_over_wordfrontier_paired_ratios": ratios,
                                    "definition": "greater than one means less elapsed time for this wordfrontier reader path; samples pair by serial round index, with forward/reverse candidate order, not adjacent A/B executions. Query and preparation are reader-specific API clocks with explicitly differing CRC, fold and I/O scopes; no uniform entropy-kernel claim. Native full clocks are excluded due to differing output I/O scopes."})
    return {"samples": result, "paired_comparisons": comparisons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--with-timing", action="store_true")
    args = parser.parse_args()
    directory = args.capture.resolve()
    registry = read_json(args.registry)
    status = read_json(directory / "status.json")
    if status.get("error") or status["completed_cells"] != status["total_cells"]:
        raise ValueError("capture is incomplete")
    environment, env_sha = phase_environment(directory)
    verify_environment_files(environment)
    manifest_path = Path(registry["corpus_manifest"])
    if digest(manifest_path) != environment["files"][str(manifest_path.resolve())]["sha256"]:
        raise ValueError("pinned corpus manifest changed")
    pinned_sources = {row["name"]: row for row in read_json(manifest_path)["corpora"] if row["split"] == "final"}
    if len(pinned_sources) != registry["final_lane_count"]:
        raise ValueError("pinned final corpus manifest count mismatch")
    storage, sizes = summarize_sizes(read_rows(directory / "results.jsonl"), registry, env_sha, pinned_sources)
    sources = [args.registry, directory / "results.jsonl", directory / "environment-start.json",
               directory / "environment-end.json", manifest_path]
    report = {"schema": 1, "status": "complete-verified-storage", "registry": registry,
              "environment": environment, "frozen_fingerprint_sha256": env_sha, "storage": storage,
              "limitations": [
                  "Self-contained exact byte compression of source projections, not complete lexical import semantics.",
                  "Every model, constructor, flag stream, directory, checksum and selector is charged in complete frame bytes.",
                  "Whole-file controls and independent 64 KiB access frames are separate comparisons.",
                  "LaneA+M size gates use full native restart CRC checks plus full source parity; WPG2/WSB2 additionally fresh-extract every original page.",
                  "Encoding pays all candidate searches, including losers. Size-phase encoder clocks are diagnostic; no encode speed rank.",
                  "Native full decode clocks have different output I/O scopes and cannot establish a common throughput ranking.",
                  "Process wall includes launch, preparation, output I/O and varying adapter overhead.",
                  "Prepared query APIs have different timed CRC/fold scopes; controls query process wall additionally includes external source-oracle reads. Ratios retain those scopes, not a uniform entropy-kernel comparison.",
                  "Peak RSS may inherit a parent high-water mark; no memory ranking is inferred from ru_maxrss.",
                  "The outer capture environment pins Runtime 2 source and binaries. The inner automatic-policy event hashes original backend source plus replacement binaries and is not sufficient by itself to identify Runtime 2 source.",
                  "Timing samples pair by serial round index with forward/reverse candidate order. Dependency rehashes occur between samples outside their process clocks; resident file-cache and thermal effects remain, so this is not a cold-cache or pure steady-state claim.",
                  "All codec choices were frozen before the final evaluation; outcomes are workload-specific, not universal compression records."
              ]}
    runtime1_parity = summarize_runtime1_parity(sizes, environment)
    if runtime1_parity is not None:
        report["runtime1_frame_parity"] = runtime1_parity
    if args.with_timing:
        timing_status = read_json(directory / "timing-status.json")
        if timing_status.get("complete") is not True or timing_status.get("error") or timing_status["completed_operations"] != timing_status["total_operations"]:
            raise ValueError("timing capture is incomplete")
        timed_env, timed_sha = phase_environment(directory, "timing-")
        if timed_env != environment:
            raise ValueError("size and timing runtime changed")
        report["timing"] = summarize_timing(read_rows(directory / "timing-results.jsonl"), registry, sizes, timed_sha)
        report["status"] = "complete-verified-storage-and-paired-access"
        sources += [directory / "timing-results.jsonl", directory / "timing-environment-start.json",
                    directory / "timing-environment-end.json"]
    report["evidence_files"] = [{"path": str(path), "bytes": path.stat().st_size,
                                  "sha256": digest(path)} for path in sources]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
