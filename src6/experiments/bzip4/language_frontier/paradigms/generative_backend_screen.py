#!/usr/bin/env python3
"""Common-backend diagnostic for the shared generative-set frame."""

from __future__ import annotations

import argparse
import bz2
import json
import pathlib
import zlib

import generative_screen
import screen


def pack(backend: str, data: bytes) -> bytes:
    if backend == "zlib":
        return zlib.compress(data, 9)
    if backend == "bz2":
        return bz2.compress(data, compresslevel=9)
    raise ValueError(backend)


def unpack(backend: str, data: bytes) -> bytes:
    if backend == "zlib":
        return zlib.decompress(data)
    if backend == "bz2":
        return bz2.decompress(data)
    raise ValueError(backend)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    parser.add_argument("--limit", type=int, default=65_536)
    parser.add_argument("--order", choices=("first", "lex", "both"), default="both")
    parser.add_argument("--backend", choices=("zlib", "bz2", "both"), default="both")
    args = parser.parse_args(argv)
    if args.limit < 0:
        parser.error("limit must be non-negative")
    full = pathlib.Path(args.input).read_bytes()
    data = full[: args.limit] if args.limit else full
    first_words, pieces = screen.scan(data)
    orders = (args.order,) if args.order != "both" else ("first", "lex")
    backends = ("zlib", "bz2") if args.backend == "both" else (args.backend,)
    print(json.dumps({
        "input": args.input,
        "input_bytes": len(data),
        "source_bytes": len(full),
        "input_hash": screen.hash_hex(data),
        "word_types": len(first_words),
        "word_occurrences": sum(piece.is_word for piece in pieces),
        "note": "complete PGS1 shared-set frame through generic backend; not bz4/tANS",
        "backends": list(backends),
        "orders": list(orders),
    }, sort_keys=True))
    for backend in backends:
        direct = pack(backend, data)
        if unpack(backend, direct) != data:
            raise AssertionError("raw direct round-trip mismatch")
        print(json.dumps({
            "kind": "raw_direct",
            "backend": backend,
            "compressed_bytes": len(direct),
            "roundtrip": True,
        }, sort_keys=True))
        for order in orders:
            frame, stats = generative_screen.build_frame(data, first_words, pieces, order)
            wrapped = pack(backend, frame)
            if unpack(backend, wrapped) != frame:
                raise AssertionError("complete generated-set frame round-trip mismatch")
            row = stats.as_dict()
            row.update({
                "kind": "complete_frame",
                "backend": backend,
                "frame_bytes": len(frame),
                "compressed_bytes": len(wrapped),
                "raw_direct_bytes": len(direct),
                "delta_vs_raw_direct": len(wrapped) - len(direct),
                "roundtrip": True,
            })
            print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
