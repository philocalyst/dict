#!/usr/bin/env python3
"""Small, independent native admission and byte-exactness regression."""
import json
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
FROZEN_REFERENCE = pathlib.Path("/workspace/scratch/wgp6/frozen-backend-runtime2/m_reference")


def run(*argv, succeeds=True):
    result = subprocess.run(argv, cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != succeeds:
        raise AssertionError((argv, result.returncode, result.stderr.decode(errors="replace")))
    return result


def varint(data, pos):
    value = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
        shift += 7


def put_varint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def oversized_raw(frame):
    assert frame[:4] == b"bz4\x03"
    header_len, pos = varint(frame, 4)
    pos += header_len
    kind = frame[pos]
    assert kind & 2
    pos += 1
    for _ in range(3 if kind & 1 else 0):
        _, pos = varint(frame, pos)
    _, end = varint(frame, pos)
    return frame[:pos] + put_varint(32 * 1024 * 1024 + 1) + frame[end:]


def main():
    with tempfile.TemporaryDirectory() as temp:
        d = pathlib.Path(temp)
        raw = (b"some shared words and numbers 123\n\x00\xff" * 1200)[:42000]
        source = d / "source.bin"
        source.write_bytes(raw)
        frame = d / "frame.bz4"
        private = d / "graph.p6f"
        encode = run(HERE / "m_whole", source, frame, private, "33554432", "1", "bytes", "0", "0")
        assert json.loads(encode.stdout)["blocks"] == 1
        inspected = json.loads(run(HERE / "whole_reader", "inspect", frame).stdout)
        assert inspected["ledger"]["raw_bytes"] == len(raw)
        verified = json.loads(run(HERE / "whole_reader", "verify", frame, source).stdout)
        assert verified["verified"] and verified["raw_bytes"] == len(raw)
        decoded = d / "decoded.bin"
        run(HERE / "whole_reader", "decode", frame, decoded)
        assert decoded.read_bytes() == raw
        wrong = d / "wrong.bin"
        wrong.write_bytes(raw + b"x")
        run(HERE / "whole_reader", "verify", frame, wrong, succeeds=False)
        real_frame_bytes = frame.stat().st_size
        malformed = d / "malformed.bz4"
        malformed.write_bytes(frame.read_bytes() + b"extra")
        run(HERE / "whole_reader", "inspect", malformed, succeeds=False)
        malformed.write_bytes(oversized_raw(frame.read_bytes()))
        run(HERE / "whole_reader", "inspect", malformed, succeeds=False)
        run(HERE / "whole_reader", "decode", malformed, decoded, succeeds=False)
        small = d / "small.bin"
        small.write_bytes(raw[:8192])
        fork_frame = d / "fork.bz4"
        old_frame = d / "old.bz4"
        run(HERE / "m_whole", small, fork_frame, d / "fork.p6f", "65536", "20", "a-best", "1", "0")
        run(FROZEN_REFERENCE, small, old_frame, d / "old.p6f", "65536", "20", "a-best", "1", "0")
        assert fork_frame.read_bytes() == old_frame.read_bytes()
        run(HERE / "whole_reader", "verify", fork_frame, small)
        print(json.dumps({"tests": 9, "source_bytes": len(raw), "frame_bytes": real_frame_bytes,
                          "source_crc32": verified["raw_crc32"]}))


if __name__ == "__main__":
    main()
