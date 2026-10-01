"""Frozen input and partition protocol for the Python frontier experiments.

The experiment consumes the already-retained projection files.  The only
payload bytes in a corpus are the third (normalised-content) TSV field: that
field is strict hexadecimal and is concatenated in source order.  Projection
file size and SHA-256 are part of the protocol, rather than optional metadata;
this prevents a candidate from accidentally measuring a locally altered
fixture.

This module deliberately has no codec or timing code.  Candidate workers can
import it without importing ctypes, a compiler, or a native library.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import binascii
from typing import Final


REPO: Final[Path] = Path(__file__).resolve().parents[4]
CORPUS_ROOT: Final[Path] = REPO / "src6" / "bench" / "real-world" / "evidence" / "corpora"

TRAIN_BYTES: Final[int] = 1 * 1024 * 1024
SCREEN_START: Final[int] = 1 * 1024 * 1024
# The plan's 1.25 MiB is binary (1 MiB + 256 KiB), not the decimal 1,250,000
# byte shorthand.  Keep this explicit because the screen is a fixed byte
# protocol and is reused by every worker.
SCREEN_END: Final[int] = TRAIN_BYTES + 256 * 1024
FINAL_START: Final[int] = 1 * 1024 * 1024
FINAL_END: Final[int] = 9 * 1024 * 1024
UNTOUCHED_START: Final[int] = 9 * 1024 * 1024
UNTOUCHED_END: Final[int] = 10 * 1024 * 1024
TRAINING_BYTES: Final[int] = TRAIN_BYTES
SCREEN_BYTES: Final[int] = SCREEN_END - SCREEN_START
FINAL_BYTES: Final[int] = FINAL_END - FINAL_START
UNTOUCHED_BYTES: Final[int] = UNTOUCHED_END - UNTOUCHED_START
MAX_CORPUS_BYTES: Final[int] = 512 * 1024 * 1024

# These are the projection hashes frozen by the prior independent round-2
# ledger.  A missing entry is a protocol error: accepting an unpinned input is
# worse than refusing to run a screening experiment.
@dataclass(frozen=True)
class CorpusSpec:
    name: str
    projection_path: Path
    projection_bytes: int
    projection_sha256: str
    decoded_bytes: int
    decoded_sha256: str


CORPUS_SPECS: Final[dict[str, CorpusSpec]] = {
    "freedict-eng-spa": CorpusSpec(
        "freedict-eng-spa",
        CORPUS_ROOT / "freedict-eng-spa" / "projection.tsv",
        90_123_314,
        "687008296b727878d26472bca5315beca8136a64365f2ac819e9e1f7f22f3865",
        43_700_255,
        "6e36329d204b027aea0cff19982964eba36df2445bda96bc6e250ba372a61649",
    ),
    "gcide-054": CorpusSpec(
        "gcide-054",
        CORPUS_ROOT / "gcide-054" / "projection.tsv",
        123_479_075,
        "4cddd7f0d23d7ef5dd923ef97b1894f7fff86cc26dbda1a9621653c1338c635b",
        58_808_436,
        "f41f0505f35686d1463bf05a5e988a7cea3de8ae5c7c52020f5a3e0b19fdfc74",
    ),
    "omw-ja-20": CorpusSpec(
        "omw-ja-20",
        CORPUS_ROOT / "omw-ja-20" / "projection.tsv",
        229_392_768,
        "ff9b2f1e56912bf3874cb77377a6f97949206a3efdff7739a10f61e1f0c43c75",
        112_147_272,
        "d3be8f96361e91ad1b48f640d0c92a1041cd6e9a6ab134b1d2412f7d2a5d7242",
    ),
}
# Compatibility spelling for worker ledgers.  Values remain immutable tuples
# and are derived only from the pinned table above.
EXPECTED_INPUTS: Final[dict[str, tuple[int, str]]] = {
    name: (spec.projection_bytes, spec.projection_sha256) for name, spec in CORPUS_SPECS.items()
}


class ProtocolError(ValueError):
    """Base class for an input or frame that is outside the frozen protocol."""


class UnknownCorpus(ProtocolError):
    pass


class InputHashMismatch(ProtocolError):
    pass


class ProjectionError(ProtocolError):
    pass


class CorpusTooShort(ProtocolError):
    pass


def corpus_spec(corpus: str | CorpusSpec) -> CorpusSpec:
    """Return a pinned corpus spec, rejecting unpinned names and paths."""

    if isinstance(corpus, CorpusSpec):
        spec = CORPUS_SPECS.get(corpus.name)
        if spec != corpus:
            raise UnknownCorpus(f"corpus spec is not the pinned instance: {corpus.name!r}")
        return spec
    if not isinstance(corpus, str) or corpus not in CORPUS_SPECS:
        known = ", ".join(sorted(CORPUS_SPECS))
        raise UnknownCorpus(f"unknown or unpinned corpus {corpus!r}; expected one of {known}")
    return CORPUS_SPECS[corpus]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def projection_fingerprint(corpus: str | CorpusSpec) -> dict[str, str | int]:
    """Verify and return the mandatory projection file fingerprint."""

    spec = corpus_spec(corpus)
    path = spec.projection_path
    try:
        byte_count = path.stat().st_size
    except OSError as exc:
        raise InputHashMismatch(f"cannot stat pinned projection {path}: {exc}") from exc
    if byte_count != spec.projection_bytes:
        raise InputHashMismatch(
            f"{spec.name}: projection byte count changed; expected "
            f"{spec.projection_bytes}, got {byte_count} ({path})"
        )
    actual = sha256_file(path)
    if actual != spec.projection_sha256:
        raise InputHashMismatch(
            f"{spec.name}: projection SHA-256 changed; expected {spec.projection_sha256}, got {actual}"
        )
    return {"path": str(path), "bytes": byte_count, "sha256": actual}


def _hex_field(value: bytes, *, corpus: str, line_number: int) -> bytes:
    if len(value) % 2:
        raise ProjectionError(f"{corpus}: line {line_number}: odd-length content hex")
    try:
        return binascii.unhexlify(value)
    except binascii.Error as exc:
        raise ProjectionError(f"{corpus}: line {line_number}: invalid content hex") from exc


def load_corpus(corpus: str | CorpusSpec) -> bytes:
    """Decode field three of a pinned projection and concatenate source order.

    The projection itself is streamed so parsing does not retain a second copy
    of the TSV.  The returned bytes are the sole corpus payload used by the
    candidate workers.  The projection fingerprint, decoded byte count, and
    decoded payload hash are checked before returning.
    """

    spec = corpus_spec(corpus)
    output = bytearray()
    projection_digest = hashlib.sha256()
    projection_bytes = 0
    try:
        if not spec.projection_path.is_file():
            raise InputHashMismatch(f"missing pinned projection {spec.projection_path}")
        expected_size = spec.projection_path.stat().st_size
        if expected_size != spec.projection_bytes:
            raise InputHashMismatch(
                f"{spec.name}: projection byte count changed; expected {spec.projection_bytes}, got {expected_size}"
            )
        with spec.projection_path.open("rb") as stream:
            for line_number, raw_line in enumerate(stream, 1):
                projection_digest.update(raw_line)
                projection_bytes += len(raw_line)
                line = raw_line
                if line.endswith(b"\n"):
                    line = line[:-1]
                if line.endswith(b"\r"):
                    line = line[:-1]
                if not line:
                    raise ProjectionError(f"{spec.name}: empty projection line {line_number}")
                columns = line.split(b"\t")
                if len(columns) != 3:
                    raise ProjectionError(
                        f"{spec.name}: line {line_number}: expected exactly three TSV fields, got {len(columns)}"
                    )
                content = _hex_field(columns[2], corpus=spec.name, line_number=line_number)
                if len(output) + len(content) > MAX_CORPUS_BYTES:
                    raise ProjectionError(f"{spec.name}: decoded payload exceeds {MAX_CORPUS_BYTES} byte limit")
                output.extend(content)
    except OSError as exc:
        raise InputHashMismatch(f"cannot read pinned projection {spec.projection_path}: {exc}") from exc
    actual_projection_sha256 = projection_digest.hexdigest()
    if projection_bytes != spec.projection_bytes or actual_projection_sha256 != spec.projection_sha256:
        raise InputHashMismatch(
            f"{spec.name}: projection changed while decoding; expected "
            f"{spec.projection_bytes}/{spec.projection_sha256}, got {projection_bytes}/{actual_projection_sha256}"
        )
    if len(output) != spec.decoded_bytes:
        raise ProjectionError(
            f"{spec.name}: decoded content byte count changed; expected {spec.decoded_bytes}, got {len(output)}"
        )
    payload = bytes(output)
    decoded_sha256 = hashlib.sha256(payload).hexdigest()
    if decoded_sha256 != spec.decoded_sha256:
        raise ProjectionError(
            f"{spec.name}: decoded content SHA-256 changed; expected {spec.decoded_sha256}, got {decoded_sha256}"
        )
    return payload


def partition_bounds(lane: str) -> tuple[int, int]:
    """Return the exact half-open evaluation range for a named lane."""

    if not isinstance(lane, str):
        raise ProtocolError("lane must be a string")
    normalized = lane.lower().replace("_", "-")
    if normalized in {"screen", "development", "dev"}:
        return SCREEN_START, SCREEN_END
    if normalized in {"final", "evaluation", "eval"}:
        return FINAL_START, FINAL_END
    if normalized in {"untouched", "holdout", "linguistic-holdout"}:
        return UNTOUCHED_START, UNTOUCHED_END
    raise ProtocolError("lane must be one of 'screen', 'final', or 'untouched'")


def corpus_partition(corpus: str | CorpusSpec, lane: str) -> tuple[bytes, bytes]:
    """Return ``(training, evaluation)`` using the frozen byte ranges.

    Training is always exactly ``[0, 1 MiB)``.  ``final`` intentionally starts
    at 1 MiB and therefore includes the development screen; ``untouched`` is
    the separate ``[9 MiB, 10 MiB)`` linguistic holdout.
    """

    data = load_corpus(corpus)
    start, end = partition_bounds(lane)
    if len(data) < end:
        spec = corpus_spec(corpus)
        raise CorpusTooShort(f"{spec.name}: lane {lane!r} requires {end} bytes, only {len(data)} available")
    return data[:TRAIN_BYTES], data[start:end]


def corpus_hashes(corpus: str | CorpusSpec, *, data: bytes | None = None) -> dict[str, str | int]:
    """Return auditable projection and decoded-payload hashes.

    The projection hash is mandatory and pinned.  The decoded hash is derived
    after exact field-three decoding and is included in every control record so
    later evidence can distinguish a framing mismatch from an input mismatch.
    """

    spec = corpus_spec(corpus)
    projection = projection_fingerprint(spec)
    payload = load_corpus(spec) if data is None else data
    if len(payload) != spec.decoded_bytes:
        raise ProjectionError(f"{spec.name}: payload length is {len(payload)}, expected {spec.decoded_bytes}")
    decoded_sha256 = hashlib.sha256(payload).hexdigest()
    if decoded_sha256 != spec.decoded_sha256:
        raise ProjectionError(f"{spec.name}: payload SHA-256 is {decoded_sha256}, expected {spec.decoded_sha256}")
    return {
        "projection_path": projection["path"],
        "projection_bytes": projection["bytes"],
        "projection_sha256": projection["sha256"],
        "decoded_bytes": len(payload),
        "decoded_sha256": decoded_sha256,
    }


__all__ = [
    "CORPUS_ROOT",
    "CORPUS_SPECS",
    "CorpusSpec",
    "TRAIN_BYTES",
    "TRAINING_BYTES",
    "SCREEN_START",
    "SCREEN_END",
    "SCREEN_BYTES",
    "FINAL_START",
    "FINAL_END",
    "FINAL_BYTES",
    "UNTOUCHED_START",
    "UNTOUCHED_END",
    "UNTOUCHED_BYTES",
    "MAX_CORPUS_BYTES",
    "EXPECTED_INPUTS",
    "ProtocolError",
    "UnknownCorpus",
    "InputHashMismatch",
    "ProjectionError",
    "CorpusTooShort",
    "corpus_spec",
    "sha256_file",
    "projection_fingerprint",
    "load_corpus",
    "partition_bounds",
    "corpus_partition",
    "corpus_hashes",
]
