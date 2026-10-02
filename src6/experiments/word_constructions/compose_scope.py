#!/usr/bin/env python3
"""Complete tag and ancestor-register archive with byte-MDL/WGP6 frame."""
import argparse
import json
import struct
import tempfile
import zlib
from pathlib import Path

import attribute_register
import scope_register
from compose_m import WGP6, run
from template_split import varint, getvar


def encode(data):
    local, local_stats = attribute_register.forward(data)
    transformed, scope_stats = scope_register.forward(local)
    with tempfile.TemporaryDirectory(prefix="wsr-") as temp:
        src, parse, frame = (Path(temp) / name for name in ("source", "parse", "frame"))
        src.write_bytes(transformed)
        prepared = run([WGP6 / "prepare_m", src, parse, 65536, 20, 1])
        compiled = run([WGP6 / "native", "compile", parse, frame, 0])
        payload = frame.read_bytes()
    archive = b"WSR1" + varint(len(data)) + varint(len(payload)) + payload + struct.pack("<I", zlib.crc32(data))
    return archive, {"local": local_stats, "scope": scope_stats, "transformed_bytes": len(transformed),
                     "backend_frame_bytes": len(payload), "wrapper_bytes": len(archive)-len(payload),
                     "prepared": prepared, "compiled": compiled}


def decode(archive):
    if not archive.startswith(b"WSR1"):
        raise ValueError("magic")
    size, at = getvar(archive, 4)
    n, at = getvar(archive, at)
    if at+n+4 != len(archive):
        raise ValueError("length")
    with tempfile.TemporaryDirectory(prefix="wsr-decode-") as temp:
        frame, dst = Path(temp) / "frame", Path(temp) / "decoded"
        frame.write_bytes(archive[at:at+n])
        run([WGP6 / "native", "decode", frame, dst])
        output = attribute_register.inverse(scope_register.inverse(dst.read_bytes()))
    if len(output) != size or zlib.crc32(output) != struct.unpack_from("<I", archive, at+n)[0]:
        raise ValueError("size or CRC")
    return output


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    data = args.input.read_bytes()
    archive, stats = encode(data)
    args.output.write_bytes(archive)
    if decode(archive) != data:
        raise ValueError("roundtrip")
    print(json.dumps({"input_bytes": len(data), "frame_bytes": len(archive), **stats}))


if __name__ == "__main__":
    main()
