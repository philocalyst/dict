#!/usr/bin/env python3
"""One frozen six-book development score for the AH1 integer predictor."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys

MANIFEST_SHA = "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d"
CONTROLS_SHA = "640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary: Path, manifest_path: Path, controls_path: Path, output: Path) -> None:
    if digest(manifest_path) != MANIFEST_SHA or digest(controls_path) != CONTROLS_SHA:
        raise ValueError("fixed DEV manifest/control hash changed")
    manifest = json.loads(manifest_path.read_text())
    controls = json.loads(controls_path.read_text())
    if manifest["role"] != "development" or manifest["whole_books"] != 6 or not controls["complete"]:
        raise ValueError("fixed six-book DEV identity changed")
    if controls["source_manifest_sha256"] != MANIFEST_SHA:
        raise ValueError("control source manifest mismatch")
    rows = {(row["book"], row["codec"]): row for row in controls["rows"]}
    report = {
        "status": "development_only_integer_q15_ideal_bits_not_frame_bytes",
        "binary_path": str(binary.resolve()),
        "binary_sha256": digest(binary),
        "source_cpp_sha256": digest(Path(__file__).with_name("ah_score.cpp")),
        "squash_table_sha256": digest(Path(__file__).parent.parent / "context_mixer" / "squash_table.h"),
        "runner_sha256": digest(Path(__file__)),
        "manifest_path": str(manifest_path.resolve()),
        "manifest_sha256": MANIFEST_SHA,
        "controls_path": str(controls_path.resolve()),
        "controls_sha256": CONTROLS_SHA,
        "cases": [],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    for book in manifest["books"]:
        prefix, = (part for part in book["prefixes"] if part["byte_limit"] == 1048576)
        path = Path(prefix["path"])
        if digest(path) != prefix["sha256"]:
            raise ValueError(f"source SHA mismatch: {book['id']}")
        control = rows[book["id"], "bzip3"]
        if control["source_sha256"] != prefix["sha256"] or not control["exact_source_verified"]:
            raise ValueError(f"control source mismatch: {book['id']}")
        proc = subprocess.run([str(binary), str(path)], text=True,
                              capture_output=True, check=True)
        score = json.loads(proc.stdout)
        if score["source_bytes"] != prefix["bytes"] or score["source_bits"] != prefix["bytes"] * 8:
            raise ValueError(f"scorer length mismatch: {book['id']}")
        if score["fixed_decoder_state_bytes"] >= 16 * 1024 * 1024:
            raise ValueError("AH1 memory cap violated")
        if score["row_updates"] != score["source_bits"] * 8 + score["source_bytes"]:
            raise ValueError("AH1 per-bit context-work count mismatch")
        report["cases"].append({
            "book_id": book["id"], "language": book["language"],
            "source_path": str(path), "source_sha256": prefix["sha256"],
            "entire_book": prefix["is_entire_book"],
            "bzip3_frame_bytes": control["complete_frame_bytes"],
            "bzip3_frame_sha256": control["frame_sha256"],
            "scorer": score,
        })
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(book["id"], prefix["bytes"],
              "byte_only", round(score["variants"]["byte_only"]["total_bits"] / 8, 2),
              "word_scalar", round(score["variants"]["word_scalar"]["total_bits"] / 8, 2),
              "bzip3_complete", control["complete_frame_bytes"],
              "ideal_bits_not_frame", flush=True)
    report["complete"] = True
    output.write_text(json.dumps(report, indent=2) + "\n")
    print("evidence", output, digest(output), flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: run_six.py AH_BINARY MANIFEST CONTROLS EVIDENCE_JSON")
    run(*(Path(arg) for arg in sys.argv[1:]))
