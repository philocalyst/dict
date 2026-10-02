#!/usr/bin/env python3
"""Paid 1 MiB development screen; no final holdout inputs."""
import hashlib
import json
import sys
from pathlib import Path

import template_split as t

ROOT = Path(__file__).resolve().parents[3]
SAMPLES = ROOT / "src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples"


def main():
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    for name in ("freedict", "gcide", "omw"):
        raw = (SAMPLES / f"{name}-eval8-saved/external-decoded.bin").read_bytes()[:1 << 20]
        old = t.native("encode", raw)
        assert t.native("decode", old) == raw
        print(name, "old", len(old), flush=True)
        for by_tag, min_count in ((False, 1), (True, 1), (True, 16), (True, 64)):
            frame, detail = t.encode(raw, min_count, by_tag)
            assert t.decode(frame, by_tag) == raw
            label = f"{name}-{'tag' if by_tag else 'all'}-{min_count}"
            (output / f"{label}.wcx").write_bytes(frame)
            row = {"corpus": name, "policy": label, "input_sha256": hashlib.sha256(raw).hexdigest(),
                   "old_bytes": len(old), "frame_sha256": hashlib.sha256(frame).hexdigest(),
                   "frame_bytes": len(frame), "delta_bytes": len(frame)-len(old), **detail}
            rows.append(row)
            print(json.dumps(row), flush=True)
    (output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
