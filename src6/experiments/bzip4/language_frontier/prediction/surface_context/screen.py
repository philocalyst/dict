#!/usr/bin/env python3
"""Run the frozen three-row contextual surface screen.

The policy is fixed before reading these rows: train on the first 64 KiB of a
specified training file, build singleton+greedy-BPE byte tokens (max 512,
length 32, minimum pair count 4), fit destination classes from continuation
signatures, then encode the exact 64 KiB evaluation bytes.  Four classes and
the C=1 iid control use the same inventory policy and complete source/header.
No native timings are run here; native v4/bzip3 controls are supplied by the
existing evidence lane or a separate quiet storage capture.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from codec import (
    DEFAULT_MAX_TOKENS,
    DEFAULT_MIN_PAIR_COUNT,
    MAX_RAW_LEN,
    encode_both,
    fit_model,
    header_for,
)


LIMIT = MAX_RAW_LEN
REPO_ROOT = Path(__file__).resolve().parents[6]


def read_slice(path: Path, offset: int, limit: int) -> bytes:
    with path.open("rb") as stream:
        stream.seek(offset)
        data = stream.read(limit)
    if len(data) == 0:
        raise ValueError(f"empty slice: {path}:{offset}")
    return data


def run_case(
    name: str,
    train_path: Path,
    eval_path: Path,
    *,
    train_offset: int,
    eval_offset: int,
    train_limit: int,
    eval_limit: int,
    class_count: int,
    max_tokens: int,
) -> dict[str, object]:
    train = read_slice(train_path, train_offset, train_limit)
    evaluation = read_slice(eval_path, eval_offset, eval_limit)
    model, fit = fit_model(
        train,
        class_count=class_count,
        max_tokens=max_tokens,
        max_len=32,
        min_pair_count=DEFAULT_MIN_PAIR_COUNT,
    )
    result = encode_both(evaluation, model)
    result.update(
        {
            "name": name,
            "train_path": str(train_path),
            "eval_path": str(eval_path),
            "train_offset": train_offset,
            "eval_offset": eval_offset,
            "train_sha256": hashlib.sha256(train).hexdigest(),
            "eval_sha256": hashlib.sha256(evaluation).hexdigest(),
            "fit": fit,
            "policy": {
                "train_limit": train_limit,
                "eval_limit": eval_limit,
                "max_tokens": max_tokens,
                "max_token_len": 32,
                "min_pair_count": DEFAULT_MIN_PAIR_COUNT,
                "initial_class": 0,
                "class_fit": "six-step deterministic Lloyd clustering of next-token signatures",
                "source": "token t ~ P(t|boundary_class), emit bytes(t), class <- g(t)",
            },
        }
    )
    return result


def default_cases(root: Path, web2: Path) -> list[tuple[str, Path, Path, int, int]]:
    data = root / "src6/experiments/bzip4/bz4/data"
    return [
        ("web2-next64k", web2, web2, 0, 65536),
        ("freedict-eval8", data / "freedict.train.bin", data / "freedict.eval8.bin", 0, 0),
        ("omw-eval8", data / "omw.train.bin", data / "omw.eval8.bin", 0, 0),
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--web2", type=Path, default=Path("/usr/share/dict/web2"))
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--train-limit", type=int, default=LIMIT)
    parser.add_argument("--eval-limit", type=int, default=LIMIT)
    # Keep the bounded screen comfortably below the hard 4096-token parser
    # limit.  The value is frozen for all rows; it is not corpus-selected.
    parser.add_argument("--max-tokens", type=int, default=min(DEFAULT_MAX_TOKENS, 384))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    cases = default_cases(root, args.web2.resolve())
    rows: list[dict[str, object]] = []
    for name, train_path, eval_path, train_offset, eval_offset in cases:
        for class_count in (1, 4):
            row = run_case(
                name,
                train_path,
                eval_path,
                train_offset=train_offset,
                eval_offset=eval_offset,
                train_limit=args.train_limit,
                eval_limit=args.eval_limit,
                class_count=class_count,
                max_tokens=args.max_tokens,
            )
            rows.append(row)
            print(
                f"{name}\tC={class_count}\tinput={row['bytes']}\tmodel={row['model']['token_count']}\t"
                f"header={row['map']['header_bytes']}\tmap={row['map']['frame_bytes']}\t"
                f"marginal={row['marginal']['frame_bytes']}\t"
                f"roundtrip={row['map']['round_trip'] and row['marginal']['round_trip']}"
            )
    if args.json:
        print(json.dumps(rows, sort_keys=True))


if __name__ == "__main__":
    main()
