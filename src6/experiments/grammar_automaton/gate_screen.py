#!/usr/bin/env python3
"""Optimistic, model-charged hot-symbol gate screen over exact WGT4 events.

The arithmetic is a lower bound, not a codec result. Each candidate pays a
fixed metadata/table floor. Surviving candidates must be fitted as full frames.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import struct
import sys


def read_trace(path: Path):
    data = path.read_bytes()
    if data[:4] != b"WGT4":
        raise ValueError("expected exact WGT4 model and event trace")
    rows, alphabet, delta_count, payload_count = struct.unpack_from("<4I", data, 4)
    pos = 20
    logs = data[pos : pos + rows]
    pos += rows
    norm = struct.unpack_from(f"<{rows * alphabet}H", data, pos)
    pos += 2 * rows * alphabet
    events = []
    for is_delta, count in ((True, delta_count), (False, payload_count)):
        stream = []
        for _ in range(count):
            row, sym, suffix, suffix_len, kind, token_len, after_row = struct.unpack_from(
                "<HHIBBIH", data, pos
            )
            pos += 16
            if row >= rows or sym >= alphabet or not norm[row * alphabet + sym]:
                raise ValueError("trace event outside fitted native table")
            stream.append((row, sym, suffix, suffix_len, kind, token_len, after_row))
        events.append((is_delta, stream))
    if pos != len(data):
        raise ValueError("trailing trace bytes")
    return rows, alphabet, logs, norm, events


FEATURES = (
    "suffix1", "suffix2", "suffix3", "suffix4", "previous_kind",
    "previous_length_bin", "second_base_row", "two_kinds", "kind_length",
    "suffix1_kind", "suffix2_kind", "previous_first_symbol", "stream",
)


def key_for(feature, row, previous, second, is_delta):
    _, _, suffix, suffix_len, _, _, _ = row
    if feature == "stream":
        return int(is_delta)
    if feature.startswith("suffix"):
        length = int(feature[6])
        if suffix_len < length:
            return None
        key = suffix & ((1 << (8 * length)) - 1)
        if feature.endswith("_kind"):
            return key * 4 + previous[4] if previous else None
        return key
    if not previous:
        return None
    if feature == "previous_kind":
        return previous[4]
    if feature == "previous_length_bin":
        return min(16, max(1, previous[5]).bit_length() - 1)
    if feature == "second_base_row":
        return previous[0]
    if feature == "two_kinds":
        return second[4] * 4 + previous[4] if second else None
    if feature == "kind_length":
        return previous[4] * 32 + min(16, max(1, previous[5]).bit_length() - 1)
    if feature == "previous_first_symbol":
        return previous[1]
    raise ValueError(feature)


def screen(path: Path, metadata_floor_bytes: int):
    rows, alphabet, logs, norm, streams = read_trace(path)
    report = []
    for feature in FEATURES:
        observations = defaultdict(Counter)
        for is_delta, stream in streams:
            previous = second = None
            for record in stream:
                if not record[3]:
                    previous = second = None
                key = key_for(feature, record, previous, second, is_delta)
                if key is not None:
                    observations[(record[0], key)][record[1]] += 1
                second, previous = previous, record
        candidates = []
        for (base_row, key), counts in observations.items():
            n = sum(counts.values())
            if n < 8:
                continue
            row_size = 1 << logs[base_row]
            for hot, count in counts.items():
                p = count / n
                gate_entropy = 0 if p == 1 else -n * (
                    p * math.log2(p) + (1 - p) * math.log2(1 - p)
                )
                base_cost = count * math.log2(row_size / norm[base_row * alphabet + hot])
                estimated_gain = base_cost - gate_entropy - 8 * metadata_floor_bytes
                if estimated_gain > 0:
                    candidates.append((estimated_gain, base_row, key, hot, n, count))
        candidates.sort(reverse=True)
        report.append({
            "feature": feature,
            "positive_selectors": len(candidates),
            "best_gate": candidates[0] if candidates else None,
            "optimistic_net_bytes_cap_16": round(sum(c[0] for c in candidates[:16]) / 8, 2),
            "optimistic_net_bytes_cap_64": round(sum(c[0] for c in candidates[:64]) / 8, 2),
        })
    report.sort(key=lambda item: item["optimistic_net_bytes_cap_64"], reverse=True)
    return {
        "trace": str(path), "rows": rows, "alphabet": alphabet,
        "delta_events": len(streams[0][1]), "payload_events": len(streams[1][1]),
        "metadata_floor_bytes_per_gate": metadata_floor_bytes,
        "note": "Optimistic tANS entropy screen; full gate rows, selectors and archive framing require an actual codec trial.",
        "features": report,
    }


if __name__ == "__main__":
    trace = Path(sys.argv[1])
    floor = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    print(json.dumps(screen(trace, floor), indent=2))
