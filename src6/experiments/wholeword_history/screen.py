#!/usr/bin/env python3
"""Fixed six-source, two-restart development comparison; no tuning loop."""
import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import time

HERE = pathlib.Path(__file__).resolve().parent
SOURCE_MANIFEST = pathlib.Path("/workspace/scratch/books2026-dev/manifest.json")
CONTROL_MANIFEST = pathlib.Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json")
SOURCE_MANIFEST_SHA = "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d"
BLOCKS = (65536, 33554432)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def child(argv, timeout=1800):
    start = time.monotonic_ns()
    proc = subprocess.Popen([str(x) for x in argv], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        stdout, stderr = proc.communicate()
        raise RuntimeError(f"timeout: {argv}; stderr={stderr[-1000:]!r}")
    if proc.returncode:
        raise RuntimeError(f"exit {proc.returncode}: {argv}; stderr={stderr[-2000:]!r}")
    return json.loads(stdout), time.monotonic_ns() - start


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert sha(SOURCE_MANIFEST) == SOURCE_MANIFEST_SHA
    books = json.loads(SOURCE_MANIFEST.read_text())["books"]
    controls_doc = json.loads(CONTROL_MANIFEST.read_text())
    assert controls_doc["source_manifest_sha256"] == SOURCE_MANIFEST_SHA
    controls = {row["book"]: row for row in controls_doc["rows"] if row["codec"] == "bzip3"}
    pins = {path.name: sha(path) for path in (HERE / "m_whole.zig", HERE / "whole_reader.zig",
                                           HERE / "budget.zig", HERE / "learner_epochs.zig",
                                           HERE / "lifetime_fit.zig", HERE / "m_whole", HERE / "whole_reader")}
    pins["grammar2.zig"] = sha(HERE / "../bzip4/bz4/grammar2.zig")
    pins["m_lexicon.zig"] = sha(HERE / "../bzip4/bz4/m_lexicon.zig")
    (out / "pins.json").write_text(json.dumps({"source_manifest": SOURCE_MANIFEST_SHA,
                                                "control_manifest": sha(CONTROL_MANIFEST),
                                                "files": pins}, indent=2) + "\n")
    with (out / "results.jsonl").open("w", buffering=1) as ledger:
        for book in books:
            prefix = next(p for p in book["prefixes"] if p["byte_limit"] == 1048576)
            source = pathlib.Path(prefix["path"])
            assert source.stat().st_size == prefix["bytes"]
            assert sha(source) == prefix["sha256"]
            control = controls[book["id"]]
            control_frame = pathlib.Path(control["frame"])
            assert control_frame.stat().st_size == control["complete_frame_bytes"]
            assert sha(control_frame) == control["frame_sha256"]
            for block in BLOCKS:
                stem = f"{book['id']}-{block}"
                frame = out / f"{stem}.bz4"
                graph = out / f"{stem}.p6f"
                row = {"id": book["id"], "language": book["language"], "source": str(source),
                       "source_bytes": prefix["bytes"], "source_sha256": prefix["sha256"],
                       "block_bytes": block, "bzip3_frame_bytes": control["complete_frame_bytes"],
                       "bzip3_frame_sha256": sha(control_frame), "m_whole_sha256": pins["m_whole"],
                       "whole_reader_sha256": pins["whole_reader"]}
                command = [HERE / "m_whole", source, frame, graph, block, 20, "a-best", 1, 0]
                row["encode_argv"] = [str(x) for x in command]
                try:
                    encoded, row["encoder_wall_ns"] = child(command)
                    row["encoder"] = encoded
                    row["frame_bytes"] = frame.stat().st_size
                    row["frame_sha256"] = sha(frame)
                    assert row["frame_bytes"] == encoded["frame_bytes"]
                    admitted, _ = child([HERE / "whole_reader", "inspect", frame])
                    verified, row["decoder_wall_ns"] = child([HERE / "whole_reader", "verify", frame, source])
                    assert admitted["ledger"]["raw_bytes"] == prefix["bytes"]
                    assert verified["raw_bytes"] == prefix["bytes"] and verified["verified"]
                    row["reader_inspect"] = admitted
                    row["reader_verify"] = verified
                    row["delta_vs_bzip3_bytes"] = row["frame_bytes"] - control["complete_frame_bytes"]
                    row["status"] = "exact"
                except Exception as exc:
                    row["status"] = "failed"
                    row["error"] = str(exc)
                ledger.write(json.dumps(row, sort_keys=True) + "\n")
                print(f"{stem}: {row['status']} {row.get('frame_bytes', '-')} vs bzip3 {control['complete_frame_bytes']}", flush=True)


if __name__ == "__main__":
    main()
