#!/usr/bin/env python3
"""Bind the one-process reader to all frozen quality/access source frames."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(binary: Path, reference: Path) -> dict:
    reference_bytes = reference.read_bytes()
    original = json.loads(reference_bytes)
    lanes = {row["corpus"]["name"]: row["corpus"] for row in original["storage"]["per_lane"]}
    cells = [row for row in original["storage"]["cells"]
             if row["candidate"] in ("wordfrontier-quality", "wordfrontier-access")]
    if len(cells) != 2 * len(lanes) or len({(r["corpus"], r["candidate"]) for r in cells}) != len(cells):
        raise ValueError("missing or duplicate profile/source frame")
    records, families = [], set()
    with tempfile.TemporaryDirectory(prefix="wordfrontier-native-gate-") as name:
        temporary = Path(name)
        output = temporary / "output.raw"
        for row in cells:
            frame = Path(row["frame_path"])
            source = Path(lanes[row["corpus"]]["path"])
            raw = source.read_bytes()
            if hashlib.sha256(raw).hexdigest() != row["source_sha256"] or digest(frame) != row["frame_sha256"]:
                raise ValueError("frozen source/frame changed")
            family = frame.read_bytes()[:4].decode("ascii")
            families.add(family)
            subprocess.run([str(binary), "decode", str(frame), str(output)], check=True, capture_output=True)
            if output.read_bytes() != raw:
                raise ValueError("native full source mismatch")
            pages = (len(raw) + 65535) // 65536
            probes = sorted({0, pages // 2, pages - 1}) if pages else []
            for page in probes:
                subprocess.run([str(binary), "query", str(frame), str(output), "--index", str(page)],
                               check=True, capture_output=True)
                if output.read_bytes() != raw[page * 65536:(page + 1) * 65536]:
                    raise ValueError("native independently extracted page mismatch")
            records.append({"corpus": row["corpus"], "profile": row["candidate"],
                            "family": family, "source_sha256": row["source_sha256"],
                            "frame_sha256": row["frame_sha256"], "frame_bytes": frame.stat().st_size,
                            "full_byte_exact": True, "independent_pages": probes})
        if families != {"WPG2", "GWT1"}:
            raise ValueError("both native reader paths must be exercised")

        # Failures preserve a pre-existing output. Include an atomic-publication
        # failure after WPG full decoding, not only rejected magic/arguments.
        sentinel = b"pre-existing-output"
        invalid = temporary / "invalid.frame"
        corruption = temporary / "corrupt.frame"
        wpg = next(Path(r["frame_path"]) for r in cells if Path(r["frame_path"]).read_bytes()[:4] == b"WPG2")
        damaged = bytearray(wpg.read_bytes())
        damaged[-1] ^= 1  # WPG's full source CRC; publication must be atomic.
        corruption.write_bytes(damaged)
        cases = [(b"", []), (b"WPG", []), (b"NOPE", []),
                 (wpg.read_bytes(), ["--index", "1x"]),
                 (wpg.read_bytes(), ["--measure", "2"])]
        for data, arguments in cases:
            invalid.write_bytes(data)
            output.write_bytes(sentinel)
            result = subprocess.run([str(binary), "query", str(invalid), str(output), *arguments],
                                    capture_output=True)
            if result.returncode == 0 or output.read_bytes() != sentinel:
                raise ValueError("invalid dispatch published output")
        output.write_bytes(sentinel)
        result = subprocess.run([str(binary), "decode", str(corruption), str(output)], capture_output=True)
        if result.returncode == 0 or output.read_bytes() != sentinel:
            raise ValueError("full source corruption published output")
    return {"protocol": "WORD-FRONTIER-NATIVE-DISPATCH-GATE/1", "status": "verified",
            "binary_sha256": digest(binary),
            "reference_sha256": hashlib.sha256(reference_bytes).hexdigest(),
            "scope": "same delivered WPG2/GWT1 frames and unchanged bounded readers; native dispatch only",
            "complete_frames": len(records), "records": records,
            "invalid_dispatch_cases": len(cases), "corrupt_full_publication_rejected": True,
            "timing": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("reference", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = verify(args.binary.resolve(), args.reference)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "complete_frames": result["complete_frames"]}))
