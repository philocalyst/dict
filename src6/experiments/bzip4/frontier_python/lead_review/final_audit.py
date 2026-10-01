"""Independent evidence audit of the frozen serial matrix.

This does not import the measurement harness. It checks the persisted raw
captures, reconstructs exact fixed corpus slices, and separately decodes every
saved block through each codec's public prepared interface. No timing claims
are derived from this audit process.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(REPO))

from src6.experiments.bzip4.frontier_python import common
from src6.experiments.bzip4.frontier_python.bwt_context import codec as bwt
from src6.experiments.bzip4.frontier_python.grammar import grammar
from src6.experiments.bzip4.frontier_python.symbol_bwt import codec as symbol_bwt
from src6.experiments.bzip4.frontier_python.protocol import framing
from src6.experiments.bzip4.frontier_python.protocol.native_bzip3 import Bzip3Session


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_file(path: str, expected_bytes: int, expected_sha256: str) -> bytes:
    data = Path(path).read_bytes()
    assert len(data) == expected_bytes, path
    assert digest(data) == expected_sha256, path
    return data


def audit(root: Path) -> dict:
    summary = json.loads((root / "results.json").read_text())
    assert summary["status"] == 0 and summary["source_drift"]["ok"]
    assert summary["native_control_unchanged"]
    for source in summary["source_snapshot"]["sources"]:
        for kind in ("source", "snapshot"):
            verify_file(source[kind], source["bytes"], source["sha256"])

    corpus_name = None
    corpus = b""
    results = []
    for record in summary["records"]:
        status = record["capture"]
        stdout = verify_file(status["stdout_path"], status["stdout"]["bytes"], status["stdout"]["sha256"])
        stderr = verify_file(status["stderr_path"], status["stderr"]["bytes"], status["stderr"]["sha256"])
        assert status["returncode"] == 0 and not stderr
        row = json.loads(stdout)
        assert row == record["result"]
        frame = verify_file(row["frame_path"], row["frame_bytes"], row["frame_sha256"])
        if row["corpus"] != corpus_name:
            corpus_name = row["corpus"]
            corpus = common.load_corpus(corpus_name)
        start, end = common.partition_bounds(row["lane"])
        expected = corpus[start:end]
        expected_hash = digest(expected)
        assert expected_hash == row["input"]["evaluation_sha256"]
        assert len(expected) == row["input"]["evaluation_bytes"]
        assert all(trial["decoded_sha256"] == expected_hash for trial in row["decode_trials"])

        variant = row["variant"]
        block_bytes = row["block_bytes"]
        output_hash = hashlib.sha256()
        block_count = 0
        native = None
        if variant == "native":
            prepared = framing.open_frame(frame)
            native = Bzip3Session(block_bytes, purpose="decode")
        else:
            codec = bwt if variant in {"A", "B", "C", "D", "E", "F"} else grammar if variant == "grammar_input" else symbol_bwt
            prepared = codec.prepare(frame)
        try:
            for index, at in enumerate(range(0, len(expected), block_bytes)):
                if native is not None:
                    directory = prepared.records[index]
                    decoded = native.decode_block(prepared.block_encoded(index), directory.raw_bytes)
                    assert framing.block_crc32(decoded) == directory.crc32
                else:
                    decoded = prepared.decode_block(index)
                assert decoded == expected[at : at + block_bytes], (corpus_name, variant, index)
                output_hash.update(decoded)
                block_count += 1
        finally:
            if native is not None:
                native.close()
        assert output_hash.hexdigest() == expected_hash
        metrics = row["metrics"]
        charged = metrics["header_bytes"] + metrics["directory_bytes"] + metrics["payload_bytes"]
        if variant != "native":
            charged += metrics["model_bytes"]
        assert charged == len(frame), (variant, charged, len(frame))
        prior_frame = None
        if variant == "symbol_bwt" and row["lane"] == "final":
            prior_frame = Path(__file__).resolve().parents[1] / "symbol_bwt" / "results" / "frames" / "final-r8192-p64-consistent" / f"{corpus_name}-{block_bytes}.sbw1"
            assert prior_frame.read_bytes() == frame, ("independent re-encode changed bytes", str(prior_frame))
        results.append({
            "corpus": corpus_name,
            "lane": row["lane"],
            "variant": variant,
            "block_bytes": block_bytes,
            "complete_bytes": len(frame),
            "blocks_independently_verified": block_count,
            "frame_sha256": digest(frame),
            "decoded_sha256": expected_hash,
            "prior_independent_encode_identical": str(prior_frame) if prior_frame else None,
        })
    return {"status": "pass", "timing_disabled": True, "cells": len(results), "records": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.root), sort_keys=True))
