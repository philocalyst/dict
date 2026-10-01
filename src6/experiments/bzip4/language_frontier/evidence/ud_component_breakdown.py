#!/usr/bin/env python3
"""Derive a non-payload-versus-payload table from frozen UD capture JSON.

This is read-only with respect to captured samples: it reads the final
``summary.json`` and writes a small derived manifest.  It does not invoke a
codec or read a clock.  v4 ``non-payload`` means ``header + lexical-definition
delta + framing``; the delta contains first-use lexical spelling/text
definitions, not merely metadata.  The bzip3 control uses the arithmetic
grouping ``total - payload``.  The two gap columns add exactly to
``v4_total - bzip3_total``; they are not a semantic claim that bzip3 payload
lacks spelling information.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
DEFAULT_RUN = HERE / "runs/storage-screen-auto-20260926-forms-fixed"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, default=DEFAULT_RUN)
    parser.add_argument("--output", type=Path, default=HERE / "manifests/ud-component-breakdown.json")
    args = parser.parse_args()

    summary_path = args.run / "summary.json"
    samples = json.loads(summary_path.read_text(encoding="utf-8"))
    rows: list[dict[str, Any]] = []
    for item in samples:
        name = str(item["source"])
        if not name.startswith("ud-"):
            continue
        v4 = item["v4"]["storage"]
        bzip3 = item["bzip3"]["storage"]
        v4_non_payload = v4["header"] + v4["delta"] + v4["framing"]
        bzip3_non_payload = bzip3["total"] - bzip3["payload"]
        row = {
            "workload": name,
            "input_bytes": v4["raw_len"],
            "v4": {
                "total": v4["total"],
                "header": v4["header"],
                "delta": v4["delta"],
                "payload": v4["payload"],
                "framing": v4["framing"],
                "non_payload_header_delta_framing": v4_non_payload,
                "payload_fraction": v4["payload"] / v4["total"],
            },
            "bzip3": {
                "total": bzip3["total"],
                "payload": bzip3["payload"],
                "non_payload_total_minus_payload": bzip3_non_payload,
            },
            "gap_v4_minus_bzip3": v4["total"] - bzip3["total"],
            "payload_gap_v4_minus_bzip3": v4["payload"] - bzip3["payload"],
            "non_payload_gap_v4_minus_bzip3": v4_non_payload - bzip3_non_payload,
        }
        if row["payload_gap_v4_minus_bzip3"] + row["non_payload_gap_v4_minus_bzip3"] != row["gap_v4_minus_bzip3"]:
            raise ValueError(f"gap decomposition failed for {name}")
        rows.append(row)
    if len(rows) != 6:
        raise ValueError(f"expected six UD rows, got {len(rows)}")

    output = {
        "schema": 1,
        "purpose": "Component decomposition of the six frozen UD storage rows; no timing.",
        "source_summary": {
            "path": str(summary_path.resolve()),
            "sha256": sha256(summary_path),
        },
        "interpretation": {
            "v4_non_payload": "header + lexical-definition delta + framing; delta contains first-use lexical spelling/text definitions, while header is actual model/frame header bytes",
            "bzip3_non_payload": "bzip3 total - bzip3 payload; an arithmetic control grouping, not a semantic equivalent of v4 header/delta",
            "gap_identity": "payload_gap + non_payload_gap = v4_total - bzip3_total",
            "comparability_caveat": "bzip3 payload includes comparable spelling information, so the payload/non-payload split cannot establish an intrinsic sequence-model advantage; information can move between v4 delta and payload.",
            "warning": "A positive total gap can coexist with a negative payload gap; this isolates charged v4 non-payload bytes but does not attribute all lexical/model quality to payload.",
        },
        "rows": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
