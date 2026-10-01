#!/usr/bin/env python3
"""Run non-timed native size/roundtrip controls on fixed lanes.

This is deliberately a correctness/size screen, not the final timing driver.
The caller should wrap it with ``protocol.capture.run_and_save`` so raw child
streams and status are persisted before any ledger parser runs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from common import CORPUS_SPECS, corpus_hashes, corpus_partition
from protocol import bzip3_control, bzip3_decode, bzip3_decode_block


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lane", action="append", choices=("screen", "untouched", "final"), default=None)
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), default=None)
    parser.add_argument("--block-bytes", action="append", type=int, default=None)
    args = parser.parse_args(argv)
    lanes = args.lane or ["screen", "untouched"]
    corpora = args.corpus or sorted(CORPUS_SPECS)
    boundaries = args.block_bytes or [16 * 1024, 64 * 1024]
    for corpus in corpora:
        hashes = corpus_hashes(corpus)
        for lane in lanes:
            training, evaluation = corpus_partition(corpus, lane)
            for block_bytes in boundaries:
                result = bzip3_control(evaluation, block_bytes, measure=False)
                rebuilt = bzip3_decode(result.frame)
                if rebuilt != evaluation:
                    raise AssertionError(f"retained decode mismatch: {corpus}/{lane}/{block_bytes}")
                block_count = (len(evaluation) + block_bytes - 1) // block_bytes
                for index in range(block_count):
                    start = index * block_bytes
                    expected = evaluation[start : start + block_bytes]
                    if bzip3_decode_block(result.frame, index) != expected:
                        raise AssertionError(f"random block mismatch: {corpus}/{lane}/{block_bytes}/{index}")
                print(
                    json.dumps(
                        {
                            "schema": "frontier-python-native-control-size-1",
                            "corpus": corpus,
                            "lane": lane,
                            "training_bytes": len(training),
                            "evaluation_start": {"screen": 1 << 20, "final": 1 << 20, "untouched": 9 << 20}[lane],
                            "evaluation_bytes": len(evaluation),
                            "input_projection_sha256": hashes["projection_sha256"],
                            "input_decoded_sha256": hashes["decoded_sha256"],
                            "evaluation_sha256": hashlib.sha256(evaluation).hexdigest(),
                            "block_bytes": block_bytes,
                            "block_count": result.block_count,
                            "payload_bytes": result.payload_bytes,
                            "framing_bytes": 32 + 16 * result.block_count,
                            "complete_bytes": result.total_bytes,
                            "frame_sha256": result.frame_sha256,
                            "control_library_sha256": result.library_sha256,
                            "conservative_scratch_bytes": result.scratch_bytes,
                            "roundtrip": "exact-all-and-every-block",
                            "timing": "not-measured",
                        },
                        sort_keys=True,
                    ),
                    flush=True,
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
