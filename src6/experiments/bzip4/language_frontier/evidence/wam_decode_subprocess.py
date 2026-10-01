#!/usr/bin/env python3
"""Decode one weighted-emission frame in a fresh process.

The caller supplies only the serialized frame.  No source input, fitted model,
or candidate-training bytes are read by this helper; ``decode_frame`` rebuilds
the model from the frame header.  It is deliberately tiny so the screen can
retain the command, output hash, and stderr for each independent decode.
"""

from __future__ import annotations

import hashlib
import importlib.util
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
WAM_SOURCE = HERE.parent / "segmentation" / "weighted_emission_coder.py"


def load_codec():
    spec = importlib.util.spec_from_file_location("weighted_emission_coder", WAM_SOURCE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import weighted-emission codec: {WAM_SOURCE}")
    module = importlib.util.module_from_spec(spec)
    if str(WAM_SOURCE.parent) not in sys.path:
        sys.path.insert(0, str(WAM_SOURCE.parent))
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: wam_decode_subprocess.py FRAME OUTPUT")
    frame_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    frame = frame_path.read_bytes()
    codec = load_codec()
    restored = codec.decode_frame(frame)
    output_path.write_bytes(restored)
    print(
        f"ok\traw_len={len(restored)}\tsha256={hashlib.sha256(restored).hexdigest()}",
        flush=True,
    )


if __name__ == "__main__":
    main()
