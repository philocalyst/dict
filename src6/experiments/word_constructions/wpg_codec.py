#!/usr/bin/env python3
"""Complete WPG2 codec adapter for 64 KiB original-byte pages.

The encoder tries every distinct constructor and both spelling graphs using
the selected quality or access model fit. The page decoder is one native
Zig/C++ process; all codec tables and construction operands are on wire.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path

from compose_best import MAX_RAW, MAX_FRAME
from compose_dp import BACKEND, fit
from compose_m import run
from template_split import getvar

HERE = Path(__file__).resolve().parent
NATIVE = HERE / "prepared_wpg"
PAGE = 65536


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse(archive):
    if not archive.startswith(b"WPG2") or len(archive) < 6:
        raise ValueError("WPG2 magic")
    mode = archive[4]
    if mode > 3:
        raise ValueError("mode")
    raw, pos = getvar(archive, 5)
    block, pos = getvar(archive, pos)
    count, pos = getvar(archive, pos)
    if raw > MAX_RAW or block != PAGE or count != (raw + PAGE - 1) // PAGE:
        raise ValueError("page geometry")
    page_index_start = pos
    lengths = []
    checksums = []
    for _ in range(count):
        length, pos = getvar(archive, pos)
        if length > 2 * PAGE or pos + 4 > len(archive):
            raise ValueError("page index")
        lengths.append(length)
        checksums.append(struct.unpack_from("<I", archive, pos)[0])
        pos += 4
    page_index_bytes = pos - page_index_start
    if pos + 4 > len(archive) or zlib.crc32(archive[:pos]) != struct.unpack_from("<I", archive, pos)[0]:
        raise ValueError("header CRC")
    pos += 4
    inner_bytes, pos = getvar(archive, pos)
    if inner_bytes > MAX_FRAME or pos + inner_bytes + 4 != len(archive):
        raise ValueError("native frame size")
    return {"mode": mode, "raw_bytes": raw, "page_bytes": PAGE, "pages": count,
            "page_index_bytes": page_index_bytes, "page_lengths": lengths,
            "page_crc32": checksums, "inner_bytes": inner_bytes,
            "wrapper_bytes": len(archive) - inner_bytes,
            "source_crc32": struct.unpack_from("<I", archive, pos + inner_bytes)[0],
            "inner_frame": archive[pos:pos + inner_bytes]}


def invoke_native(command, archive_path, output_path, index=None):
    args = [NATIVE, command, archive_path, output_path]
    if index is not None:
        args += ["--index", str(index)]
    start = time.perf_counter_ns()
    completed = subprocess.run(args, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout), time.perf_counter_ns() - start


def inspect(data):
    info = parse(data)
    with tempfile.TemporaryDirectory(prefix="wpg-inspect-") as temp:
        inner, ledger = Path(temp) / "inner.frame", Path(temp) / "ledger.json"
        inner.write_bytes(info["inner_frame"])
        native = run([BACKEND / "native", "inspect", inner, ledger])
        if native["frame_bytes"] != info["inner_bytes"] or native["raw_bytes"] != sum(info["page_lengths"]):
            raise ValueError("native frame geometry")
    accounted = (info["wrapper_bytes"] + native["header_bytes"] + native["directory_bytes"] +
                 native["model_dictionary_bytes"] + native["payload_bytes"])
    if accounted != len(data):
        raise ValueError("unaccounted frame bytes")
    return {"format": "WPG2", "archive_bytes": len(data), "archive_sha256": sha(data),
            "source_bytes": info["raw_bytes"], "source_crc32": info["source_crc32"],
            "mode": info["mode"], "mode_name": ("raw", "local", "scope", "local+scope")[info["mode"]],
            "original_page_bytes": PAGE, "original_pages": info["pages"],
            "transformed_bytes": sum(info["page_lengths"]), "native_payload_jobs": native["blocks"],
            "accounting": {"outer_wrapper_bytes": info["wrapper_bytes"],
                           "outer_page_index_bytes_in_wrapper": info["page_index_bytes"],
                           "native_header_bytes": native["header_bytes"],
                           "native_directory_bytes": native["directory_bytes"],
                           "native_model_dictionary_bytes": native["model_dictionary_bytes"],
                           "native_payload_bytes": native["payload_bytes"],
                           "sum_bytes": accounted}}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="operation", required=True)
    for op in ("encode", "decode", "extract", "inspect"):
        p = sub.add_parser(op)
        p.add_argument("input", type=Path)
        p.add_argument("output", type=Path)
        if op == "encode":
            p.add_argument("--profile", choices=("quality", "access"), default="quality")
            p.add_argument("--block", type=int, default=PAGE)
        if op == "extract":
            p.add_argument("--index", type=int, required=True)
    args = ap.parse_args()
    if args.operation == "encode":
        if args.block != PAGE:
            raise ValueError("WPG2 supports only original-byte 65536-byte pages")
        raw = args.input.read_bytes()
        start = time.perf_counter_ns()
        archive, trials = fit(raw, profile=args.profile)
        search_wall_ns = time.perf_counter_ns() - start
        info = inspect(archive)
        with tempfile.TemporaryDirectory(prefix="wpg-verify-",dir=args.output.parent) as temp:
            candidate = Path(temp) / "candidate.wpg2"
            decoded = Path(temp) / "decoded"
            candidate.write_bytes(archive)
            native, verification_wall_ns = invoke_native("decode", candidate, decoded)
            if decoded.read_bytes() != raw:
                raise ValueError("native byte mismatch")
            candidate.replace(args.output)
        selected = next(row for row in trials if row["frame_sha256"] == info["archive_sha256"])
        backend_hashes = {name: sha((BACKEND / name).read_bytes()) for name in
                          ("m_reference", "native_forward", "native_forward_hoist",
                           "reparse_context", "native")}
        paid_process_ns = sum(sum(row["phase_wall_ns"].values()) for row in trials if row["graph"] == "base")
        paid_native_codec_ns = sum(row["codec_ns_paid"] for row in trials if row["graph"] == "base")
        print(json.dumps({**info, "profile": args.profile, "source_sha256": sha(raw),
                          "backend_directory": str(BACKEND), "backend_binary_sha256": backend_hashes,
                          "selected_graph": selected["graph"], "search_wall_ns": search_wall_ns,
                          "paid_process_and_transform_wall_ns": paid_process_ns,
                          "paid_native_codec_ns": paid_native_codec_ns,
                          "native_verification_wall_ns": verification_wall_ns,
                          "fresh_native_full_decode_exact": True, "native_decoder": native,
                          "trials": trials}))
    elif args.operation == "inspect":
        result = inspect(args.input.read_bytes())
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    else:
        result, wall = invoke_native("decode" if args.operation == "decode" else "query",
                                     args.input, args.output,
                                     args.index if args.operation == "extract" else None)
        print(json.dumps({**result, "operation": args.operation,
                          "adapter_wall_ns": wall, "output_sha256": sha(args.output.read_bytes())}))


if __name__ == "__main__":
    main()
