#!/usr/bin/env python3
"""Development-only complete-frame spelling-DAG screen.

Native preparation and native compilation are both paid in encoder time.
Fresh-process old-v4 decode must match the identical input before a row is kept.
No final holdout paths belong in this harness.
"""
import argparse
import hashlib
import itertools
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SAMPLES = REPO / "src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples"


def run(args):
    r = subprocess.run(list(map(str, args)), capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output", type=Path)
    ap.add_argument("--size", type=int, default=1 << 20)
    ap.add_argument("--corpora", default="freedict,gcide,omw")
    ap.add_argument("--classes", type=int, default=16)
    ap.add_argument("--modes", default="all,prefix,suffix,edge")
    ap.add_argument("--floors", default="0,2,4")
    ap.add_argument("--rounds", default="0,2,4")
    ap.add_argument("--shares", default="0,32")
    ap.add_argument("--once", default="1")
    ap.add_argument("--old", type=Path, default=Path("/tmp/frontier2026-bzip4-v3"))
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sources = {name: sha(HERE / name) for name in ("prepare.cpp", "compile.zig", "prepare", "compile")}
    rows = []
    for name in args.corpora.split(","):
        source = SAMPLES / f"{name}-eval8-saved/external-decoded.bin"
        data = source.read_bytes()[:args.size]
        raw = args.output / f"{name}.raw"
        raw.write_bytes(data)
        control = args.output / f"{name}-old.frame"
        old = run([args.old, "encode", raw, control, "--block", 65536])
        old_decode = args.output / f"{name}-old.decoded"
        run([args.old, "decode", control, old_decode])
        if old_decode.read_bytes() != data:
            raise RuntimeError("native old control roundtrip")
        common = {"corpus": name, "input_bytes": len(data), "input_sha256": sha(raw), "sources": sources,
                  "old_fullframe": old["output_bytes"], "old": old}
        policies = itertools.product(args.modes.split(","), map(float, args.floors.split(",")),
                                     map(int, args.rounds.split(",")), map(int, args.shares.split(",")),
                                     map(int, args.once.split(",")))
        for mode, floor, rounds, share, once in policies:
            key = f"{name}-{mode}-f{floor}-r{rounds}-s{share}-o{once}"
            parse, frame, decoded = (args.output / (key + x) for x in (".parse", ".frame", ".decoded"))
            prep = run([HERE / "prepare", raw, parse, "--seed", mode, "--floor", floor,
                        "--rounds", rounds, "--share", share, "--once", once])
            encoded = run([HERE / "compile", "compile", parse, frame, args.classes])
            dec = run([HERE / "compile", "decode", frame, decoded])
            if decoded.read_bytes() != data:
                raise RuntimeError(f"productive spelling roundtrip: {key}")
            row = dict(common, policy={"seed": mode, "floor": floor, "rounds": rounds, "share": share,
                                      "once": once, "classes": args.classes}, prepare=prep, encoded=encoded,
                       decoded=dec, frame_sha256=sha(frame), encoder_codec_ns=prep["codec_ns"] + encoded["codec_ns"],
                       delta_bytes=encoded["frame_bytes"] - old["output_bytes"])
            rows.append(row)
            with (args.output / "rows.jsonl").open("a") as f:
                f.write(json.dumps(row, sort_keys=True) + "\n")
            print(json.dumps({"candidate": key, "frame": encoded["frame_bytes"], "old": old["output_bytes"],
                              "delta": row["delta_bytes"], "entries": prep["entries"]}), flush=True)
            parse.unlink(); decoded.unlink()
    (args.output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
