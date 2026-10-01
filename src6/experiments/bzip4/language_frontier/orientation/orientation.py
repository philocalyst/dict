"""A charged, reversible probe of prefix versus suffix spelling.

Reversing an entire lexical run preserves its identity/repetition while putting
the suffix where v4's prefix CUT can reach it. This is a diagnostic transform,
not a new entropy coder or a claim of linguistic segmentation. The exact byte
classifier is invariant under reversal, even for malformed UTF-8.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import time

RUN = re.compile(rb"[A-Za-z\x80-\xff]+|[0-9]+")
HEADER = struct.Struct("<4sBBHQ")


def reverse_runs(data: bytes) -> bytes:
    return RUN.sub(lambda match: match[0][::-1], data)


def unpack(frame: bytes, decoded: bytes) -> bytes:
    if len(frame) < HEADER.size:
        raise ValueError("truncated orientation header")
    magic, version, mode, reserved, length = HEADER.unpack_from(frame)
    if magic != b"B4OR" or version != 1 or mode not in (0, 1) or reserved:
        raise ValueError("invalid orientation header")
    if len(decoded) != length:
        raise ValueError("decoded length mismatch")
    return reverse_runs(decoded) if mode else decoded


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def capture(argv: list[str], stem: Path) -> None:
    start = time.perf_counter_ns()
    result = subprocess.run(argv, capture_output=True, check=False)
    elapsed = time.perf_counter_ns() - start
    stem.with_suffix(".stdout").write_bytes(result.stdout)
    stem.with_suffix(".stderr").write_bytes(result.stderr)
    stem.with_suffix(".status.json").write_text(json.dumps({
        "argv": argv, "returncode": result.returncode,
        "subprocess_ns_contended_not_benchmark": elapsed,
    }, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"command failed: {argv}; see {stem}.stderr")


def measure(binary: Path, source: Path, output: Path, limit: int) -> dict:
    data = source.read_bytes()
    if limit:
        data = data[:limit]
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    for mode in (0, 1):
        original = output / f"mode{mode}.input"
        compressed = output / f"mode{mode}.bz4"
        decoded_path = output / f"mode{mode}.decoded"
        transformed = reverse_runs(data) if mode else data
        original.write_bytes(transformed)
        capture([str(binary), "c", str(original), str(compressed), "65536"],
                output / f"mode{mode}.encode")
        capture([str(binary), "d", str(compressed), str(decoded_path), "1"],
                output / f"mode{mode}.decode")
        payload = compressed.read_bytes()
        frame = HEADER.pack(b"B4OR", 1, mode, 0, len(data)) + payload
        (output / f"mode{mode}.b4or").write_bytes(frame)
        decoded = unpack(frame, decoded_path.read_bytes())
        if decoded != data:
            raise AssertionError("orientation round trip failed")
        rows.append({"mode": mode, "complete_bytes": len(frame),
                     "wrapper_bytes": HEADER.size, "bz4_bytes": len(payload),
                     "sha256": sha(frame), "roundtrip": True})
    result = {"source": str(source), "raw_bytes": len(data),
              "input_sha256": sha(data), "binary_sha256": sha(binary.read_bytes()),
              "rows": rows,
              "change_bytes": rows[1]["complete_bytes"] - rows[0]["complete_bytes"]}
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--limit", type=int, default=262144)
    args = parser.parse_args()
    print(json.dumps(measure(args.binary.resolve(), args.source.resolve(),
                             args.output.resolve(), args.limit), indent=2))


if __name__ == "__main__":
    main()
