"""Measure Python-managed preparation and selected-query allocation peaks.

This separate diagnostic is intentionally not a speed benchmark. Tracing begins
after the frame and codec modules are loaded. It measures extra traced Python
allocations, not OS RSS, native allocator memory, or a full-output decode peak.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
from pathlib import Path
import sys
import tracemalloc

sys.path.insert(0, str(Path(__file__).resolve().parents[5]))
from src6.experiments.bzip4.frontier_python.bwt_context import codec as bwt
from src6.experiments.bzip4.frontier_python.grammar import grammar
from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_bwt


def measure_query(codec, frame: bytes, label: str, check: dict) -> dict:
    gc.collect()
    tracemalloc.start()
    try:
        prepared = codec.prepare(frame)
        prepare_live, prepare_peak = tracemalloc.get_traced_memory()
        gc.collect()
        current_before, _ = tracemalloc.get_traced_memory()
        tracemalloc.reset_peak()
        decoded = prepared.decode_block(check["index"])
        current_after, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert hashlib.sha256(decoded).hexdigest() == check["decode_trials"][0]["sha256"]
    return {
        "query": label,
        "index": check["index"],
        "raw_bytes": len(decoded),
        "prepare_live_traced_bytes": prepare_live,
        "prepare_peak_traced_bytes": prepare_peak,
        "current_before_bytes": current_before,
        "current_after_bytes": current_after,
        "peak_bytes_including_prepared": peak,
        "peak_increment_from_query_start_bytes": peak - current_before,
    }


def profile(row: dict) -> dict:
    frame = Path(row["frame_path"]).read_bytes()
    assert hashlib.sha256(frame).hexdigest() == row["frame_sha256"]
    codec = bwt if row["variant"] == "F" else grammar if row["variant"] == "grammar_input" else symbol_bwt
    blocks = [measure_query(codec, frame, label, row[label]) for label in ("first_block", "random_block")]
    return {
        "corpus": row["corpus"],
        "lane": row["lane"],
        "variant": row["variant"],
        "block_bytes": row["block_bytes"],
        "frame_bytes_loaded_before_trace": len(frame),
        "frame_sha256": row["frame_sha256"],
        "selected_block_queries": blocks,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    summary = json.loads((args.root / "results.json").read_text())
    assert summary["status"] == 0
    results = [profile(item["result"]) for item in summary["records"] if item["result"]["variant"] != "native"]
    print(json.dumps({
        "status": "pass",
        "timing_disabled": True,
        "scope": "Extra tracemalloc-visible Python allocations after frame/modules load; excludes frame, interpreter baseline, untraced native allocations, and full-output decode peak.",
        "query_state": "Fresh preparation for each first/middle query; no retained derived cache is carried between queries.",
        "records": results,
    }, sort_keys=True))
