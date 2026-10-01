#!/usr/bin/env python3
"""Candidate adapter for the root quickbench harness.

The adapter fits its charged contextual model from the exact raw input passed
to ``encode``.  It is intentionally a one-block research frame: callers must
use a block no larger than ``block_bytes`` and the frame carries all token
surfaces, class rows, transitions, raw length, and arithmetic payload.
"""

from __future__ import annotations

from codec import (
    DEFAULT_MAX_TOKENS,
    DEFAULT_MIN_PAIR_COUNT,
    MAX_RAW_LEN,
    decode_frame,
    encode_map,
    encode_marginal,
    fit_model,
)


def encode(
    raw: bytes,
    *,
    block_bytes: int = 65536,
    mode: str = "marginal",
    class_count: int = 4,
    max_tokens: int = min(DEFAULT_MAX_TOKENS, 384),
    max_token_len: int = 32,
    min_pair_count: int = DEFAULT_MIN_PAIR_COUNT,
    **_options: object,
) -> bytes:
    """Return one complete contextual-surface frame for ``raw``."""

    if block_bytes <= 0 or len(raw) > block_bytes or len(raw) > MAX_RAW_LEN:
        raise ValueError("surface_context adapter accepts one bounded block")
    if max_token_len != 32:
        raise ValueError("the frozen adapter policy requires max_token_len=32")
    model, _ = fit_model(
        raw,
        class_count=class_count,
        max_tokens=max_tokens,
        max_len=max_token_len,
        min_pair_count=min_pair_count,
    )
    if mode == "map":
        frame, _ = encode_map(raw, model)
    elif mode == "marginal":
        frame, _ = encode_marginal(raw, model)
    else:
        raise ValueError("mode must be 'map' or 'marginal'")
    return frame


def decode(frame: bytes) -> bytes:
    """Decode one self-contained contextual-surface frame."""

    return decode_frame(frame)
