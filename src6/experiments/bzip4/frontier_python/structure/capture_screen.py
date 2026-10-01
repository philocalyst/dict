#!/usr/bin/env python3
"""Run the fixed structural screen through the lossless capture helper.

The child emits only size/roundtrip JSON and never reads a clock.  This wrapper
stores child stdout, stderr, and return status before parsing any rows.  The
saved elapsed field belongs to the subprocess envelope and is not a codec
timing result.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

FRONTIER_ROOT = Path(__file__).resolve().parents[1]
REPO = FRONTIER_ROOT.parents[3]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from src6.experiments.bzip4.frontier_python.protocol.capture import run_and_save  # noqa: E402


def main() -> int:
    raw_root = FRONTIER_ROOT / "structure" / "evidence" / "screen-capture"
    record_root = FRONTIER_ROOT / "structure" / "evidence" / "screen"
    measure = FRONTIER_ROOT / "structure" / "measure.py"
    for corpus in ("freedict-eng-spa", "gcide-054", "omw-ja-20"):
        command = [
            sys.executable,
            str(measure),
            "--corpus",
            corpus,
            "--lane",
            "screen",
            "--variants",
            "all",
            "--block-bytes",
            "all",
            "--retain-dir",
            str(record_root),
        ]
        stem = f"structure-screen-{corpus}"
        capture = run_and_save(command, cwd=REPO, raw_root=raw_root, stem=stem)
        print(json.dumps(capture.record(), sort_keys=True), flush=True)
        if capture.returncode != 0:
            return capture.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
