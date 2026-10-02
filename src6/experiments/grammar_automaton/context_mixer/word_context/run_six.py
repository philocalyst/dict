#!/usr/bin/env python3
"""Exact-identity six-prefix development runner for the frozen CCW1 scorer."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary: Path, manifest_path: Path, controls_path: Path, output: Path):
    manifest = json.loads(manifest_path.read_text())
    controls = json.loads(controls_path.read_text())
    assert manifest["role"] == controls["role"] == "development"
    assert manifest["whole_books"] == 6 and controls["complete"]
    assert controls["source_manifest_sha256"] == digest(manifest_path)
    rows = {(r["book"], r["codec"]): r for r in controls["rows"]}
    cases = []
    for book in manifest["books"]:
        prefix, = (p for p in book["prefixes"] if p["byte_limit"] == 1048576)
        path = Path(prefix["path"])
        assert digest(path) == prefix["sha256"]
        control = rows[book["id"], "bzip3"]
        assert control["source_sha256"] == prefix["sha256"]
        assert control["exact_source_verified"]
        process = subprocess.run([str(binary), str(path)], text=True,
                                 capture_output=True, check=True)
        score = json.loads(process.stdout)
        assert score["source_bytes"] == prefix["bytes"]
        variants = {name: row["total_bits"] / 8 for name, row in score["variants"].items()}
        best = min(variants, key=variants.get)
        print(book["id"], prefix["bytes"], "best", best, round(variants[best], 2),
              "bzip3_complete", control["complete_frame_bytes"],
              "ideal_bits_not_frame", flush=True)
        cases.append({"book_id": book["id"], "language": book["language"],
                      "source_path": str(path), "source_sha256": prefix["sha256"],
                      "entire_book": prefix["is_entire_book"],
                      "bzip3_frame_bytes": control["complete_frame_bytes"],
                      "bzip3_frame_sha256": control["frame_sha256"],
                      "scorer": score})
    report = {"status": "development_only_q15_ideal_bits_not_frame_bytes",
              "binary_path": str(binary), "binary_sha256": digest(binary),
              "source_cpp_sha256": digest(Path(__file__).with_name("ccw_score.cpp")),
              "squash_table_sha256": digest(Path(__file__).parent.parent / "squash_table.h"),
              "squash_generator_sha256": digest(Path(__file__).parent.parent / "gen_tables.py"),
              "runner_sha256": digest(Path(__file__)),
              "manifest_path": str(manifest_path), "manifest_sha256": digest(manifest_path),
              "controls_path": str(controls_path), "controls_sha256": digest(controls_path),
              "cases": cases}
    output.write_text(json.dumps(report, indent=2) + "\n")
    print("evidence", output, digest(output), flush=True)


if __name__ == "__main__":
    run(*(Path(arg) for arg in sys.argv[1:5]))
