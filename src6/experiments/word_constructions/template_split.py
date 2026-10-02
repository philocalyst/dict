#!/usr/bin/env python3
"""Exact leaf-text / markup split, using paid old-v4 frames as an entropy backend.

This is an experimental format, not an estimate: each selector, group boundary,
frame, and checksum is transmitted. No XML normalization is performed.
"""
import argparse
import json
import re
import struct
import subprocess
import tempfile
import zlib
from collections import Counter, defaultdict
from pathlib import Path

LEAF = re.compile(rb"<([A-Za-z][A-Za-z0-9:._-]*)>([^<>]{1,1024})</\1>")
MARKED = re.compile(rb"<([A-Za-z][A-Za-z0-9:._-]*)>(\x00\x01)</\1>")
NATIVE = Path("/tmp/frontier2026-bzip4-v3")


def varint(n):
    out = bytearray()
    while n >= 128:
        out.append(128 | (n & 127))
        n >>= 7
    out.append(n)
    return bytes(out)


def getvar(data, at):
    value = 0
    shift = 0
    while True:
        if at >= len(data) or shift > 63:
            raise ValueError("bad varint")
        byte = data[at]
        at += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, at
        shift += 7


def native(action, data):
    with tempfile.TemporaryDirectory(prefix="wcx-") as temp:
        src, dst = Path(temp) / "src", Path(temp) / "dst"
        src.write_bytes(data)
        args = [NATIVE, action, src, dst]
        if action == "encode":
            args += ["--block", "65536"]
        subprocess.run(args, check=True, capture_output=True)
        return dst.read_bytes()


def split(data, min_count, by_tag):
    matches = list(LEAF.finditer(data))
    counts = Counter(m.group(1) for m in matches)
    out = bytearray()
    groups = defaultdict(list)
    at = 0
    used = 0
    for m in matches:
        tag, body = m.groups()
        if counts[tag] < min_count:
            continue
        out += data[at:m.start(2)].replace(b"\x00", b"\x00\x00")
        out += b"\x00\x01"
        at = m.end(2)
        groups[tag if by_tag else b""].append(body)
        used += 1
    out += data[at:].replace(b"\x00", b"\x00\x00")
    return bytes(out), dict(groups), used


def encode(data, min_count=16, by_tag=True):
    skeleton, groups, used = split(data, min_count, by_tag)
    index = bytearray()
    values = bytearray()
    for name, seq in sorted(groups.items()):
        index += varint(len(name)) + name + varint(len(seq))
        segment = b"".join(varint(len(value)) + value for value in seq)
        index += varint(len(segment))
        values += segment
    skframe, valframe = native("encode", skeleton), native("encode", bytes(values))
    frame = (b"WCX1" + varint(len(data)) + varint(len(groups)) + index +
             varint(len(skframe)) + varint(len(valframe)) + skframe + valframe +
             struct.pack("<I", zlib.crc32(data)))
    return frame, {"holes": used, "groups": len(groups), "skeleton_bytes": len(skeleton),
                   "values_bytes": len(values), "skeleton_frame": len(skframe),
                   "values_frame": len(valframe), "wrapper_bytes": len(frame)-len(skframe)-len(valframe)}


def decode(frame, by_tag=True):
    if not frame.startswith(b"WCX1"):
        raise ValueError("magic")
    at = 4
    raw_size, at = getvar(frame, at)
    n, at = getvar(frame, at)
    index = []
    for _ in range(n):
        name_size, at = getvar(frame, at)
        name = frame[at:at+name_size]
        at += name_size
        count, at = getvar(frame, at)
        size, at = getvar(frame, at)
        index.append((name, count, size))
    sk_size, at = getvar(frame, at)
    val_size, at = getvar(frame, at)
    if at + sk_size + val_size + 4 != len(frame):
        raise ValueError("frame length")
    skeleton = native("decode", frame[at:at+sk_size]); at += sk_size
    values = native("decode", frame[at:at+val_size]); at += val_size
    expected_crc = struct.unpack_from("<I", frame, at)[0]
    groups = {}
    pos = 0
    for name, count, size in index:
        end = pos + size
        seq = []
        for _ in range(count):
            length, pos = getvar(values, pos)
            if pos + length > end:
                raise ValueError("value boundary")
            seq.append(values[pos:pos+length]); pos += length
        if pos != end:
            raise ValueError("group boundary")
        groups[name] = iter(seq)
    if pos != len(values):
        raise ValueError("values trailing bytes")
    output = bytearray()
    last = 0
    seen = Counter()
    for m in MARKED.finditer(skeleton):
        output += skeleton[last:m.start()].replace(b"\x00\x00", b"\x00")
        name = m.group(1) if by_tag else b""
        if name not in groups:
            raise ValueError("missing group")
        output += skeleton[m.start():m.start(2)]
        try:
            output += next(groups[name])
        except StopIteration:
            raise ValueError("short group") from None
        output += skeleton[m.end(2):m.end()]
        last = m.end()
        seen[name] += 1
    output += skeleton[last:].replace(b"\x00\x00", b"\x00")
    if any(seen[name] != count for name, count, _ in index):
        raise ValueError("wrong group count")
    if len(output) != raw_size or zlib.crc32(output) != expected_crc:
        raise ValueError("size or CRC")
    return bytes(output)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--min-count", type=int, default=16)
    ap.add_argument("--all-tags", action="store_true")
    args = ap.parse_args()
    data = args.input.read_bytes()
    frame, detail = encode(data, args.min_count, not args.all_tags)
    args.output.write_bytes(frame)
    if decode(frame, not args.all_tags) != data:
        raise AssertionError("roundtrip")
    print(json.dumps({"input_bytes": len(data), "frame_bytes": len(frame), **detail}))


if __name__ == "__main__":
    main()
