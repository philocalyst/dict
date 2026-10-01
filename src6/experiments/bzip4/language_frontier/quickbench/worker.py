#!/usr/bin/env python3
"""A fresh decoder receives a frame and codec identity, never the source/model.

This is a process-isolation boundary for reproducibility, not a security
sandbox. Candidate modules are trusted local experiment code.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]


def load_module(path: Path):
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location("quickbench_candidate", path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load candidate: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    # Rapid experiments can change a same-sized source twice in one second;
    # bypass timestamp-based .pyc reuse for the adapter itself.
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def transform(codec: dict, operation: str, source: Path, target: Path) -> None:
    kind = codec["kind"]
    block = codec.get("block_bytes")
    if kind == "v4":
        mode, argument = ("c", str(block)) if operation == "encode" else ("d", "1")
        subprocess.run([codec["binary"], mode, str(source), str(target), argument], check=True)
        return

    data = source.read_bytes()
    if kind == "bzip3":
        sys.path.insert(0, str(LAB))
        from frontier_python.protocol.native_bzip3 import bzip3_decode, bzip3_encode_blocks
        output = bzip3_encode_blocks(data, block) if operation == "encode" else bzip3_decode(data)
    elif kind == "wam":
        module = load_module(LAB / "language_frontier/segmentation/weighted_emission_coder.py")
        if operation == "decode":
            output = module.decode_frame(data)
        else:
            tokens, weights = module.make_tokens(data, 8, 2, 256)
            weights = module.em_fit_freqs(data, tokens, weights, 2)
            model = module.Model(tokens, weights, require_singletons=True)
            encode = module.encode_map if codec["mode"] == "map" else module.encode_marginal
            output, valid = encode(data, model)
            if not valid:
                raise ValueError("candidate's internal roundtrip failed")
    elif kind == "module":
        module = load_module(Path(codec["module"]))
        # Only the encoder receives configuration. Every decoder-required
        # option, dictionary, or trained weight must be in the frame itself.
        output = (module.encode(data, block_bytes=block, **codec["options"])
                  if operation == "encode" else module.decode(data))
    else:
        raise ValueError(f"unknown codec: {kind}")
    if not isinstance(output, bytes):
        raise TypeError("encode/decode must return bytes, not an estimate or a size")
    target.write_bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("encode", "decode"))
    parser.add_argument("spec", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    codec = json.loads(args.spec.read_text())
    transform(codec, args.operation, args.source, args.target)


if __name__ == "__main__":
    main()
