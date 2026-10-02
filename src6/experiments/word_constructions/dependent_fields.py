#!/usr/bin/env python3
"""Paid native proof for generically reconstructing list words from an ID field.

The encoder learns two within-record overlap lengths from the actual bytes.
The decoder receives both lengths per record. Neither language, ID syntax,
nor a vocabulary is baked into the reconstruction rule.
"""
import argparse
import json
import re
import struct
import zlib
from pathlib import Path

from template_split import native, varint, getvar

PAIR = re.compile(rb'(<[A-Za-z][A-Za-z0-9:._-]*\s+id="([^"]+)"[^>]*?\s+members=")([^"]*)"')
REF = re.compile(rb'(<[A-Za-z][A-Za-z0-9:._-]*\s+id="([^"]+)"[^>]*?\s+members=")\x00\x01([\x00-\x1f])([\x00-\x1f])([^"]*)"')


def overlap(id_value, names):
    p = 0
    while p < min(map(len, [id_value, *names])) and all(name[p] == id_value[p] for name in names):
        p += 1
    s = 0
    # The prefix and suffix may overlap *inside the ID*: both are copied
    # independently, and each member is longer than their combined lengths.
    while s < len(id_value) and p+s+1 < min(map(len, names)) and all(name[-s-1] == id_value[-s-1] for name in names):
        s += 1
    return p, s


def forward(data):
    escaped = data.replace(b"\x00", b"\x00\x00")
    stats = {"records": 0, "members": 0, "removed_bytes": 0,
             "overlaps": {}}

    def change(m):
        id_value, names = m.group(2), m.group(3).split(b" ")
        if not names or any(not name for name in names):
            return m.group()
        p, s = overlap(id_value, names)
        if p < 2 or s < 2 or p > 31 or s > 31 or p+s >= min(map(len, names)):
            return m.group()
        if len(names)*(p+s) <= 4:
            return m.group()
        short = b" ".join(name[p:len(name)-s] for name in names)
        stats["records"] += 1
        stats["members"] += len(names)
        stats["removed_bytes"] += len(names)*(p+s)
        key = f"{p},{s}"
        stats["overlaps"][key] = stats["overlaps"].get(key, 0) + 1
        return m.group(1) + b"\x00\x01" + bytes((p,s)) + short + b'"'

    return PAIR.sub(change, escaped), stats


def inverse(encoded):
    def change(m):
        id_value = m.group(2)
        p, s = m.group(3)[0], m.group(4)[0]
        if p < 2 or s < 2 or p > len(id_value) or s > len(id_value):
            raise ValueError("bad reference")
        prefix, suffix = id_value[:p], id_value[-s:]
        names = m.group(5).split(b" ")
        return m.group(1) + b" ".join(prefix + name + suffix for name in names) + b'"'

    return REF.sub(change, encoded).replace(b"\x00\x00", b"\x00")


def encode(data):
    source, stats = forward(data)
    payload = native("encode", source)
    frame = b"WCF1" + varint(len(data)) + varint(len(payload)) + payload + struct.pack("<I", zlib.crc32(data))
    return frame, {**stats, "transformed_bytes": len(source), "backend_frame_bytes": len(payload),
                   "wrapper_bytes": len(frame)-len(payload)}


def decode(frame):
    if not frame.startswith(b"WCF1"):
        raise ValueError("magic")
    size, at = getvar(frame, 4)
    compressed_size, at = getvar(frame, at)
    if at+compressed_size+4 != len(frame):
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
