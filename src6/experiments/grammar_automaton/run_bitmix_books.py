#!/usr/bin/env python3
"""Run a fixed native ideal-bit scorer on locked 1 MiB development prefixes."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary: Path, source: Path, controls: Path, output: Path):
    manifest = json.loads(source.read_text())
    control = json.loads(controls.read_text())
    assert manifest["role"] == control["role"] == "development"
    assert control["source_manifest_sha256"] == digest(source)
    lookup = {(row["book"], row["codec"]): row for row in control["rows"]}
    cases = []
    for book in manifest["books"]:
        prefix, = (p for p in book["prefixes"] if p["byte_limit"] == 1048576)
        path = Path(prefix["path"])
        assert digest(path) == prefix["sha256"]
        baseline = lookup[book["id"], "bzip3"]
        assert baseline["source_sha256"] == prefix["sha256"]
        assert baseline["exact_source_verified"]
        process = subprocess.run([str(binary), str(path)], capture_output=True,
                                 text=True, check=True)
        result = json.loads(process.stdout)
        assert result["source_bytes"] == prefix["bytes"]
        mixture = result["integer_discounted_mixture_ideal_bits"] / 8
        experts = {key: value / 8 for key, value in result["expert_ideal_bits"].items()}
        best = min(experts, key=experts.get)
        row = {
            "book_id": book["id"], "source_path": str(path),
            "source_sha256": prefix["sha256"], "source_bytes": prefix["bytes"],
            "entire_book": prefix["is_entire_book"],
            "bzip3_frame_bytes": baseline["complete_frame_bytes"],
            "bzip3_frame_sha256": baseline["frame_sha256"],
            "scorer_result": result,
        }
        cases.append(row)
        print(book["id"], "best_expert", best, round(experts[best], 2),
              "quantized_mix_ideal", round(mixture, 2),
              "bzip3_complete_frame", baseline["complete_frame_bytes"], flush=True)
    report = {
        "status": "development_only_quantized_ideal_bits_not_frame_bytes",
        "binary_path": str(binary), "binary_sha256": digest(binary),
        "source_path": str(source), "source_sha256": digest(source),
        "controls_path": str(controls), "controls_sha256": digest(controls),
        "cases": cases,
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    print("evidence", output, digest(output), flush=True)


if __name__ == "__main__":
    run(*(Path(p) for p in sys.argv[1:5]))
