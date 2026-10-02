#!/usr/bin/env python3
"""Original-byte 64 KiB reset pages with a single shared entropy model.

Page lengths map each original page onto the transformed stream. WGP6's
independent entropy blocks can cover an original page via their overlap with
that transformed interval; constructor registers reset at every page edge.
"""
import argparse
import hashlib
import json
import subprocess
import struct
import tempfile
import zlib
from pathlib import Path

import attribute_register
import scope_register
from compose_best import inverse, REGISTER_DECODER, MAX_RAW, MAX_FRAME
from compose_m import WGP6, run
from template_split import varint, getvar

PAGE = 65536


def transform_page(raw, mode):
    stats = {"local_records": 0, "scope_slices": 0, "scope_edges": 0}
    if mode == 0:
        return raw, stats
    if mode in (1,3):
        local, a = attribute_register.forward(raw)
        stats["local_records"] = a["records"]
    else:
        local = raw.replace(b"\x00",b"\x00\x00")
    if mode in (2,3):
        part, b = scope_register.forward(local)
        stats["scope_slices"] = b["slices"]
        stats["scope_edges"] = b["edges"]
    else:
        part = local
    return part, stats


def encode(data, modes=(0,1,2,3), hoist=False, seed="a-best"):
    if len(data) > MAX_RAW:
        raise ValueError("input exceeds backend limit")
    pages = [data[start:start+PAGE] for start in range(0,len(data),PAGE)]
    checksums = [zlib.crc32(page) for page in pages]
    trials = []
    best = None
    seen = set()
    for mode in modes:
        parts = []
        stats = {"local_records": 0, "scope_slices": 0, "scope_edges": 0}
        for raw in pages:
            part, row = transform_page(raw,mode)
            parts.append(part)
            for key in stats:
                stats[key] += row[key]
        source = b"".join(parts)
        if source in seen or len(source) > MAX_RAW:
            continue
        seen.add(source)
        with tempfile.TemporaryDirectory(prefix="wpg-") as temp:
            src, parse, frame = (Path(temp) / name for name in ("source", "parse", "frame"))
            src.write_bytes(source)
            compiled = run([WGP6 / "m_reference", src, frame, parse, 65536, 20, seed, 1, int(hoist)])
            payload = frame.read_bytes()
        index = b"".join(varint(len(part)) + struct.pack("<I", checksum)
                         for part, checksum in zip(parts, checksums))
        header = b"WPG2" + bytes((mode,)) + varint(len(data)) + varint(PAGE) + varint(len(parts)) + index
        archive = (header + struct.pack("<I",zlib.crc32(header)) +
                   varint(len(payload)) + payload + struct.pack("<I",zlib.crc32(data)))
        row = {**stats, "mode": mode, "hoist": hoist, "seed": seed, "frame_bytes": len(archive), "source_bytes": len(source), "pages": len(parts),
               "page_index_bytes": len(index), "backend_frame_bytes": len(payload),
               "wrapper_bytes": len(archive)-len(payload), "compiled": compiled}
        trials.append(row)
        if best is None or len(archive) < len(best):
            best = archive
    if best is None:
        raise ValueError("no viable modes")
    return best, trials


def decode(archive, native_register=False):
    if not archive.startswith(b"WPG2") or len(archive) < 5:
        raise ValueError("magic")
    mode = archive[4]
    if mode > 3:
        raise ValueError("mode")
    raw_size, at = getvar(archive,5)
    page_size, at = getvar(archive,at)
    count, at = getvar(archive,at)
    if page_size != PAGE or count != (raw_size+PAGE-1)//PAGE:
        raise ValueError("page geometry")
    if raw_size > MAX_RAW:
        raise ValueError("archive limit")
    lengths = []
    checksums = []
    for _ in range(count):
        n, at = getvar(archive,at)
        if n > 2*PAGE:
            raise ValueError("page length")
        lengths.append(n)
        if at+4 > len(archive):
            raise ValueError("short checksum")
        checksums.append(struct.unpack_from("<I",archive,at)[0])
        at += 4
    if at+4 > len(archive) or zlib.crc32(archive[:at]) != struct.unpack_from("<I",archive,at)[0]:
        raise ValueError("header CRC")
    at += 4
    payload_size, at = getvar(archive,at)
    if payload_size > MAX_FRAME:
        raise ValueError("archive limit")
    if at+payload_size+4 != len(archive):
        raise ValueError("frame length")
    with tempfile.TemporaryDirectory(prefix="wpg-decode-") as temp:
        frame, dst = Path(temp) / "frame", Path(temp) / "decoded"
        frame.write_bytes(archive[at:at+payload_size])
        run([WGP6 / "native", "decode", frame, dst])
        if dst.stat().st_size != sum(lengths):
            raise ValueError("transformed length")
        if native_register:
            index_path, output_path = Path(temp)/"lengths",Path(temp)/"raw"
            index_path.write_text("".join(f"{n}\n" for n in lengths))
            subprocess.run([REGISTER_DECODER,str(mode),dst,output_path,"--pages",index_path],
                           check=True,capture_output=True)
            output = output_path.read_bytes()
            if len(output) != raw_size:
                raise ValueError("raw length")
            for i, checksum in enumerate(checksums):
                if zlib.crc32(output[i*PAGE:(i+1)*PAGE]) != checksum:
                    raise ValueError("page CRC")
        else:
            transformed = dst.read_bytes()
            output = bytearray()
            pos = 0
            for n, checksum in zip(lengths, checksums):
                page = inverse(transformed[pos:pos+n], mode)
                if len(page) != min(PAGE,raw_size-len(output)):
                    raise ValueError("raw page length")
                if zlib.crc32(page) != checksum:
                    raise ValueError("page CRC")
                output += page
                pos += n
    if len(output) != raw_size or zlib.crc32(output) != struct.unpack_from("<I",archive,at+payload_size)[0]:
        raise ValueError("CRC")
    return bytes(output)


def extract_page(archive, index):
    """Fresh native extraction of only entropy blocks overlapping one page."""
    if not archive.startswith(b"WPG2") or len(archive) < 5:
        raise ValueError("magic")
    mode = archive[4]
    if mode > 3:
        raise ValueError("mode")
    raw_size, at = getvar(archive,5)
    page_size, at = getvar(archive,at)
    count, at = getvar(archive,at)
    if page_size != PAGE or count != (raw_size+PAGE-1)//PAGE or index >= count:
        raise ValueError("page geometry")
    if raw_size > MAX_RAW:
        raise ValueError("archive limit")
    lengths, checksums = [], []
    for _ in range(count):
        n, at = getvar(archive,at)
        if n > 2*PAGE or at+4 > len(archive):
            raise ValueError("page index")
        lengths.append(n)
        checksums.append(struct.unpack_from("<I",archive,at)[0])
        at += 4
    if at+4 > len(archive) or zlib.crc32(archive[:at]) != struct.unpack_from("<I",archive,at)[0]:
        raise ValueError("header CRC")
    at += 4
    payload_size, at = getvar(archive,at)
    if payload_size > MAX_FRAME:
        raise ValueError("archive limit")
    if at+payload_size+4 != len(archive):
        raise ValueError("frame length")
    start, end = sum(lengths[:index]), sum(lengths[:index+1])
    with tempfile.TemporaryDirectory(prefix="wpg-extract-") as temp:
        frame, ledger = Path(temp)/"frame", Path(temp)/"ledger.json"
        frame.write_bytes(archive[at:at+payload_size])
        run([WGP6/"native","inspect",frame,ledger])
        block_lengths = json.loads(ledger.read_text())["block_raw_lengths"]
        if sum(block_lengths) != sum(lengths):
            raise ValueError("block lengths")
        covered = bytearray()
        block_at = 0
        selected = []
        for block_id, block_len in enumerate(block_lengths):
            block_end = block_at+block_len
            if block_at < end and block_end > start:
                dst = Path(temp)/f"block-{block_id}"
                run([WGP6/"native","extract",frame,dst,block_id])
                raw = dst.read_bytes()
                if len(raw) != block_len:
                    raise ValueError("block length")
                covered += raw[max(0,start-block_at):min(block_len,end-block_at)]
                selected.append(block_id)
            block_at = block_end
        if len(covered) != lengths[index]:
            raise ValueError("transformed page length")
        source, output = Path(temp)/"page-source",Path(temp)/"page-output"
        source.write_bytes(covered)
        subprocess.run([REGISTER_DECODER,str(mode),source,output],check=True,capture_output=True)
        page = output.read_bytes()
    if len(page) != min(PAGE,raw_size-index*PAGE) or zlib.crc32(page) != checksums[index]:
        raise ValueError("page CRC or length")
    return page, selected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input",type=Path)
    ap.add_argument("output",type=Path)
    ap.add_argument("--hoist",action="store_true")
    ap.add_argument("--seed",default="a-best")
    args=ap.parse_args()
    data=args.input.read_bytes()
    archive,trials=encode(data,hoist=args.hoist,seed=args.seed)
    args.output.write_bytes(archive)
    if decode(archive)!=data or decode(archive,native_register=True)!=data:
        raise ValueError("roundtrip")
    for row in trials:
        row["compiled"]={k:row["compiled"].get(k) for k in ("codec_ns","frame_bytes","model_dictionary_bytes","payload_bytes","blocks")}
    print(json.dumps({"input_bytes":len(data),"frame_bytes":len(archive),"selected_mode":archive[4],
                      "frame_sha256":hashlib.sha256(archive).hexdigest(),"trials":trials}))


if __name__=="__main__":
    main()
