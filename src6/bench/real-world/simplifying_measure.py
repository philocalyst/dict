#!/usr/bin/env python3
"""Run the bounded pre/post LEX6 simplification comparison.

This is a narrow wrapper around the existing public ``measure`` protocol.  It
reuses the retained projections, query plans, artifacts, oracle validation,
and fixed runner workload; it does not rebuild an artifact or generate a new
plan.  Each lane is paired in a fixed order: the preserved post-review
executable is run first, then the frozen-tree executable, for three fresh
process samples.  The wrapper records ``post_verify_all_ns`` as the explicit
verifyAll-after-reads control and retains the runner's cache counters.

The literal quiet gate is required before any child process is launched or
any wall-clock measurement is read.  Fresh process is not a cold-OS-cache
claim; no cache eviction is attempted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
GATE = "ROOT-EXPLICIT-QUIET-GATE"
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
CODECS = ("raw", "adaptive")
PROCESS_RUNS = 3

sys.path.insert(0, str(ROOT))
import formats  # noqa: E402
import measure  # noqa: E402


def sha256_file(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise RuntimeError(f"missing retained file: {path}")
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def tree_record(path: Path) -> dict[str, Any]:
    if not path.is_dir():
        raise RuntimeError(f"missing retained source tree: {path}")
    files = sorted(item for item in path.rglob("*") if item.is_file())
    state = hashlib.sha256()
    total = 0
    for item in files:
        relative = item.relative_to(path).as_posix().encode("utf-8")
        digest = sha256_file(item).encode("ascii")
        size = item.stat().st_size
        total += size
        state.update(len(relative).to_bytes(8, "little")); state.update(relative)
        state.update(size.to_bytes(8, "little")); state.update(digest)
    return {"path": str(path), "kind": "file-tree", "files": len(files), "bytes": total, "sha256": state.hexdigest()}


def verify_file(path: Path, expected: dict[str, Any], label: str) -> dict[str, Any]:
    actual = file_record(path)
    if actual["bytes"] != expected.get("bytes") or actual["sha256"] != expected.get("sha256"):
        raise RuntimeError(f"{label} hash/size changed: expected={expected!r} actual={actual!r}")
    return actual


def source_records() -> list[dict[str, Any]]:
    paths = [
        ROOT / "runner.zig",
        ROOT / "build.zig",
        ROOT / "measure.py",
        ROOT / "formats.py",
        ROOT / "simplifying_measure.py",
        REPO / "build6.zig",
        REPO / "src6" / "root.zig",
        REPO / "src6" / "model.zig",
        REPO / "src6" / "packet.zig",
        REPO / "src6" / "compression.zig",
        REPO / "src6" / "archive.zig",
        REPO / "src6" / "query.zig",
        REPO / "src6" / "nodes.zig",
        REPO / "src6" / "render.zig",
        REPO / "src6" / "walk.zig",
        REPO / "src6" / "validate.zig",
    ]
    records = [file_record(path) for path in paths]
    records.append(tree_record(REPO / "vendor" / "bzip3"))
    return records


def retained_inputs(
    baseline_manifest_path: Path,
    timing_path: Path,
    corpora_root: Path,
    artifact_root: Path,
    plan_root: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, dict[str, Any]], dict[str, Any]]:
    baseline = json.loads(baseline_manifest_path.read_text(encoding="utf-8"))
    timing = json.loads(timing_path.read_text(encoding="utf-8"))
    if baseline.get("status") != "baseline-preserved-before-simplifying-rebuild":
        raise RuntimeError(f"unexpected baseline status: {baseline.get('status')!r}")
    expected_original = baseline["runner"]
    original = Path(expected_original["preserved_path"])
    if not original.is_absolute():
        original = REPO / original
    verify_file(original, expected_original, "preserved original runner")
    verify_file(timing_path, {"sha256": baseline["retained_evidence"]["timing_sha256"], "bytes": timing_path.stat().st_size}, "retained timing ledger")

    artifact_expectations = {
        (item["corpus"], item["codec"]): item for item in baseline["lex6_artifacts"]
    }
    timing_corpora = {item["corpus"]: item for item in timing.get("corpora", [])}
    if tuple(timing_corpora) != CORPORA:
        raise RuntimeError(f"retained corpus order changed: {tuple(timing_corpora)!r}")

    input_records: dict[str, Any] = {}
    for corpus in CORPORA:
        corpus_timing = timing_corpora[corpus]
        projection_expected = corpus_timing["projection"]
        projection = corpora_root / corpus / "projection.tsv"
        projection_actual = verify_file(projection, projection_expected, f"{corpus} projection")

        plan = corpus_timing["plan"]
        query_expected = plan["query_file"]
        rows_expected = plan["rows_file"]
        query_path = plan_root / corpus / "timed-queries.tsv"
        rows_path = plan_root / corpus / "timed-rows.tsv"
        query_actual = verify_file(query_path, query_expected, f"{corpus} timed query plan")
        rows_actual = verify_file(rows_path, rows_expected, f"{corpus} timed row plan")

        lanes: dict[str, Any] = {}
        timing_lanes = {(lane.get("codec")): lane for lane in corpus_timing.get("lex6", []) if lane.get("codec") in CODECS}
        for codec in CODECS:
            expected = artifact_expectations[(corpus, codec)]
            artifact = artifact_root / corpus / f"lex6-{codec}-64k.lex6"
            actual = verify_file(artifact, expected, f"{corpus}/{codec} retained artifact")
            timing_lane = timing_lanes.get(codec)
            if timing_lane is None or timing_lane.get("artifact", {}).get("sha256") != expected["sha256"]:
                raise RuntimeError(f"timing ledger artifact mismatch for {corpus}/{codec}")
            lanes[codec] = {"artifact": actual, "timing_artifact": timing_lane["artifact"]}
        input_records[corpus] = {
            "projection": projection_actual,
            "plan": {"queries": query_actual, "rows": rows_actual},
            "lanes": lanes,
        }
    return baseline, timing, input_records, {"original": original, "original_expected": expected_original}


def run_one(
    binary: Path,
    corpus: str,
    codec: str,
    projection: Path,
    artifact: Path,
    query_path: Path,
    rows_path: Path,
    oracle: Any,
    queries: Sequence[dict[str, Any]],
    rows: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    argv = [
        str(binary),
        "--mode", "measure",
        "--quiet-gate", GATE,
        "--input", str(projection),
        "--artifact", str(artifact),
        "--queries", str(query_path),
        "--rows", str(rows_path),
    ]
    process = measure.run_capture(argv)
    record: dict[str, Any] = {"binary": file_record(binary), "process": process}
    if process.get("returncode") != 0:
        record.update({"status": "failed", "error": f"runner returned {process.get('returncode')}"})
        return record
    try:
        parsed = measure.parse_runner_output(process["stdout"])
        measure.validate_lex6_timed_result(oracle, queries, rows, parsed)
        if not isinstance(parsed.get("post_verify_all_ns"), int) or parsed["post_verify_all_ns"] <= 0:
            raise RuntimeError("missing positive post_verify_all_ns control")
        for label in ("metadata_open_ns", "reader_init_ns"):
            if not isinstance(parsed.get(label), int) or parsed[label] < 0:
                raise RuntimeError(f"missing {label} control")
    except (RuntimeError, ValueError, KeyError, TypeError) as exc:
        record.update({"status": "failed", "error": f"output validation failed for {corpus}/{codec}: {exc}"})
        return record
    record.update({"status": "ok", "phases": parsed})
    return record


def main(args: argparse.Namespace) -> int:
    if args.quiet_gate != GATE:
        print(f"simplifying_measure.py: refusing timing: expected literal {GATE!r}", file=sys.stderr)
        return 2
    runner = args.runner.resolve()
    if not runner.is_file():
        print(f"simplifying_measure.py: current runner not found: {runner}", file=sys.stderr)
        return 2

    try:
        baseline, timing, inputs, runner_info = retained_inputs(
            args.baseline_manifest.resolve(),
            args.baseline_timing.resolve(),
            args.corpora_root.resolve(),
            args.artifact_root.resolve(),
            args.plan_root.resolve(),
        )
        current = file_record(runner)
        if current["sha256"] == runner_info["original_expected"]["sha256"]:
            raise RuntimeError("current runner is byte-identical to preserved baseline")
        source = source_records()
    except (OSError, RuntimeError, KeyError, ValueError, TypeError) as exc:
        print(f"simplifying_measure.py: ERROR before timing: {exc}", file=sys.stderr)
        return 2

    result: dict[str, Any] = {
        "schema": 1,
        "status": "simplifying-post-review-timed-results",
        "timing": "gate-granted",
        "gate": GATE,
        "schedule": {
            "corpora": list(CORPORA),
            "codecs": list(CODECS),
            "process_runs": PROCESS_RUNS,
            "warmups": 1,
            "batch_ops": measure.BATCH_OPS,
            "prefix_batches": measure.PREFIX_BATCHES,
            "main_page_bytes": 65536,
            "pair_order": "preserved original first, current runner second; corpus then codec then sample",
            "os_cache": "not forcibly evicted; fresh process is not cold disk",
            "verify_all": "runner post_verify_all_ns after measured reads; not a cold verify claim",
        },
        "platform": platform.platform(),
        "baseline_manifest": file_record(args.baseline_manifest.resolve()),
        "baseline_timing_ledger": file_record(args.baseline_timing.resolve()),
        "original_runner": {"path": str(runner_info["original"]), **runner_info["original_expected"]},
        "current_runner": current,
        "source_hashes_current_tree": source,
        "inputs": inputs,
        "corpora": [],
        "failures": [],
    }

    for corpus in CORPORA:
        projection = args.corpora_root.resolve() / corpus / "projection.tsv"
        query_path = args.plan_root.resolve() / corpus / "timed-queries.tsv"
        rows_path = args.plan_root.resolve() / corpus / "timed-rows.tsv"
        try:
            oracle = formats.read_projection(projection)
            queries, rows = measure.load_measure_plan(query_path, rows_path)
        except (OSError, ValueError, formats.FormatError) as exc:
            result["failures"].append({"lane": f"{corpus}/plan", "error_type": type(exc).__name__, "error": str(exc)})
            continue
        corpus_result: dict[str, Any] = {"corpus": corpus, "lanes": []}
        for codec in CODECS:
            artifact = args.artifact_root.resolve() / corpus / f"lex6-{codec}-64k.lex6"
            lane_result: dict[str, Any] = {"format": "lex6", "codec": codec, "artifact": file_record(artifact), "samples": []}
            for sample in range(PROCESS_RUNS):
                # This order is part of the paired schedule.  No retry is made
                # after a process or correctness failure.
                before = run_one(runner_info["original"], corpus, codec, projection, artifact, query_path, rows_path, oracle, queries, rows)
                after = run_one(runner, corpus, codec, projection, artifact, query_path, rows_path, oracle, queries, rows)
                sample_result = {"sample": sample, "before": before, "after": after}
                lane_result["samples"].append(sample_result)
                for side, record in (("before", before), ("after", after)):
                    if record.get("status") != "ok":
                        result["failures"].append({"lane": f"{corpus}/lex6/{codec}/sample-{sample}/{side}", "error": record.get("error", "unknown failure")})
            corpus_result["lanes"].append(lane_result)
        result["corpora"].append(corpus_result)

    if result["failures"]:
        result["status"] = "simplifying-post-review-timed-results-with-failures"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(args.output.resolve()), "failures": len(result["failures"])}, indent=2))
    return 0 if not result["failures"] else 2


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet-gate", required=True)
    parser.add_argument("--runner", type=Path, default=ROOT / "zig-out" / "bin" / "real-lex6")
    parser.add_argument("--baseline-manifest", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-baseline.json")
    parser.add_argument("--baseline-timing", type=Path, default=ROOT / "evidence" / "runs" / "timing-results-post-review-final.json")
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--artifact-root", type=Path, default=Path("/private/tmp/dictionary-real-world-current"))
    parser.add_argument("--plan-root", type=Path, default=Path("/private/tmp/dictionary-real-world-measure-plans-post-review-final"))
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-timing.json")
    return parser.parse_args(argv)


if __name__ == "__main__":
    raise SystemExit(main(parse_args()))
