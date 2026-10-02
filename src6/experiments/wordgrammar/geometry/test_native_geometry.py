#!/usr/bin/env python3
"""Independent GWT1 native-reader parity and hostile-envelope checks.

Pass a completed GWT1 archive and its exact original source. Mutations are
resealed where necessary so they exercise the intended downstream guard.
"""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

HEADER = struct.Struct("<4sIIQIIIIIII")
PAGE = 65536


def layout(data):
    h = list(HEADER.unpack_from(data))
    count, native_len, flags_len, model_len = h[4:8]
    model_at = HEADER.size + count * 12
    native_at = model_at + model_len
    flags_at = native_at + native_len
    assert flags_at + flags_len == len(data)
    return h, model_at, native_at, flags_at


def reseal(data):
    h, model_at, _, _ = layout(data)
    h[-1] = 0
    data[:HEADER.size] = HEADER.pack(*h)
    h[-1] = zlib.crc32(data[:model_at+h[7]])
    data[:HEADER.size] = HEADER.pack(*h)
    return data


def varint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out + bytes((value,)))


def getvar(blob, at):
    value = 0
    for shift in range(0, 35, 7):
        c = blob[at]; at += 1
        value |= (c & 127) << shift
        if c < 128:
            return value, at
    raise ValueError("native varint")


def first_delta_declaration(native):
    assert native[:4] == b"bz4\x03"
    header_len, at = getvar(native, 4)
    at += header_len
    while at < len(native):
        kind = native[at]; at += 1
        if kind == 0: break
        delta = payload = 0
        if kind & 1:
            _, at = getvar(native, at)
            field_start = at
            _, at = getvar(native, at)
            return field_start, at
        if kind & 2:
            _, at = getvar(native, at)
            _, at = getvar(native, at)
            payload, at = getvar(native, at)
        at += delta + payload
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("--reader", type=Path, default=Path(__file__).with_name("prepared_geometry"))
    args = parser.parse_args()
    frame, source = args.archive.read_bytes(), args.source.read_bytes()
    h, model_at, native_at, flags_at = layout(frame)
    assert len(source) == h[3] and h[4] >= 2, "fixture needs at least two pages"
    assert zlib.crc32(source) == h[8]
    reader = str(args.reader.resolve())
    checked = []
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        archive, output = scratch/"archive.gwt", scratch/"output"

        def run(data, operation, should_pass, index=0, preserved=False):
            archive.write_bytes(data)
            if preserved:
                output.write_bytes(b"original destination must survive")
            else:
                output.unlink(missing_ok=True)
            cmd = [reader, operation, str(archive), str(output)]
            if operation == "query":
                cmd += ["--index", str(index)]
            done = subprocess.run(cmd, capture_output=True, text=True)
            assert (done.returncode == 0) == should_pass, (operation, done.stdout, done.stderr)
            if preserved:
                assert output.read_bytes() == b"original destination must survive"
            checked.append((operation, should_pass))
            return output.read_bytes() if should_pass else b""

        assert run(frame, "decode", True) == source
        assert b'GWT1-PREPARED-INSPECT/1' in run(frame, "inspect", True)
        for index in (0, h[4]//2, h[4]-1):
            assert run(frame, "query", True, index) == source[index*PAGE:(index+1)*PAGE]
        run(frame, "query", False, h[4])

        for position in (0, 4, 44):
            data = bytearray(frame); data[position] ^= 1
            run(data, "query", False)
            run(data, "inspect", False)
        for field, replacement in ((2, 0), (2, 4097), (3, 64*1024*1024+1),
                                   (4, h[4]+1), (5, 64*1024*1024+1), (6, h[6]+1),
                                   (7, 0)):
            data = bytearray(frame); hh = list(HEADER.unpack_from(data))
            hh[field] = replacement; data[:HEADER.size] = HEADER.pack(*hh)
            run(data, "query", False)
        for index_value, replacement in ((0, PAGE+1), (4, 3), (4, 2*PAGE+5), (8, h[8]^1)):
            data = bytearray(frame)
            struct.pack_into("<I", data, HEADER.size + index_value, replacement)
            run(reseal(data), "query", False)
        first_events = struct.unpack_from("<I", frame, HEADER.size)[0]
        if first_events < PAGE:
            data = bytearray(frame)
            struct.pack_into("<I", data, HEADER.size, first_events+1)
            run(reseal(data), "query", False)
        data = bytearray(frame)
        second_crc_at = HEADER.size + 12 + 8
        struct.pack_into("<I", data, second_crc_at,
                         struct.unpack_from("<I", data, second_crc_at)[0] ^ 1)
        data = reseal(data)
        assert run(data, "query", True, 0) == source[:PAGE]
        run(data, "query", False, 1)
        first_flags = struct.unpack_from("<I", frame, HEADER.size+4)[0]
        second_flags = struct.unpack_from("<I", frame, HEADER.size+12+4)[0]
        if second_flags > 4 and first_flags + 1 <= 2*first_events + 4:
            data = bytearray(frame)
            struct.pack_into("<I", data, HEADER.size+4, first_flags+1)
            struct.pack_into("<I", data, HEADER.size+12+4, second_flags-1)
            data = reseal(data)
            run(data, "query", False, 0)
            run(data, "query", False, 1)
        data = bytearray(frame); data[model_at] = 6
        run(reseal(data), "query", False)
        def replace_model(wire):
            data = bytearray(frame)
            data[model_at:native_at] = wire
            hh = list(HEADER.unpack_from(data)); hh[7] = len(wire)
            data[:HEADER.size] = HEADER.pack(*hh)
            return reseal(data)
        run(replace_model(bytes((0, 1, 16))), "query", False)  # leaf freq 4097
        deep = bytes((0, 0, 8))
        for _ in range(17):
            deep = bytes((1, 0, 0, 0, 0, 8)) + deep
        run(replace_model(deep), "query", False)  # depth 17
        data = bytearray(frame); data[flags_at] ^= 0x80
        run(data, "query", False)
        data = bytearray(frame); data[native_at] ^= 1
        run(data, "query", False)
        wide_native = (b"bz4\x03\x0c" +
                       bytes.fromhex("00dffdff68fa47d7c0000000") + b"\0")
        wide_model = bytes((0, 0, 8))
        wide_fields = (b"GWT1", 1, 72, 0, 0, len(wide_native), 0,
                       len(wide_model), 0, 0, 0)
        wide_header = HEADER.pack(*wide_fields)
        wide_header = HEADER.pack(*wide_fields[:-1],
                                  zlib.crc32(wide_header+wide_model))
        wide_archive = wide_header + wide_model + wide_native
        run(wide_archive, "inspect", False)
        run(wide_archive, "decode", False, preserved=True)
        declaration = first_delta_declaration(frame[native_at:flags_at])
        if declaration is not None:
            start, end = declaration
            data = bytearray(frame)
            data[native_at+start:native_at+end] = varint(64*1024*1024+1)
            hh = list(HEADER.unpack_from(data))
            hh[5] += len(data)-len(frame)
            data[:HEADER.size] = HEADER.pack(*hh)
            run(reseal(data), "query", False)
        for field in (8, 9):
            data = bytearray(frame); hh = list(HEADER.unpack_from(data))
            hh[field] ^= 1; data[:HEADER.size] = HEADER.pack(*hh)
            run(reseal(data), "decode", False, preserved=True)
        # Damage a later page so the full decoder has already written a valid
        # prefix to its temporary file when it discovers the failure.
        data = bytearray(frame)
        # The first page's flag length is the second u32 in its entry.
        later_flag_at = flags_at + struct.unpack_from("<I", frame, HEADER.size + 4)[0]
        data[later_flag_at] ^= 0x80
        run(data, "decode", False, preserved=True)
    print({"native_gwt1_cases": len(checked), "valid": sum(ok for _,ok in checked),
           "rejected": sum(not ok for _,ok in checked)})


if __name__ == "__main__":
    main()
