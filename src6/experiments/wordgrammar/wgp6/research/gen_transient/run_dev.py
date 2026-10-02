#!/usr/bin/env python3
"""Compare complete private GEN1, native-original, and WGP6 frames on old DEV prefixes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
WGP6 = HERE.parents[1]
SRC6 = HERE.parents[4]
SAMPLES = SRC6 / "experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples"
CORPORA = ("freedict", "gcide", "omw")
sys.path.insert(0, str(HERE))
from gen_transient import encode, decode, restart_blocks  # noqa: E402


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def invoke(command: list[object]) -> dict:
    result = subprocess.run(list(map(str, command)), check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def file_sha(path: Path) -> str:
    return sha(path.read_bytes())


def control_row(corpus: str, output_dir: Path, prefix_bytes: int) -> dict:
    source = SAMPLES / f"{corpus}-eval8-saved/external-decoded.bin"
    data = source.read_bytes()[:prefix_bytes]
    source_path = output_dir / f"{corpus}.raw"
    source_path.write_bytes(data)
    old_frame, old_decoded = output_dir / f"{corpus}-old.frame", output_dir / f"{corpus}-old.decoded"
    old = invoke([WGP6 / "native", "original", source_path, old_frame, 65536])
    invoke([WGP6 / "native", "decode", old_frame, old_decoded])
    if old_decoded.read_bytes() != data:
        raise AssertionError(f"native original roundtrip failed for {corpus}")

    wgp6_frame, wgp6_decoded = output_dir / f"{corpus}-wgp6.frame", output_dir / f"{corpus}-wgp6.decoded"
    wgp6 = invoke([sys.executable, WGP6 / "encode.py", "encode", source_path, wgp6_frame,
                   "--block", 65536])
    invoke([WGP6 / "native", "decode", wgp6_frame, wgp6_decoded])
    if wgp6_decoded.read_bytes() != data:
        raise AssertionError(f"WGP6 full-frame roundtrip failed for {corpus}")

    row = {"corpus": corpus, "input_bytes": len(data), "input_sha256": sha(data),
           "native_original": {"frame_bytes": old["frame_bytes"],
                               "frame_sha256": file_sha(old_frame), "roundtrip": True},
           "wgp6_maximal": {"frame_bytes": wgp6["frame_bytes"],
                            "frame_sha256": file_sha(wgp6_frame), "roundtrip": True,
                            "selected_candidate": wgp6["selected_candidate"],
                            "candidate_frame_bytes": [trial["frame_bytes"] for trial in wgp6["trials"]]}}
    block_spans = [b"".join(block) for block in restart_blocks(data)]
    for mode, scalar in (("byte", False), ("scalar", True)):
        frame, metrics = encode(data, scalar)
        frame_path, decoded_path = output_dir / f"{corpus}-gen-{mode}.frame", output_dir / f"{corpus}-gen-{mode}.decoded"
        frame_path.write_bytes(frame)
        full = decode(frame)
        if full != data:
            raise AssertionError(f"GEN1 full-frame roundtrip failed: {corpus}/{mode}")
        decoded_path.write_bytes(full)
        if len(metrics["blocks"]) != len(block_spans):
            raise AssertionError("GEN1 restart count differs from atom-aligned source")
        for index, expected in enumerate(block_spans):
            selected = decode(frame, index)
            if selected != expected:
                raise AssertionError(f"GEN1 selected restart mismatch: {corpus}/{mode}/{index}")
        row["gen_transient_" + mode] = {
            **metrics, "full_decode": True, "every_restart_decode": True,
            "delta_vs_native_original_bytes": metrics["frame_bytes"] - old["frame_bytes"],
            "delta_vs_wgp6_bytes": metrics["frame_bytes"] - wgp6["frame_bytes"],
        }
    return row


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="temporary directory for complete frames")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--size", type=int, default=1 << 20)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for corpus in CORPORA:
        row = control_row(corpus, args.output, args.size)
        rows.append(row)
        print(json.dumps({"corpus": corpus,
                          "original": row["native_original"]["frame_bytes"],
                          "wgp6": row["wgp6_maximal"]["frame_bytes"],
                          "gen_byte": row["gen_transient_byte"]["frame_bytes"],
                          "gen_scalar": row["gen_transient_scalar"]["frame_bytes"]}), flush=True)
    fingerprints = {}
    for path in (WGP6 / "prepare_maximal.cpp", WGP6 / "prepare_maximal", WGP6 / "native.zig",
                 WGP6 / "native", WGP6 / "encode.py", HERE / "gen_transient.py"):
        fingerprints[str(path.relative_to(SRC6.parent))] = file_sha(path)
    report = {"scope": "retained old DEV prefixes; no held-out corpus read",
              "size": args.size, "timings": "not collected or reported",
              "fingerprints": fingerprints, "rows": rows}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"report": str(args.report), "rows": len(rows)}))


if __name__ == "__main__":
    main()
