#!/usr/bin/env python3
"""Screen the structural candidates on the fixed projection corpus split.

This driver records sizes and exact roundtrips only.  It intentionally has no
clock reads: long final timing is controlled by the parent serial protocol.
The default window is the development screen [1 MiB, 1.25 MiB).  ``--lane
final`` selects [1 MiB, 9 MiB), and ``--lane untouched`` selects the separate
[9 MiB, 10 MiB) linguistic check.  This worker records sizes and roundtrips;
the parent controls any timing gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shlex
import sys
from pathlib import Path

# Running this file directly puts ``structure/`` on sys.path.  Add the
# frontier parent explicitly before importing the frozen corpus protocol.
FRONTIER_ROOT = Path(__file__).resolve().parents[1]
if str(FRONTIER_ROOT) not in sys.path:
    sys.path.insert(0, str(FRONTIER_ROOT))

from common import (  # noqa: E402
    CORPUS_SPECS,
    FINAL_BYTES,
    SCREEN_BYTES,
    TRAIN_BYTES,
    UNTOUCHED_BYTES,
    corpus_partition,
    corpus_spec,
)
import structure


CORPORA = tuple(sorted(CORPUS_SPECS))
LANE_BYTES = {"screen": SCREEN_BYTES, "final": FINAL_BYTES, "untouched": UNTOUCHED_BYTES}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _variant_names(value: str) -> list[str]:
    if value == "all":
        return ["raw", "shape", "byteclass", "templates"]
    names = [part.strip() for part in value.split(",") if part.strip()]
    unknown = [name for name in names if name not in ("raw", "shape", "byteclass", "templates")]
    if unknown:
        raise ValueError(f"unknown variant(s): {', '.join(unknown)}")
    return names


def _block_sizes(value: str) -> list[int]:
    if value == "all":
        return [16 * 1024, 64 * 1024]
    result = [int(part) for part in value.split(",") if part]
    if not result or any(not 1 <= item <= structure.MAX_BLOCK_BYTES for item in result):
        raise ValueError("block sizes must be in 1..65536")
    return result


def _retained_paths(retain_dir: Path, stem: str) -> tuple[Path, Path]:
    retain_dir.mkdir(parents=True, exist_ok=True)
    return (
        retain_dir / f"{stem}.frame",
        retain_dir / f"{stem}.record.json",
    )


def run_one(
    *,
    corpus_name: str,
    corpus_path: Path,
    projection_sha256: str,
    decoded_sha256: str,
    training: bytes,
    source: bytes,
    variant: str,
    block_bytes: int,
    start: int,
    retain_dir: Path | None,
    command: str,
) -> dict:
    model = structure.train(training, variant=variant)
    model_bytes = len(model.to_bytes())
    frame = structure.encode(model, source, block_bytes=block_bytes)
    info = structure.frame_info(frame)
    decoded = structure.decode(frame)
    if decoded != source:
        raise AssertionError("full decode mismatch")
    checked_blocks = 0
    block_hash = hashlib.sha256()
    for index in range(info["block_count"]):
        block = structure.decode_block(frame, index)
        block_hash.update(block)
        checked_blocks += 1
    if block_hash.hexdigest() != _sha256(source):
        raise AssertionError("block decode digest mismatch")

    fixed_bytes = info["header_bytes"] + info["model_bytes"] + info["directory_bytes"]
    payload_ratio = info["payload_bytes"] / info["raw_bytes"] if info["raw_bytes"] else 0.0
    if payload_ratio < 1.0:
        break_even = fixed_bytes / (1.0 - payload_ratio)
    else:
        break_even = None
    result = {
        "schema": "bzip4-structure-screen-1",
        "status": "ok",
        "command": command,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "corpus": corpus_name,
        "projection": str(corpus_path),
        "projection_sha256": projection_sha256,
        "decoded_corpus_sha256": decoded_sha256,
        "lane": "projection_content_field3",
        "training_start": 0,
        "training_bytes": len(training),
        "evaluation_start": start,
        "evaluation_bytes": len(source),
        "evaluation_sha256": _sha256(source),
        "variant": variant,
        "block_bytes": block_bytes,
        "model_bytes_from_train": model_bytes,
        "template_count": len(model.templates),
        "frame_sha256": _sha256(frame),
        "complete_bytes": info["complete_bytes"],
        "header_bytes": info["header_bytes"],
        "model_bytes": info["model_bytes"],
        "directory_bytes": info["directory_bytes"],
        "payload_bytes": info["payload_bytes"],
        "transformed_bytes": info["transformed_bytes"],
        "compressed_payload_bytes": info["compressed_payload_bytes"],
        "raw_fallback_payload_bytes": info["raw_fallback_payload_bytes"],
        "input_ratio": info["complete_bytes"] / len(source) if source else 0.0,
        "payload_ratio": payload_ratio,
        "fixed_bytes": fixed_bytes,
        "payload_break_even_raw_bytes": break_even,
        "block_count": info["block_count"],
        "blocks_checked": checked_blocks,
        "decode_work_bytes": info["decode_work_bytes"],
        "cold_block_metadata_bytes": info["cold_block_metadata_bytes"],
    }
    if retain_dir is not None:
        stem = f"{corpus_name}.{variant}.b{block_bytes}.s{start}.n{len(source)}"
        frame_path, json_path = _retained_paths(retain_dir, stem)
        frame_path.write_bytes(frame)
        result["frame_path"] = str(frame_path)
        result["frame_sha256"] = _sha256(frame_path.read_bytes())
        encoded = (json.dumps(result, sort_keys=True) + "\n").encode()
        json_path.write_bytes(encoded)
        result["record_path"] = str(json_path)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", choices=CORPORA, required=True)
    parser.add_argument("--variants", default="all", help="comma-separated variants or all")
    parser.add_argument("--block-bytes", default="all", help="comma-separated block sizes or all")
    parser.add_argument("--lane", choices=sorted(LANE_BYTES), default="screen")
    parser.add_argument("--retain-dir", type=Path)
    args = parser.parse_args(argv)
    spec = corpus_spec(args.corpus)
    corpus_path = spec.projection_path
    training, source = corpus_partition(args.corpus, args.lane)
    eval_bytes = LANE_BYTES[args.lane]
    start = {"screen": TRAIN_BYTES, "final": TRAIN_BYTES, "untouched": 9 * 1024 * 1024}[args.lane]
    variants = _variant_names(args.variants)
    block_sizes = _block_sizes(args.block_bytes)
    command = " ".join(shlex.quote(part) for part in [sys.executable, *sys.argv])
    failed = False
    for block_bytes in block_sizes:
        for variant in variants:
            try:
                result = run_one(
                    corpus_name=args.corpus,
                    corpus_path=corpus_path,
                    projection_sha256=spec.projection_sha256,
                    decoded_sha256=spec.decoded_sha256,
                    training=training,
                    source=source,
                    variant=variant,
                    block_bytes=block_bytes,
                    start=start,
                    retain_dir=args.retain_dir,
                    command=command,
                )
            except Exception as exc:  # retain a machine-readable failed row
                failed = True
                result = {
                    "schema": "bzip4-structure-screen-1",
                    "status": "failed",
                    "command": command,
                    "corpus": args.corpus,
                    "variant": variant,
                    "block_bytes": block_bytes,
                    "evaluation_start": start,
                    "evaluation_bytes": eval_bytes,
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                }
            print(json.dumps(result, sort_keys=True), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
