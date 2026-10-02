"""Measured file adapter plus strict WSB2 frame inspection for sbwt."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SBWT = REPO / "src6/experiments/wordzip/sbwt"
SBWT_AUTO = REPO / "src6/experiments/wordzip/sbwt-auto"
SBWT_SELECT = REPO / "src6/experiments/wordzip/sbwt-select"
SBWT_UNICODE_AUTO = REPO / "src6/experiments/wordzip/sbwt-unicode-auto"
HEADER = struct.Struct("<4sII I Q IIII")
RECORD = struct.Struct("<Q6I")


def inspect(frame: bytes) -> dict[str, object]:
    if len(frame) < 40:
        raise ValueError("truncated WSB2 header")
    magic, version, block_bytes, count, raw_bytes, grammar_bytes, entropy_bytes, crc, flags = HEADER.unpack_from(frame)
    if magic != b"WSB2" or version != 2 or block_bytes == 0 or block_bytes > 4 * 1024 * 1024:
        raise ValueError("invalid WSB2 header")
    if (raw_bytes > 512 * 1024 * 1024 or count > 1_000_000 or
            grammar_bytes > 9 * 1024 * 1024 or entropy_bytes > 9 * 1024 * 1024):
        raise ValueError("WSB2 resource limit")
    # The native decoder treats this word as order + 4 * dictionary mode.
    # Keep the same accepted domain here so the accounting parser rejects
    # reserved encodings before starting a child process.
    if flags & ~31 or (flags & 15) >= 12 or count != (raw_bytes + block_bytes - 1) // block_bytes:
        raise ValueError("invalid WSB2 flags or block count")
    model_bytes = grammar_bytes + entropy_bytes
    directory_bytes = count * RECORD.size
    payload_at = 40 + model_bytes + directory_bytes
    if payload_at > len(frame):
        raise ValueError("truncated WSB2 metadata")
    metadata = bytearray(frame[:payload_at])
    metadata[32:36] = b"\0\0\0\0"
    if zlib.crc32(metadata) & 0xFFFFFFFF != crc:
        raise ValueError("WSB2 metadata CRC mismatch")
    offset = 0
    raw_sum = 0
    raw_lens: list[int] = []
    for i in range(count):
        record = RECORD.unpack_from(frame, 40 + model_bytes + i * RECORD.size)
        member_offset, encoded, raw_n, roots, primary, events, raw_crc = record
        expected = min(block_bytes, raw_bytes - raw_sum)
        if (member_offset != offset or encoded <= 0 or raw_n != expected or
                roots <= 0 or roots > raw_n or events <= 0 or events > roots * 2 or
                (primary == 0xFFFFFFFF and encoded != raw_n) or
                (primary != 0xFFFFFFFF and primary >= roots)):
            raise ValueError(f"invalid WSB2 restart record {i}")
        if payload_at + offset + encoded > len(frame):
            raise ValueError(f"WSB2 restart record {i} exceeds frame")
        offset += encoded
        raw_sum += raw_n
        raw_lens.append(raw_n)
    if raw_sum != raw_bytes or payload_at + offset != len(frame):
        raise ValueError("WSB2 frame length or tail mismatch")
    return {
        "header_bytes": 40,
        "model_dictionary_bytes": model_bytes,
        "directory_bytes": directory_bytes,
        "payload_bytes": len(frame) - payload_at,
        "frame_bytes": len(frame),
        "raw_bytes": raw_bytes,
        "block_bytes": block_bytes,
        "blocks": count,
        "block_raw_lengths": raw_lens,
        "flags": flags,
        "input_sha256": hashlib.sha256(frame).hexdigest(),
    }


def run(command: list[str]) -> tuple[bytes, bytes, int]:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError(f"sbwt command failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return result.stdout, result.stderr, result.returncode


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("operation", choices=("encode", "decode", "extract"))
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--block-bytes", type=int, default=65536)
    ap.add_argument("--block-index", type=int, default=0)
    ap.add_argument("--cap", type=int, default=16384)
    ap.add_argument("--passes", type=int, default=64)
    ap.add_argument("--policy", type=int, default=0)
    ap.add_argument("--order", type=int, default=1)
    ap.add_argument("--dp", type=int, default=2)
    ap.add_argument("--contexts", type=int, default=1)
    ap.add_argument("--dict", type=int, default=0)
    ap.add_argument("--auto", action="store_true",
                    help="select the minimum complete frame over the fixed dictionary-cap set")
    ap.add_argument("--surface-choice", action="store_true",
                    help="select the minimum complete frame between lexical-only and copy-12 surface modes")
    ap.add_argument("--unicode-auto", action="store_true",
                    help="select the minimum complete frame across fixed byte/Unicode and dictionary-cap policies")
    args = ap.parse_args()
    if args.input.stat().st_size > 512 * 1024 * 1024:
        raise ValueError("input exceeds sbwt adapter limit")
    if args.operation == "encode":
        binary = (SBWT_SELECT if args.surface_choice else
                  SBWT_UNICODE_AUTO if args.unicode_auto else SBWT_AUTO if args.auto else SBWT)
        command = [str(binary), "encode", str(args.input), str(args.output), "--block", str(args.block_bytes),
                   "--cap", str(args.cap), "--passes", str(args.passes), "--policy", str(args.policy),
                   "--order", str(args.order), "--dp", str(args.dp), "--contexts", str(args.contexts),
                   "--dict", str(args.dict)]
        if args.auto:
            command.extend(["--auto", "1"])
        if args.surface_choice:
            command.extend(["--choice", "1"])
        if args.unicode_auto:
            command.extend(["--unicode-auto", "1"])
    elif args.operation == "decode":
        binary = SBWT_SELECT if args.surface_choice else SBWT
        command = [str(binary), "decode", str(args.input), str(args.output)]
    else:
        binary = SBWT_SELECT if args.surface_choice else SBWT
        command = [str(binary), "decode", str(args.input), str(args.output), "--index", str(args.block_index)]
    stdout, stderr, status = run(command)
    record: dict[str, object] = {"command": command, "exit_code": status,
                                 "tool_stdout": stdout.decode("utf-8", "replace"),
                                 "tool_stderr": stderr.decode("utf-8", "replace")}
    if args.operation == "encode":
        stats = inspect(args.output.read_bytes())
        if stats["raw_bytes"] != args.input.stat().st_size or stats["block_bytes"] != args.block_bytes:
            raise ValueError("WSB2 frame input/block lengths disagree with encode request")
        try:
            native = json.loads(stdout)
        except json.JSONDecodeError:
            native = {}
        record.update(stats)
        record.update({key: native[key] for key in ("codec_ns", "codec_us", "peakrss_kib") if key in native})
    else:
        try:
            native = json.loads(stdout)
        except json.JSONDecodeError:
            native = {}
        record.update({key: native[key] for key in ("codec_ns", "codec_us", "peakrss_kib") if key in native})
    print(json.dumps(record, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"sbwt_adapter: {e}", file=sys.stderr)
        raise SystemExit(2)
