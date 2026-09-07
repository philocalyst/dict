#!/usr/bin/env python3
"""Render a short human report from the lossless benchmark JSON."""

from __future__ import annotations

import argparse
import json
import platform
from collections import defaultdict
from pathlib import Path


FIXTURES = ("flat", "prose_heavy", "repeated", "rich", "pathological_prefix")
CLASS_METRICS = tuple(
    f"{name}.{category}.p{pctl}_ns"
    for name, categories in (
        ("exact", ("hit", "miss")),
        ("prefix", ("zero", "one", "many", "pathological")),
    )
    for category in categories
    for pctl in (50, 95, 99)
)
SIZE_ONLY_EXTERNAL_PROFILES = {
    ("sqlite", "zlib"),
    ("sqlite", "zstd"),
    ("stardict", "gzip"),
}


def validate_dataset(data, presets: str) -> None:
    """Reject incomplete, stale, or semantically divergent run inputs."""
    measured = {}
    available = {}
    unavailable_profiles = set()
    metadata = {}
    for row in data:
        if row["kind"] == "result":
            measured.setdefault((row["fixture"], row["format"], row["variant"]), {})[row["metric"]] = row["value"]
            available.setdefault((row["fixture"], row["format"]), set()).add(row["variant"])
        elif row["kind"] == "unavailable":
            available.setdefault((row["fixture"], row["format"]), set()).add(row["variant"])
            unavailable_profiles.add((row["fixture"], row["format"], row["variant"]))
        elif row["kind"] == "meta":
            metadata[f"{row['scope']}.{row['name']}"] = row["value"]

    expected_internal = {("v1", "raw"), ("v1", "bzip3")}
    for preset in (part.strip() for part in presets.split(",")):
        if preset not in {"latency", "balanced", "compact"}:
            raise ValueError(f"unknown v2 preset in report configuration: {preset!r}")
        expected_internal.update({("v2", f"raw.{preset}"), ("v2", f"bzip3.{preset}")})
    required_profile_metrics = {"artifact_bytes", "build_ns", "open_ns", "semantic_digest", "query_checksum", "outputs"}
    required_profile_metrics.update(CLASS_METRICS)
    for fixture in FIXTURES:
        digest_values = set()
        checksum_values = set()
        for family in ("zig", "external"):
            wall = metadata.get(f"{fixture}.{family}.process_wall_ns")
            rss = metadata.get(f"{fixture}.{family}.process_peak_rss_bytes")
            if not isinstance(wall, int) or wall <= 0 or not isinstance(rss, int) or rss <= 0:
                raise ValueError(f"missing portable process wall/RSS metadata for {fixture}/{family}")

        for fmt, variant in expected_internal:
            metrics = measured.get((fixture, fmt, variant))
            if metrics is None:
                raise ValueError(f"missing internal profile {fixture}/{fmt}/{variant}")
            missing = required_profile_metrics.difference(metrics)
            if missing:
                raise ValueError(f"incomplete internal profile {fixture}/{fmt}/{variant}: {sorted(missing)}")
            if not isinstance(metrics["semantic_digest"], int) or not isinstance(metrics["query_checksum"], int):
                raise ValueError(f"non-numeric semantic checks for {fixture}/{fmt}/{variant}")
            digest_values.add(metrics["semantic_digest"])
            checksum_values.add(metrics["query_checksum"])

        for fmt in ("sqlite", "stardict", "dict-index", "slob"):
            if (fixture, fmt) not in available:
                raise ValueError(f"missing external availability row for {fixture}/{fmt}")
        for (row_fixture, fmt, variant), metrics in measured.items():
            if row_fixture != fixture or fmt in {"v1", "v2"}:
                continue
            missing = required_profile_metrics.difference(metrics)
            if missing:
                if (
                    (fmt, variant) in SIZE_ONLY_EXTERNAL_PROFILES
                    and set(metrics) == {"artifact_bytes"}
                    and (row_fixture, fmt, variant) in unavailable_profiles
                ):
                    continue
                raise ValueError(f"incomplete external profile {fixture}/{fmt}/{variant}: {sorted(missing)}")
            if not isinstance(metrics["semantic_digest"], int) or not isinstance(metrics["query_checksum"], int):
                raise ValueError(f"non-numeric external semantic checks for {fixture}/{fmt}/{variant}")
            digest_values.add(metrics["semantic_digest"])
            checksum_values.add(metrics["query_checksum"])

        if len(digest_values) != 1 or len(checksum_values) != 1:
            raise ValueError(f"semantic/query equivalence failure for {fixture}: digests={digest_values}, checksums={checksum_values}")

    for row in data:
        if row["kind"] == "unavailable" and row["format"] in {"zig", "external"} and row["variant"] == "process":
            raise ValueError(f"benchmark child failed: {row['fixture']}/{row['format']}: {row['value']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--records", required=True)
    parser.add_argument("--repetitions", required=True)
    parser.add_argument("--warmup", required=True)
    parser.add_argument("--external-repetitions", required=True)
    parser.add_argument("--external-warmup", required=True)
    parser.add_argument("--presets", required=True)
    args = parser.parse_args()
    if args.external_repetitions != args.repetitions or args.external_warmup != args.warmup:
        raise ValueError("external repetitions/warmup must match Zig for checksum-equivalent reports")
    data = json.loads(args.json.read_text(encoding="utf-8"))["rows"]
    validate_dataset(data, args.presets)
    measured = defaultdict(dict)
    unavailable = []
    metadata = {}
    for row in data:
        if row["kind"] == "result":
            measured[(row["fixture"], row["format"], row["variant"])][row["metric"]] = row["value"]
        elif row["kind"] == "unavailable":
            unavailable.append(row)
        elif row["kind"] == "meta":
            metadata[f"{row['scope']}.{row['name']}"] = row["value"]

    def number(metrics, key):
        value = metrics.get(key)
        return "-" if value is None or value == "-" else f"{value:,}"

    def millis(metrics, key):
        value = metrics.get(key)
        return "-" if value is None or value == "-" else f"{value / 1_000_000:.3f}"

    def micros(metrics, key):
        value = metrics.get(key)
        return "-" if value is None or value == "-" else f"{value / 1000:.2f}"

    lines = [
        "# LEX2 benchmark results",
        "",
        "This report is generated from `benchmark.json`; the raw TSV files retain every observation.",
        "",
        "## Reproduction",
        "",
        f"- Host: `{metadata.get('global.host', platform.platform())}` (the run's exact tool versions are in `raw/machine.tsv`).",
        f"- Corpus: deterministic fixtures, `{args.records}` records, seed `0x4c45583200020001`.",
        f"- Repetitions/warmup: Zig `{args.repetitions}`/`{args.warmup}`; external `{args.external_repetitions}`/`{args.external_warmup}`.",
        f"- v2 prose presets: `{args.presets}`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.",
        "- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.",
        "- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.",
        "",
        "## Measured profiles",
        "",
        "| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for (fixture, fmt, variant), metrics in sorted(measured.items()):
        if "artifact_bytes" not in metrics:
            continue
        def us(name, pctl):
            key = f"{name}.p{pctl}_ns"
            if key not in metrics and name == "render":
                key = f"render_cold.p{pctl}_ns"
            return micros(metrics, key)
        lines.append(
            f"| {fixture} | `{fmt}/{variant}` | {number(metrics, 'artifact_bytes')} | "
            f"{millis(metrics, 'build_ns')} | {micros(metrics, 'open_ns')} | "
            f"{us('exact', 50)}/{us('exact', 95)}/{us('exact', 99)} | "
            f"{us('prefix', 50)}/{us('prefix', 95)}/{us('prefix', 99)} | "
            f"{us('render', 50)}/{us('render', 95)}/{us('render', 99)} |"
        )

    lines += [
        "",
        "## Cardinality-class timings",
        "",
        "Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.",
        "",
        "| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for (fixture, fmt, variant), metrics in sorted(measured.items()):
        lines.append(
            f"| {fixture} | `{fmt}/{variant}` | "
            f"{micros(metrics, 'exact.hit.p50_ns')} | {micros(metrics, 'exact.miss.p50_ns')} | "
            f"{micros(metrics, 'prefix.zero.p50_ns')} | {micros(metrics, 'prefix.one.p50_ns')} | "
            f"{micros(metrics, 'prefix.many.p50_ns')} | {micros(metrics, 'prefix.pathological.p50_ns')} |"
        )

    rss = [(key, value) for key, value in metadata.items() if "process_peak_rss_bytes" in key]
    lines += ["", "## Semantic checks", "", "All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.", ""]
    for fixture in sorted({key[0] for key in measured}):
        digests = sorted({str(metrics.get("semantic_digest")) for key, metrics in measured.items() if key[0] == fixture and "semantic_digest" in metrics})
        lines.append(f"- `{fixture}` digest values: `{', '.join(digests)}`")
    if rss:
        lines += [
            "",
            "Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).",
            "Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.",
        ]
        lines.extend(f"- `{key}`: `{value}` bytes" for key, value in sorted(rss))

    lines += ["", "## Availability and caveats", ""]
    if unavailable:
        for row in unavailable:
            lines.append(f"- `{row['fixture']} {row['format']}/{row['variant']}`: {row['value']}")
    else:
        lines.append("- No unavailable profile was emitted.")
    lines += [
        "- The v1/v2 comparison is an equal lexical projection. v2's rich fixture adds graph assertions; external formats intentionally receive only the same flat key/definition projection, so those rows do not measure graph preservation.",
        "- SQLite zlib/zstd and StarDict gzip rows report artifact sizes only: whole-file compression destroys page/index random access unless a decompression staging policy is chosen, so query latency is not fabricated.",
        "- `dict-index` is a local sorted UTF-8 offset reader, not a dictd daemon; it is intentionally relabeled when real dictfmt/dictd service timing is unavailable. Its dictzip variant uses range decompression.",
        "- External profiles are Python readers: Python's sqlite3 wrapper, the custom StarDict and sorted-offset readers, and optional reference SLOB. Their interpreter/library overhead is part of those timings and is not equivalent to the native Zig v1/v2 implementations.",
        "- v1/v2 open timing includes their format-specific structural/semantic open path (v2 validates the canonical manifest, sections, derived indexes, and cached views). External open timing measures reader construction only; every external artifact is semantically validated before warmup and timing, but that validation is not part of external open latency.",
        "- Build timing is format-specific: v1/v2 includes builder/compile plus the in-process Reader/Snapshot.open validation boundary; external build timing covers the custom reader/artifact construction. It is not an equivalent end-to-end build pipeline.",
        "- SLOB is Python reference SLOB with raw and lzma2 compression. Its UUID/timestamp metadata is not byte-for-byte deterministic even though the corpus and semantic digest are.",
        "- Timings are single-process wall-clock samples after deterministic warmup on one otherwise uncontrolled host; use p95/p99 and raw TSV for comparisons, not a claim of universal performance.",
        "",
        "Raw outputs: `results/latest/raw/*.tsv`; machine-readable output: `results/latest/benchmark.json`; generated artifacts: `results/latest/artifacts/<fixture>/`; SHA-256 manifest: `results/latest/hashes.tsv`.",
    ]
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
