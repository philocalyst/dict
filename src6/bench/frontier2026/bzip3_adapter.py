#!/usr/bin/env python3
"""Whole-frame bzip3 1.5.1 control over the root-provided pinned shared library."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROTOCOL = REPO / "src6/experiments/bzip4/frontier_python"
sys.path.insert(0, str(PROTOCOL))

from protocol.framing import block_crc32, frame_blocks, open_frame
from protocol.native_bzip3 import Bzip3Session, _Bzip3Bindings


def encode(raw_path: Path, output_path: Path, block_bytes: int, library: Path) -> None:
    raw = raw_path.read_bytes()
    parts = [raw[i:i + block_bytes] for i in range(0, len(raw), block_bytes)]
    if not parts:
        output_path.write_bytes(frame_blocks([], [], block_bytes))
        return
    bindings = _Bzip3Bindings(library.resolve())
    with Bzip3Session(block_bytes, purpose="encode", bindings=bindings) as session:
        encoded = [session.encode_block(part) for part in parts]
    output_path.write_bytes(frame_blocks(encoded, parts, block_bytes))


def decode(frame_path: Path, output_path: Path, block_bytes: int, library: Path) -> None:
    wire = frame_path.read_bytes()
    frame = open_frame(wire, max_raw_bytes=2**32 - 1, max_frame_bytes=2**32 - 1)
    if frame.block_bytes != block_bytes:
        raise ValueError(f"frame block size {frame.block_bytes} does not match requested {block_bytes}")
    bindings = _Bzip3Bindings(library.resolve())
    output = bytearray()
    with Bzip3Session(block_bytes, purpose="decode", bindings=bindings) as session:
        for index, rec in enumerate(frame.records):
            chunk = session.decode_block(frame.block_encoded(index), rec.raw_bytes)
            if block_crc32(chunk) != rec.crc32:
                raise ValueError(f"block {index} CRC mismatch")
            output.extend(chunk)
    output_path.write_bytes(output)


def extract(frame_path: Path, output_path: Path, block_bytes: int, index: int, library: Path) -> None:
    frame = open_frame(frame_path.read_bytes(), max_raw_bytes=2**32 - 1, max_frame_bytes=2**32 - 1)
    if frame.block_bytes != block_bytes:
        raise ValueError(f"frame block size {frame.block_bytes} does not match requested {block_bytes}")
    if index < 0 or index >= frame.block_count:
        raise ValueError(f"block index {index} is out of range")
    record = frame.block_record(index)
    bindings = _Bzip3Bindings(library.resolve())
    with Bzip3Session(block_bytes, purpose="decode", bindings=bindings) as session:
        raw = session.decode_block(frame.block_encoded(index), record.raw_bytes)
    if block_crc32(raw) != record.crc32:
        raise ValueError(f"block {index} CRC mismatch")
    output_path.write_bytes(raw)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("encode", "decode", "extract"))
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--block-bytes", type=int, default=65536)
    parser.add_argument("--block-index", type=int, default=0)
    parser.add_argument("--library", type=Path, default=Path("/workspace/scratch/libbzip3.so"))
    args = parser.parse_args()
    if args.block_bytes <= 0:
        parser.error("--block-bytes must be positive")
    if args.operation == "encode":
        encode(args.input, args.output, args.block_bytes, args.library)
    elif args.operation == "decode":
        decode(args.input, args.output, args.block_bytes, args.library)
    else:
        extract(args.input, args.output, args.block_bytes, args.block_index, args.library)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
