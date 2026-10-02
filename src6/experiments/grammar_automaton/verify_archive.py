#!/usr/bin/env python3
"""Independent full-source, all-page, ledger, and control identity gate."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def sha(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def call(*args):
    run = subprocess.run([str(x) for x in args], check=True, text=True, capture_output=True)
    return json.loads(run.stdout)


def verify(codec: Path, source: Path, graph: Path, control: Path, frame: Path):
    raw = source.read_bytes()
    with tempfile.TemporaryDirectory(prefix="wga-verify-") as td:
        temp = Path(td)
        inspect = temp / "inspect.json"
        ledger = call(codec, "inspect", frame, inspect)
        if ledger["frame_bytes"] != frame.stat().st_size:
            raise ValueError("ledger frame size")
        fields = ("header_bytes", "directory_bytes", "model_dictionary_bytes", "payload_bytes")
        if sum(ledger[field] for field in fields) != ledger["frame_bytes"]:
            raise ValueError("ledger parts do not sum to complete frame")
        if ledger["raw_bytes"] != len(raw):
            raise ValueError("ledger source size")
        sizes = ledger["block_raw_lengths"]
        if sum(sizes) != len(raw) or any(n < 1 or n > 65536 for n in sizes):
            raise ValueError("source page directory")
        whole = temp / "whole.raw"
        call(codec, "decode", frame, whole)
        if whole.read_bytes() != raw:
            raise ValueError("whole source mismatch")
        start = 0
        page_path = temp / "page.raw"
        for index, length in enumerate(sizes):
            response = call(codec, "extract", frame, page_path, index)
            if response["block_index"] != index or response["raw_bytes"] != length:
                raise ValueError(f"page {index} metadata")
            if page_path.read_bytes() != raw[start : start + length]:
                raise ValueError(f"page {index} mismatch")
            start += length
    return {
        "source_bytes": len(raw), "source_sha256": sha(source),
        "graph_sha256": sha(graph), "untouched_M_bytes": control.stat().st_size,
        "untouched_M_sha256": sha(control), "wga_bytes": frame.stat().st_size,
        "wga_sha256": sha(frame), "pages_exact": len(sizes),
        "ledger": {field: ledger[field] for field in fields},
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    for name in ("codec", "source", "graph", "control", "frame"):
        ap.add_argument(name, type=Path)
    args = ap.parse_args()
    print(json.dumps(verify(args.codec, args.source, args.graph, args.control, args.frame)))
