#!/usr/bin/env python3
"""Export compact CSV and Markdown summaries from a completed harness run."""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


FIELDS = [
    "candidate", "corpus", "split", "block_mode", "block_bytes", "raw_bytes",
    "frame_bytes", "metadata_bytes", "model_dictionary_bytes", "payload_bytes",
    "blocks", "block_raw_min_bytes", "block_raw_max_bytes", "ratio",
    "encode_ns_median", "decode_ns_median", "intrinsic_encode_ns_median",
    "intrinsic_decode_ns_median", "encode_maxrss_kib_median", "decode_maxrss_kib_median",
    "extract_first_wall_ns_median", "extract_middle_wall_ns_median", "extract_last_wall_ns_median",
    "extract_first_codec_ns_median", "extract_middle_codec_ns_median", "extract_last_codec_ns_median",
    "extraction_policy", "extraction_verified_blocks", "extraction_verified_raw_bytes",
]


def summarize(rows: list[dict], out: Path) -> None:
    with (out / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({**row, "split": row.get("input", {}).get("split")})

    env = json.loads((out / "environment.json").read_text()) if (out / "environment.json").is_file() else {}
    mode = env.get("mode", "unknown")
    grouped: dict[tuple[str, int], list[dict]] = {}
    for row in rows:
        block = int(row["block_bytes"])
        grouped.setdefault((row["candidate"], block), []).append(row)
    note = ("Screen clocks are diagnostic only." if mode == "screen" else
            "Codec time is reported from operation-matched candidate subprocess metrics; process wall time and cold extraction are separate.")
    lines = ["# Frontier 2026 benchmark summary", "", note, "",
             "| Candidate | Block target | Input bytes | Frame bytes | Weighted ratio | Encode codec ms | Decode codec ms | Corpora | Extraction checks |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for (candidate, block), group in sorted(grouped.items()):
        raw_bytes = sum(int(row["raw_bytes"]) for row in group)
        frame_bytes = sum(int(row["frame_bytes"]) for row in group)
        checks = sum(int(row.get("extraction_verified_blocks", 0)) for row in group)
        encode_values = [row["intrinsic_encode_ns_median"] for row in group
                         if row.get("intrinsic_encode_ns_median") is not None]
        decode_values = [row["intrinsic_decode_ns_median"] for row in group
                         if row.get("intrinsic_decode_ns_median") is not None]
        enc_ms = f"{sorted(encode_values)[len(encode_values)//2] / 1_000_000:.2f}" if encode_values else "—"
        dec_ms = f"{sorted(decode_values)[len(decode_values)//2] / 1_000_000:.2f}" if decode_values else "—"
        lines.append(f"| {candidate} | {block} | {raw_bytes} | {frame_bytes} | "
                     f"{frame_bytes / max(1, raw_bytes):.4f} | {enc_ms} | {dec_ms} | {len(group)} | {checks} |")
    lines.extend(["", "## Per-corpus rows", "",
                  "See `summary.csv` for exact per-lane frame, metadata, model, payload, and timing fields.", ""])
    (out / "summary.md").write_text("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run_dir", type=Path, help="directory containing completed results.json")
    args = ap.parse_args()
    source = args.run_dir / "results.json"
    rows = json.loads(source.read_text())
    summarize(rows, args.run_dir)
    print(f"wrote {args.run_dir / 'summary.csv'} and {args.run_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
