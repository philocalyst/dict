#!/usr/bin/env python3
"""Pinned complete-book DEV density probes; diagnostics, never codec scores."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
MANIFEST = Path("/workspace/scratch/books2026-dev/manifest.json")
MANIFEST_SHA = "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d"
REPORT = HERE.parent / "evidence" / "phrase-books-six-one-slot-asym.jsonl"
BZIP3 = Path("/workspace/scratch/bzip3")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def bounded(args, time_limit=115):
    proc = subprocess.run(args, capture_output=True, timeout=time_limit)
    if proc.returncode:
        raise RuntimeError(f"{args}: status={proc.returncode}, stderr={proc.stderr.decode(errors='replace')[-2000:]}")
    return proc


def main() -> None:
    raw_manifest = MANIFEST.read_bytes()
    if sha(raw_manifest) != MANIFEST_SHA:
        raise RuntimeError("book development manifest hash changed")
    manifest = json.loads(raw_manifest)
    source_code_sha = sha((HERE / "probe.py").read_bytes())
    REPORT.parent.mkdir(exist_ok=True)
    staged = REPORT.with_suffix(".jsonl.tmp")
    with staged.open("w") as ledger:
        for book in manifest["books"]:
            source = Path(book["full"]["path"])
            data = source.read_bytes()
            if len(data) != book["full"]["bytes"] or sha(data) != book["full"]["sha256"]:
                raise RuntimeError(f"source changed: {book['id']}")
            start = time.perf_counter()
            trial = bounded(
                ["timeout", "110s", "prlimit", "--as=4294967296", "--cpu=120", "--",
                 sys.executable, str(HERE / "probe.py"), str(source),
                 "--segmentation", "both", "--max-candidates", "1024"]
            )
            result = json.loads(trial.stdout)
            for mode in ("runs", "scalars"):
                if result[mode]["source_sha256"] != book["full"]["sha256"]:
                    raise RuntimeError("probe source accounting mismatch")
            bzip3 = bounded([str(BZIP3), "-c", str(source)], time_limit=115)
            row = {
                "scope": "complete-development-book-source-only-diagnostic",
                "book_id": book["id"],
                "language": book["language"],
                "source_bytes": len(data),
                "source_sha256": sha(data),
                "manifest_sha256": MANIFEST_SHA,
                "probe_code_sha256": source_code_sha,
                "whole_bzip3_bytes": len(bzip3.stdout),
                "probe_wall_s": round(time.perf_counter() - start, 3),
                "modes": result,
            }
            ledger.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
            ledger.flush()
            os.fsync(ledger.fileno())
            print(f"{book['id']}: bzip3={len(bzip3.stdout)} "
                  f"run={result['runs']['optimistic_saved_bytes']} "
                  f"run_unigram={result['runs']['unigram_proxy_saved_bytes']} "
                  f"scalar={result['scalars']['optimistic_saved_bytes']}", flush=True)
    staged.replace(REPORT)


if __name__ == "__main__":
    main()
