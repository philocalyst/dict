"""One ordinary input-fit screen child; stdout is captured byte-for-byte."""

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

from common import SCREEN_END, SCREEN_START, corpus_spec, load_corpus, projection_fingerprint  # noqa: E402
from bwt_context import decode, encode, frame_metrics, train  # noqa: E402


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--variant", required=True, choices=("A", "F"))
    parser.add_argument("--block-bytes", required=True, type=int)
    args = parser.parse_args()

    spec = corpus_spec(args.corpus)
    source = projection_fingerprint(spec)
    data = load_corpus(spec)
    if len(data) < SCREEN_END:
        raise ValueError("pinned corpus is too short for screen")
    screen = data[SCREEN_START:SCREEN_END]

    started = time.perf_counter()
    # This is deliberately ordinary input fitting: the complete model is
    # serialized in the resulting frame and charged in its metrics.  It is
    # not a frozen-prefix prediction claim.
    model = train(screen, args.variant, args.block_bytes)
    trained = time.perf_counter()
    frame = encode(screen, model, args.block_bytes)
    encoded = time.perf_counter()
    rebuilt = decode(frame)
    decoded = time.perf_counter()
    if rebuilt != screen:
        raise AssertionError("roundtrip mismatch")

    screen_hash = _sha256(screen)
    record = {
        "corpus": args.corpus,
        "variant": args.variant,
        "block_bytes": args.block_bytes,
        "status": 0,
        "source": source,
        "input_fit": {
            "ordinary_compression": True,
            "prediction_claim": False,
            "scope": "same_256KiB_screen_input",
            "training_start": SCREEN_START,
            "training_end": SCREEN_END,
            "training_bytes": len(screen),
            "training_sha256": screen_hash,
            "encoded_start": SCREEN_START,
            "encoded_end": SCREEN_END,
            "encoded_bytes": len(screen),
            "encoded_sha256": screen_hash,
        },
        "input": {
            "decoded_bytes": len(data),
            "decoded_sha256": _sha256(data),
            "screen_start": SCREEN_START,
            "screen_end": SCREEN_END,
            "screen_sha256": screen_hash,
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
