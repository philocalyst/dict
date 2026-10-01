"""Print derived tables from actual final capture records, without timing work."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics


def median_ns(trials: list[dict]) -> int:
    return int(statistics.median(item["decode_ns"] for item in trials))


def optional_count(value: int | None) -> str:
    return "—" if value is None else f"{value:,}"


def tables(root: Path) -> str:
    summary = json.loads((root / "results.json").read_text())
    assert summary["status"] == 0 and summary["source_drift"]["ok"]
    rows = [item["result"] for item in summary["records"]]
    native = {(row["corpus"], row["lane"], row["block_bytes"]): row for row in rows if row["variant"] == "native"}
    out = [
        "# Frozen serial measurements",
        "",
        "Derived from saved subprocess records; all sizes are complete frames.",
        "F, grammar_input, and symbol_bwt are Python references; native is compiled bzip3.",
        "These clocks describe these implementations and are not evidence of a native candidate speedup.",
        "Each retained full decode has three samples after one separately recorded first decode.",
        "Restart samples each include fresh model preparation. First and middle blocks are deterministic, not disk-cold.",
        "",
    ]
    for lane in ("final", "untouched"):
        out.extend([
            f"## {lane}",
            "",
            "| Corpus | Block KiB | Codec | Complete B | vs bzip3 | Decode ms min/median/max | MiB/s | Prep ms | First restart ms | Middle restart ms | Encode s |",
            "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        ])
        for row in rows:
            if row["lane"] != lane:
                continue
            control = native[(row["corpus"], lane, row["block_bytes"])]
            clocks = [trial["decode_ns"] for trial in row["decode_trials"]]
            middle = statistics.median(clocks)
            ms = "/".join(f"{value / 1e6:.3f}" for value in (min(clocks), middle, max(clocks)))
            mibps = row["input"]["evaluation_bytes"] / 1048576 / (middle / 1e9)
            ratio = row["frame_bytes"] / control["frame_bytes"] - 1
            encode_ns = row["encode"]["encode_total_ns"]
            out.append(
                f"| {row['corpus']} | {row['block_bytes'] // 1024} | {row['variant']} | {row['frame_bytes']:,} | {ratio:+.2%} | {ms} | {mibps:.3f} | "
                f"{row['decode_model_prep_ns'] / 1e6:.3f} | {median_ns(row['first_block']['decode_trials']) / 1e6:.3f} | "
                f"{median_ns(row['random_block']['decode_trials']) / 1e6:.3f} | {encode_ns / 1e9:.3f} |"
            )
        out.append("")
    out.extend([
        "## Safety and memory accounting",
        "",
        "Process peak RSS includes corpus loading, training, encoding, saving, and decoding; it is not decoder-only memory.",
        "Logical prepared-state estimates omit Python object overhead and must not be presented as measured native scratch.",
        "",
        "| Corpus | Lane | Block KiB | Codec | Model B | Whole-process peak RSS | Logical prepared B | Logical initialization B | Grammar expansion B | Native conservative scratch B | First full decode ms |",
        "|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for row in rows:
        memory = row["memory"]
        analytic = memory["decoder_analytic"]
        rss = memory["process_rss_peak"]
        out.append(
            f"| {row['corpus']} | {row['lane']} | {row['block_bytes'] // 1024} | {row['variant']} | "
            f"{optional_count(row['model_bytes'])} | {rss['value']} {rss['units']} | {optional_count(analytic.get('prepared_state_bytes_estimate'))} | "
            f"{optional_count(analytic.get('initialization_bytes'))} | {optional_count(analytic.get('grammar_preexpanded_bytes'))} | "
            f"{optional_count(analytic.get('conservative_native_scratch_bytes'))} | {row['decode_warmup']['first_full_decode_ns'] / 1e6:.3f} |"
        )
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(tables(args.root), end="")
