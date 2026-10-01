#!/usr/bin/env python3
"""Recompute aggregate summaries from immutable per-case evidence JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path)
    args = parser.parse_args()
    rows: list[dict] = []
    for path in sorted(args.run.glob("*/dev.json")) + sorted(args.run.glob("*/final.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        old = payload.get("baseline_v4", {}).get("storage", {}).get("total", 0)
        bzip3 = payload.get("baseline_bzip3", {}).get("storage", {}).get("total", 0)
        for candidate in payload.get("candidates", []):
            candidate = dict(candidate)
            candidate["v4_frame_bytes"] = old
            candidate["bzip3_frame_bytes"] = bzip3
            candidate["v4_frame_ratio"] = candidate["frame_bytes"] / old if old else None
            candidate["bzip3_frame_ratio"] = candidate["frame_bytes"] / bzip3 if bzip3 else None
            rows.append(candidate)
    summary: dict = {"phase": rows[0]["split"] if rows else "unknown", "cases": len({r["case"] for r in rows}), "candidates": {}}
    for row in rows:
        key = f"k{row['k_teacher']}-{row['clustering']}"
        bucket = summary["candidates"].setdefault(key, {"rows": 0, "frame_bytes": 0, "input_bytes": 0, "v4_bytes": 0, "bzip3_bytes": 0, "teacher_bits": 0.0, "compiled_bits": 0.0})
        bucket["rows"] += 1
        bucket["frame_bytes"] += row["frame_bytes"]
        bucket["input_bytes"] += row["frame_breakdown"]["output"]
        bucket["v4_bytes"] += row["v4_frame_bytes"]
        bucket["bzip3_bytes"] += row["bzip3_frame_bytes"]
        bucket["teacher_bits"] += row["teacher_cross_entropy_bits"]
        bucket["compiled_bits"] += row["compiled_cross_entropy_bits"]
    for bucket in summary["candidates"].values():
        n = max(1, bucket["input_bytes"])
        bucket["frame_bpb"] = 8.0 * bucket["frame_bytes"] / n
        bucket["teacher_bpb"] = bucket["teacher_bits"] / n
        bucket["compiled_bpb"] = bucket["compiled_bits"] / n
        bucket["frame_vs_v4"] = bucket["frame_bytes"] / max(1, bucket["v4_bytes"])
        bucket["frame_vs_bzip3"] = bucket["frame_bytes"] / max(1, bucket["bzip3_bytes"])
    (args.run / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (args.run / "results.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.run / "summary.json")


if __name__ == "__main__":
    main()

