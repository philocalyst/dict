#!/usr/bin/env python3
"""Screen record constructors with a paid conditional spelling reparse.

Both candidate graphs compile into the unchanged v4 entropy frame. A WPG2
wrapper pays the source-page index, selector, frame, and checksums. The DP
and first native fit are encoder work; neither is a decoder dependency.
"""
import argparse
import hashlib
import json
import os
import struct
import tempfile
import time
import zlib
from pathlib import Path

from compose_best import MAX_RAW, MAX_FRAME
from compose_m import WGP6, run
from compose_page import PAGE, transform_page, decode
from template_split import varint

BACKEND = Path(os.environ.get("WPG6_BIN_DIR", str(WGP6)))


def wrap(raw, parts, mode, payload):
    index = b"".join(varint(len(part)) + struct.pack("<I", zlib.crc32(raw[i * PAGE:(i + 1) * PAGE]))
                     for i, part in enumerate(parts))
    header = b"WPG2" + bytes((mode,)) + varint(len(raw)) + varint(PAGE) + varint(len(parts)) + index
    return header + struct.pack("<I", zlib.crc32(header)) + varint(len(payload)) + payload + struct.pack("<I", zlib.crc32(raw))


def fit(data, modes=(0, 1, 2, 3), profile="quality"):
    if len(data) > MAX_RAW:
        raise ValueError("input bound")
    if profile not in ("quality", "access"):
        raise ValueError("profile")
    hoist = profile == "access"
    compiler = BACKEND / ("native_forward_hoist" if hoist else "native_forward")
    raw_pages = [data[i:i + PAGE] for i in range(0, len(data), PAGE)]
    winner = None
    trials = []
    seen_sources = set()
    for mode in modes:
        mode_start = time.perf_counter_ns()
        parts = [transform_page(raw, mode)[0] for raw in raw_pages]
        source = b"".join(parts)
        if len(source) > MAX_RAW or source in seen_sources:
            continue
        seen_sources.add(source)
        transform_ns = time.perf_counter_ns() - mode_start
        with tempfile.TemporaryDirectory(prefix="wpg-dp-") as temp:
            base = Path(temp)
            raw, graph, frame, check, prices, reparsed, updated = [base / n for n in
                ("source", "base.forward", "base.frame", "check.frame", "prices", "reparsed.forward", "updated.frame")]
            raw.write_bytes(source)
            phase_start = time.perf_counter_ns()
            first = run([BACKEND / "m_reference", raw, frame, graph, PAGE, 20, "a-best", 1, int(hoist)])
            initial_wall_ns = time.perf_counter_ns() - phase_start
            phase_start = time.perf_counter_ns()
            fitted = run([compiler, "compile", graph, check, 0, prices])
            price_wall_ns = time.perf_counter_ns() - phase_start
            if check.read_bytes() != frame.read_bytes():
                raise AssertionError("baseline refit changed frame")
            phase_start = time.perf_counter_ns()
            reparse = run([BACKEND / "reparse_context", raw, graph, prices, reparsed, "both", 0])
            reparse_wall_ns = time.perf_counter_ns() - phase_start
            phase_start = time.perf_counter_ns()
            second = run([compiler, "compile", reparsed, updated, 0])
            final_wall_ns = time.perf_counter_ns() - phase_start
            phase_wall_ns = {"python_transform": transform_ns, "initial_model_process": initial_wall_ns,
                             "price_model_process": price_wall_ns, "conditional_dp_process": reparse_wall_ns,
                             "final_model_process": final_wall_ns}
            for label, path, ledger in (("base", frame, first), ("conditional_dp", updated, second)):
                payload = path.read_bytes()
                if len(payload) > MAX_FRAME:
                    continue
                archive = wrap(data, parts, mode, payload)
                row = {"mode": mode, "profile": profile, "graph": label, "source_bytes": len(source),
                       "frame_bytes": len(archive), "v4_frame_bytes": len(payload),
                       "frame_sha256": hashlib.sha256(archive).hexdigest(),
                       "codec_ns_paid": sum(int(r.get("codec_ns", 0)) for r in
                                            (first, fitted, reparse, second)),
                       "phase_wall_ns": phase_wall_ns,
                       "model_dictionary_bytes": ledger.get("model_dictionary_bytes"),
                       "payload_bytes": ledger.get("payload_bytes")}
                trials.append(row)
                if winner is None or len(archive) < len(winner):
                    winner = archive
    if winner is None:
        raise ValueError("no candidate")
    return winner, trials


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--modes", default="0,1,2,3")
    ap.add_argument("--profile",choices=("quality","access"),default="quality")
    args = ap.parse_args()
    raw = args.input.read_bytes()
    modes = tuple(int(m) for m in args.modes.split(","))
    if any(m not in range(4) for m in modes):
        raise ValueError("mode")
    archive, rows = fit(raw, modes, args.profile)
    args.output.write_bytes(archive)
    if decode(archive, native_register=True) != raw:
        raise AssertionError("fresh native constructor mismatch")
    print(json.dumps({"input_bytes": len(raw), "input_sha256": hashlib.sha256(raw).hexdigest(),
                      "profile": args.profile,
                      "frame_bytes": len(archive), "selected_mode": archive[4],
                      "frame_sha256": hashlib.sha256(archive).hexdigest(), "trials": rows}))


if __name__ == "__main__":
    main()
