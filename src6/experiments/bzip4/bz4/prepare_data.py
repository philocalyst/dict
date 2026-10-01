#!/usr/bin/env python3
"""One-off corpus slicer for the bz4 lab (tooling only; the codec is pure Zig).

Dictionary lanes replicate the frozen frontier protocol exactly:
  train     = content[0, 1MiB)
  eval8     = content[1MiB, 9MiB)
  untouched = content[9MiB, 10MiB)
Generality lanes are 8 MiB local samples of other data types.
"""
import hashlib, os, subprocess, sys, glob
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
CORP = os.path.join(ROOT, "src6/bench/real-world/evidence/corpora")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
MiB = 1 << 20
os.makedirs(OUT, exist_ok=True)

def content(path, limit):
    out = bytearray()
    with open(path, "rb") as f:
        for line in f:
            line = line.rstrip(b"\n")
            if not line: continue
            out += bytes.fromhex(line.split(b"\t")[2].decode())
            if len(out) >= limit: break
    return bytes(out)

def put(name, data):
    with open(os.path.join(OUT, name), "wb") as f: f.write(data)
    print(f"{name}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}")

for short, d in (("freedict", "freedict-eng-spa"), ("gcide", "gcide-054"), ("omw", "omw-ja-20")):
    c = content(os.path.join(CORP, d, "projection.tsv"), 10 * MiB)
    put(f"{short}.train.bin", c[:MiB])
    put(f"{short}.eval8.bin", c[MiB:9 * MiB])
    put(f"{short}.untouched.bin", c[9 * MiB:10 * MiB])

# generality lanes
with open(os.path.join(CORP, "gcide-054", "rows.jsonl"), "rb") as f:
    f.seek(4 * MiB); put("json.eval8.bin", f.read(8 * MiB))
zig = os.path.realpath(subprocess.check_output(["which", "zig"]).decode().strip())
with open(zig, "rb") as f:
    f.seek(32 * MiB); put("macho.eval8.bin", f.read(8 * MiB))
std = subprocess.check_output(["zig", "env"]).decode()
std_dir = [l.split('"')[1] for l in std.splitlines() if ".std_dir" in l][0]
src = bytearray()
for p in sorted(glob.glob(os.path.join(std_dir, "**/*.zig"), recursive=True)):
    with open(p, "rb") as f: src += f.read()
    if len(src) >= 8 * MiB: break
put("zigsrc.eval8.bin", bytes(src[:8 * MiB]))
