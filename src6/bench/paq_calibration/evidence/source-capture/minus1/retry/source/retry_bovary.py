#!/usr/bin/env python3
"""One clean retry of Bovary after the PAQ -1 quiet-window suspension."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("paq_contextmix", HERE / "capture_contextmix.py")
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-root", type=Path, default=Path("/tmp/paq8px-v217"))
    ap.add_argument("--binary", type=Path, default=Path("/tmp/paq8px-v217-buildsrc/build/paq8px"))
    ap.add_argument("--manifest", type=Path, default=Path("/workspace/scratch/books2026-dev/manifest.json"))
    ap.add_argument("--controls", type=Path, default=Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json"))
    ap.add_argument("--original", type=Path, default=Path("/workspace/scratch/paq8px-v217-level1-books6"))
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    original = args.original.resolve()
    original_summary = load_json(original / "summary.json")
    if not original_summary.get("complete") or original_summary.get("profile") != "-1":
        raise RuntimeError("original six-row capture is not complete for profile -1")
    rows = [json.loads(line) for line in (original / "rows.jsonl").read_text().splitlines()]
    failures = [r for r in rows if not r.get("exact_fresh_decode")]
    if len(failures) != 1 or failures[0].get("id") != "madame-bovary-fr":
        raise RuntimeError("the original artifact must contain exactly the registered Bovary failure")
    if not failures[0]["encode"].get("timeout"):
        raise RuntimeError("Bovary original row is not a timeout; retry rationale does not apply")
    out = args.out.resolve()
    if out.exists() and any(out.iterdir()):
        raise RuntimeError(f"retry output directory is not empty: {out}")
    out.mkdir(parents=True, exist_ok=True)
    root, binary = args.source_root.resolve(), args.binary.resolve()
    env_start = CAPTURE.capture_env(binary, root)
    orig_env = load_json(original / "environment-start.json")
    if env_start["source"]["tree_sha256"] != orig_env["source"]["tree_sha256"]:
        raise RuntimeError("source identity changed since the original capture")
    if env_start["runtime"] != orig_env["runtime"]:
        raise RuntimeError("binary/runtime identity changed since the original capture")
    books = CAPTURE.selected_books(args.manifest.resolve(), args.controls.resolve())
    selected = [book for book in books if book["id"] == "madame-bovary-fr"]
    if len(selected) != 1:
        raise RuntimeError("frozen Bovary input/control row is missing")
    row = CAPTURE.execute_case(binary, root, out, selected[0])
    env_end = CAPTURE.capture_env(binary, root)
    guards_ok = env_start["source"]["tree_sha256"] == env_end["source"]["tree_sha256"] and env_start["runtime"] == env_end["runtime"]
    original_row_raw = next(line for line in (original / "rows.jsonl").read_text().splitlines()
                            if json.loads(line).get("id") == "madame-bovary-fr")
    result = {
        "schema": "PAQ8PX-CONTEXTMIX-BOVARY-RETRY/1",
        "profile": "-1", "memory_limit_bytes": CAPTURE.MEMORY_LIMIT,
        "timeout_seconds_per_operation": CAPTURE.TIMEOUT_SECONDS,
        "reason": "The original registered attempt was SIGSTOPed for the parent-authorized quiet reader comparison; the 180-second monotonic encode deadline elapsed while suspended. This is a separate same-policy retry; the original timeout row is retained unchanged.",
        "original_capture": str(original),
        "original_row_sha256": hashlib.sha256(original_row_raw.encode()).hexdigest(),
        "source_manifest_sha256": CAPTURE.EXPECTED_MANIFEST_SHA,
        "controls_sha256": CAPTURE.EXPECTED_CONTROLS_SHA,
        "environment_start": env_start, "environment_end": env_end,
        "runtime_guard_passed": guards_ok,
        "row": row,
        "complete": guards_ok and row.get("exact_fresh_decode", False)
    }
    (out / "retry.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0 if result["complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
