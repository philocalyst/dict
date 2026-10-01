#!/usr/bin/env python3
"""Build and diagnose the bounded LEX6 page-size/bzip3 sweep.

This module intentionally never reads a clock.  It records artifact hashes,
page composition, and whole-stream bzip3 storage-only controls for the three
complete projections.  Query and latency collection belongs to a separate
quiet-gated measurement driver.
"""

from __future__ import annotations

import argparse
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import formats  # noqa: E402
import smoke  # noqa: E402


ROOT = Path(__file__).resolve().parent
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
TARGETS = (16 * 1024, 64 * 1024, 256 * 1024)
CODECS = ("raw", "adaptive", "bzip3")
MAX_PAGE_BYTES = 1024 * 1024
MAX_DOCUMENT_BYTES = 1024 * 1024


def run_capture(argv: Sequence[str]) -> dict[str, Any]:
    try:
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return {"argv": list(argv), "returncode": None, "stdout": "", "stderr": str(exc), "error": str(exc)}
    return {
        "argv": list(argv),
        "returncode": result.returncode,
        "stdout": result.stdout.decode("utf-8", "replace"),
        "stderr": result.stderr.decode("utf-8", "replace"),
    }


def parse_diagnostic(text: str) -> dict[str, Any]:
    pages: list[dict[str, Any]] = []
    summary: dict[str, Any] | None = None
    for line in text.splitlines():
        fields = line.split("\t")
        if fields and fields[0] == "diag" and len(fields) >= 13:
            values = dict(zip(fields[1::2], fields[2::2]))
            pages.append({
                "page": int(values["page"]),
                "raw_bytes": int(values["raw"]),
                "encoded_bytes": int(values["encoded"]),
                "codec": values["codec"],
                "probe": values.get("probe"),
                "probe_relation": values.get("probe_relation"),
            })
        elif fields and fields[0] == "diag_summary":
            values = dict(zip(fields[1::2], fields[2::2]))
            summary = {key: int(value) for key, value in values.items() if key != "status"}
    if summary is None:
        raise RuntimeError(f"diagnostic had no summary: {text[-1000:]!r}")
    if summary.get("pages") != len(pages):
        raise RuntimeError(f"diagnostic page count mismatch: {summary} vs {len(pages)}")
    return {"summary": summary, "pages": pages}


def parse_whole_bzip3(text: str) -> dict[str, Any]:
    for line in text.splitlines():
        fields = line.split("\t")
        if fields and fields[0] == "whole_bzip3":
            values = dict(zip(fields[1::2], fields[2::2]))
            result: dict[str, Any] = {"status": values.get("status")}
            for key in ("raw_bytes", "encoded_bytes"):
                if key in values:
                    result[key] = int(values[key])
            if "error" in values:
                result["error"] = values["error"]
            continue
        if fields and fields[0] == "whole_bzip3_sha256" and len(fields) >= 2:
            result["sha256"] = fields[1]
    if "result" not in locals():
        raise RuntimeError(f"whole-stream diagnostic had no status: {text!r}")
    return result


def run_corpus(corpus: str, corpus_root: Path, artifact_root: Path, runner: Path) -> dict[str, Any]:
    projection = corpus_root / corpus / "projection.tsv"
    oracle = formats.read_projection(projection)
    corpus_artifacts = artifact_root / corpus
    corpus_artifacts.mkdir(parents=True, exist_ok=True)
    sizes: list[dict[str, Any]] = []
    for target in TARGETS:
        target_dir = corpus_artifacts / f"page-{target}"
        target_dir.mkdir(parents=True, exist_ok=True)
        lanes: list[dict[str, Any]] = []
        for codec in CODECS:
            artifact = target_dir / f"lex6-{codec}.lex6"
            build = run_capture([
                str(runner), "--mode", "build", "--input", str(projection),
                "--artifact", str(artifact), "--compression", codec,
                "--target-page-bytes", str(target),
                "--max-page-bytes", str(MAX_PAGE_BYTES),
                "--max-document-bytes", str(MAX_DOCUMENT_BYTES),
            ])
            if build["returncode"] != 0:
                raise RuntimeError(f"LEX6 sweep build failed {corpus}/{target}/{codec}: {build}")
            diagnostic = run_capture([
                str(runner), "--mode", "diagnose", "--artifact", str(artifact),
                "--max-page-bytes", str(MAX_PAGE_BYTES),
            ])
            if diagnostic["returncode"] != 0:
                raise RuntimeError(f"LEX6 sweep diagnostic failed {corpus}/{target}/{codec}: {diagnostic}")
            lanes.append({
                "codec": codec,
                "build": build,
                "artifact": formats.artifact_file(artifact),
                "layout": smoke.lex6_layout(artifact),
                "diagnostic": parse_diagnostic(diagnostic["stdout"]),
            })
        sizes.append({"target_page_bytes": target, "max_page_bytes": MAX_PAGE_BYTES, "max_document_bytes": MAX_DOCUMENT_BYTES, "lanes": lanes})

    whole = run_capture([str(runner), "--mode", "whole_bzip3", "--input", str(projection)])
    if whole["returncode"] != 0:
        raise RuntimeError(f"whole-stream bzip3 diagnostic failed {corpus}: {whole}")
    return {
        "corpus": corpus,
        "projection": formats.artifact_file(projection),
        "records": len(oracle.records),
        "unique_keys": len(oracle.unique_keys),
        "key_hits": len(oracle.postings),
        "page_sizes": sizes,
        "whole_stream_bzip3_storage_only": {"command": whole["argv"], "stdout": whole["stdout"], "stderr": whole["stderr"], "result": parse_whole_bzip3(whole["stdout"])},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--artifact-root", type=Path, default=Path("/tmp/dictionary-real-world-sweep"))
    parser.add_argument("--runner", type=Path, default=ROOT / "zig-out" / "bin" / "real-lex6")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "page-sweep.json")
    parser.add_argument("--corpus", choices=CORPORA, action="append")
    args = parser.parse_args(argv)
    selected = tuple(args.corpus) if args.corpus else CORPORA
    if not args.runner.is_file():
        raise SystemExit(f"runner not found: {args.runner}; run zig build in {ROOT}")
    try:
        corpora = [run_corpus(corpus, args.corpora_root, args.artifact_root, args.runner) for corpus in selected]
    except (OSError, RuntimeError, formats.FormatError) as exc:
        print(f"sweep.py: ERROR: {exc}", file=sys.stderr)
        return 2
    report = {
        "schema": 1,
        "status": "sweep-ok",
        "timing": "not run",
        "page_sweep_targets": list(TARGETS),
        "limits": {"max_page_bytes": MAX_PAGE_BYTES, "max_document_bytes": MAX_DOCUMENT_BYTES},
        "whole_stream_policy": "concatenated normalized content only; storage-only bzip3 diagnostic, not random-access-equivalent",
        "corpora": corpora,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "corpora": [item["corpus"] for item in corpora], "output": str(args.output.resolve())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
