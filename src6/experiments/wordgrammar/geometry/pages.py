#!/usr/bin/env python3
"""GWT1: exact word geometry with a paid tree and independent original pages."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import zlib

import context_tree
import geometry

HERE = Path(__file__).resolve().parent
PAGE = 65536
HEADER = struct.Struct("<4sIIQIIIIIII")
INDEX = struct.Struct("<III")
MAX_NATIVE = 64 * 1024 * 1024
MAX_ARCHIVE = 3 * geometry.LIMIT + 16384


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def transform(raw, width=72):
    normalized, rows, counts, checksums = [], [], [], []
    for start in range(0, len(raw), PAGE):
        page = raw[start:start+PAGE]
        output, events = geometry.propose(page, width)
        features, labels = context_tree.observations(page, width)
        if len(events) != len(labels) or any(e[1] != y for e, y in zip(events, labels)):
            raise ValueError("page observation mismatch")
        normalized.append(output)
        rows.append((features, labels))
        counts.append(len(events))
        checksums.append(zlib.crc32(page))
    return b"".join(normalized), rows, counts, checksums


def fit_residual(raw, width=72):
    normalized, observations, counts, checksums = transform(raw, width)
    columns = [row for page, _ in observations for row in page]
    labels = [label for _, page in observations for label in page]
    learned = context_tree.fit(columns, labels)
    basic_rows = geometry.frequencies([(r[0], y) for r, y in zip(columns, labels)])
    basic = (1, 0, (0, basic_rows[0]), (0, basic_rows[1]))
    trials = []
    winner = None
    for name, tree in (("two_rows", basic), ("mdl_tree", learned)):
        model = context_tree.serialize(tree)
        flags = [context_tree.pack(tree, rows, symbols) for rows, symbols in observations]
        for i, part in enumerate(flags):
            recovered = context_tree.realize(normalized[i*PAGE:(i+1)*PAGE], part,
                                              model, counts[i], width)
            if recovered != raw[i*PAGE:(i+1)*PAGE]:
                raise ValueError("page realization mismatch")
        charged = len(model) + sum(map(len, flags))
        trials.append({"policy":name,"model_bytes":len(model),"flags_bytes":sum(map(len,flags)),
                       "model_and_flags_bytes":charged})
        if winner is None or charged < winner[0]:
            winner = charged, model, flags, name
    return normalized, counts, checksums, winner[1], winner[2], trials, winner[3]


def container(raw, normalized, counts, checksums, model, flags, native, width=72):
    if len(raw) > geometry.LIMIT or len(native) > MAX_NATIVE:
        raise ValueError("GWT1 raw or native limit")
    if not len(counts) == len(checksums) == len(flags) == (len(raw)+PAGE-1)//PAGE:
        raise ValueError("GWT1 page count")
    index = b"".join(INDEX.pack(c, len(f), checksum) for c, f, checksum in zip(counts, flags, checksums))
    fields = [b"GWT1", 1, width, len(raw), len(counts), len(native), sum(map(len,flags)),
              len(model), zlib.crc32(raw), zlib.crc32(normalized), 0]
    fields[-1] = zlib.crc32(HEADER.pack(*fields) + index + model)
    return HEADER.pack(*fields) + index + model + native + b"".join(flags)


def parse(frame):
    if len(frame) < HEADER.size or len(frame) > MAX_ARCHIVE:
        raise ValueError("GWT1 archive limit")
    fields = list(HEADER.unpack_from(frame))
    magic, version, width, raw, pages, native_len, flags_len, model_len, source_crc, normalized_crc, header_crc = fields
    if (magic != b"GWT1" or version != 1 or not 1 <= width <= 4096 or raw > geometry.LIMIT or
            pages != (raw+PAGE-1)//PAGE or native_len > MAX_NATIVE or
            not 3 <= model_len <= 1533 or flags_len > 2*raw+4*pages or
            HEADER.size+INDEX.size*pages+model_len+native_len+flags_len != len(frame)):
        raise ValueError("GWT1 header")
    index_end = HEADER.size+INDEX.size*pages
    model_end = index_end+model_len
    fields[-1] = 0
    if zlib.crc32(HEADER.pack(*fields)+frame[HEADER.size:model_end]) != header_crc:
        raise ValueError("GWT1 header CRC")
    model = frame[index_end:model_end]
    context_tree.parse(model)
    index, total = [], 0
    for i in range(pages):
        count, size, checksum = INDEX.unpack_from(frame, HEADER.size+INDEX.size*i)
        page_bytes = min(PAGE,raw-i*PAGE)
        if count > page_bytes or not 4 <= size <= 2*count+4:
            raise ValueError("GWT1 page index")
        index.append((count,size,checksum))
        total += size
    if total != flags_len:
        raise ValueError("GWT1 flags geometry")
    return {"raw":raw,"pages":pages,"width":width,"model":model,"index":index,
            "native":frame[model_end:model_end+native_len],"flags":frame[model_end+native_len:],
            "source_crc":source_crc,"normalized_crc":normalized_crc,
            "wrapper_bytes":HEADER.size+INDEX.size*pages+model_len+flags_len}


def restore(normalized, info):
    if len(normalized) != info["raw"] or zlib.crc32(normalized) != info["normalized_crc"]:
        raise ValueError("GWT1 normalized bytes")
    output, at = bytearray(), 0
    for i, (count, size, checksum) in enumerate(info["index"]):
        page = context_tree.realize(normalized[i*PAGE:(i+1)*PAGE],info["flags"][at:at+size],
                                    info["model"],count,info["width"])
        at += size
        if zlib.crc32(page) != checksum:
            raise ValueError("GWT1 page CRC")
        output += page
    if len(output) != info["raw"] or zlib.crc32(output) != info["source_crc"]:
        raise ValueError("GWT1 source CRC")
    return bytes(output)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("operation", choices=("encode","decode","screen"))
    p.add_argument("input",type=Path)
    p.add_argument("output",type=Path)
    p.add_argument("--reference",type=Path,default=HERE.parent/"wgp6"/"m_reference")
    p.add_argument("--native",type=Path,default=HERE.parent/"wgp6"/"native")
    p.add_argument("--profile",choices=("quality","access"),default="quality")
    args = p.parse_args()
    if args.input.stat().st_size > (geometry.LIMIT if args.operation != "decode" else MAX_ARCHIVE):
        raise ValueError("GWT1 input file limit")
    source = args.input.read_bytes()
    source_hash = digest(__file__)
    if args.operation in ("encode","screen"):
        start = time.perf_counter_ns()
        normalized, counts, checksums, model, flags, trials, policy = fit_residual(source)
        residual_ns = time.perf_counter_ns()-start
        basic = trials[0]["model_and_flags_bytes"]
        if args.operation == "screen":
            args.output.write_bytes(normalized)
            print(json.dumps({"source_sha256":hashlib.sha256(source).hexdigest(),"normalized_sha256":hashlib.sha256(normalized).hexdigest(),
                "source_bytes":len(source),"pages":len(counts),"trials":trials,"selected":policy,
                "saved_residual_bytes":basic-len(model)-sum(map(len,flags)),"source_identity":source_hash}))
            return
        native_hash, encoder_hash = digest(args.native), digest(args.reference)
        with tempfile.TemporaryDirectory(prefix="gwt1-") as temporary:
            temp = Path(temporary)
            a,b,graph = temp/"source",temp/"native",temp/"graph"
            a.write_bytes(normalized)
            start = time.perf_counter_ns()
            command = [str(args.reference),str(a),str(b),str(graph),"65536","20","a-best","1",
                       str(int(args.profile=="access"))]
            result = subprocess.run(command,check=True,capture_output=True,text=True)
            backend_ns = time.perf_counter_ns()-start
            native = b.read_bytes()
            if digest(args.reference)!=encoder_hash or digest(args.native)!=native_hash or digest(__file__)!=source_hash:
                raise ValueError("GWT1 executable or source changed during encode")
            subprocess.run([str(args.native),"decode",str(b),str(a)],check=True,capture_output=True)
            if a.read_bytes()!=normalized:
                raise ValueError("GWT1 native normalized gate")
            frame = container(source,normalized,counts,checksums,model,flags,native)
            if restore(a.read_bytes(),parse(frame))!=source:
                raise ValueError("GWT1 complete source gate")
            pending = temp/"archive"
            pending.write_bytes(frame)
            # The eventual native GWT1 reader provides a second independent gate.
            prepared = HERE/"prepared_geometry"
            if prepared.exists():
                subprocess.run([str(prepared),"decode",str(pending),str(a)],check=True,capture_output=True)
                if a.read_bytes()!=source:
                    raise ValueError("GWT1 native realization gate")
            args.output.parent.mkdir(parents=True,exist_ok=True)
            publication = None
            try:
                with tempfile.NamedTemporaryFile(prefix=".gwt1-",dir=args.output.parent,delete=False) as pending:
                    publication = Path(pending.name)
                    pending.write(frame)
                    pending.flush()
                    os.fsync(pending.fileno())
                os.replace(publication,args.output)
            finally:
                if publication is not None:
                    publication.unlink(missing_ok=True)
        print(json.dumps({"frame_bytes":len(frame),"source_bytes":len(source),"profile":args.profile,
            "source_sha256":hashlib.sha256(source).hexdigest(),"frame_sha256":hashlib.sha256(frame).hexdigest(),
            "native_encoder_sha256":encoder_hash,"native_decoder_sha256":native_hash,"source_identity":source_hash,
            "native_frame_bytes":len(native),"wrapper_bytes":len(frame)-len(native),"model_bytes":len(model),
            "page_directory_bytes":INDEX.size*len(counts),"flags_bytes":sum(map(len,flags)),"pages":len(counts),
            "residual_fit_wall_ns":residual_ns,"backend_wall_ns":backend_ns,"residual_trials":trials,
            "native_events":[json.loads(line)for line in result.stdout.splitlines()]}))
    else:
        info = parse(source)
        with tempfile.TemporaryDirectory(prefix="gwt1-decode-") as temporary:
            a,b = Path(temporary)/"native",Path(temporary)/"normalized"
            a.write_bytes(info["native"])
            subprocess.run([str(args.native),"decode",str(a),str(b)],check=True,capture_output=True)
            output = restore(b.read_bytes(),info)
        args.output.write_bytes(output)


if __name__=="__main__":
    main()
