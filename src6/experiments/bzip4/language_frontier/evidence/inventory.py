#!/usr/bin/env python3
"""Inventory immutable Bzip4 inputs, parses, binaries, and provenance.

This is a read-only manifest generator.  It hashes files but never rewrites
the v3 data, dumps, or source tree.  The output intentionally distinguishes
real frame bytes from published estimates and from historical timing claims.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
BZ4 = HERE.parents[1] / "bz4"
V3 = BZ4 / "v3"
DATA = BZ4 / "data"
DUMPS = BZ4 / "dumps"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def record(path: Path, *, role: str) -> dict[str, object]:
    return {
        "role": role,
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def command_output(argv: list[str]) -> str | None:
    try:
        return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        return f"unavailable: {exc}"


def split_manifest() -> list[dict[str, object]]:
    path = DATA / "MANIFEST.tsv"
    rows: list[dict[str, object]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        columns = line.split("\t")
        if len(columns) != 3:
            raise ValueError(f"{path}:{line_number}: expected 3 columns")
        name, size, digest = columns
        actual = DATA / name
        if actual.stat().st_size != int(size) or sha256(actual) != digest:
            raise ValueError(f"manifest mismatch for {actual}")
        rows.append({"name": name, "bytes": int(size), "sha256": digest})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=HERE / "manifests" / "inventory.json")
    args = parser.parse_args()

    files: list[dict[str, object]] = []
    files += [record(path, role="input") for path in sorted(DATA.glob("*.bin"))]
    # The m_* parse is the primary saved-parse candidate.  Retain hashes for
    # all dumps so candidate promotion cannot silently change the comparison.
    files += [record(path, role="saved_parse_m") for path in sorted(DUMPS.glob("m_*.b4sd"))]
    files += [record(path, role="candidate_parse_a") for path in sorted(DUMPS.glob("a_*.b4sd"))]
    files += [record(path, role="candidate_parse_l") for path in sorted(DUMPS.glob("l_*.b4sd"))]
    for path, role in (
        (V3 / "zig-out/bin/bz4", "binary_v3_bz4"),
        (V3 / "zig-out/bin/lab", "binary_v3_lab"),
        (BZ4 / "bin/bz3base", "binary_bzip3_control"),
    ):
        if path.is_file():
            files.append(record(path, role=role))
    docs = [
        V3 / "DESIGN.md",
        V3 / "RESULTS.md",
        V3 / "results_v4.tsv",
        V3 / "lab/RESEARCH.md",
        V3 / "lab/LANE_W2.md",
        BZ4 / "BASELINES.md",
        BZ4 / "baselines.tsv",
        DATA / "MANIFEST.tsv",
        HERE.parent / "BRIEF.md",
        HERE / "README.md",
        HERE / "RESULTS.md",
        HERE / "UD_COMPONENTS.md",
        HERE / "UD_TRAIN_RESOURCE.md",
        HERE / "ud-manifest.json",
        HERE / "ud-train-manifest.json",
    ]
    files += [record(path, role="protocol_or_result") for path in docs if path.is_file()]
    if (HERE / "bin/capture_frame").is_file():
        files.append(record(HERE / "bin/capture_frame", role="evidence_driver"))
    files += [
        record(path, role="ud_resource")
        for path in sorted((HERE / "corpora").rglob("*"))
        if path.is_file()
    ]

    output = {
        "schema": 1,
        "purpose": "Exact-input and implementation inventory for language-frontier storage evidence.",
        "repository": str(REPO.resolve()),
        "host": platform.platform(),
        "zig_version": command_output(["zig", "version"]),
        "split_manifest": split_manifest(),
        "files": files,
        "claims": {
            "real": [
                "v3/results_v4.tsv totals are real encoded frames with in-process exact round trips.",
                "The evidence driver performs a real v4 encode and serial decoder check, then bz4 d performs a second process decode.",
                "All frame fields are byte counts from the complete frame, including headers, deltas, payloads, and framing.",
            ],
            "estimate_or_separate": [
                "Lane M's model_B and Re-Pair-static columns are separate model-codec experiments, not v4 frame sizes.",
                "Published decode_MBps and xN values are historical shared-machine timings; this lane does not re-use them as storage evidence.",
                "Whole-file bzip3 totals are not matched-block controls; both are recorded with explicit block policy.",
            ],
            "class_policy": "classes=0 is current plan.fit auto-search; fixed classes are separate controls and never mixed with auto-fit claims.",
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
