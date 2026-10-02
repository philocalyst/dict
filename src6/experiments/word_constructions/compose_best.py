#!/usr/bin/env python3
"""Paid policy search over exact register constructors and strong M backend.

The selected mode occupies one byte in the archive. Every candidate is
fully compressed with the same native compiler; no size oracle is free.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

import attribute_register
import scope_register
from compose_m import WGP6, run
from template_split import getvar, varint

REGISTER_DECODER = Path(__file__).resolve().parent / "register_decode"
MAX_RAW = 32 * 1024 * 1024
MAX_FRAME = 64 * 1024 * 1024


def candidates(data):
    yield 0, data, {"mode": "raw"}
    local, local_stats = attribute_register.forward(data)
    if local != data:
        yield 1, local, {"mode": "local", "local": local_stats}
    escaped = data.replace(b"\x00", b"\x00\x00")
    scoped, scope_stats = scope_register.forward(escaped)
    if scoped != escaped:
        yield 2, scoped, {"mode": "scope", "scope": scope_stats}
    combined, scope_stats = scope_register.forward(local)
    if combined != local and combined != scoped:
        yield 3, combined, {"mode": "local+scope", "local": local_stats, "scope": scope_stats}


def inverse(source, mode):
    if mode == 0:
        return source
    if mode == 1:
        return attribute_register.inverse(source)
    if mode == 2:
        return scope_register.inverse(source).replace(b"\x00\x00",b"\x00")
    if mode == 3:
        return attribute_register.inverse(scope_register.inverse(source))
    raise ValueError("mode")


def encode(data, seed="a-best", modes=None, hoist=False):
    if len(data) > MAX_RAW:
        raise ValueError("input exceeds backend limit")
    trials = []
    best = None
    for mode, transformed, metadata in candidates(data):
        if modes is not None and mode not in modes:
            continue
        if len(transformed) > MAX_RAW:
            continue
        with tempfile.TemporaryDirectory(prefix="wbp-") as temp:
            src, parse, frame = (Path(temp) / name for name in ("source", "parse", "frame"))
            src.write_bytes(transformed)
            compiled = run([WGP6 / "m_reference", src, frame, parse, 65536, 20, seed, 1, int(hoist)])
            payload = frame.read_bytes()
        archive = (b"WBP1" + bytes((mode,)) + varint(len(data)) + varint(len(payload)) +
                   payload + struct.pack("<I", zlib.crc32(data)))
        trial = {**metadata, "mode_id": mode, "hoist": hoist, "source_bytes": len(transformed),
                 "frame_bytes": len(archive), "frame_sha256": hashlib.sha256(archive).hexdigest(),
                 "compiled": compiled}
        trials.append(trial)
        if best is None or len(archive) < len(best):
            best = archive
    if best is None:
        raise ValueError("no candidates")
    return best, trials


def decode(archive, native_register=False):
    if not archive.startswith(b"WBP1") or len(archive) < 5:
        raise ValueError("magic")
    mode = archive[4]
    if mode > 3:
        raise ValueError("mode")
    size, at = getvar(archive, 5)
    n, at = getvar(archive, at)
    if size > MAX_RAW or n > MAX_FRAME:
        raise ValueError("archive limit")
    if at+n+4 != len(archive):
        raise ValueError("length")
    with tempfile.TemporaryDirectory(prefix="wbp-decode-") as temp:
        frame, dst, restored = (Path(temp) / name for name in ("frame", "decoded", "restored"))
        frame.write_bytes(archive[at:at+n])
        run([WGP6 / "native", "decode", frame, dst])
        if native_register:
            subprocess.run([REGISTER_DECODER, str(mode), dst, restored],
                           check=True, capture_output=True)
            output = restored.read_bytes()
        else:
            output = inverse(dst.read_bytes(), mode)
    if len(output) != size or zlib.crc32(output) != struct.unpack_from("<I",archive,at+n)[0]:
        raise ValueError("size or CRC")
    return output


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--seed", default="a-best")
    ap.add_argument("--modes", default="0,1,2,3")
    ap.add_argument("--hoist", action="store_true")
    args = ap.parse_args()
    data = args.input.read_bytes()
    archive, trials = encode(data, args.seed, set(map(int,args.modes.split(","))), args.hoist)
    args.output.write_bytes(archive)
    if decode(archive, native_register=True) != data or decode(archive) != data:
        raise ValueError("roundtrip")
    print(json.dumps({"input_bytes":len(data),"selected_mode":archive[4],
                      "frame_bytes":len(archive),"trials":trials}))


if __name__ == "__main__":
    main()
