#!/usr/bin/env python3
"""Exact byte-level C++/Python geometry residual parity, independent of v4."""
from pathlib import Path
import argparse
import random
import subprocess
import tempfile

import context_tree
import geometry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reader", type=Path, default=Path(__file__).with_name("geometry_decode"))
    parser.add_argument("--real-source", type=Path, help="optional corpus with four sampled 64 KiB pages")
    args = parser.parse_args()
    reader = str(args.reader.resolve())
    rng = random.Random(999)
    cases = [b"", b" ", b"\n", b"word word\nword", b"word \nword",
             bytes(range(256))*256, b"x"*65535+b"\n",
             (b"\x00 \xff\n\xfe \xc0"*7000)[:65536], b"X"*65536,
             b"\nY"+b"x"*65534]
    for _ in range(80):
        chunks = []
        for _ in range(rng.randrange(1, 200)):
            chunks.append(bytes(rng.randrange(256) for _ in range(rng.randrange(0, 70))))
            chunks.append(rng.choice((b" ", b"\n", b"  ", b"\n\n", b" \n")))
        cases.append(b"".join(chunks)[:65536])
    if args.real_source:
        source = args.real_source.read_bytes()
        cases += [source[i:i+65536] for i in (0, 65536, 7*65536, 127*65536)
                  if i < len(source)]
    trees = [(0, 2048), (3, 8, (0, 3000), (0, 1000))]
    with tempfile.TemporaryDirectory(prefix="gwt1-residual-") as name:
        d = Path(name)
        def invoke(normalized, flags, model, count, width=72, accept=True):
            (d/"n").write_bytes(normalized)
            (d/"f").write_bytes(flags)
            (d/"m").write_bytes(model)
            (d/"o").unlink(missing_ok=True)
            done = subprocess.run([reader,str(d/"n"),str(d/"f"),str(d/"m"),
                                   str(count),str(width),str(d/"o")],
                                  capture_output=True,text=True)
            assert (done.returncode == 0) == accept, done.stderr
            return (d/"o").read_bytes() if accept else None
        checks = 0
        for raw in cases:
            normalized, _ = geometry.propose(raw, 72)
            rows, symbols = context_tree.observations(raw, 72)
            for tree in trees:
                model = context_tree.serialize(tree)
                flags = context_tree.pack(tree, rows, symbols)
                assert context_tree.realize(normalized,flags,model,len(symbols),72) == raw
                assert invoke(normalized,flags,model,len(symbols)) == raw
                checks += 1
        normalized = b"a b"
        rows, symbols = context_tree.observations(normalized,72)
        model = context_tree.serialize(trees[0])
        flags = context_tree.pack(trees[0],rows,symbols)
        invoke(normalized,flags[:-1],model,len(symbols),accept=False)
        invoke(normalized,flags+b"\0",model,len(symbols),accept=False)
        invoke(normalized,b"\0\0\0\0",model,len(symbols),accept=False)
        invoke(normalized,flags,model,len(symbols)+1,accept=False)
        invoke(normalized,flags,model,len(symbols),width=0,accept=False)
        invoke(normalized,flags,bytes((0,1,16)),len(symbols),accept=False)
        print({"residual_parity_cases": checks,"malformed_rejections": 6,
               "max_input_bytes": max(map(len,cases))})


if __name__ == "__main__":
    main()
