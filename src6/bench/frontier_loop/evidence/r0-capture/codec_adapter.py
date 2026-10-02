#!/usr/bin/env python3
"""Write ordinary standard-codec archives without adding comparison framing."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("encode", "decode"))
    parser.add_argument("codec", choices=("bzip3", "bzip2", "zstd", "xz"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if not args.binary.is_absolute() or not args.binary.is_file():
        raise ValueError("an absolute codec executable is required")
    flags = {"bzip3": ["-b", "32", "-c"], "bzip2": ["-9", "-c"],
             "zstd": ["-19", "--single-thread", "-q", "-c"],
             "xz": ["-9", "--threads=1", "--check=crc64", "-c"]}
    argv = [str(args.binary)] + (flags[args.codec] if args.operation == "encode"
                                else ["-d", "-c"])
    fd, name = tempfile.mkstemp(prefix=".codec-", dir=args.output.parent)
    try:
        with args.input.open("rb") as source, os.fdopen(fd, "wb") as output:
            subprocess.run(argv, stdin=source, stdout=output, check=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, args.output)
    finally:
        if os.path.exists(name):
            os.unlink(name)


if __name__ == "__main__":
    main()
