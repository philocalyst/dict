#!/usr/bin/env python3
"""Preserve benchmark TSV exactly while adding a machine-readable JSON view."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def value(raw: str):
    try:
        return int(raw)
    except ValueError:
        try:
            return float(raw)
        except ValueError:
            return raw


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()
    rows = []
    for name in args.files:
        for line_number, line in enumerate(Path(name).read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if not line:
                continue
            fields = line.split("\t")
            kind = fields[0]
            if kind == "result":
                if len(fields) != 6:
                    raise ValueError(f"malformed result row in {name}:{line_number}")
                rows.append({
                    "kind": kind,
                    "fixture": fields[1],
                    "format": fields[2],
                    "variant": fields[3],
                    "metric": fields[4],
                    "value": value("\t".join(fields[5:])),
                })
            elif kind == "sample":
                if len(fields) != 7:
                    raise ValueError(f"malformed sample row in {name}:{line_number}")
                try:
                    index = int(fields[5])
                except ValueError as exc:
                    raise ValueError(f"non-numeric sample index in {name}:{line_number}") from exc
                try:
                    sample_value = int(fields[6])
                except ValueError as exc:
                    raise ValueError(f"non-numeric sample value in {name}:{line_number}") from exc
                rows.append({
                    "kind": kind,
                    "fixture": fields[1],
                    "format": fields[2],
                    "variant": fields[3],
                    "metric": fields[4],
                    "index": index,
                    "value": sample_value,
                })
            elif kind == "unavailable":
                if len(fields) != 6:
                    raise ValueError(f"malformed unavailable row in {name}:{line_number}")
                rows.append({
                    "kind": kind,
                    "fixture": fields[1],
                    "format": fields[2],
                    "variant": fields[3],
                    "metric": fields[4],
                    "value": "\t".join(fields[5:]),
                })
            elif kind == "meta":
                if len(fields) not in (4, 5):
                    raise ValueError(f"malformed meta row in {name}:{line_number}")
                if len(fields) >= 5:
                    rows.append({
                        "kind": kind,
                        "scope": f"{fields[1]}.{fields[2]}",
                        "name": fields[3],
                        "value": value("\t".join(fields[4:])),
                    })
                    continue
                rows.append({
                    "kind": kind,
                    "scope": fields[1],
                    "name": fields[2],
                    "value": value("\t".join(fields[3:])),
                })
            else:
                raise ValueError(f"unknown TSV row kind {kind!r} in {name}:{line_number}")
    args.out.write_text(json.dumps({"rows": rows}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
