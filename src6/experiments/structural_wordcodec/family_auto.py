#!/usr/bin/env python3
"""Development selector: complete unchanged M versus paid family GEN."""
import argparse
import hashlib
import json
import os
import resource
from pathlib import Path
import subprocess
import sys
import tempfile
from time import perf_counter
from inspect_family import inspect as inspect_gen

HERE = Path(__file__).resolve().parent
M = HERE.parent / "wordgrammar" / "wgp6" / "runtime2-backend"
MAGICS = {b"bz4\x03": M / "native", b"sgf\x01": HERE / "family_reader"}


def run(args):
    def limit():
        resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3, 4 * 1024**3))
        resource.setrlimit(resource.RLIMIT_CPU, (120, 120))

    proc = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, preexec_fn=limit, timeout=110)
    if proc.returncode:
        raise RuntimeError(f"{' '.join(map(str,args))}: {proc.stderr.decode(errors='replace')[-2000:]}")
    return proc


def reader(frame):
    magic = Path(frame).open("rb").read(4)
    if magic not in MAGICS:
        raise ValueError("unknown native frame magic")
    executable = MAGICS[magic]
    if not executable.is_file():
        raise FileNotFoundError(executable)
    return executable


def verify(frame, source, tmp):
    executable = reader(frame)
    result = tmp / "verify.bin"
    run([executable, "decode", frame, result])
    if result.read_bytes() != source:
        raise RuntimeError(f"full-source mismatch: {frame}")
    for index in range((len(source) + 65535) // 65536):
        run([executable, "extract", frame, result, index])
        if result.read_bytes() != source[index * 65536:(index + 1) * 65536]:
            raise RuntimeError(f"restart mismatch: {frame}, block {index}")


def encode(src, dst):
    source = src.read_bytes()
    if len(source) > 64 * 1024 * 1024:
        raise ValueError("native input limit is 64 MiB")
    for executable in (M / "m_reference", HERE / "family_m_reference", *MAGICS.values()):
        if not executable.is_file():
            raise FileNotFoundError(executable)
    start = perf_counter()
    with tempfile.TemporaryDirectory(prefix="gen-auto-", dir=str(dst.parent)) as directory:
        tmp = Path(directory)
        candidates = []
        for label, executable in (("unchanged_M", M / "m_reference"),
                                  ("native_family_GEN", HERE / "family_m_reference")):
            frame, forward = tmp / f"{label}.frame", tmp / f"{label}.forward"
            t0 = perf_counter()
            proc = run([executable, src, frame, forward, 65536, 20, "a-best", 1, 0])
            encode_s = perf_counter() - t0
            verify(frame, source, tmp)
            reported = json.loads(proc.stdout.decode().splitlines()[-1])
            if label == "native_family_GEN":
                ledger = inspect_gen(frame.read_bytes())
                policy = {key: reported[key] for key in ("classes", "gen", "gen_min_match", "families")}
            else:
                ledger = {key: reported[key] for key in
                          ("frame_bytes", "header_bytes", "directory_bytes",
                           "model_dictionary_bytes", "payload_bytes", "raw_bytes")}
                policy = {"classes": reported["classes"], "gen": False}
            candidates.append(dict(label=label, frame=frame, bytes=frame.stat().st_size,
                                   encode_s=encode_s, ledger=ledger, policy=policy))
        chosen = min(candidates, key=lambda c: c["bytes"])
        staged = tmp / "selected.frame"
        staged.write_bytes(chosen["frame"].read_bytes())
        os.replace(staged, dst)
        print(json.dumps(dict(raw_bytes=len(source), source_sha256=hashlib.sha256(source).hexdigest(),
                              selected=chosen["label"], frame_bytes=chosen["bytes"],
                              candidate_bytes={c["label"]: c["bytes"] for c in candidates},
                              candidate_ledgers={c["label"]: c["ledger"] for c in candidates},
                              candidate_policies={c["label"]: c["policy"] for c in candidates},
                              candidate_encode_s={c["label"]: c["encode_s"] for c in candidates},
                              paid_wall_s=perf_counter() - start, verified_full_and_all_pages=True),
                         sort_keys=True), file=sys.stderr)


def decode(src, dst, index):
    with tempfile.TemporaryDirectory(prefix="gen-decode-", dir=str(dst.parent)) as directory:
        staged = Path(directory) / "output.bin"
        args = [reader(src), "extract" if index is not None else "decode", src, staged]
        if index is not None:
            args.append(index)
        run(args)
        os.replace(staged, dst)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("encode", "decode"))
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--index", type=int)
    args = parser.parse_args()
    if args.operation == "encode":
        if args.index is not None:
            parser.error("--index only applies to decode")
        encode(args.input.resolve(), args.output.resolve())
    else:
        decode(args.input.resolve(), args.output.resolve(), args.index)


if __name__ == "__main__":
    main()
