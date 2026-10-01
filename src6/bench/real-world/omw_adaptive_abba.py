#!/usr/bin/env python3
"""Prepare/run the fixed OMW-adaptive order-bias diagnostic.

The diagnostic is intentionally separate from the completed six-lane paired
ledger.  It uses two fixed ``original, current, current, original`` blocks
(eight fresh processes total), the same retained OMW adaptive artifact and
timed plans, and the existing public measure/oracle validator.  It does not
evict OS caches, rebuild anything, retry a failed sample, or replace the
original comparison evidence.
"""

from __future__ import annotations

import argparse
import json
import platform
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
GATE = "ROOT-EXPLICIT-QUIET-GATE"
CORPUS = "omw-ja-20"
CODEC = "adaptive"
BLOCKS = 2
ORDER = ("before", "after", "after", "before")

sys.path.insert(0, str(ROOT))
import formats  # noqa: E402
import measure  # noqa: E402
from simplifying_measure import file_record, source_records, verify_file  # noqa: E402


def resolve_repo_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else REPO / path


def main(args: argparse.Namespace) -> int:
    if args.quiet_gate != GATE:
        print(f"omw_adaptive_abba.py: refusing timing: expected literal {GATE!r}", file=sys.stderr)
        return 2
    try:
        baseline_path = args.baseline.resolve()
        timing_path = args.timing.resolve()
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        timing = json.loads(timing_path.read_text(encoding="utf-8"))
        original_expected = baseline["runner"]
        original = resolve_repo_path(original_expected["preserved_path"])
        verify_file(original, original_expected, "preserved original runner")
        current = args.runner.resolve()
        current_record = file_record(current)
        if current_record["sha256"] == original_expected["sha256"]:
            raise RuntimeError("current runner is byte-identical to preserved original")

        corpus_timing = next(item for item in timing["corpora"] if item["corpus"] == CORPUS)
        projection = args.corpora_root.resolve() / CORPUS / "projection.tsv"
        verify_file(projection, corpus_timing["projection"], "OMW projection")
        query_path = args.plan_root.resolve() / CORPUS / "timed-queries.tsv"
        rows_path = args.plan_root.resolve() / CORPUS / "timed-rows.tsv"
        verify_file(query_path, corpus_timing["plan"]["query_file"], "OMW timed query plan")
        verify_file(rows_path, corpus_timing["plan"]["rows_file"], "OMW timed row plan")
        expected_artifact = next(
            item for item in baseline["lex6_artifacts"] if item["corpus"] == CORPUS and item["codec"] == CODEC
        )
        artifact = args.artifact_root.resolve() / CORPUS / "lex6-adaptive-64k.lex6"
        artifact_actual = verify_file(artifact, expected_artifact, "OMW adaptive retained artifact")
        oracle = formats.read_projection(projection)
        queries, rows = measure.load_measure_plan(query_path, rows_path)
        source = source_records()
        source.append(file_record(Path(__file__).resolve()))
    except (OSError, KeyError, StopIteration, ValueError, TypeError, formats.FormatError, RuntimeError) as exc:
        print(f"omw_adaptive_abba.py: ERROR before timing: {exc}", file=sys.stderr)
        return 2

    result: dict[str, Any] = {
        "schema": 1,
        "status": "omw-adaptive-abba-timed-results",
        "timing": "gate-granted",
        "gate": GATE,
        "purpose": "Order-bias diagnostic for the OMW adaptive uncached render regression; not a replacement for the six-lane ledger.",
        "schedule": {
            "blocks": BLOCKS,
            "order_per_block": list(ORDER),
            "fresh_processes": BLOCKS * len(ORDER),
            "os_cache": "not forcibly evicted; fresh process is not cold disk",
            "retries": 0,
        },
        "platform": platform.platform(),
        "baseline_timing_ledger": file_record(timing_path),
        "baseline_manifest": file_record(baseline_path),
        "original_runner": {"path": str(original), **original_expected},
        "current_runner": current_record,
        "projection": file_record(projection),
        "plan": {"queries": file_record(query_path), "rows": file_record(rows_path)},
        "artifact": artifact_actual,
        "source_hashes_current_tree": source,
        "blocks": [],
        "failures": [],
    }

    binaries = {"before": original, "after": current}
    for block_index in range(BLOCKS):
        block: dict[str, Any] = {"block": block_index, "order": []}
        for position, side in enumerate(ORDER):
            record = measure.run_capture(
                [
                    str(binaries[side]),
                    "--mode", "measure",
                    "--quiet-gate", GATE,
                    "--input", str(projection),
                    "--artifact", str(artifact),
                    "--queries", str(query_path),
                    "--rows", str(rows_path),
                ]
            )
            entry: dict[str, Any] = {"position": position, "side": side, "binary": file_record(binaries[side]), "process": record}
            if record.get("returncode") != 0:
                entry.update({"status": "failed", "error": f"runner returned {record.get('returncode')}"})
            else:
                try:
                    parsed = measure.parse_runner_output(record["stdout"])
                    measure.validate_lex6_timed_result(oracle, queries, rows, parsed)
                    if not isinstance(parsed.get("post_verify_all_ns"), int) or parsed["post_verify_all_ns"] <= 0:
                        raise RuntimeError("missing positive post_verify_all_ns")
                    entry.update({"status": "ok", "phases": parsed})
                except (RuntimeError, ValueError, KeyError, TypeError) as exc:
                    entry.update({"status": "failed", "error": str(exc)})
            if entry.get("status") != "ok":
                result["failures"].append({"block": block_index, "position": position, "side": side, "error": entry.get("error")})
            block["order"].append(entry)
        result["blocks"].append(block)

    if result["failures"]:
        result["status"] = "omw-adaptive-abba-timed-results-with-failures"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(args.output.resolve()), "failures": len(result["failures"])}, indent=2))
    return 0 if not result["failures"] else 2


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet-gate", required=True)
    parser.add_argument("--runner", type=Path, default=ROOT / "zig-out" / "bin" / "real-lex6")
    parser.add_argument("--baseline", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-baseline.json")
    parser.add_argument("--timing", type=Path, default=ROOT / "evidence" / "runs" / "timing-results-post-review-final.json")
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--artifact-root", type=Path, default=Path("/private/tmp/dictionary-real-world-current"))
    parser.add_argument("--plan-root", type=Path, default=Path("/private/tmp/dictionary-real-world-measure-plans-post-review-final"))
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-omw-adaptive-abba.json")
    return parser.parse_args(argv)


if __name__ == "__main__":
    raise SystemExit(main(parse_args()))
