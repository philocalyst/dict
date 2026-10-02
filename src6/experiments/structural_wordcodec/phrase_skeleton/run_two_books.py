#!/usr/bin/env python3
"""Pinned complete-book two-whole-word-slot source-only screens."""

import hashlib
import json
import os
from pathlib import Path
import sys
import time

from run_books import MANIFEST, MANIFEST_SHA, REPORT, bounded, sha

HERE = Path(__file__).resolve().parent
TWO_REPORT = REPORT.parent / "phrase-books-six-two-slot.jsonl"


def main() -> None:
    raw_manifest = MANIFEST.read_bytes()
    if sha(raw_manifest) != MANIFEST_SHA:
        raise RuntimeError("book development manifest hash changed")
    manifest = json.loads(raw_manifest)
    code_sha = hashlib.sha256((HERE / "probe_two.py").read_bytes()).hexdigest()
    staged = TWO_REPORT.with_suffix(".jsonl.tmp")
    with staged.open("w") as ledger:
        for book in manifest["books"]:
            source = Path(book["full"]["path"])
            data = source.read_bytes()
            if len(data) != book["full"]["bytes"] or sha(data) != book["full"]["sha256"]:
                raise RuntimeError(f"source changed: {book['id']}")
            start = time.perf_counter()
            proc = bounded(["timeout", "110s", "prlimit", "--as=4294967296", "--cpu=120", "--",
                            sys.executable, str(HERE / "probe_two.py"), str(source)])
            result = json.loads(proc.stdout)
            if result["source_sha256"] != book["full"]["sha256"]:
                raise RuntimeError("probe source accounting mismatch")
            row = {
                "scope": "complete-development-book-source-only-two-whole-word-slot-diagnostic",
                "book_id": book["id"],
                "language": book["language"],
                "manifest_sha256": MANIFEST_SHA,
                "probe_code_sha256": code_sha,
                "probe_wall_s": round(time.perf_counter() - start, 3),
                "result": result,
            }
            ledger.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
            ledger.flush()
            os.fsync(ledger.fileno())
            print(f"{book['id']}: templates={result['selected_templates']} "
                  f"proxy={result['unigram_proxy_saved_bytes']}", flush=True)
    staged.replace(TWO_REPORT)


if __name__ == "__main__":
    main()
