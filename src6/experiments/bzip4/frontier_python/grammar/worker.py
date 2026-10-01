"""One deterministic grammar screen child; stdout is captured verbatim."""

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
FRONTIER = ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

import grammar  # noqa: E402
from common import (
    FINAL_END,
    FINAL_START,
    SCREEN_END,
    SCREEN_START,
    TRAIN_BYTES,
    corpus_partition,
    corpus_spec,
    partition_bounds,
    projection_fingerprint,
)  # noqa: E402
from protocol import bzip3_control  # noqa: E402


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _code_hash() -> str:
    digest = hashlib.sha256()
    for path in (HERE / "grammar.py", HERE / "worker.py", HERE / "screen.py"):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def _one(
    *,
    corpus: str,
    training: bytes,
    evaluation: bytes,
    variant: str,
    block_bytes: int,
    max_rules: int,
    max_passes: int,
    pair_policy: str,
    lane: str,
    source: dict[str, object],
    control: dict[str, object],
) -> dict[str, object]:
    started = time.perf_counter_ns()
    if variant == "training_huff":
        model = grammar.train(
            training,
            block_bytes=block_bytes,
            coder="huff",
            max_rules=max_rules,
            max_passes=max_passes,
            pair_policy=pair_policy,
        )
        trained_ns = time.perf_counter_ns() - started
        encode_started = time.perf_counter_ns()
        frame = grammar.encode(evaluation, block_bytes, model=model)
    elif variant == "input_fixed":
        model = None
        trained_ns = 0
        encode_started = time.perf_counter_ns()
        frame = grammar.encode(
            evaluation,
            block_bytes,
            variant="input_fixed",
            max_rules=max_rules,
            max_passes=max_passes,
            pair_policy=pair_policy,
        )
    elif variant == "input_huff":
        model = None
        trained_ns = 0
        encode_started = time.perf_counter_ns()
        frame = grammar.encode(
            evaluation,
            block_bytes,
            variant="input_huff",
            max_rules=max_rules,
            max_passes=max_passes,
            pair_policy=pair_policy,
        )
    else:
        raise ValueError(f"unknown screen variant {variant}")
    encode_ns = time.perf_counter_ns() - encode_started
    encode_metrics = grammar.metrics()
    decode_started = time.perf_counter_ns()
    prepared = grammar.prepare(frame)
    decoded = prepared.decode_all()
    decode_ns = time.perf_counter_ns() - decode_started
    if decoded != evaluation:
        raise AssertionError(f"{variant}: full roundtrip mismatch")
    random_index = (len(prepared.records) - 1) // 2 if prepared.records else None
    random_sha256 = None
    random_ns = None
    if random_index is not None:
        random_started = time.perf_counter_ns()
        random = prepared.decode_block(random_index)
        random_ns = time.perf_counter_ns() - random_started
        expected_start = random_index * block_bytes
        if random != evaluation[expected_start : expected_start + len(random)]:
            raise AssertionError(f"{variant}: random restart mismatch")
        random_sha256 = _sha256(random)
    frame_info = grammar.frame_metrics(prepared)
    frame_info["encode_model_bytes"] = len(model.serialize()) if model is not None else encode_metrics.get("model_bytes", 0)
    return {
        "corpus": corpus,
        "variant": variant,
        "block_bytes": block_bytes,
        "status": "ok",
        "source": source,
        "code_sha256": _code_hash(),
        "training_bytes": len(training),
        "training_sha256": _sha256(training),
        "evaluation_bytes": len(evaluation),
        "evaluation_sha256": _sha256(evaluation),
        "lane": lane,
        "fit_scope": "training" if variant == "training_huff" else "input",
        "max_rules": max_rules,
        "max_passes": max_passes,
        "pair_policy": pair_policy,
        "training_model_bytes": len(model.serialize()) if model is not None else None,
        "frame_sha256": _sha256(frame),
        "decoded_sha256": _sha256(decoded),
        "trained_ns": trained_ns,
        "encode_ns": encode_ns,
        "decode_ns": decode_ns,
        "random_block_ns": random_ns,
        "random_block_index": random_index,
        "random_block_sha256": random_sha256,
        "frame": frame_info,
        "encode_metrics": encode_metrics,
        "control": control,
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, choices=("freedict-eng-spa", "gcide-054", "omw-ja-20"))
    parser.add_argument("--variant", required=True, choices=("input_huff", "input_fixed", "training_huff"))
    parser.add_argument("--block-bytes", required=True, type=int)
    parser.add_argument("--max-rules", type=int, default=4096)
    parser.add_argument("--max-passes", type=int, default=10)
    parser.add_argument("--pair-policy", choices=("overlap_greedy", "consistent"), default="overlap_greedy")
    parser.add_argument("--lane", choices=("screen", "final"), default="screen")
    args = parser.parse_args(argv)
    source_spec = corpus_spec(args.corpus)
    training, evaluation = corpus_partition(args.corpus, args.lane)
    lane_start, lane_end = partition_bounds(args.lane)
    expected_eval_bytes = (SCREEN_END - SCREEN_START) if args.lane == "screen" else (FINAL_END - FINAL_START)
    if len(training) != TRAIN_BYTES or len(evaluation) != expected_eval_bytes:
        raise AssertionError("frozen corpus partition changed")
    projection = projection_fingerprint(source_spec)
    source = {
        **projection,
        "decoded_bytes": source_spec.decoded_bytes,
        "decoded_sha256": source_spec.decoded_sha256,
        "training_sha256": _sha256(training),
        "evaluation_sha256": _sha256(evaluation),
    }
    control_result = bzip3_control(evaluation, args.block_bytes, measure=False)
    control = control_result.record()
    row = _one(
        corpus=args.corpus,
        training=training,
        evaluation=evaluation,
        variant=args.variant,
        block_bytes=args.block_bytes,
        max_rules=args.max_rules,
        max_passes=args.max_passes,
        pair_policy=args.pair_policy,
        lane=args.lane,
        source=source,
        control=control,
    )
    print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
