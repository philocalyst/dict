#!/usr/bin/env python3
"""Fixed development-only LXB1 transform screen; writes durable exact frames."""
import argparse
import hashlib
import itertools
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
SOURCES = pathlib.Path("/workspace/scratch/frontier-corpora")
EXE = ROOT / "lexical_bwt"
BZIP3 = pathlib.Path("/workspace/scratch/bzip3")
INITIAL = {
    "freedict-eng-fra": SOURCES / "dictionaries/freedict-eng-fra/development/content.txt",
    "gcide-debian-054": SOURCES / "dictionaries/gcide-debian-054/development/content.txt",
    "omw-ja-20": SOURCES / "dictionaries/omw-ja-20/development/content.txt",
}
def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(argv):
    t0 = time.monotonic_ns()
    p = subprocess.run(argv, capture_output=True)
    elapsed = time.monotonic_ns() - t0
    if p.returncode:
        raise RuntimeError({"argv": list(map(str, argv)), "status": p.returncode,
                            "stderr": p.stderr.decode(errors="replace")})
    return p, elapsed


def policies(stage):
    if stage == "initial":
        # All requested factorizations, rank orders, direction maps and a
        # direct-token control share one exact zstd-9 backend and one wire.
        for kind in ("byte", "word", "subword"):
            orders = ("lex",) if kind == "byte" else ("lex", "frequency", "first")
            cap = 0 if kind == "byte" else 1024 if kind == "word" else 32
            for order, direction, pipe in itertools.product(
                    orders, ("forward", "reverse", "lines"), ("direct", "bwt")):
                yield kind, order, direction, pipe, cap, 9, "zstd"
    elif stage == "backend":
        # Frozen from the initial three-corpus source-only screen: retain each
        # corpus winner's token/pipe family plus neighboring BWT controls.
        choices = (("byte", "direct", 0), ("byte", "bwt", 0),
                   ("word", "bwt", 1024), ("subword", "direct", 32),
                   ("subword", "bwt", 32))
        for (kind, pipe, cap), backend in itertools.product(choices, ("zstd", "bzip3")):
            yield kind, "lex", "forward", pipe, cap, 19, backend
    elif stage == "scale":
        # Promoted mechanisms from the 128 KiB backend gate, including the
        # byte-direct identity control. Complete same-source frames decide.
        for kind, pipe, cap in (("byte", "direct", 0), ("byte", "bwt", 0),
                                ("word", "bwt", 1024), ("subword", "direct", 32)):
            yield kind, "lex", "forward", pipe, cap, 19, "bzip3"
    elif stage == "allword":
        # True lexical alphabet: every eligible word run has a delivered ID;
        # optional exact separator-run IDs test whether side literals dominate.
        for kind, order, pipe in itertools.product(
                ("word-all", "word-sep"), ("lex", "frequency"), ("direct", "bwt")):
            yield kind, order, "forward", pipe, 65536, 19, "bzip3"
    else:
        raise ValueError("unknown fixed stage")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", choices=["initial", "backend", "scale", "allword"], default="initial")
    ap.add_argument("--out", type=pathlib.Path, required=True)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    prefix = 1048576 if a.stage == "scale" else 131072
    manifest = {
        "stage": a.stage, "input_prefix_bytes": prefix,
        "corpora": {k: str(v) for k, v in INITIAL.items()},
        "policies": list(policies(a.stage)), "control": "bzip3 1.5.1 whole CLI",
        "backend": "zstd level 9 for initial; zstd level 19 versus bzip3 1.5.1 for backend; bzip3 1.5.1 for scale; transform-only",
        "lxb_source_sha256": sha((ROOT / "lexical_bwt.cpp").read_bytes()),
        "lxb_binary_sha256": sha(EXE.read_bytes()),
        "bzip3_binary_sha256": sha(BZIP3.read_bytes()),
    }
    (a.out / "protocol.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (a.out / "rows.jsonl").open("w") as rows:
        for name, path in INITIAL.items():
            data = path.read_bytes()[:prefix]
            cell = a.out / name
            cell.mkdir()
            source = cell / "source.bin"
            source.write_bytes(data)
            control, control_ns = run([str(BZIP3), "-c", str(source)])
            (cell / "whole.bz3").write_bytes(control.stdout)
            check, _ = run([str(BZIP3), "-d", "-c", str(cell / "whole.bz3")])
            assert check.stdout == data
            for kind, order, direction, pipe, cap, level, backend in policies(a.stage):
                label = f"{kind}-{order}-{direction}-{pipe}-{backend}"
                frame = cell / f"{label}.lxb"
                restored = cell / "restored.bin"
                argv = [str(EXE), "encode", str(source), str(frame), "--kind", kind,
                        "--order", order, "--direction", direction, "--pipe", pipe,
                        "--cap", str(cap), "--level", str(level), "--backend", backend]
                encode, encode_ns = run(argv)
                decode, decode_ns = run([str(EXE), "decode", str(frame), str(restored)])
                assert restored.read_bytes() == data
                assert not encode.stdout and not decode.stdout
                packed = frame.read_bytes()
                ledger = json.loads(encode.stderr)
                assert ledger["frame"] == len(packed)
                row = {
                    "corpus": name, "source_path": str(path), "source_bytes": len(data),
                    "source_sha256": sha(data), "control_whole_bzip3_bytes": len(control.stdout),
                    "control_sha256": sha(control.stdout), "control_process_ns": control_ns,
                    "kind": kind, "order": order, "direction": direction, "pipe": pipe,
                    "cap": cap, "zstd_level": level, "backend": backend, "frame_bytes": len(packed),
                    "frame_sha256": sha(packed), "frame_path": str(frame),
                    "delta_vs_whole_bzip3": len(packed) - len(control.stdout),
                    "encode_process_ns": encode_ns, "decode_process_ns": decode_ns,
                    "ledger": ledger, "decode_exact": True,
                }
                rows.write(json.dumps(row, sort_keys=True) + "\n")
                rows.flush()
                print(f"{name} {label} {len(packed)} / {len(control.stdout)}", flush=True)
            restored.unlink()


if __name__ == "__main__":
    main()
