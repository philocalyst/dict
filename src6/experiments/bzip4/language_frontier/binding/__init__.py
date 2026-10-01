"""Bounded parameterized lexical-context experiment.

The package is deliberately independent of the production codec.  It emits a
self-contained, exact byte frame whose model is a finite table of literal
contexts, ranked slot occurrences, and byte bindings.  The entropy backend is zlib and is
labelled as a diagnostic backend in the accompanying report; the existing v4
binary is measured separately as a control.
"""

from .codec import (
    BACKEND_ZLIB_DIAGNOSTIC,
    FrameError,
    Model,
    Template,
    decode,
    encode,
    frame_info,
    model_info,
    train,
)

__all__ = [
    "BACKEND_ZLIB_DIAGNOSTIC",
    "FrameError",
    "Model",
    "Template",
    "decode",
    "encode",
    "frame_info",
    "model_info",
    "train",
]
