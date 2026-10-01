"""One deterministic symbol-BWT size-screen child.

The parent process captures this child's stdout, stderr, and status before
parsing stdout as JSON.  The model is input-derived and complete in the
returned frame; this worker therefore reports an input-fit byte-codec result,
not a training-generalization claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
FRONTIER = ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from common import corpus_hashes, corpus_partition, corpus_spec, partition_bounds  # noqa: E402
from protocol import bzip3_control  # noqa: E402
from symbol_bwt import codec  # noqa: E402


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _code_sha() -> str:
    digest = hashlib.sha256()
    for path in (HERE / "codec.py", HERE / "worker.py", HERE / "screen.py"):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--block-bytes", required=True, type=int)
    parser.add_argument("--max-rules", type=int, default=8192)
    parser.add_argument("--max-passes", type=int, default=24)
    parser.add_argument("--pair-policy", choices=("consistent", "overlap_greedy"), default="consistent")
    parser.add_argument("--lane", choices=("screen", "final", "untouched"), default="screen")
    parser.add_argument("--frame-path", type=Path, default=None)
    args = parser.parse_args(argv)

    training, evaluation = corpus_partition(args.corpus, args.lane)
    spec = corpus_spec(args.corpus)
    lane_start, lane_end = partition_bounds(args.lane)
    model = codec.train(
        evaluation,
        block_bytes=args.block_bytes,
        max_rules=args.max_rules,
        max_passes=args.max_passes,
        pair_policy=args.pair_policy,
        input_fit=True,
    )
    frame = codec.encode(evaluation, model, args.block_bytes)
    if args.frame_path is not None:
        args.frame_path.parent.mkdir(parents=True, exist_ok=True)
        args.frame_path.write_bytes(frame)
    prepared = codec.prepare(frame)
    decoded = prepared.decode_all()
    if decoded != evaluation:
        raise AssertionError("full roundtrip mismatch")
    block_prepared = codec.prepare(frame)
    for index in range(len(prepared.parsed.records)):
        expected = evaluation[index * args.block_bytes : (index + 1) * args.block_bytes]
        if block_prepared.decode_block(index) != expected:
            raise AssertionError(f"block roundtrip mismatch at {index}")
    control = bzip3_control(evaluation, args.block_bytes, measure=False).record()
    row = {
        "status": "ok",
        "family": "symbol_bwt",
        "corpus": args.corpus,
        "lane": args.lane,
        "block_bytes": args.block_bytes,
        "max_rules": args.max_rules,
        "max_passes": args.max_passes,
        "pair_policy": args.pair_policy,
        "fit_scope": "input",
        "training_bytes": len(training),
        "training_sha256": _sha(training),
        "evaluation_bytes": len(evaluation),
        "evaluation_sha256": _sha(evaluation),
        "source": {
            **corpus_hashes(args.corpus),
            "lane_start": lane_start,
            "lane_end": lane_end,
            "projection": str(spec.projection_path),
        },
        "code_sha256": _code_sha(),
        "frame_sha256": _sha(frame),
        "decoded_sha256": _sha(decoded),
        "frame_path": str(args.frame_path) if args.frame_path is not None else None,
        "frame_file_bytes": len(frame),
        "frame": codec.frame_metrics(prepared),
        "encode_metrics": codec.metrics(),
        "control": control,
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
    }
    print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
