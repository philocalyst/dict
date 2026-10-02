#!/usr/bin/env python3
"""Run one frozen ideal-bit model over the manifest's fixed 1 MiB book prefixes."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(model_path: Path, manifest_path: Path, output_path: Path):
    model_bytes = model_path.read_bytes()
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest["role"] == "development"
    spec = importlib.util.spec_from_file_location("frozen_ideal_screen", model_path)
    model = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)
    cases = []
    for book in manifest["books"]:
        prefix, = (p for p in book["prefixes"] if p["byte_limit"] == 1048576)
        source_path = Path(prefix["path"])
        source = source_path.read_bytes()
        assert len(source) == prefix["bytes"] <= 1048576
        assert digest(source) == prefix["sha256"]
        source.decode("utf-8")
        result = model.screen(source)
        assert result["source_sha256"] == prefix["sha256"]
        cases.append({"book_id": book["id"], "language": book["language"],
                      "source_path": str(source_path),
                      "entire_book": prefix["is_entire_book"],
                      "result": result})
        if isinstance(result["candidate_ideal_bits"], list):
            best = min(result["candidate_ideal_bits"], key=lambda x: x["estimated_bytes"])
            label, estimate = best["mode"], best["estimated_bytes"]
        else:
            label, value = min(result["candidate_ideal_bits"].items(), key=lambda x: x[1])
            estimate = round(value / 8, 2)
        print(book["id"], len(source), prefix["sha256"], label, estimate,
              "IDEAL_BYTES_NOT_FRAME", flush=True)
    report = {
        "status": "development_only_ideal_entropy_not_frame_bytes",
        "manifest_path": str(manifest_path),
        "manifest_sha256": digest(manifest_bytes),
        "model_path": str(model_path),
        "model_sha256": digest(model_bytes),
        "cases": cases,
    }
    output_path.write_text(json.dumps(report, indent=2) + "\n")
    print("evidence", output_path, digest(output_path.read_bytes()), flush=True)


if __name__ == "__main__":
    run(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
