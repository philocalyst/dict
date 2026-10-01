"""One screen measurement child; stdout is captured byte-for-byte by screen.py."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
sys.path.insert(0, str(ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"))

from common import SCREEN_END, SCREEN_START, TRAIN_BYTES, corpus_spec, load_corpus, projection_fingerprint  # noqa: E402
from bwt_context import decode, encode, frame_metrics, train  # noqa: E402


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--variant", required=True, choices=list("ABCDEF"))
    parser.add_argument("--block-bytes", required=True, type=int)
    args = parser.parse_args()
    spec = corpus_spec(args.corpus)
    source = projection_fingerprint(spec)
    data = load_corpus(spec)
    if len(data) < SCREEN_END:
        raise ValueError("pinned corpus is too short for screen")
    training = data[:TRAIN_BYTES]
    evaluation = data[SCREEN_START:SCREEN_END]
    started = time.perf_counter()
    model = train(training, args.variant, args.block_bytes)
    trained = time.perf_counter()
    frame = encode(evaluation, model, args.block_bytes)
    encoded = time.perf_counter()
    rebuilt = decode(frame)
    decoded = time.perf_counter()
    if rebuilt != evaluation:
        raise AssertionError("roundtrip mismatch")
    record = {
        "corpus": args.corpus,
        "variant": args.variant,
        "block_bytes": args.block_bytes,
        "status": 0,
        "source": source,
        "input": {
            "decoded_bytes": len(data),
            "decoded_sha256": _sha256(data),
            "training_start": 0,
            "training_end": TRAIN_BYTES,
            "training_sha256": _sha256(training),
            "evaluation_start": SCREEN_START,
            "evaluation_end": SCREEN_END,
            "evaluation_sha256": _sha256(evaluation),
        },
        "model_bytes": len(model.wire()),
        "frame_sha256": _sha256(frame),
        "train_seconds_python": trained - started,
        "encode_seconds_python": encoded - trained,
        "decode_seconds_python": decoded - encoded,
        "metrics": frame_metrics(frame),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
    }
    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
