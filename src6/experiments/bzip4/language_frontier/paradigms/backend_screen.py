#!/usr/bin/env python3
"""Apply common byte compressors to complete PPL1 frames.

This is a secondary diagnostic only.  A PPL1 frame already contains its
header, dictionary/model, payload, CRC, and all exception bytes.  Compressing
that *complete* frame with zlib or bz2 makes the backend identical across the
independent, CUT, edit, program, and DAFSA candidates.  It is not the bz4
tANS backend and must not be reported as a production codec result.
"""

from __future__ import annotations

import argparse
import bz2
import json
import pathlib
import sys
import zlib

import screen


def compress(name: str, data: bytes) -> bytes:
    if name == "zlib":
        return zlib.compress(data, level=9)
    if name == "bz2":
        return bz2.compress(data, compresslevel=9)
    raise ValueError(f"unknown backend {name}")


def decompress(name: str, data: bytes) -> bytes:
    if name == "zlib":
        return zlib.decompress(data)
    if name == "bz2":
        return bz2.decompress(data)
    raise ValueError(f"unknown backend {name}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="exact byte input")
    parser.add_argument("--limit", type=int, default=65_536, help="prefix bytes to screen (0 means all)")
    parser.add_argument("--modes", default="independent,cut,edit,program,dafsa")
    parser.add_argument("--order", choices=("first", "lex", "both"), default="both")
    parser.add_argument("--backend", choices=("zlib", "bz2", "both"), default="both")
    parser.add_argument("--max-edits", type=int, default=4)
    parser.add_argument("--max-word", type=int, default=128)
    parser.add_argument("--edit-limit", type=int, default=2_000)
    args = parser.parse_args(argv)
    if args.limit < 0 or args.max_edits < 0 or args.max_word < 1 or args.edit_limit < 0:
        parser.error("limits must be non-negative and max-word positive")

    full = pathlib.Path(args.input).read_bytes()
    data = full[: args.limit] if args.limit else full
    words, pieces = screen.scan(data)
    backends = ("zlib", "bz2") if args.backend == "both" else (args.backend,)
    modes = screen.parse_mode_list(args.modes)
    orders = (args.order,) if args.order != "both" else ("first", "lex")
    print(json.dumps({
        "input": args.input,
        "input_bytes": len(data),
        "source_bytes": len(full),
        "input_hash": screen.hash_hex(data),
        "word_types": len(words),
        "word_occurrences": sum(piece.is_word for piece in pieces),
        "backends": list(backends),
        "modes": modes,
        "orders": list(orders),
        "note": "complete PPL1 frame compressed; not bz4/tANS",
    }, sort_keys=True))

    for backend in backends:
        direct = compress(backend, data)
        if decompress(backend, direct) != data:
            raise AssertionError(f"{backend} raw direct round-trip mismatch")
        print(json.dumps({
            "kind": "raw_direct",
            "backend": backend,
            "input_bytes": len(data),
            "compressed_bytes": len(direct),
            "input_hash": screen.hash_hex(data),
            "compressed_hash": screen.hash_hex(direct),
            "roundtrip": True,
        }, sort_keys=True))
        for mode in modes:
            mode_orders = ("lex",) if mode == "dafsa" else orders
            for order in mode_orders:
                frame, stats = screen.build_frame(
                    data,
                    words,
                    pieces,
                    mode,
                    order,
                    args.max_edits,
                    args.max_word,
                    args.edit_limit,
                )
                wrapped = compress(backend, frame)
                if decompress(backend, wrapped) != frame:
                    raise AssertionError(f"{backend} wrapped {mode}/{order} round-trip mismatch")
                row = stats.as_dict()
                row.update({
                    "kind": "complete_frame",
                    "backend": backend,
                    "frame_bytes": len(frame),
                    "compressed_bytes": len(wrapped),
                    "raw_direct_bytes": len(direct),
                    "delta_vs_raw_direct": len(wrapped) - len(direct),
                    "compressed_hash": screen.hash_hex(wrapped),
                    "roundtrip": True,
                })
                print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
