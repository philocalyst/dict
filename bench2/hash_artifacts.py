#!/usr/bin/env python3
"""Write a deterministic SHA-256 manifest for every completed run file."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    files = sorted(path for path in args.root.rglob("*") if path.is_file() and path != args.out)
    with args.out.open("w", encoding="utf-8") as stream:
        for path in files:
            relative = path.relative_to(args.root).as_posix()
            stream.write(f"sha256\t{relative}\t{path.stat().st_size}\t{digest(path)}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
