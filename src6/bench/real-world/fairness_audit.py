#!/usr/bin/env python3
"""Audit alias and payload fairness in the retained real-world smoke ledger.

This is a non-timed ledger.  It reads the independent rows/projection
metadata and the already-retained smoke manifests; it never opens a format
reader and never reads a clock.  Native format bytes and benchmark-only
identity sidecars remain separate so a large sidecar cannot be mistaken for
payload duplication.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")


def digest(path: Path) -> str:
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            state.update(block)
    return state.hexdigest()


def rows_stats(path: Path) -> dict[str, Any]:
    rows = key_hits = content_bytes = native_bytes = 0
    multi_key_rows = duplicate_keys_in_row = 0
    max_keys = 0
    counts: dict[str, int] = {}
    for line in path.open(encoding="utf-8"):
        row = json.loads(line)
        keys = list(row["keys"])
        rows += 1
        key_hits += len(keys)
        content_bytes += int(row["content_bytes"])
        native_bytes += int(row.get("native_record_bytes", 0))
        max_keys = max(max_keys, len(keys))
        multi_key_rows += len(keys) > 1
        duplicate_keys_in_row += len(keys) != len(set(keys))
        for key in keys:
            counts[key] = counts.get(key, 0) + 1
    return {
        "rows": rows,
        "key_hits": key_hits,
        "unique_keys": len(counts),
        "duplicate_key_hits": sum(count - 1 for count in counts.values() if count > 1),
        "multi_key_rows": multi_key_rows,
        "duplicate_keys_in_row": duplicate_keys_in_row,
        "max_keys_in_row": max_keys,
        "content_bytes": content_bytes,
        "native_record_bytes": native_bytes,
    }


def file_summary(files: list[dict[str, Any]]) -> dict[str, Any]:
    sidecars = [file for file in files if Path(str(file.get("path", ""))).name.endswith((".rows.json", ".refs.json"))]
    native = [file for file in files if file not in sidecars]
    summarized = [
        {
            "name": Path(str(file.get("path", ""))).name,
            "bytes": int(file.get("bytes", 0)),
            "sha256": file.get("sha256"),
            "retained_path_exists": Path(str(file.get("path", ""))).is_file(),
            "current_sha256": digest(Path(str(file["path"]))) if Path(str(file.get("path", ""))).is_file() else None,
        }
        for file in files
    ]
    return {
        "native_bytes": sum(int(file.get("bytes", 0)) for file in native),
        "sidecar_bytes": sum(int(file.get("bytes", 0)) for file in sidecars),
        "total_bytes": sum(int(file.get("bytes", 0)) for file in files),
        "files": summarized,
        "paths_and_hashes_verified": all(item["retained_path_exists"] and item["current_sha256"] == item["sha256"] for item in summarized),
    }


def gcide_alias_span(projection_path: Path, row: dict[str, Any]) -> dict[str, Any]:
    """Corroborate that the largest key group is a real grouped alias span.

    The rows ledger intentionally omits content.  Locate the matching retained
    projection by its content hash, then inspect the XML-ish source payload for
    the paired ``ent``/``hw`` elements and ordinary definition structure.
    """
    target_hash = str(row["content_sha256"])
    content: bytes | None = None
    with projection_path.open("rb") as stream:
        for raw in stream:
            columns = raw.rstrip(b"\r\n").split(b"\t")
            if len(columns) != 3:
                continue
            candidate = bytes.fromhex(columns[2].decode("ascii"))
            if hashlib.sha256(candidate).hexdigest() == target_hash:
                content = candidate
                break
    if content is None:
        return {"status": "missing-projection-content", "content_sha256": target_hash}
    text = content.decode("utf-8", "replace")
    ents = re.findall(r"<ent>(.*?)</ent>", text, flags=re.DOTALL)
    hws = re.findall(r"<hw>(.*?)</hw>", text, flags=re.DOTALL)
    first_hw = text.find("<hw>")
    last_ent = text.rfind("</ent>")
    return {
        "status": "ok" if len(ents) == len(hws) == int(row["key_count"]) and first_hw >= 0 and last_ent < first_hw and set(ents) == set(hws) else "failed",
        "source_entry_id": row.get("source_entry_id"),
        "content_sha256": target_hash,
        "key_count": int(row["key_count"]),
        "ent_count": len(ents),
        "hw_count": len(hws),
        "ent_set_equals_hw_set": set(ents) == set(hws),
        "all_ent_before_first_hw": first_hw >= 0 and last_ent < first_hw,
        "paragraph_count": len(re.findall(r"<p>", text)),
        "definition_count": len(re.findall(r"<def>", text)),
    }


def run(*, corpora_root: Path, smoke_path: Path, baseline_path: Path) -> dict[str, Any]:
    smoke = json.loads(smoke_path.read_text(encoding="utf-8"))
    corpus_manifest = json.loads((corpora_root / "manifest.json").read_text(encoding="utf-8"))
    smoke_by_corpus = {entry["corpus"]: entry for entry in smoke.get("corpora", [])}
    manifest_by_corpus = {entry["corpus"]: entry for entry in corpus_manifest.get("corpora", [])}
    output: list[dict[str, Any]] = []
    for corpus in CORPORA:
        rows_path = corpora_root / corpus / "rows.jsonl"
        stats = rows_stats(rows_path)
        smoke_entry = smoke_by_corpus[corpus]
        artifact_entries = smoke_entry.get("external", {}).get("artifacts", [])
        bundles: dict[str, dict[str, Any]] = {}
        validation: dict[str, dict[str, Any]] = {}
        for item in artifact_entries:
            key = f"{item.get('format')}:{item.get('variant')}"
            if item.get("files"):
                bundles[key] = file_summary(item["files"])
            if item.get("validation"):
                validation[key] = item["validation"]
        # The builder manifest intentionally stores one content payload per
        # source row for every external lane.  Aliases are separate index
        # occurrences; this is the fairness invariant under audit.
        payload_checks: list[dict[str, Any]] = []
        for key, item in ((f"stardict:raw", next((x for x in artifact_entries if x.get("format") == "stardict" and x.get("files")), None)),
                          (f"dict:raw", next((x for x in artifact_entries if x.get("format") == "dict" and x.get("variant") == "raw" and x.get("files")), None)),
                          (f"sqlite:raw", next((x for x in artifact_entries if x.get("format") == "sqlite" and x.get("files")), None)),
                          (f"slob:raw", next((x for x in artifact_entries if x.get("format") == "slob" and x.get("variant") == "raw" and x.get("files")), None)),
                          (f"slob:lzma2", next((x for x in artifact_entries if x.get("format") == "slob" and x.get("variant") == "lzma2" and x.get("files")), None))):
            if item is None:
                payload_checks.append({"lane": key, "status": "missing"})
                continue
            payload = int(item.get("payload_bytes", -1))
            payload_checks.append({"lane": key, "payload_bytes": payload, "normalized_content_bytes": stats["content_bytes"], "payload_once_per_record": payload == stats["content_bytes"]})
        stardict = next((x for x in artifact_entries if x.get("format") == "stardict" and x.get("files")), {})
        dictionary = next((x for x in artifact_entries if x.get("format") == "dict" and x.get("variant") == "raw" and x.get("files")), {})
        slob_raw = next((x for x in artifact_entries if x.get("format") == "slob" and x.get("variant") == "raw" and x.get("files")), {})
        sqlite = next((x for x in artifact_entries if x.get("format") == "sqlite" and x.get("files")), {})
        occurrence_checks = {
            "stardict_primary_words": {"actual": stardict.get("primary_words"), "expected": stats["rows"]},
            "stardict_synonym_words": {"actual": stardict.get("synonym_words"), "expected": stats["key_hits"] - stats["rows"]},
            "dict_postings": {"actual": dictionary.get("postings"), "expected": stats["key_hits"]},
            "sqlite_postings": {"actual": sqlite.get("postings"), "expected": stats["key_hits"]},
            "slob_key_hits": {"actual": slob_raw.get("key_hits"), "expected": stats["key_hits"]},
        }
        occurrence_checks["all_match"] = all(item["actual"] == item["expected"] for item in occurrence_checks.values())
        alias_span = None
        if corpus == "gcide-054":
            max_row = max((json.loads(line) for line in rows_path.open(encoding="utf-8")), key=lambda item: int(item["key_count"]))
            alias_span = gcide_alias_span(corpora_root / corpus / "projection.tsv", max_row)
        source = manifest_by_corpus[corpus]
        output.append({
            "corpus": corpus,
            "source_archive_sha256": source["source_manifest"]["archive"]["sha256"],
            "projection_sha256": source["projection_tsv"]["sha256"],
            "rows": stats,
            "payload_checks": payload_checks,
            "occurrence_checks": occurrence_checks,
            "max_alias_span": alias_span,
            "validation_status": {key: item.get("status") for key, item in validation.items()},
            "artifact_storage": bundles,
            "status": "ok" if occurrence_checks["all_match"] and all(item.get("payload_once_per_record", True) for item in payload_checks) and (alias_span is None or alias_span.get("status") == "ok") and all(bundle.get("paths_and_hashes_verified", False) for bundle in bundles.values()) else "failed",
        })
    return {
        "schema": 1,
        "status": "fairness-audit-ok" if all(item["status"] == "ok" for item in output) else "fairness-audit-failed",
        "timing": "not run",
        "source_generation": "fresh post-review artifacts built from retained hashed projections; baseline ledgers remain pre-refactor",
        "smoke_ledger": {"path": str(smoke_path.resolve()), "sha256": digest(smoke_path)},
        "baseline_manifest": {"path": str(baseline_path.resolve()), "sha256": digest(baseline_path) if baseline_path.is_file() else None},
        "corpora": output,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--smoke", type=Path, default=ROOT / "evidence" / "runs" / "main-smoke.json")
    parser.add_argument("--baseline", type=Path, default=ROOT / "evidence" / "runs" / "baseline-pre-refactor.json")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "fairness-audit.json")
    args = parser.parse_args(argv)
    report = run(corpora_root=args.corpora_root, smoke_path=args.smoke, baseline_path=args.baseline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "output": str(args.output.resolve())}, indent=2))
    return 0 if report["status"] == "fairness-audit-ok" else 2


if __name__ == "__main__":
    raise SystemExit(main())
