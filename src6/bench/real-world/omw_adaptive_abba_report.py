#!/usr/bin/env python3
"""Render the separate OMW adaptive ABBA order-bias diagnostic."""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent


def sha256_file(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def phase_ns(entry: dict[str, Any], name: str) -> int | None:
    value = entry["phases"].get(name)
    if isinstance(value, int):
        return value
    if isinstance(value, dict):
        return value.get("ns")
    return None


def fmt(values: list[int]) -> str:
    if not values:
        return "not collected"
    return f"{statistics.median(values) / 1_000_000:.3f} ms (samples: " + ", ".join(f"{v / 1_000_000:.3f}" for v in values) + ")"


def render(data: dict[str, Any], ledger_path: Path) -> str:
    before = [entry for block in data["blocks"] for entry in block["order"] if entry["side"] == "before"]
    after = [entry for block in data["blocks"] for entry in block["order"] if entry["side"] == "after"]
    metrics = (
        ("wall_ns", "fresh process wall", lambda e: e["process"].get("wall_ns")),
        ("metadata_open_ns", "Archive.open / metadata", lambda e: phase_ns(e, "metadata_open_ns")),
        ("exact_batch", "exact batch", lambda e: phase_ns(e, "exact_batch")),
        ("uncached_render_batch", "uncached render batch", lambda e: phase_ns(e, "uncached_render_batch")),
        ("uncached_snippet_batch", "uncached snippet batch", lambda e: phase_ns(e, "uncached_snippet_batch")),
        ("session_mixed_page_render", "mixed-page render", lambda e: phase_ns(e, "session_mixed_page_render")),
        ("session_mixed_page_snippet", "mixed-page snippet", lambda e: phase_ns(e, "session_mixed_page_snippet")),
        ("post_verify_all_ns", "verifyAll after reads", lambda e: phase_ns(e, "post_verify_all_ns")),
    )
    lines = [
        "# OMW adaptive ABBA order-bias diagnostic",
        "",
        f"Status: `{data['status']}`; failures: **{len(data.get('failures', []))}**.",
        "",
        "This separate diagnostic does not replace the six-lane paired ledger. It uses the same retained OMW adaptive artifact and fixed plans, with two fresh-process blocks in the exact order `original → current → current → original`.",
        "",
        f"Ledger: [`{ledger_path.name}`](../runs/{ledger_path.name}), SHA-256 `{sha256_file(ledger_path)}`.",
        f"Original binary: `{data['original_runner']['sha256']}`; current binary: `{data['current_runner']['sha256']}`.",
        "",
        "| phase | original median (raw samples, ms) | current median (raw samples, ms) |",
        "| --- | --- | --- |",
    ]
    for _, label, getter in metrics:
        before_values = [value for entry in before if (value := getter(entry)) is not None]
        after_values = [value for entry in after if (value := getter(entry)) is not None]
        lines.append(f"| {label} | {fmt(before_values)} | {fmt(after_values)} |")
    lines.extend([
        "",
        "All eight samples must pass the same public-oracle digest, output-count, and Reader-cache validation as the main ledger. This is an order-bias check, not a tuned retry or a replacement result; fresh process still does not mean cold OS cache.",
    ])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ledger", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-omw-adaptive-abba.json")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "reports" / "real-world-report-simplifying-post-review-omw-adaptive-abba.md")
    args = parser.parse_args()
    data = json.loads(args.ledger.read_text(encoding="utf-8"))
    if data.get("status") != "omw-adaptive-abba-timed-results" or data.get("failures"):
        raise SystemExit("refusing to render a failed or incomplete ABBA ledger")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(data, args.ledger), encoding="utf-8")
    print(json.dumps({"output": str(args.output.resolve()), "sha256": sha256_file(args.output)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
