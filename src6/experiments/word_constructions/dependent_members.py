#!/usr/bin/env python3
"""Byte-exact dependent-field reference for XML member lists.

A Synset's member names are often `omw-ja-LEMMA-SYNSET_ID` and the ID is
present in the same record. This transducer delivers that dependency once
per eligible record. Literal zero bytes are escaped, and all noneligible
records pass through byte-for-byte. The native v4 stream is a paid backend.
"""
import argparse
import json
import re
import struct
import zlib
from pathlib import Path

from template_split import native, varint, getvar

RAW = re.compile(rb'(<Synset id="omw-ja-([0-9]+-[a-z])"[^>]*? members=")([^"]*)"')
MARKED = re.compile(rb'(<Synset id="omw-ja-([0-9]+-[a-z])"[^>]*? members=")\x00\x01([^"]*)"')
PREFIX = b"omw-ja-"


def forward(data):
    escaped = data.replace(b"\x00", b"\x00\x00")
    stats = {"records": 0, "members": 0, "removed_bytes": 0}

    def change(m):
        suffix = b"-" + m.group(2)
        names = m.group(3).split(b" ")
        if not names or not all(name.startswith(PREFIX) and name.endswith(suffix)
                                and len(name) > len(PREFIX) + len(suffix) for name in names):
            return m.group()
        stats["records"] += 1
        stats["members"] += len(names)
        stats["removed_bytes"] += len(names) * (len(PREFIX) + len(suffix))
        short = b" ".join(name[len(PREFIX):-len(suffix)] for name in names)
        return m.group(1) + b"\x00\x01" + short + b'"'

    return RAW.sub(change, escaped), stats


def inverse(encoded):
    def change(m):
        suffix = b"-" + m.group(2)
        names = m.group(3).split(b" ")
        return m.group(1) + b" ".join(PREFIX + name + suffix for name in names) + b'"'

    return MARKED.sub(change, encoded).replace(b"\x00\x00", b"\x00")


def encode(data):
    source, stats = forward(data)
    payload = native("encode", source)
    frame = b"WCM1" + varint(len(data)) + varint(len(payload)) + payload + struct.pack("<I", zlib.crc32(data))
    return frame, {**stats, "transformed_bytes": len(source), "backend_frame_bytes": len(payload),
                   "wrapper_bytes": len(frame)-len(payload)}


def decode(frame):
    if not frame.startswith(b"WCM1"):
        raise ValueError("magic")
    size, at = getvar(frame, 4)
    compressed_size, at = getvar(frame, at)
    if at + compressed_size + 4 != len(frame):
        raise ValueError("length")
    source = native("decode", frame[at:at+compressed_size])
    output = inverse(source)
    if len(output) != size or zlib.crc32(output) != struct.unpack_from("<I", frame, at+compressed_size)[0]:
        raise ValueError("size or CRC")
    return output


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    data = args.input.read_bytes()
    frame, stats = encode(data)
    args.output.write_bytes(frame)
    if decode(frame) != data:
        raise ValueError("roundtrip")
    print(json.dumps({"input_bytes": len(data), "frame_bytes": len(frame), **stats}))


if __name__ == "__main__":
    main()
