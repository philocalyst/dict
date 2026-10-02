#!/usr/bin/env python3
"""Exact byte ledger for the private SGN2 native wire; no source decoding."""
import argparse
import json
from pathlib import Path

MAGIC = b"sgn\x02"


def read_var(frame: bytes, at: int):
    value = 0
    for shift in range(0, 35, 7):
        if at >= len(frame):
            raise ValueError("truncated varint")
        byte = frame[at]
        at += 1
        value |= (byte & 127) << shift
        if byte < 128:
            if value > 0xFFFFFFFF:
                raise ValueError("oversize varint")
            return value, at
    raise ValueError("varint too long")


def inspect(frame: bytes, magic: bytes = MAGIC):
    if not frame.startswith(magic):
        raise ValueError("not a recognized private frame")
    at = len(magic)
    header_len, at = read_var(frame, at)
    header_end = at + header_len
    if header_end > len(frame):
        raise ValueError("truncated model")
    row = dict(header_bytes=header_end, dictionary_bytes=0,
               definition_gen_bytes=0, payload_bytes=0,
               payload_gen_bytes=0, directory_bytes=0, raw_bytes=0,
               definitions=0, definition_gen_events=0,
               payload_gen_events=0, blocks=0, pages=0)
    at = header_end
    while True:
        start = at
        if at >= len(frame):
            raise ValueError("missing footer")
        kind = frame[at]
        at += 1
        if kind == 0:
            row["directory_bytes"] += 1
            break
        if kind > 3:
            raise ValueError("bad block kind")
        defs = delta_len = dgens = dgen_len = 0
        raw = items = payload_len = gens = gen_len = 0
        if kind & 1:
            defs, at = read_var(frame, at)
            _, at = read_var(frame, at)  # maximum delta workspace bytes
            delta_len, at = read_var(frame, at)
            dgens, at = read_var(frame, at)
            dgen_len, at = read_var(frame, at)
        if kind & 2:
            raw, at = read_var(frame, at)
            items, at = read_var(frame, at)
            payload_len, at = read_var(frame, at)
            gens, at = read_var(frame, at)
            gen_len, at = read_var(frame, at)
        row["directory_bytes"] += at - start
        row["dictionary_bytes"] += delta_len
        row["definition_gen_bytes"] += dgen_len
        row["payload_bytes"] += payload_len
        row["payload_gen_bytes"] += gen_len
        row["raw_bytes"] += raw
        row["definitions"] += defs
        row["definition_gen_events"] += dgens
        row["payload_gen_events"] += gens
        row["blocks"] += 1
        row["pages"] += bool(items)
        at += delta_len + dgen_len + payload_len + gen_len
        if at > len(frame):
            raise ValueError("truncated block")
    if at != len(frame):
        raise ValueError("trailing frame bytes")
    row["frame_bytes"] = len(frame)
    assert sum(row[k] for k in ("header_bytes", "dictionary_bytes",
                                 "definition_gen_bytes", "payload_bytes",
                                 "payload_gen_bytes", "directory_bytes")) == len(frame)
    return row


if __name__ == "__main__":
    cli = argparse.ArgumentParser()
    cli.add_argument("frame")
    args = cli.parse_args()
    print(json.dumps(inspect(Path(args.frame).read_bytes()), sort_keys=True))
