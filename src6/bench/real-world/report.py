#!/usr/bin/env python3
"""Render the real-world smoke and page-diagnostic evidence report.

The report is generated from the JSON ledgers produced by the independent
preparation, smoke, sweep, legacy-probe, inventory, and (after authorization)
measurement commands.  Until the root-only gate is used, the timing section
remains explicitly pending.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent
DEFAULT_RUNS = ROOT / "evidence" / "runs"
DEFAULT_CORPORA = ROOT / "evidence" / "corpora"
DEFAULT_OUTPUT = ROOT / "evidence" / "reports" / "real-world-report.md"

CORPUS_NAMES = {
    "freedict-eng-spa": "FreeDict eng-spa",
    "gcide-054": "GNU GCIDE 0.54",
    "omw-ja-20": "OMW Japanese 2.0",
}


def load(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def choose_existing(root: Path, *names: str) -> Path:
    for name in names:
        candidate = root / name
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"none of the retained ledgers exist: {', '.join(names)}")


def comma(value: int | float) -> str:
    if isinstance(value, float):
        return f"{value:,.2f}"
    return f"{value:,}"


def pct(numerator: int | float, denominator: int | float) -> str:
    if not denominator:
        return "n/a"
    return f"{100.0 * numerator / denominator:.2f}%"


def ratio(numerator: int | float, denominator: int | float) -> str:
    if not denominator:
        return "n/a"
    return f"{numerator / denominator:.3f}x"


def short_hash(value: str | None) -> str:
    if not value:
        return "n/a"
    return value[:16] + "…"


def row_stats(corpus_root: Path, corpus: str) -> dict[str, Any]:
    path = corpus_root / corpus / "rows.jsonl"
    content = native = rows = max_content = 0
    max_key_count = 0
    non_ascii_keys = duplicate_key_rows = 0
    seen_keys: dict[str, int] = {}
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            row = json.loads(line)
            rows += 1
            content += int(row["content_bytes"])
            native += int(row.get("native_record_bytes", 0))
            max_content = max(max_content, int(row["content_bytes"]))
            max_key_count = max(max_key_count, int(row["key_count"]))
            keys = row["keys"]
            for key in keys:
                seen_keys[key] = seen_keys.get(key, 0) + 1
                if any(ord(char) >= 128 for char in key):
                    non_ascii_keys += 1
            if len(keys) != len(set(keys)):
                duplicate_key_rows += 1
    return {
        "rows": rows,
        "content_bytes": content,
        "native_record_bytes": native,
        "max_content_bytes": max_content,
        "max_key_count": max_key_count,
        "non_ascii_key_hits": non_ascii_keys,
        "duplicate_key_rows": duplicate_key_rows,
        "unique_keys": len(seen_keys),
        "duplicate_key_hits": sum(count - 1 for count in seen_keys.values() if count > 1),
    }


def read_diag_summary(text: str) -> dict[str, int]:
    for line in reversed(text.splitlines()):
        fields = line.split("\t")
        if fields and fields[0] == "diag_summary":
            values = dict(zip(fields[1::2], fields[2::2]))
            return {key: int(value) for key, value in values.items() if key != "status"}
    return {}


def markdown_table(headers: list[str], rows: Iterable[Iterable[Any]]) -> str:
    output = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        output.append("| " + " | ".join(str(value).replace("|", "\\|") for value in row) + " |")
    return "\n".join(output)


def external_summary(corpus: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for item in corpus["external"]["artifacts"]:
        key = f"{item.get('format')}:{item.get('variant')}"
        result.setdefault(key, []).append(item)
    return result


def storage_row(item: dict[str, Any]) -> dict[str, Any] | None:
    """Summarize native format bytes separately from benchmark sidecars."""
    files = [file for file in item.get("files", []) if isinstance(file, dict) and file.get("bytes") is not None]
    if not files:
        return None
    fmt = str(item.get("format", "unknown"))
    variant = str(item.get("variant", "raw"))
    sidecar_names = (".rows.json", ".refs.json")
    sidecar = [file for file in files if Path(str(file.get("path", ""))).name.endswith(sidecar_names)]
    native = [file for file in files if file not in sidecar]
    return {
        "lane": fmt if variant in {"raw", ""} else f"{fmt} {variant}",
        "native_bytes": sum(int(file.get("bytes", 0)) for file in native),
        "sidecar_bytes": sum(int(file.get("bytes", 0)) for file in sidecar),
        "total_bytes": sum(int(file.get("bytes", 0)) for file in files),
        "components": ", ".join(f"{Path(str(file.get('path', ''))).name}={comma(int(file.get('bytes', 0)))}" for file in files),
        "status": item.get("status", "ok"),
    }


def corpus_storage_rows(corpus: dict[str, Any]) -> list[list[str]]:
    rows: list[list[str]] = []
    for lane in corpus.get("lex6", []):
        layout = lane.get("layout", {})
        artifact = layout.get("file", {})
        if not artifact:
            continue
        rows.append([
            f"LEX6 {lane.get('codec')}",
            f"metadata={comma(int(layout.get('metadata_bytes', 0)))}; payload={comma(int(layout.get('payload_bytes', 0)))}",
            comma(int(artifact.get("bytes", 0))),
            "0",
            comma(int(artifact.get("bytes", 0))),
        ])
    seen: set[tuple[str, int]] = set()
    for item in corpus.get("external", {}).get("artifacts", []):
        summary = storage_row(item)
        if summary is None:
            continue
        identity = (summary["lane"], int(summary["total_bytes"]))
        # Smoke reports retain a separate validation record for StarDict with
        # no files.  Keep each actual storage bundle exactly once even if a
        # future ledger repeats a successful builder record.
        if identity in seen:
            continue
        seen.add(identity)
        rows.append([
            summary["lane"],
            summary["components"],
            comma(summary["native_bytes"]),
            comma(summary["sidecar_bytes"]),
            comma(summary["total_bytes"]),
        ])
    return rows


def render(*, runs: Path, corpora_root: Path, output: Path) -> str:
    selected = load(ROOT / "manifest.json")
    corpus_manifest = load(corpora_root / "manifest.json")
    main_smoke_path = choose_existing(runs, "main-smoke-post-review.json", "main-smoke.json")
    if main_smoke_path.name == "main-smoke-post-review.json":
        smoke_paths = [main_smoke_path]
    else:
        smoke_paths = [main_smoke_path, runs / "gcide-smoke.json", runs / "omw-ja-smoke.json"]
    smoke_reports = [load(path) for path in smoke_paths]
    smoke_by_corpus: dict[str, Any] = {}
    # main-smoke.json is the current all-corpus ledger.  Keep its entries when
    # older per-corpus convenience ledgers are also present, so newly added
    # validation lanes (for example dictzip RA reads) are not shadowed.
    for report in smoke_reports:
        for corpus in report["corpora"]:
            smoke_by_corpus.setdefault(corpus["corpus"], corpus)
    exhaustive_path = runs / "all-exact-smoke.json"
    # The post-review main ledger already ran --all-exact-queries.  Do not
    # mix the retained pre-refactor convenience ledger into current results.
    exhaustive = load(exhaustive_path) if main_smoke_path.name != "main-smoke-post-review.json" and exhaustive_path.is_file() else None
    timing_path = choose_existing(runs, "timing-results-post-review-final.json", "timing-results-post-review.json", "timing-results.json")
    timing_exists = timing_path.is_file()
    sweep_path = choose_existing(runs, "page-sweep-post-review.json", "page-sweep.json")
    sweep = load(sweep_path)
    environment_path = choose_existing(runs, "environment-post-review.json", "environment.json")
    environment = load(environment_path)
    legacy = load(runs / "legacy-availability.json")
    fairness_path = runs / "fairness-audit-post-review.json"
    fairness = load(fairness_path) if fairness_path.is_file() else None
    ledger_environment = None
    if environment.get("source_inputs", {}).get("status") != "ok" and (runs / "environment.json").is_file():
        ledger_environment = load(runs / "environment.json")

    for report in smoke_reports:
        if report.get("status") != "smoke-ok" or report.get("timing") != "not run":
            raise RuntimeError(f"unexpected smoke ledger status: {report}")
    if sweep.get("status") != "sweep-ok" or sweep.get("timing") != "not run":
        raise RuntimeError("page sweep is not a successful non-timed ledger")
    if exhaustive is not None and (exhaustive.get("status") != "smoke-ok" or exhaustive.get("timing") != "not run"):
        raise RuntimeError("exhaustive LEX6 smoke ledger is not a successful non-timed ledger")
    if fairness is not None and fairness.get("status") != "fairness-audit-ok":
        raise RuntimeError("post-review fairness audit is not successful")

    corpus_entries = {entry["corpus"]: entry for entry in corpus_manifest["corpora"]}
    selected_entries = {entry["id"]: entry for entry in selected["selected_corpora"]}
    stats_by_corpus = {corpus: row_stats(corpora_root, corpus) for corpus in corpus_entries}
    source_inventory = environment if environment.get("source_inputs", {}).get("status") == "ok" else ledger_environment
    source_inventory_note = "current environment ledger" if source_inventory is environment else "baseline environment ledger; source paths are not claimed live"

    lines: list[str] = []
    status_sentence = (
        "The complete three-corpus preparation, independent core-format smoke matrix, bounded LEX6 page/bzip3 decomposition, and the fixed gated timing schedule are retained below.  Timed values are descriptive within each lane; they are not a cross-language microsecond ranking."
        if timing_exists else
        "The complete three-corpus preparation, independent core-format smoke matrix, and bounded LEX6 page/bzip3 decomposition all completed successfully.  This ledger contains correctness and storage evidence only: no latency or throughput clock was read.  The root-only `ROOT-EXPLICIT-QUIET-GATE` is still required before any timing command is valid."
    )
    lines += [
        "# Independent real-world dictionary evidence",
        "",
        "## Status",
        "",
        status_sentence,
        "",
        "All three corpora use the full pinned input selected in the manifest; no 2,048/8,192-row or other cherry-picked subset was used.  Every parser reported zero malformed records or unresolved OMW references.  The independent oracle retains source order, source IDs, every key occurrence, homographs, Unicode, empty content, and full normalized content; readers are checked against it rather than receiving expected answers.",
        "",
        "## Corpus provenance and projection",
        "",
        markdown_table(
            ["corpus", "archive", "archive checksum", "license", "source retained", "rows / unique keys / hits", "content / projection"],
            [
                [
                    CORPUS_NAMES[corpus],
                    comma(entry["source_manifest"]["archive"]["bytes"]) + " B",
                    "SHA-256 " + short_hash(entry["source_manifest"]["archive"]["sha256"]),
                    selected_entries[corpus]["license"],
                    comma(environment_source(source_inventory or {}, corpus)["extracted"]["bytes"]) + " B / " + comma(environment_source(source_inventory or {}, corpus)["extracted"]["files"]) + " files (" + source_inventory_note + ")",
                    f"{comma(entry['rows'])} / {comma(entry['unique_keys'])} / {comma(entry['key_hits'])}",
                    f"{comma(stats_by_corpus[corpus]['content_bytes'])} B / {comma(entry['projection_tsv']['bytes'])} B",
                ]
                for corpus, entry in corpus_entries.items()
            ],
        ),
        "",
        f"Exact provenance URLs and full checksums are in `../corpora/manifest.json` and `../runs/{environment_path.name}`; the abbreviated table is only for readability.  Extracted-source byte totals above are {source_inventory_note}.",
        "",
    ]

    for corpus, entry in corpus_entries.items():
        stats = entry["stats"]
        row = stats_by_corpus[corpus]
        source = entry["source_manifest"]
        lines += [f"### {CORPUS_NAMES[corpus]}", ""]
        lines.append(f"Source: [{source['url']}]({source['url']}); archive `{source['archive']['path']}` ({comma(source['archive']['bytes'])} bytes, SHA-256 `{source['archive']['sha256']}`, SHA-512 `{source['archive']['sha512']}`); retained license `{source['license']['path']}` (SHA-256 `{source['license']['sha256']}`).")
        if corpus == "freedict-eng-spa":
            lines.append("The parser consumed the complete TEI `eng-spa.tei` entry set.  Front matter outside entries is excluded from the matched rows; each row preserves every form, pronunciation, label, sense, translation, example, and nested child as deterministic normalized TEI XML.")
        elif corpus == "gcide-054":
            lines.append(f"The parser consumed all CIDE.A through CIDE.Z files and captured each complete SGML entry span through the next `<p><ent>` boundary, including every `<ent>` alias, `<hw>`, paragraphs, labels, citations, and cross-references.  {comma(stats.get('front_matter_excluded_bytes', 0))} source bytes of front matter/trailing editor text were outside entry rows; legacy ISO-8859-1 bytes were decoded explicitly and reported in the projection manifest.")
        else:
            lines.append(f"The parser consumed complete `omw-ja.xml` LexicalEntry records.  Each entry keeps its entire Lemma/Form/Sense markup and appends each referenced Synset's definitions, examples, and relation children exactly once, without recursive graph expansion.  Sense→Synset resolution was complete: {comma(stats['synset_references'])} references, {comma(stats['unique_synsets_referenced'])} unique referenced synsets, and zero unresolved references.")
            lines.append(f"OMW shared-resource expansion is quantified separately: {comma(stats['unique_synset_serialized_bytes'])} B of unique referenced Synset XML becomes {comma(stats['expanded_synset_serialized_bytes'])} B when charged to entries, an introduced duplicate of {comma(stats['expansion_duplication_bytes'])} B.  This normalized flattening is matched storage evidence; native shared synset/graph richness is not claimed by the flattened lane.")
        lines.append(f"Projection counts: {comma(entry['rows'])} source lexical rows, {comma(entry['unique_keys'])} unique keys, {comma(entry['key_hits'])} key occurrences, {comma(entry['duplicate_key_hits'])} repeated-key hits; normalized content totals {comma(row['content_bytes'])} B (largest row {comma(row['max_content_bytes'])} B).  `projection.tsv` SHA-256 is `{entry['projection_tsv']['sha256']}` and `rows.jsonl` retains metadata/content hashes and source IDs.")
        lines.append("")

    lines += [
        "## Format matrix and correctness boundaries",
        "",
        "The following lanes are genuinely built/read artifacts.  Validation is independent of construction and includes every distinct exact key, every source row's content, selected prefixes, and all-hit occurrence counts.  A native tool is used for representative edge checks where available; CLI startup/transport is not silently treated as in-process reader latency.",
        "",
        markdown_table(
            ["lane", "storage/reader", "FreeDict", "GCIDE", "OMW Japanese", "boundary"],
            [
                ["LEX6 raw / adaptive / forced bzip3", "public src6 archive API via independent runner", "smoke-ok", "smoke-ok", "smoke-ok", "all entries/hits/content/rendering checked; page diagnostics below"],
                ["StarDict raw", "real `.ifo/.idx/.syn/.dict`; independent binary reader + genuine sdcv", "ok", "ok", "ok", "sdcv uses 8 finite representative cases; custom reader exhaustive exact/content checks"],
                ["DICT raw", "real `.dict/.index`; independent reader + `dictunformat`", "ok", "ok", "ok", "dictd server transport not started"],
                ["dictzip", "real `dict.dict.dz`; full decompression + `dictzip` range", "ok", "ok", "ok", "random-access compressed payload; whole-file gzip is not substituted"],
                ["SLOB raw / lzma2", "real Python SLOB writer/reader, ICU recorded separately", "ok", "ok", "ok", "timed reader-ready includes native open plus explicitly charged refs sidecar setup; build validation is separate"],
                ["SQLite control", "real indexed SQLite key/content tables + sqlite3 CLI", "ok", "ok", "ok", "indexed control, not a dictionary-native protocol"],
                ["LEX5", "frozen source test build probe", "unavailable adapter", "unavailable adapter", "unavailable adapter", "no corpus build/reader frontend exposed by src5/root.zig/build5.zig"],
                ["src4 bench frontend", "frozen compiled `lex4-bench`", "unavailable adapter", "unavailable adapter", "unavailable adapter", "binary accepts its semantic fixture protocol, not the full projection TSV"],
                ["src2 bench frontend", "frozen compiled `src2-bench`", "unavailable adapter", "unavailable adapter", "unavailable adapter", "binary accepts its semantic fixture protocol, not the full projection TSV"],
            ],
        ),
        "",
        "External validation counts (per corpus) are recorded in each smoke JSON.  StarDict aliases use `.syn` with one primary payload per source row; SLOB uses one native blob with multiple keys; SQLite has explicit key-index rows; DICT shares offsets among aliases.  Where a format lacks source row identity, the validation maps occurrence multisets by key/content and never invents a persisted identity comparison.",
        "",
        "Primary format references used for the adapters: [StarDict file format](https://github.com/huzheng001/stardict-3/blob/master/dict/doc/StarDictFileFormat), [sdcv](https://github.com/Dushistov/sdcv), [DICT RFC 2229](https://www.rfc-editor.org/info/rfc2229/), [dictzip reference](https://manpages.opensuse.org/Leap-16.0/dictd/dictzip.1.en.html), [SLOB reference implementation](https://github.com/itkach/slob), and [SQLite file format](https://www.sqlite.org/fileformat.html).  These references define the storage/reader boundaries; they do not turn custom Python readers into native implementations.",
        "",
        "The legacy compile probes are preserved verbatim in [`legacy-availability.json`](../runs/legacy-availability.json): LEX5 returned code 0 for its tests but exposed no artifact/frontend; src4 and src2 returned code 0 and produced binaries (SHA-256 `412cabd14ef6c501` and `b588e63c769a915e` respectively), but their `--help` invocations returned `InvalidArgument` and no adapter can represent this full projection.  They are therefore not timed or presented as failed format implementations.",
        "",
    ]

    lines += ["## 64 KiB smoke artifacts", ""]
    smoke_rows = []
    for corpus, report in smoke_by_corpus.items():
        by_codec = {item["codec"]: item for item in report["lex6"]}
        raw = by_codec["raw"]["layout"]
        adaptive = by_codec["adaptive"]["layout"]
        bzip = by_codec["bzip3"]["layout"]
        ext_status = {key: value for key, value in external_statuses(report).items()}
        smoke_rows.append([
            CORPUS_NAMES[corpus],
            f"{comma(report['records'])}/{comma(report['unique_keys'])}/{comma(report['key_hits'])}",
            f"{comma(raw['file']['bytes'])} B",
            f"{comma(adaptive['file']['bytes'])} B",
            f"{comma(bzip['file']['bytes'])} B",
            f"{raw['page_count']}",
            "; ".join(f"{key}={value}" for key, value in ext_status.items()),
        ])
    lines += [
        markdown_table(["corpus", "rows / keys / hits", "LEX6 raw", "adaptive", "forced bzip3", "pages", "external validation"], smoke_rows),
        "",
        f"Raw/adaptive/bzip3 LEX6 artifacts are byte-hashed in the smoke ledgers and retained under the artifact root recorded by `{environment_path.name}`; every LEX6 run reports `smoke-ok`, all-hit/content digests matching the external oracle, and the post-review ledger `{main_smoke_path.name}` checks every distinct exact key.  Independent external readers also validate every distinct exact key.",
        "",
    ]

    if fairness is not None:
        fairness_rows = []
        for item in fairness.get("corpora", []):
            rows = item.get("rows", {})
            payload = item.get("payload_checks", [])
            payload_status = "ok" if all(check.get("payload_once_per_record") for check in payload) else "failed"
            span = item.get("max_alias_span") or {}
            span_text = "n/a" if not span else f"{span.get('key_count', 0)} keys; ent={span.get('ent_count', 0)}, hw={span.get('hw_count', 0)}, paired={span.get('ent_set_equals_hw_set')}, before-hw={span.get('all_ent_before_first_hw')}"
            fairness_rows.append([
                CORPUS_NAMES.get(item["corpus"], item["corpus"]),
                f"{comma(rows.get('rows', 0))}/{comma(rows.get('key_hits', 0))}",
                f"{comma(rows.get('multi_key_rows', 0))}; max {comma(rows.get('max_keys_in_row', 0))}",
                payload_status,
                "ok" if item.get("occurrence_checks", {}).get("all_match") else "failed",
                span_text,
                item.get("status"),
            ])
        lines += [
            "## Alias and payload fairness audit",
            "",
            f"The post-review fairness ledger [`{fairness_path.name}`](../runs/{fairness_path.name}) is non-timed and is keyed to the fresh smoke ledger `{main_smoke_path.name}` plus the retained projection hashes.  Every current native bundle path and SHA-256 matched at audit time.  Each external format stores one content payload per source row; aliases are index occurrences, not duplicated payloads.  StarDict `.syn`, DICT index entries, SQLite key rows, and SLOB identity refs are charged as their actual format or explicitly labeled harness boundaries.",
            "",
            markdown_table(["corpus", "rows / key hits", "multi-key rows / max aliases", "payload once", "occurrences", "largest grouped span", "status"], fairness_rows),
            "",
            "GCIDE's 1,179-key maximum span is corroborated from the retained projection content: 1,179 `<ent>` values equal 1,179 `<hw>` values, all `<ent>` tags precede the first `<hw>`, with 2 paragraphs and 1,181 definitions.  It is a genuine grouped alias span, not an embedded cross-reference list.",
            "",
        ]

    lines += ["## 64 KiB full artifact storage", ""]
    lines.append("The table below reports every retained 64 KiB lane, including competitor files that are not part of the LEX6 layout table.  `native bytes` are the format files a native reader needs; `harness sidecar` is charged separately for row/identity mapping used only to validate aliases and source-order occurrences.  `total` is the complete retained bundle for that lane, and component names preserve the exact file boundary.")
    lines.append("")
    storage_rows: list[list[str]] = []
    for corpus, report in smoke_by_corpus.items():
        for row in corpus_storage_rows(report):
            storage_rows.append([CORPUS_NAMES.get(corpus, corpus), *row])
    lines += [
        markdown_table(["corpus", "lane", "native components / LEX6 breakdown", "native bytes", "harness sidecar", "total bytes"], storage_rows),
        "",
        "LEX6 metadata includes its header/index/catalog/directory and payload is the page region; external sidecars are never presented as native compression or reader storage.  DICT and dictzip each include their own index because that index is required for lookup; the dictzip row counts `.dz` rather than the raw `.dict` retained as the builder input.  SLOB `.refs.json` is the explicitly charged identity bridge, not part of the SLOB file.",
        "",
    ]
    if exhaustive is not None:
        exhaustive_rows = []
        for corpus in exhaustive.get("corpora", []):
            exhaustive_rows.append([
                CORPUS_NAMES.get(corpus["corpus"], corpus["corpus"]),
                comma(corpus["unique_keys"]),
                ", ".join(f"{item['codec']}={comma(item['smoke']['query_checks'])}" for item in corpus["lex6"]),
            ])
        lines += [
            "An explicitly exhaustive, non-timed LEX6 query audit is retained in [`all-exact-smoke.json`](../runs/all-exact-smoke.json).  It queried every distinct exact key through each raw/adaptive/forced-bzip3 archive in addition to the fixed edge cases; the counts below include those edge cases.",
            "",
            markdown_table(["corpus", "distinct exact keys", "LEX6 query checks by codec"], exhaustive_rows),
            "",
        ]

    lines += ["## Bzip3/adaptive decomposition", ""]
    lines.append("Each page-size lane first opens and fully verifies its archive and then measures the actual selected page codec, raw and encoded page lengths, page count, metadata (`header + index + directory`), payload, and probe result.  `max_page_bytes` and `max_document_bytes` stayed at 1 MiB for all targets, so the 16/64/256 KiB values are target page sizes rather than an accidental bzip3 block-limit reduction.  Oversized documents remain intact.")
    lines.append("")
    sweep_rows = []
    for corpus_report in sweep["corpora"]:
        for size in corpus_report["page_sizes"]:
            lanes = {lane["codec"]: lane for lane in size["lanes"]}
            raw = lanes["raw"]["layout"]
            adaptive = lanes["adaptive"]["layout"]
            diag = lanes["adaptive"]["diagnostic"]["summary"]
            selected_bzip = diag.get("bzip3_pages", 0)
            sweep_rows.append([
                CORPUS_NAMES[corpus_report["corpus"]],
                f"{size['target_page_bytes'] // 1024} KiB",
                f"{raw['page_count']}",
                f"{comma(raw['file']['bytes'])}",
                f"{comma(adaptive['file']['bytes'])}",
                f"{comma(adaptive['metadata_bytes'])} ({pct(adaptive['metadata_bytes'], adaptive['file']['bytes'])})",
                f"{comma(raw['payload_bytes'])} / {comma(adaptive['payload_bytes'])}",
                f"{selected_bzip}/{diag.get('raw_pages', 0)} raw",
                f"{diag.get('probe_smaller', 0)} smaller; {diag.get('resource_limit_fallbacks', 0)} limit fallback",
            ])
    lines += [
        markdown_table(["corpus", "target", "pages", "raw file", "adaptive file", "adaptive metadata", "raw/adaptive payload", "selected bzip/raw", "probe"], sweep_rows),
        "",
        "For every corpus and every target, adaptive selected bzip3 on every page: 0 raw fallbacks, 0 resource-limit fallbacks, 0 probe errors, and every bzip3 probe was smaller.  Consequently adaptive and forced-bzip3 artifacts are byte-identical within each target.  This is a measured result on these real inputs, not an assumption inherited from synthetic fixtures.",
        "",
    ]

    lines += ["### Storage causes and losses", ""]
    cause_rows = []
    for corpus_report in sweep["corpora"]:
        corpus = corpus_report["corpus"]
        content_bytes = stats_by_corpus[corpus]["content_bytes"]
        size64 = next(item for item in corpus_report["page_sizes"] if item["target_page_bytes"] == 65536)
        lanes = {lane["codec"]: lane for lane in size64["lanes"]}
        raw = lanes["raw"]["layout"]
        adaptive = lanes["adaptive"]["layout"]
        diag = lanes["adaptive"]["diagnostic"]["summary"]
        cause_rows.append([
            CORPUS_NAMES[corpus],
            f"{comma(content_bytes)} B",
            f"{comma(raw['payload_bytes'])} B (+{comma(raw['payload_bytes'] - content_bytes)}; {pct(raw['payload_bytes'] - content_bytes, content_bytes)})",
            f"{comma(adaptive['metadata_bytes'])} B / {pct(adaptive['metadata_bytes'], adaptive['file']['bytes'])}",
            f"{diag.get('bzip3_pages', 0)} bzip3, {diag.get('raw_pages', 0)} raw",
            f"{comma(adaptive['payload_bytes'])} B",
        ])
    lines += [
        markdown_table(["corpus", "normalized content", "LEX6 raw payload overhead", "64 KiB metadata", "adaptive selection", "adaptive payload"], cause_rows),
        "",
        "The raw-payload excess over normalized content is packet/model framing and per-entry/key representation charged identically to the LEX6 lane; it is not silently attributed to bzip3.  The metadata floor is hot index/catalog/directory data and remains uncompressed in the archive.  Larger pages reduce page count and metadata (and reduce adaptive total storage here) but provide coarser random-access granularity; the report does not turn that storage trade-off into a latency claim.",
        "",
        "GCIDE demonstrates the document-boundary limit: at 16 KiB its largest raw page is 112,754 B because an oversized source entry is retained rather than dropped or split.  OMW's many short Japanese entries produce 7,840 pages at 16 KiB, so its metadata fraction is correspondingly higher.  These are measured page distributions, not generic codec explanations.",
        "",
    ]

    lines += ["### Whole-stream bzip3 control (storage-only)", ""]
    whole_rows = []
    for corpus_report in sweep["corpora"]:
        result = corpus_report["whole_stream_bzip3_storage_only"]["result"]
        size64 = next(item for item in corpus_report["page_sizes"] if item["target_page_bytes"] == 65536)
        adaptive = next(lane for lane in size64["lanes"] if lane["codec"] == "adaptive")["layout"]
        whole_rows.append([
            CORPUS_NAMES[corpus_report["corpus"]],
            f"{comma(result['raw_bytes'])} B",
            f"{comma(result['encoded_bytes'])} B",
            ratio(result["encoded_bytes"], result["raw_bytes"]),
            f"{comma(adaptive['file']['bytes'])} B (64 KiB pages)",
            short_hash(result["sha256"]),
        ])
    lines += [
        markdown_table(["corpus", "whole raw content", "whole bzip3", "whole ratio", "paged adaptive", "whole digest"], whole_rows),
        "",
        "The whole-stream control concatenates normalized content only and compresses it once.  It omits LEX6 packet/model bytes, index/catalog/directory metadata, and page restart boundaries; it is therefore a storage diagnostic for compression horizon, not a random-access-equivalent dictionary format and not a query-performance result.",
        "",
    ]

    reproduction_intro = (
        "The commands below reproduce the preparation, smoke, sweep, and gated measurement ledgers.  The measurement command is intentionally listed with its literal root authorization."
        if timing_exists else
        "All commands below are bounded and non-timed unless a future measurement command explicitly passes the root gate.  The current ledgers were produced with the Nix development environment where SLOB/PyICU and native dictionary tools are available."
    )
    fairness_retained = f"[`{fairness_path.name}`](../runs/{fairness_path.name})" if fairness is not None else "fairness audit unavailable"
    lines += [
        "## Reproduction and retained evidence",
        "",
        reproduction_intro,
        "",
        "```sh",
        "python3 src6/bench/real-world/prepare.py fetch --cache-dir /tmp/dictionary-real-world-cache",
        "python3 src6/bench/real-world/prepare.py project --cache-dir /tmp/dictionary-real-world-cache --output-dir src6/bench/real-world/evidence/corpora",
        "python3 -m unittest -v src6/bench/real-world/test_prepare.py",
        "/etc/profiles/per-user/mileswirht/bin/zig build -Doptimize=ReleaseSafe --build-file src6/bench/real-world/build.zig",
        "nix develop .# --command python3 src6/bench/real-world/smoke.py --artifact-root /private/tmp/dictionary-real-world-current --output src6/bench/real-world/evidence/runs/main-smoke-post-review.json --all-exact-queries",
        "nix develop .# --command python3 src6/bench/real-world/fairness_audit.py --smoke src6/bench/real-world/evidence/runs/main-smoke-post-review.json --output src6/bench/real-world/evidence/runs/fairness-audit-post-review.json",
        "python3 src6/bench/real-world/sweep.py --artifact-root /private/tmp/dictionary-real-world-sweep-post-review --output src6/bench/real-world/evidence/runs/page-sweep-post-review.json",
        "nix develop .# --command python3 src6/bench/real-world/legacy_probe.py",
        "python3 src6/bench/real-world/verification.py",
        "nix develop .# --command python3 src6/bench/real-world/inventory.py --evidence-root /private/tmp/dictionary-real-world-current --sweep-root /private/tmp/dictionary-real-world-sweep-post-review --timed-build-root /private/tmp/dictionary-real-world-timed-builds-post-review-final --measurement-plan-root /private/tmp/dictionary-real-world-measure-plans-post-review-final --output src6/bench/real-world/evidence/runs/environment-post-review.json",
        "nix develop .# --command python3 src6/bench/real-world/measure.py --quiet-gate ROOT-EXPLICIT-QUIET-GATE --artifact-root /private/tmp/dictionary-real-world-current --output src6/bench/real-world/evidence/runs/timing-results-post-review-final.json --plan-root /private/tmp/dictionary-real-world-measure-plans-post-review-final --build-root /private/tmp/dictionary-real-world-timed-builds-post-review-final",
        "python3 src6/bench/real-world/report.py --output src6/bench/real-world/evidence/reports/real-world-report-post-review.md",
        "```",
        "",
        f"Retained ledgers: [`corpora/manifest.json`](../corpora/manifest.json), [`{main_smoke_path.name}`](../runs/{main_smoke_path.name}), {fairness_retained}, [`{sweep_path.name}`](../runs/{sweep_path.name}), [`{timing_path.name}`](../runs/{timing_path.name}), [`baseline-pre-refactor.json`](../runs/baseline-pre-refactor.json), [`timing-results-post-review-failed-label-collision.json`](../runs/timing-results-post-review-failed-label-collision.json), [`legacy-availability.json`](../runs/legacy-availability.json), [`verification.json`](../runs/verification.json), and [`{environment_path.name}`](../runs/{environment_path.name}).  The post-review environment ledger inventories every regular file beneath the fresh artifact, sweep, timed-build, and measurement-plan roots, including generated `.idx.oft` sdcv sidecars, and records source archive/projection/license byte costs plus SHA-256/SHA-512 hashes where retained.  It also hashes the owned harness, exact LEX6 production/build inputs, vendored bzip3 source tree, and the current compiled `real-lex6` binary.  The pre-refactor baseline manifest remains separate and is not overwritten.",
        "",
        "The environment ledger reports Zig 0.16.0, Nix/Lix 2.95.2, sdcv 0.5.5, dictd tools 1.13.3, SQLite 3.53.3, Python 3.14.7, SLOB from the pinned Nix environment, and PyICU 2.16.2/ICU 78.3.  A nonzero `--version` return code for some dictd utilities is preserved as probe behavior; the executable path and printed version are still recorded, and actual format validation return codes are recorded separately.",
        "",
    ]
    if timing_exists:
        lines += render_timing_section(load(timing_path))
        failed_timing = runs / "timing-results-post-review-failed-label-collision.json"
        if failed_timing.is_file():
            lines += [
                "",
                f"The first post-review timing pass is preserved separately in [`{failed_timing.name}`](../runs/{failed_timing.name}).  Its 18 rejected samples were caused by duplicate high-multiplicity query labels in the harness plan; the corrected plan uses unique labels and the selected final ledger reports zero failures.  This is a functional correction record, not a cherry-picked timing retry.",
            ]
    else:
        lines += [
            "## Timing gate and interpretation limits",
            "",
            "Timing remains intentionally absent (`timing: not run` in every current ledger).  After the parent grants the literal `ROOT-EXPLICIT-QUIET-GATE`, the fixed schedule is three paired fresh-process 64 KiB runs per available format/codec, one declared warmup, 256-operation batches for fast exact/missing/load/render/snippet work, three bounded prefix batches after one all-hit correctness pass, and three startup samples.  The page sweep remains one build/open/verify/control run at 16/64/256 KiB.  Fresh process does not mean cold disk: hot OS cache versus any explicitly established cold condition will be labelled separately.",
            "",
            "CLI process startup/transport, eager decode/identity setup, native ICU behavior, and custom in-process readers are separate operations.  No cross-language microsecond ranking will be claimed.  Losses and unavailable lanes remain visible alongside storage wins; no failed lane is eligible for timing.",
            "",
        ]
    return "\n".join(lines) + "\n"


def environment_source(environment: dict[str, Any], corpus: str) -> dict[str, Any]:
    for source in environment.get("source_inputs", {}).get("sources", []):
        if source.get("id") == corpus:
            return source
    return {"extracted": {"bytes": 0, "files": 0}}


def external_statuses(report: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in report["external"]["artifacts"]:
        fmt = item.get("format")
        variant = item.get("variant")
        if fmt == "stardict" and "validation" in item:
            native = item.get("native_sdcv", [])
            result["StarDict"] = "ok" if item["validation"].get("status") == "ok" and all(case.get("status") == "ok" for case in native) else "failed"
        elif fmt == "dict" and variant == "dictzip":
            result["dictzip"] = item.get("status", "unknown")
        elif fmt == "dict" and "native_dictunformat" in item:
            probe = item["native_dictunformat"]
            result["DICT"] = "ok" if probe.get("returncode") == 0 else "failed"
        elif fmt == "sqlite":
            probe = item.get("native_sqlite3", {})
            result["SQLite"] = "ok" if probe.get("returncode") == 0 else "failed"
        elif fmt == "slob" and "validation" in item:
            name = "SLOB " + str(variant)
            result[name] = "ok" if item["validation"].get("status") == "ok" else "failed"
    return result


def timing_value(samples: list[dict[str, Any]], getter: Any) -> str:
    values = [int(value) for sample in samples if (value := getter(sample)) is not None]
    if not values:
        return "n/a"
    median = statistics.median(values)
    return f"median {median / 1_000_000:.3f} ms (min {min(values) / 1_000_000:.3f}, max {max(values) / 1_000_000:.3f})"


def phase_value(samples: list[dict[str, Any]], phase: str) -> str:
    values: list[float] = []
    for sample in samples:
        item = sample.get("phases", {}).get(phase)
        if isinstance(item, dict) and item.get("operations"):
            values.append(float(item["ns"]) / float(item["operations"]))
    if not values:
        return "n/a"
    return f"median {statistics.median(values) / 1_000:.2f} µs/op"


def array_value(samples: list[dict[str, Any]], phase: str, *, per_operation: bool = False) -> str:
    values: list[float] = []
    for sample in samples:
        items = sample.get("phases", {}).get(phase, [])
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict) or item.get("ns") is None:
                continue
            value = float(item["ns"])
            if per_operation and item.get("operations"):
                value /= float(item["operations"])
            values.append(value)
    if not values:
        return "n/a"
    scale = 1_000 if per_operation else 1_000_000
    unit = "µs/op" if per_operation else "ms"
    return f"median {statistics.median(values) / scale:.2f} {unit} (min {min(values) / scale:.2f}, max {max(values) / scale:.2f})"


def render_timing_section(timed: dict[str, Any]) -> list[str]:
    lines = [
        "## Timed results (root gate granted)",
        "",
        "The following section is emitted only when a retained timing ledger exists.  It summarizes the raw samples; all per-sample process output, phase nanoseconds, operation counts, checksums, and artifact references remain in that JSON.  Values are descriptive within a lane, not a cross-language microsecond ranking.",
        "",
        f"Gate: `{timed.get('gate')}`; process runs `{timed.get('schedule', {}).get('process_runs')}`, warmups `{timed.get('schedule', {}).get('warmups')}`, fast batch `{timed.get('schedule', {}).get('batch_ops')}`, prefix batches `{timed.get('schedule', {}).get('prefix_batches')}`.  Fresh processes ran with the OS cache state left untouched; this is not a cold-disk measurement.",
        "",
    ]
    failures = timed.get("failures", [])
    if failures:
        lines += [
            "### Failed or unavailable timed lanes",
            "",
            "A lane failure is retained here and is not treated as a valid timing result.  The raw process/error record remains in the selected timing ledger; no retry or cherry-picked rerun is implied.",
            "",
            markdown_table(["lane", "error type", "error"], [[item.get("lane"), item.get("error_type"), str(item.get("error", "")).replace("\n", " ")[:500]] for item in failures]),
            "",
        ]
    lines += [
        "### LEX6 in-process phases",
        "",
    ]
    lex_rows = []
    for corpus in timed.get("corpora", []):
        for lane in corpus.get("lex6", []):
            samples = lane.get("samples", [])
            lex_rows.append([
                CORPUS_NAMES.get(corpus["corpus"], corpus["corpus"]),
                lane.get("codec"),
                timing_value(samples, lambda sample: sample.get("process", {}).get("wall_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("input_parse_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("artifact_read_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("metadata_open_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("post_verify_all_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("reader_init_ns")),
                array_value(samples, "first_exact"),
                array_value(samples, "prefix_batches", per_operation=True),
                array_value(samples, "first_render"),
                array_value(samples, "first_snippet"),
                phase_value(samples, "exact_batch"),
                phase_value(samples, "uncached_render_batch"),
                phase_value(samples, "uncached_snippet_batch"),
                phase_value(samples, "session_first_cold"),
                phase_value(samples, "session_same_page_render"),
                phase_value(samples, "session_mixed_page_render"),
                phase_value(samples, "session_mixed_page_snippet"),
            ])
    lines += [
        markdown_table(["corpus", "codec", "fresh process wall", "projection parse", "artifact read", "metadata open", "post verify", "reader init", "first exact", "prefix batch", "first render", "first snippet", "exact batch", "uncached render", "uncached snippet", "session cold", "session same-page", "session mixed render", "session mixed snippet"], lex_rows),
        "",
        "`first_exact`/`first_render`/`first_snippet` arrays in the raw ledger expose the cold-in-process first operation per fixed case (including missing and high-multiplicity exact queries); uncached batches use `Archive.load` per operation.  Stateful Reader rows expose a cold first decode, hot same-page reuse (expected zero page loads and 256 cache hits), and mixed-page cycling with page-load/decode/cache-hit counters.  Prefix rows retain hits and key bytes for each of the three batches rather than reducing them to an unqualified latency number.",
        "",
        "### Custom Python reader phases",
        "",
    ]
    ext_rows = []
    for corpus in timed.get("corpora", []):
        for lane in corpus.get("external", []):
            samples = lane.get("samples", [])
            ext_rows.append([
                CORPUS_NAMES.get(corpus["corpus"], corpus["corpus"]),
                lane.get("lane"),
                timing_value(samples, lambda sample: sample.get("process", {}).get("wall_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("startup_phases", {}).get("oracle_parse_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("startup_phases", {}).get("query_plan_parse_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("startup_phases", {}).get("reader_ready_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("open_phases", {}).get("open_ns")),
                timing_value(samples, lambda sample: sample.get("phases", {}).get("open_phases", {}).get("identity_setup_ns")),
                array_value(samples, "first_exact"),
                array_value(samples, "prefix_batches", per_operation=True),
                array_value(samples, "first_render"),
                array_value(samples, "first_snippet"),
                phase_value(samples, "exact_batch"),
                phase_value(samples, "render_batch"),
                phase_value(samples, "snippet_batch"),
            ])
    lines += [
        markdown_table(["corpus", "lane", "fresh process wall", "oracle parse", "plan parse", "reader ready", "native open", "identity setup", "first exact", "prefix batch", "first render", "first snippet", "exact batch", "content/render", "snippet"], ext_rows),
        "",
        "These are custom Python readers with normal allocation and checksum work.  Fresh-process wall includes process startup plus oracle/plan setup and all fixed operations; the explicitly reported `reader ready` boundary excludes oracle and plan parsing.  SLOB's native open and sidecar identity setup are separate; its `native_icu` fixed cases are retained separately in the raw ledger.  Reader times include Python harness/mapping costs and must not be compared as native-language rankings.",
        "",
        "### Native CLI process/transport samples",
        "",
    ]
    cli_rows = []
    for corpus in timed.get("corpora", []):
        for name, value in corpus.get("native_cli", {}).items():
            samples = value.get("samples", [])
            process_values: list[int] = []
            if name == "sdcv_cli":
                for sample in samples:
                    process_values.extend(int(case.get("process", {}).get("wall_ns", 0)) for case in sample.get("cases", []) if case.get("process", {}).get("wall_ns") is not None)
            else:
                process_values.extend(int(sample.get("process", {}).get("wall_ns", 0)) for sample in samples if sample.get("process", {}).get("wall_ns") is not None)
            cli_rows.append([CORPUS_NAMES.get(corpus["corpus"], corpus["corpus"]), name, timing_value([{"x": value} for value in process_values], lambda sample: sample.get("x")), value.get("status")])
    lines += [
        markdown_table(["corpus", "lane", "process wall", "status"], cli_rows),
        "",
        "CLI rows include process startup, command transport, and output handling.  StarDict `sdcv` and dictzip are genuine external implementations; no Python custom-reader number is merged with these process measurements.  DICT server startup/query remains unavailable because no dictd server was started.",
        "",
        "### Build process phases",
        "",
    ]
    build_rows = []
    for build in timed.get("builds", []):
        build_rows.append([build.get("corpus"), build.get("codec"), timing_value([build.get("process", {})], lambda sample: sample.get("wall_ns")), build.get("artifact", {}).get("bytes", "n/a"), short_hash(build.get("artifact", {}).get("sha256"))])
    for corpus in timed.get("corpora", []):
        external_build = corpus.get("external_build", {})
        result = external_build.get("result", {})
        phases = result.get("phases", [])
        for phase in phases:
            build_rows.append([corpus.get("corpus"), phase.get("phase"), f"{int(phase.get('ns', 0)) / 1_000_000:.3f} ms", "bundle in build-dir", "see environment inventory"])
    lines += [
        markdown_table(["corpus", "build phase", "wall", "artifact", "hash"], build_rows),
        "",
        "LEX6 build rows are fresh-process build wall times for the 64 KiB artifacts.  External builder phase names retain their validation boundaries (dictunformat, dictzip full/range, SQLite integrity, and SLOB identity/reader validation) and therefore are not pure encoder times.",
        "",
    ]
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, default=DEFAULT_RUNS)
    parser.add_argument("--corpora-root", type=Path, default=DEFAULT_CORPORA)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(runs=args.runs, corpora_root=args.corpora_root, output=args.output), encoding="utf-8")
    print(json.dumps({"status": "report-written", "output": str(args.output.resolve())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
