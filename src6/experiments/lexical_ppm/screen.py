#!/usr/bin/env python3
"""Fixed six-book, two-tokenizer source-only lexical PPM screen."""
import argparse
import hashlib
import json
import math
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
BOOKS = pathlib.Path("/workspace/scratch/books2026-dev/manifest.json")
CONTROLS = pathlib.Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json")
BOOKS_SHA = "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert sha(BOOKS) == BOOKS_SHA
    controls_doc = json.loads(CONTROLS.read_text())
    assert controls_doc["source_manifest_sha256"] == BOOKS_SHA
    controls = {row["book"]: row for row in controls_doc["rows"] if row["codec"] == "bzip3"}
    books = json.loads(BOOKS.read_text())["books"]
    pins = {"source_manifest": BOOKS_SHA, "control_manifest": sha(CONTROLS),
            "ppm_probe_sha256": sha(HERE / "ppm_probe.py"),
            "screen_sha256": sha(HERE / "screen.py"),
            "protocol_sha256": sha(HERE / "PROTOCOL.md"),
            "python_executable": sys.executable,
            "python_executable_sha256": sha(pathlib.Path(sys.executable).resolve())}
    (out / "pins.json").write_text(json.dumps(pins, sort_keys=True, indent=2) + "\n")
    with (out / "results.jsonl").open("w", buffering=1) as ledger:
        for book in books:
            prefix = next(p for p in book["prefixes"] if p["byte_limit"] == 1048576)
            source = pathlib.Path(prefix["path"])
            assert source.stat().st_size == prefix["bytes"] and sha(source) == prefix["sha256"]
            control = controls[book["id"]]
            control_file = pathlib.Path(control["frame"])
            assert (control_file.stat().st_size == control["complete_frame_bytes"] and
                    sha(control_file) == control["frame_sha256"])
            for mode in ("byte", "scalar"):
                argv = [sys.executable, str(HERE / "ppm_probe.py"), mode, str(source)]
                start = time.monotonic_ns()
                row = {"id": book["id"], "language": book["language"], "mode": mode,
                       "source_bytes": prefix["bytes"], "source_sha256": prefix["sha256"],
                       "bzip3_frame_bytes": control["complete_frame_bytes"],
                       "bzip3_frame_sha256": control["frame_sha256"], "argv": argv,
                       "probe_sha256": pins["ppm_probe_sha256"]}
                try:
                    process = subprocess.run(argv, capture_output=True, timeout=900, check=False)
                    if process.returncode:
                        raise RuntimeError(f"exit {process.returncode}: {process.stderr[-1500:]!r}")
                    result = json.loads(process.stdout)
                    assert result["source_sha256"] == prefix["sha256"]
                    assert result["source_bytes"] == prefix["bytes"]
                    assert math.isclose(sum(result["parts_bits"].values()), result["ideal_bits"], abs_tol=1e-6)
                    row.update({"status": "exact_source_ideal", "model": result,
                                "ratio_vs_bzip3": result["optimistic_complete_bytes"] / control["complete_frame_bytes"]})
                except Exception as exc:
                    row.update({"status": "failed", "error": str(exc)})
                row["process_wall_ns_diagnostic"] = time.monotonic_ns() - start
                ledger.write(json.dumps(row, sort_keys=True) + "\n")
                size = row.get("model", {}).get("optimistic_complete_bytes", "-")
                print(f"{book['id']} {mode}: {row['status']} ideal={size} bzip3={control['complete_frame_bytes']}", flush=True)


if __name__ == "__main__":
    main()
