#!/usr/bin/env python3
"""One-source paid operand ablation on the fixed original M forward graph."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from time import perf_counter

from inspect_gen import inspect

HERE = Path(__file__).resolve().parent
M = HERE.parent / "wordgrammar" / "wgp6" / "runtime2-backend"
SOURCE = Path("/workspace/scratch/structural-wordcodec/omw-ja-development-1m.bin")
EXPECTED = "256a84131871e344cba72e8fe26130f2148e3ac2c3e08c1af7048125cb79a2b1"


def run(*args):
    result = subprocess.run([str(x) for x in args], capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-2500:])
    return result


def verify(frame, reader, source, output):
    run(reader, "decode", frame, output)
    if output.read_bytes() != source:
        raise RuntimeError("full decode mismatch")
    for index in range((len(source) + 65535) // 65536):
        run(reader, "extract", frame, output, index)
        if output.read_bytes() != source[index * 65536:(index + 1) * 65536]:
            raise RuntimeError(f"page {index} mismatch")


def main():
    source = SOURCE.read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest != EXPECTED:
        raise RuntimeError("source fingerprint mismatch")
    with tempfile.TemporaryDirectory(prefix="typed-ablation-") as folder:
        temp = Path(folder)
        raw, parse = temp / "source.bin", temp / "m.forward"
        raw.write_bytes(source)
        t0 = perf_counter()
        old = run(M / "m_reference", raw, temp / "m.frame", parse, 65536, 20, "a-best", 1, 0)
        m_s = perf_counter() - t0
        m_row = json.loads(old.stdout.decode().splitlines()[-1])
        verify(temp / "m.frame", M / "native", source, temp / "check.bin")
        if m_row["frame_bytes"] != 51272:
            raise RuntimeError("unchanged M baseline drifted")
        frames = {}
        for label, binary, reader, magic in (
            ("SGN2", HERE / "gen_fixed", HERE / "gen_native_reader", b"sgn\x02"),
            ("SGT1", HERE / "typed_fixed", HERE / "typed_reader", b"sgt\x01"),
        ):
            frame = temp / f"{label}.frame"
            t0 = perf_counter()
            run(binary, "compile", parse, frame, 16)
            elapsed = perf_counter() - t0
            verify(frame, reader, source, temp / "check.bin")
            data = frame.read_bytes()
            frames[label] = dict(bytes=len(data), encode_s=elapsed,
                                 sha256=hashlib.sha256(data).hexdigest(),
                                 ledger=inspect(data, magic),
                                 binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        row = dict(source_sha256=digest, raw_bytes=len(source),
                   fixed_policy={"classes": 16, "gen": True, "gen_min_match": 12},
                   unchanged_M_bytes=m_row["frame_bytes"], m_encode_s=m_s,
                   frames=frames, all_frames_full_and_all_pages_exact=True,
                   note="Diagnostic forced GEN; complete private selection is evaluated separately.")
        print(json.dumps(row, sort_keys=True))


if __name__ == "__main__":
    main()
