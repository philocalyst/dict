#!/usr/bin/env python3
"""Run the complete non-timed core matrix and write evidence manifests.

The command builds all three LEX6 codecs at the pinned 64 KiB target and all
external formats for every selected corpus.  It performs correctness checks but
never reads a clock.  The output is suitable input to the later gated measure
driver.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import formats  # noqa: E402


ROOT = Path(__file__).resolve().parent
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
CODECS = ("raw", "adaptive", "bzip3")


def field_digest(marker: bytes, fields: Sequence[bytes], markers: Sequence[bytes] = ()) -> str:
    state = hashlib.sha256()
    state.update(marker)
    state.update(b"\0")
    for value in fields:
        state.update(struct.pack("<Q", len(value)))
        state.update(value)
    for marker_value in markers:
        state.update(marker_value)
        state.update(b"\0")
    return state.hexdigest()


def expected_loaded_digest(oracle: formats.Oracle) -> str:
    state = hashlib.sha256()
    state.update(b"loaded-entry-content-v1\0")
    for record in oracle.records:
        for value in (record.identity, record.keys[0], record.content):
            state.update(struct.pack("<Q", len(value)))
            state.update(value)
    return state.hexdigest()


def expected_hit_digest(oracle: formats.Oracle) -> str:
    state = hashlib.sha256()
    state.update(b"all-index-hits-v1\0")
    for posting in oracle.sorted_postings:
        row_bytes = posting.row.to_bytes(4, "little")
        for value in (row_bytes, posting.key):
            state.update(struct.pack("<Q", len(value)))
            state.update(value)
        state.update(b"form:null\0")
    return state.hexdigest()


def expected_query_digest(oracle: formats.Oracle, mode: str, key: bytes) -> tuple[int, str]:
    postings = oracle.exact(key) if mode == "exact" else oracle.prefix(key)
    state = hashlib.sha256()
    state.update(b"query-hits-v1\0")
    state.update(struct.pack("<Q", len(key)))
    state.update(key)
    for posting in postings:
        row_bytes = posting.row.to_bytes(4, "little")
        for value in (row_bytes, posting.key):
            state.update(struct.pack("<Q", len(value)))
            state.update(value)
        state.update(b"form:null\0")
    return len(postings), state.hexdigest()


def write_queries(oracle: formats.Oracle, path: Path, *, all_exact: bool = False) -> list[tuple[str, bytes]]:
    # The external readers validate every distinct exact key.  LEX6's
    # correctness pass already walks every indexed occurrence and every entry;
    # its query API gets a bounded fixed workload here so compressed pages are
    # not needlessly decoded once per 100k-key corpus.  --all-exact-queries is
    # available for a deliberately exhaustive LEX6 audit.
    queries: list[tuple[str, bytes]] = [("exact", key) for key in oracle.unique_keys] if all_exact else []
    seen = set(queries)
    for name, key in oracle.queries():
        mode = "exact" if name.startswith("exact-") else "prefix"
        pair = (mode, key)
        if pair not in seen:
            seen.add(pair)
            queries.append(pair)
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for mode, key in queries:
            stream.write(mode + "\t" + key.hex() + "\n")
    return queries


def run_capture(argv: Sequence[str]) -> dict[str, Any]:
    try:
        process = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return {"argv": list(argv), "returncode": None, "stdout": "", "stderr": str(exc)}
    return {"argv": list(argv), "returncode": process.returncode, "stdout": process.stdout.decode("utf-8", "replace"), "stderr": process.stderr.decode("utf-8", "replace")}


def parse_smoke(text: str, oracle: formats.Oracle, queries: list[tuple[str, bytes]]) -> dict[str, Any]:
    values: dict[str, Any] = {}
    observed_queries: dict[tuple[str, str], tuple[int, str]] = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if not fields:
            continue
        if fields[0] == "status" and len(fields) >= 2:
            values["status"] = fields[1]
        elif fields[0] == "entries" and len(fields) >= 2:
            values["entries"] = int(fields[1])
        elif fields[0] == "hits" and len(fields) >= 6:
            values["hits"] = int(fields[1]); values["key_bytes"] = int(fields[3]); values["content_bytes"] = int(fields[5])
        elif fields[0] in ("all_hit_digest", "loaded_content_digest") and len(fields) >= 2:
            values[fields[0]] = fields[1]
        elif fields[0] == "loaded_entries" and len(fields) >= 2:
            values["loaded_entries"] = int(fields[1])
        elif fields[0] == "query" and len(fields) >= 5:
            observed_queries[(fields[1], fields[2])] = (int(fields[3]), fields[4])
    if values.get("status") != "smoke-ok":
        raise RuntimeError(f"LEX6 smoke did not report success: {values}")
    if values.get("entries") != len(oracle.records) or values.get("loaded_entries") != len(oracle.records):
        raise RuntimeError(f"LEX6 entry count mismatch: {values}")
    if values.get("hits") != len(oracle.postings) or values.get("all_hit_digest") != expected_hit_digest(oracle):
        raise RuntimeError(f"LEX6 all-hit mismatch: {values}")
    if values.get("loaded_content_digest") != expected_loaded_digest(oracle):
        raise RuntimeError(f"LEX6 content mismatch: {values}")
    checked = 0
    for mode, key in queries:
        key_hash = hashlib.sha256(key).hexdigest()
        expected = expected_query_digest(oracle, mode, key)
        actual = observed_queries.get((mode, key_hash))
        if actual != expected:
            raise RuntimeError(f"LEX6 {mode} mismatch key={key!r}: expected={expected} actual={actual}")
        checked += 1
    values["query_checks"] = checked
    return values


def lex6_layout(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    if len(raw) < 112 or raw[:8] != b"LEX6AR01":
        raise RuntimeError(f"invalid LEX6 artifact {path}")
    page_count = struct.unpack_from("<I", raw, 20)[0]
    index_offset, index_length = struct.unpack_from("<QQ", raw, 32)
    directory_offset, directory_length = struct.unpack_from("<QQ", raw, 48)
    pages_offset, pages_length = struct.unpack_from("<QQ", raw, 64)
    if pages_offset + pages_length != len(raw) or directory_length != page_count * 64:
        raise RuntimeError(f"invalid LEX6 layout {path}")
    page_rows = []
    raw_total = encoded_total = 0
    codec_counts: dict[str, int] = {"raw": 0, "bzip3": 0}
    raw_lengths: list[int] = []
    encoded_lengths: list[int] = []
    for index in range(page_count):
        at = directory_offset + index * 64
        offset = struct.unpack_from("<Q", raw, at)[0]
        encoded, page_raw, first_document, document_count = struct.unpack_from("<IIII", raw, at + 8)
        codec = "raw" if raw[at + 24] == 0 else "bzip3" if raw[at + 24] == 1 else f"unknown-{raw[at + 24]}"
        raw_total += page_raw; encoded_total += encoded
        codec_counts[codec] = codec_counts.get(codec, 0) + 1
        raw_lengths.append(page_raw); encoded_lengths.append(encoded)
        page_rows.append({"page": index, "offset": offset, "raw_bytes": page_raw, "encoded_bytes": encoded, "first_document": first_document, "document_count": document_count, "codec": codec, "digest_sha256": hashlib.sha256(raw[pages_offset + offset: pages_offset + offset + encoded]).hexdigest()})
    def stats(values: list[int]) -> dict[str, int]:
        return {"min": min(values) if values else 0, "max": max(values) if values else 0, "total": sum(values)}
    return {"file": formats.artifact_file(path), "header_bytes": 112, "index_bytes": index_length, "directory_bytes": directory_length, "metadata_bytes": pages_offset, "payload_bytes": pages_length, "page_count": page_count, "codec_counts": codec_counts, "raw_page_lengths": stats(raw_lengths), "encoded_page_lengths": stats(encoded_lengths), "pages": page_rows}


def run_corpus(corpus: str, corpus_root: Path, artifact_root: Path, runner: Path, *, reuse_lex6: bool = False, all_exact_queries: bool = False) -> dict[str, Any]:
    projection = corpus_root / corpus / "projection.tsv"
    oracle = formats.read_projection(projection)
    corpus_artifacts = artifact_root / corpus
    corpus_artifacts.mkdir(parents=True, exist_ok=True)
    query_file = corpus_artifacts / "queries.tsv"
    queries = write_queries(oracle, query_file, all_exact=all_exact_queries)
    lex6_results = []
    for codec in CODECS:
        artifact = corpus_artifacts / f"lex6-{codec}-64k.lex6"
        if reuse_lex6:
            if not artifact.is_file():
                raise RuntimeError(f"requested LEX6 reuse but artifact is absent: {artifact}")
            build = {"status": "reused-existing-artifact", "artifact": formats.artifact_file(artifact), "parameters": {"compression": codec, "target_page_bytes": 65536, "max_page_bytes": 1048576, "max_document_bytes": 1048576}}
        else:
            build = run_capture([str(runner), "--mode", "build", "--input", str(projection), "--artifact", str(artifact), "--compression", codec, "--target-page-bytes", "65536", "--max-page-bytes", "1048576", "--max-document-bytes", "1048576"])
            if build["returncode"] != 0:
                raise RuntimeError(f"LEX6 build failed {corpus}/{codec}: {build}")
        smoke = run_capture([str(runner), "--mode", "smoke", "--input", str(projection), "--artifact", str(artifact), "--queries", str(query_file)])
        if smoke["returncode"] != 0:
            raise RuntimeError(f"LEX6 smoke failed {corpus}/{codec}: {smoke}")
        parsed = parse_smoke(smoke["stdout"], oracle, queries)
        diag = run_capture([str(runner), "--mode", "diagnose", "--artifact", str(artifact), "--max-page-bytes", "1048576"])
        if diag["returncode"] != 0:
            raise RuntimeError(f"LEX6 diagnostic failed {corpus}/{codec}: {diag}")
        lex6_results.append({"codec": codec, "build": build, "smoke": parsed, "diagnostic": diag["stdout"], "layout": lex6_layout(artifact)})
    external_dir = corpus_artifacts / "external"
    external = formats.build_all(projection, external_dir)
    return {"corpus": corpus, "projection": formats.artifact_file(projection), "records": len(oracle.records), "unique_keys": len(oracle.unique_keys), "key_hits": len(oracle.postings), "expected_hit_digest": expected_hit_digest(oracle), "expected_loaded_digest": expected_loaded_digest(oracle), "query_file": formats.artifact_file(query_file), "lex6_query_mode": "all-distinct-exact" if all_exact_queries else "fixed-representative-exact-prefix", "lex6": lex6_results, "external": external}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--artifact-root", type=Path, default=Path("/tmp/dictionary-real-world-evidence"))
    parser.add_argument("--runner", type=Path, default=ROOT / "zig-out" / "bin" / "real-lex6")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "main-smoke.json")
    parser.add_argument("--corpus", choices=CORPORA, action="append")
    parser.add_argument("--reuse-lex6", action="store_true", help="reuse already-built 64 KiB artifacts after a prior successful LEX6 build")
    parser.add_argument("--all-exact-queries", action="store_true", help="also query every distinct exact key through LEX6 (external readers always do this)")
    args = parser.parse_args(argv)
    selected = tuple(args.corpus) if args.corpus else CORPORA
    if not args.runner.is_file():
        raise SystemExit(f"runner not found: {args.runner}; run zig build in {ROOT}")
    try:
        results = [run_corpus(corpus, args.corpora_root, args.artifact_root, args.runner, reuse_lex6=args.reuse_lex6, all_exact_queries=args.all_exact_queries) for corpus in selected]
    except (OSError, RuntimeError, formats.FormatError) as exc:
        print(f"smoke.py: ERROR: {exc}", file=sys.stderr)
        return 2
    report = {"schema": 1, "status": "smoke-ok", "timing": "not run", "corpora": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "corpora": [item["corpus"] for item in results], "output": str(args.output.resolve())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
