"""Capture independent post-run audits and diagnostics serially.

This runs only after a complete successful frozen timing matrix. It preserves
all raw streams before parsing and never reruns or replaces benchmark cells.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
sys.path.insert(0, str(REPO))
from src6.experiments.bzip4.frontier_python.protocol.capture import run_and_save, snapshot_sources, verify_snapshot_sources


def main(matrix: Path, output: Path) -> None:
    matrix = matrix.resolve()
    manifest = json.loads((matrix / "results.json").read_text())
    assert manifest["status"] == 0 and manifest["source_drift"]["ok"]
    assert manifest["native_control_unchanged"]
    output.mkdir(parents=True, exist_ok=False)
    helpers = ("final_audit", "memory_profile", "work_profile", "model_budget_profile", "final_tables")
    snapshot = snapshot_sources(
        [HERE / f"{name}.py" for name in helpers] + [Path(__file__).resolve()],
        output / "source-snapshot",
    )
    results = []
    for name in helpers:
        command = [sys.executable, "-B", str(HERE / f"{name}.py"), str(matrix)]
        if name == "model_budget_profile":
            command += ["--streams-dir", str(output / "standard-model-diagnostics")]
        capture = run_and_save(
            command,
            cwd=REPO,
            raw_root=output / "raw",
            stem=name,
            timeout=900,
        )
        if capture.returncode != 0 or capture.stderr:
            raise RuntimeError(f"post-run {name} failed; inspect preserved raw streams")
        if name == "final_tables":
            assert capture.stdout.startswith(b"# Frozen serial measurements")
            (output / "TABLES.md").write_bytes(capture.stdout)
            parsed = {"derived_table": str(output / "TABLES.md")}
        else:
            parsed = json.loads(capture.stdout)
            assert parsed["status"] == "pass"
            (output / f"{name}.json").write_text(json.dumps(parsed, indent=2, sort_keys=True) + "\n")
        results.append({"name": name, "capture": capture.record(), "result": parsed})
    drift = verify_snapshot_sources(snapshot)
    codec_drift = verify_snapshot_sources(manifest["source_snapshot"])
    summary = {
        "status": 0 if drift["ok"] and codec_drift["ok"] else 1,
        "matrix": str(matrix),
        "source_snapshot": snapshot,
        "source_drift": drift,
        "codec_source_drift": codec_drift,
        "records": results,
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    assert summary["status"] == 0
    print(json.dumps({"status": 0, "output": str(output), "jobs": len(results)}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matrix", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    main(args.matrix, args.output)
