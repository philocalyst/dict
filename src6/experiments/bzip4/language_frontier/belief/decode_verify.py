#!/usr/bin/env python3
"""Fresh-process LBEL decoder used by the storage screen."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from belief_codec import decode_frame  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("frame", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(decode_frame(args.frame.read_bytes()))


if __name__ == "__main__":
    main()

