"""Count symbolic decoder work; this is not a native timing estimate.

Uses the candidate's entropy helpers to inspect its actual saved streams. The
work counters are descriptive, not an independent correctness oracle. Run only
after the serial timing lane finishes.
"""

from __future__ import annotations

from collections import Counter
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[5]))
from src6.experiments.bzip4.frontier_python.symbol_bwt import codec


def rank_quantile(histogram: Counter, fraction: float) -> int:
    target = max(1, int(sum(histogram.values()) * fraction))
    accumulated = 0
    for rank in sorted(histogram):
        accumulated += histogram[rank]
        if accumulated >= target:
            return rank
    return 0


def profile(path: Path) -> dict:
    frame = path.read_bytes()
    prepared = codec.prepare(frame)
    histogram = Counter()
    event_count = 0
    coded_bits = 0
    coded_raw_bytes = 0
    raw_blocks = 0
    for record in prepared.parsed.records:
        first = prepared.parsed.payload_offset + record.offset
        payload = frame[first : first + record.encoded_bytes]
        if payload[0] == codec.MODE_RAW:
            raw_blocks += 1
            continue
        events = codec._huffman_decode(payload[1:], record.valid_bits, record.event_count, prepared._tree)
        ranks = codec._events_to_ranks(events, record.token_count, prepared.model.symbol_count)
        histogram.update(ranks)
        event_count += len(events)
        coded_bits += record.valid_bits
        coded_raw_bytes += record.raw_bytes
    root_count = sum(histogram.values())
    prefix_moves = sum(rank * count for rank, count in histogram.items())
    return {
        "frame": str(path),
        "frame_sha256": hashlib.sha256(frame).hexdigest(),
        "raw_bytes": prepared.parsed.raw_length,
        "coded_raw_bytes": coded_raw_bytes,
        "coded_root_count": root_count,
        "event_count": event_count,
        "huffman_bits": coded_bits,
        "raw_block_count": raw_blocks,
        "bytes_per_coded_root": coded_raw_bytes / root_count if root_count else None,
        "mtf_alphabet": prepared.model.symbol_count,
        "mtf_rank_sum": prefix_moves,
        "mtf_rank_median": rank_quantile(histogram, 0.5),
        "mtf_rank_p95": rank_quantile(histogram, 0.95),
        "mtf_rank_max": max(histogram, default=0),
        "ideal_u16_prefix_shift_bytes": 2 * prefix_moves,
        "note": "Logical copied-prefix volume only; excludes reads/cache effects and is not a native speed or memory-bandwidth prediction.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    summary = json.loads((args.root / "results.json").read_text())
    assert summary["status"] == 0
    results = []
    for item in summary["records"]:
        row = item["result"]
        if row["variant"] == "symbol_bwt":
            result = profile(Path(row["frame_path"]))
            result.update({"corpus": row["corpus"], "lane": row["lane"], "block_bytes": row["block_bytes"]})
            results.append(result)
    print(json.dumps({"status": "pass", "timing_disabled": True, "records": results}, sort_keys=True))
