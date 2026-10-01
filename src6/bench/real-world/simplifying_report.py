#!/usr/bin/env python3
"""Render the retained simplifying post-review paired timing ledger."""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parent
CORPUS_NAMES = {
    "freedict-eng-spa": "FreeDict eng-spa",
    "gcide-054": "GNU GCIDE 0.54",
    "omw-ja-20": "OMW Japanese 2.0",
}


def sha256_file(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def median_ns(samples: list[dict[str, Any]], getter: Callable[[dict[str, Any]], Any]) -> float | None:
    values = [value for sample in samples if (value := getter(sample)) is not None]
    return float(statistics.median(values)) if values else None


def phase_ns(sample: dict[str, Any], name: str) -> int | None:
    phases = sample["phases"]
    value = phases.get(name)
    if isinstance(value, int):
        return value
    if isinstance(value, dict) and isinstance(value.get("ns"), int):
        return value["ns"]
    return None


def labeled_ns(sample: dict[str, Any], phase: str, label: str) -> int | None:
    for item in sample["phases"].get(phase, []):
        if item.get("label") == label:
            return item.get("ns")
    return None


def metric_getter(name: str) -> Callable[[dict[str, Any]], Any]:
    if name == "wall_ns":
        return lambda sample: sample["process"].get("wall_ns")
    if name.startswith("label:"):
        _, phase, label = name.split(":", 2)
        return lambda sample: labeled_ns(sample, phase, label)
    if name == "prefix0":
        return lambda sample: next((item.get("ns") for item in sample["phases"].get("prefix_batches", []) if item.get("batch") == 0), None)
    return lambda sample: phase_ns(sample, name)


def fmt_ms(value: float | None) -> str:
    if value is None:
        return "not collected"
    return f"{value / 1_000_000:.3f} ms"


def fmt_pair(before: float | None, after: float | None) -> str:
    if before is None or after is None:
        return "—"
    if before < 1_000 or after < 1_000:
        return f"{before:.0f} ns → {after:.0f} ns (display-only)"
    delta = (after - before) / before * 100 if before else None
    suffix = "n/a" if delta is None else f"{delta:+.1f}%"
    return f"{fmt_ms(before)} → {fmt_ms(after)} ({suffix})"


def phase_table(data: dict[str, Any]) -> str:
    metrics = [
        ("wall_ns", "fresh process"),
        ("metadata_open_ns", "Archive.open / metadata"),
        ("reader_init_ns", "Reader.init"),
        ("label:first_exact:exact-first", "first exact"),
        ("exact_batch", "exact batch"),
        ("prefix0", "prefix batch 0"),
        ("label:first_render:render-0", "first render"),
        ("label:first_snippet:snippet-0", "first snippet"),
        ("uncached_render_batch", "uncached render batch"),
        ("uncached_snippet_batch", "uncached snippet batch"),
        ("session_first_cold", "session cold render"),
        ("session_same_page_render", "session same-page render"),
        ("session_same_page_snippet", "session same-page snippet"),
        ("session_mixed_page_render", "session mixed-page render"),
        ("session_mixed_page_snippet", "session mixed-page snippet"),
        ("post_verify_all_ns", "verifyAll after reads"),
    ]
    lines = [
        "| corpus | codec | " + " | ".join(label for _, label in metrics) + " |",
        "| --- | --- | " + " | ".join("---" for _ in metrics) + " |",
    ]
    for corpus in data["corpora"]:
        for lane in corpus["lanes"]:
            sides = {side: [sample[side] for sample in lane["samples"]] for side in ("before", "after")}
            cells: list[str] = []
            for key, _ in metrics:
                if key == "session_same_page_snippet":
                    cells.append("NOT COLLECTED")
                    continue
                getter = metric_getter(key)
                before = median_ns(sides["before"], getter)
                after = median_ns(sides["after"], getter)
                cells.append(fmt_pair(before, after))
            lines.append(f"| {CORPUS_NAMES[corpus['corpus']]} | {lane['codec']} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def cache_table(data: dict[str, Any]) -> str:
    lines = [
        "| corpus | codec | phase | page loads | bzip3 decodes | cache hits | decoded bytes |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    for corpus in data["corpora"]:
        for lane in corpus["lanes"]:
            sample = lane["samples"][0]
            for side, title in (("before", "before"), ("after", "after")):
                for phase in ("session_first_cold", "session_same_page_render", "session_mixed_page_render", "session_mixed_page_snippet"):
                    stats = sample[side]["phases"][phase]
                    lines.append(
                        f"| {CORPUS_NAMES[corpus['corpus']]} | {lane['codec']} | {title} {phase} | "
                        f"{stats['page_loads']} | {stats['bzip3_decodes']} | {stats['cache_hits']} | {stats['decoded_bytes']} |"
                    )
    return "\n".join(lines)


def artifact_table(data: dict[str, Any]) -> str:
    lines = ["| corpus | codec | bytes | SHA-256 |", "| --- | --- | ---: | --- |"]
    for corpus in data["corpora"]:
        for lane in corpus["lanes"]:
            artifact = lane["artifact"]
            lines.append(f"| {CORPUS_NAMES[corpus['corpus']]} | {lane['codec']} | {artifact['bytes']:,} | `{artifact['sha256']}` |")
    return "\n".join(lines)


def source_table(data: dict[str, Any]) -> str:
    lines = ["| path | bytes | SHA-256 |", "| --- | ---: | --- |"]
    for item in data["source_hashes_current_tree"]:
        lines.append(f"| `{item['path']}` | {item['bytes']:,} | `{item['sha256']}` |")
    return "\n".join(lines)


def render(data: dict[str, Any], timing_path: Path, baseline_path: Path, old_report_path: Path) -> str:
    timing_hash = sha256_file(timing_path)
    baseline_hash = sha256_file(baseline_path)
    old_report_hash = sha256_file(old_report_path)
    return f"""# Simplifying post-review real-world comparison

Status: `{data['status']}`; correctness failures: **{len(data.get('failures', []))}**.

This is a separate targeted report. It does not overwrite or replace the full
format report at [`real-world-report-post-review.md`](real-world-report-post-review.md),
whose SHA-256 is `{old_report_hash}`. That retained report contains the complete
all-format native/sidecar storage table and the measured page-size/bzip3 horizon
analysis. This report adds only the matched production-simplification check.

## Paired scope and provenance

The run used the same retained 64 KiB raw and adaptive LEX6 artifacts, source
projections, and fixed query/row plans for FreeDict eng-spa, GNU GCIDE 0.54,
and OMW Japanese 2.0. For each lane and sample, the preserved post-review
binary ran first and the frozen-tree binary ran second. There were three
samples per side, 36 child processes total, and no retries. Fresh processes
were used without claiming cold OS cache; no cache eviction was attempted.

| item | value |
| --- | --- |
| preserved original binary | `{data['original_runner']['sha256']}` ({data['original_runner']['bytes']:,} B) |
| current binary | `{data['current_runner']['sha256']}` ({data['current_runner']['bytes']:,} B) |
| paired ledger | [`simplifying-post-review-timing.json`](../runs/simplifying-post-review-timing.json), `{timing_hash}` |
| baseline manifest | [`simplifying-post-review-baseline.json`](../runs/simplifying-post-review-baseline.json), `{baseline_hash}` |
| fixed order | corpus → codec (`raw`, `adaptive`) → sample; original then current |
| operation schedule | runner internal warmup; fixed exact/prefix/render/snippet workloads; 256-operation batches; 3 prefix batches |
| verification control | `post_verify_all_ns`, after measured reads; not a cold verify measurement |

All 36 samples passed independent oracle validation. Digests, hit/key/output
counts, and cache counters matched between before and after for every lane.
The pair order is retained for auditability and is a possible cache-order
confound; the table is descriptive evidence, not a blanket speedup claim.

## Retained input artifacts

{artifact_table(data)}

Every path and SHA-256 above was checked immediately before the paired run;
the result also retains projection and plan hashes under `inputs`.

## Latency comparison

Each cell is the three-sample median, before → after, followed by the relative
change. Positive percentages mean the current binary took longer for that
phase. Values are kept in milliseconds here; raw nanoseconds and every sample
remain in the JSON ledger.

{phase_table(data)}

The existing public measure protocol did not emit a distinct
`session_same_page_snippet` phase. It emitted same-page full render and
mixed-page snippet, and those are reported above; the missing same-page
snippet is explicitly **not collected**, not inferred from another phase.

The measured verifyAll-after-reads medians improve by roughly 10.5–14.0% on
the three raw lanes and 0.7–2.5% on the three adaptive lanes, while
same-page render is generally modestly lower. Mixed-page render/snippet varies
by corpus and codec: OMW raw is +4.1%/+3.7% and OMW adaptive is +2.3%/+4.1%
for mixed render/snippet, and OMW adaptive's uncached render batch is a larger
+15.4% regression. This does not support a universal “faster” conclusion.
`Reader.init` is retained as a separate control even when its nanosecond value
rounds to 0.000 ms in this display.

## Reader cache accounting

The first cold session load must show one or more page loads and zero cache
hits; same-page render must show 256 cache hits and zero page loads; mixed-page
phases must cross page boundaries. The paired counters are shown for sample 0
(they are identical across all three samples).

{cache_table(data)}

## Source hashes used by the current build

The current-tree provenance includes all benchmark inputs, the root module's
production imports, `build6.zig`, and the vendored bzip3 tree digest. The
preserved original is treated as a retained executable baseline; this source
tree is not asserted to reproduce that older binary.

{source_table(data)}

The vendored bzip3 tree is recorded as a deterministic file-tree digest above.

## Storage and bzip3 interpretation

The retained full report is the authority for all-format storage comparisons:
LEX6 metadata/payload, StarDict, DICT, dictzip (including its required index),
SQLite, and SLOB native files plus separately charged SLOB identity sidecars.
Its bzip3 section records every 16/64/256 KiB page decision: adaptive selected
bzip3 on every page, with zero raw/resource-limit fallbacks and zero probe
errors; adaptive and forced-bzip3 artifacts were byte-identical per target.
Larger pages reduced metadata and adaptive storage on these corpora but make
random-access granularity coarser. Whole-stream bzip3 is storage-only because
it omits packet framing, metadata, and page restart boundaries; it is not a
random-access latency lane.

## Reproduction boundary

The bounded driver is [`simplifying_measure.py`](../simplifying_measure.py).
It wraps the existing public `runner.zig` measure protocol, checks every
retained hash before launch, requires the literal quiet gate, and writes the
paired ledger. No source corpora or archives were regenerated for this run.
The one preflight path-resolution rejection launched zero child processes and
collected zero clocked samples; it is retained as
[`simplifying-post-review-preflight-path-bug.json`](../runs/simplifying-post-review-preflight-path-bug.json).
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timing", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-timing.json")
    parser.add_argument("--baseline", type=Path, default=ROOT / "evidence" / "runs" / "simplifying-post-review-baseline.json")
    parser.add_argument("--old-report", type=Path, default=ROOT / "evidence" / "reports" / "real-world-report-post-review.md")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "reports" / "real-world-report-simplifying-post-review.md")
    args = parser.parse_args()
    data = json.loads(args.timing.read_text(encoding="utf-8"))
    if data.get("status") != "simplifying-post-review-timed-results" or data.get("failures"):
        raise SystemExit("refusing to render a report from a failed paired ledger")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(data, args.timing, args.baseline, args.old_report), encoding="utf-8")
    print(json.dumps({"output": str(args.output.resolve()), "sha256": sha256_file(args.output)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
