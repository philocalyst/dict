"""ctypes bzip3 control with retained state and complete Python framing.

This module is a CONTROL only.  Candidate workers must not import it as their
codec: a Python candidate's decoder remains pure Python and its model/framing
bytes are charged separately.  The control exists to reproduce the prior
matched-boundary bzip3 totals and to provide a transparent native baseline.
`Bzip3Session(purpose="both")` preserves the historical two-state control;
one-sided encode/decode helpers allocate and charge only the state they use.
"""

from __future__ import annotations

from dataclasses import dataclass
import ctypes
import hashlib
from pathlib import Path
import struct
import time
from typing import Final

from .builder import build_shared_library, library_path
from .framing import Bzip3Frame, block_crc32, frame_blocks, open_frame


MIN_NATIVE_BLOCK_BYTES: Final[int] = 65 * 1024
MAX_NATIVE_BLOCK_BYTES: Final[int] = 511 * 1024 * 1024
LIBSAIS_ACCOUNTED_BYTES: Final[int] = 1024 * 1024
MAX_RAW_BYTES: Final[int] = 512 * 1024 * 1024
MAX_BLOCKS: Final[int] = 1_000_000


class NativeBzip3Error(RuntimeError):
    pass


class ExactRoundtripError(NativeBzip3Error):
    pass


def _library_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class _Bzip3Bindings:
    def __init__(self, path: Path):
        self.path = path
        try:
            self.lib = ctypes.CDLL(str(path))
        except OSError as exc:
            raise NativeBzip3Error(f"cannot load isolated bzip3 control {path}: {exc}") from exc
        c_void = ctypes.c_void_p
        c_u8_p = ctypes.POINTER(ctypes.c_uint8)
        self.lib.bz3_new.argtypes = [ctypes.c_int32]
        self.lib.bz3_new.restype = c_void
        self.lib.bz3_free.argtypes = [c_void]
        self.lib.bz3_free.restype = None
        self.lib.bz3_bound.argtypes = [ctypes.c_size_t]
        self.lib.bz3_bound.restype = ctypes.c_size_t
        self.lib.bz3_min_memory_needed.argtypes = [ctypes.c_int32]
        self.lib.bz3_min_memory_needed.restype = ctypes.c_size_t
        self.lib.bz3_last_error.argtypes = [c_void]
        self.lib.bz3_last_error.restype = ctypes.c_int8
        self.lib.bz3_strerror.argtypes = [c_void]
        self.lib.bz3_strerror.restype = ctypes.c_char_p
        self.lib.bz3_encode_block.argtypes = [c_void, c_u8_p, ctypes.c_int32]
        self.lib.bz3_encode_block.restype = ctypes.c_int32
        self.lib.bz3_decode_block.argtypes = [c_void, c_u8_p, ctypes.c_size_t, ctypes.c_int32, ctypes.c_int32]
        self.lib.bz3_decode_block.restype = ctypes.c_int32

    def strerror(self, state: ctypes.c_void_p) -> str:
        try:
            value = self.lib.bz3_strerror(state)
            return value.decode("utf-8", "replace") if value else "unknown bzip3 error"
        except Exception:
            return "unknown bzip3 error"


_BINDINGS: dict[Path, _Bzip3Bindings] = {}


def load_bindings(*, ensure: bool = True) -> _Bzip3Bindings:
    path = library_path()
    if ensure:
        # Validation is part of every control load, not just first build: a
        # tampered retained object must not silently become a new baseline.
        path = build_shared_library()
    if not path.is_file():
        raise NativeBzip3Error(f"isolated bzip3 control library is absent: {path}")
    bindings = _BINDINGS.get(path)
    if bindings is None:
        bindings = _Bzip3Bindings(path)
        _BINDINGS[path] = bindings
    return bindings


def control_library_record() -> dict[str, str | int]:
    """Return the isolated control object's path, size, and SHA-256."""

    path = build_shared_library()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": _library_sha256(path)}


def bzip3_bound(input_size: int, *, bindings: _Bzip3Bindings | None = None) -> int:
    if input_size < 0 or input_size > MAX_NATIVE_BLOCK_BYTES:
        raise NativeBzip3Error(f"invalid bzip3 input size {input_size}")
    bindings = bindings or load_bindings()
    bound = int(bindings.lib.bz3_bound(input_size))
    if bound <= 0:
        raise NativeBzip3Error(f"bzip3 returned no bound for {input_size}")
    return bound


def bzip3_min_memory(block_bytes: int, *, bindings: _Bzip3Bindings | None = None) -> int:
    state_size = _state_size(block_bytes)
    bindings = bindings or load_bindings()
    result = int(bindings.lib.bz3_min_memory_needed(state_size))
    if result <= 0:
        raise NativeBzip3Error(f"bzip3 returned no state memory for {state_size}")
    return result


def _state_size(block_bytes: int) -> int:
    if block_bytes <= 0 or block_bytes > MAX_NATIVE_BLOCK_BYTES:
        raise NativeBzip3Error(f"invalid block size {block_bytes}")
    return max(block_bytes, MIN_NATIVE_BLOCK_BYTES)


class _NativeState:
    def __init__(self, bindings: _Bzip3Bindings, block_bytes: int):
        self.bindings = bindings
        self.block_bytes = block_bytes
        self.state_size = _state_size(block_bytes)
        self.ptr = bindings.lib.bz3_new(self.state_size)
        if not self.ptr:
            raise NativeBzip3Error(f"bz3_new({self.state_size}) failed")

    def close(self) -> None:
        if self.ptr:
            self.bindings.lib.bz3_free(self.ptr)
            self.ptr = None

    def __enter__(self) -> "_NativeState":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()


class Bzip3Session:
    """Retained native state with an explicit encode/decode purpose.

    ``purpose="both"`` preserves the historical control allocation.  Final
    encode-only and decode-only paths can now charge only the state they use;
    the mutable work buffer remains shared within that session.
    """

    PURPOSES = frozenset(("encode", "decode", "both"))

    def __init__(self, block_bytes: int, *, purpose: str = "both", bindings: _Bzip3Bindings | None = None):
        if purpose not in self.PURPOSES:
            raise NativeBzip3Error(f"unknown bzip3 session purpose {purpose!r}; expected encode, decode, or both")
        self.block_bytes = block_bytes
        self.purpose = purpose
        self.bindings = bindings or load_bindings()
        self.state_size = _state_size(block_bytes)
        self.work_capacity = bzip3_bound(self.state_size, bindings=self.bindings)
        self.encode_state: _NativeState | None = None
        self.decode_state: _NativeState | None = None
        if purpose in {"encode", "both"}:
            self.encode_state = _NativeState(self.bindings, block_bytes)
        try:
            if purpose in {"decode", "both"}:
                self.decode_state = _NativeState(self.bindings, block_bytes)
        except Exception:
            if self.encode_state is not None:
                self.encode_state.close()
            raise
        self.work = ctypes.create_string_buffer(self.work_capacity)
        self.closed = False
        # Charge exactly the requested native state count, plus one shared work
        # buffer and the pinned conservative libsais allowance.  The historical
        # both-purpose control therefore remains two states, while final
        # decode-only/encode-only paths report one.
        state_memory = bzip3_min_memory(block_bytes, bindings=self.bindings)
        self.retained_state_count = int(self.encode_state is not None) + int(self.decode_state is not None)
        self.scratch_bytes = (
            self.retained_state_count * state_memory
            + self.work_capacity
            + LIBSAIS_ACCOUNTED_BYTES
        )

    def close(self) -> None:
        if not self.closed:
            if self.decode_state is not None:
                self.decode_state.close()
            if self.encode_state is not None:
                self.encode_state.close()
            self.closed = True

    def __enter__(self) -> "Bzip3Session":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def _check_raw(self, raw: bytes) -> None:
        if self.closed:
            raise NativeBzip3Error("session is closed")
        if not raw or len(raw) > self.block_bytes:
            raise NativeBzip3Error(f"raw block length {len(raw)} is outside session block size {self.block_bytes}")

    def encode_block(self, raw: bytes) -> bytes:
        self._check_raw(raw)
        if self.encode_state is None:
            raise NativeBzip3Error(f"session purpose {self.purpose!r} does not retain an encoder state")
        ctypes.memmove(self.work, raw, len(raw))
        pointer = ctypes.cast(self.work, ctypes.POINTER(ctypes.c_uint8))
        result = int(self.bindings.lib.bz3_encode_block(self.encode_state.ptr, pointer, len(raw)))
        error = int(self.bindings.lib.bz3_last_error(self.encode_state.ptr))
        if result < 0 or error != 0:
            raise NativeBzip3Error(f"bzip3 encode failed (code={result}, error={error}): {self.bindings.strerror(self.encode_state.ptr)}")
        if result <= 0 or result > self.work_capacity:
            raise NativeBzip3Error(f"bzip3 returned invalid encoded length {result}")
        return ctypes.string_at(self.work, result)

    def decode_block(self, encoded: bytes, raw_bytes: int) -> bytes:
        if self.closed:
            raise NativeBzip3Error("session is closed")
        if self.decode_state is None:
            raise NativeBzip3Error(f"session purpose {self.purpose!r} does not retain a decoder state")
        if not encoded or raw_bytes <= 0 or raw_bytes > self.block_bytes:
            raise NativeBzip3Error(f"invalid decode block lengths encoded={len(encoded)} raw={raw_bytes}")
        # Keep malformed-input probes inside a caller-owned allocation.  The
        # upstream helper needs at least the fixed eight-byte literal header;
        # transformed blocks carry a ninth model byte and reserve only bits
        # 1-2 in that byte, matching the Zig control's boundary checks.
        if len(encoded) < 8:
            raise NativeBzip3Error("truncated bzip3 block header")
        bwt_index = struct.unpack_from("<i", encoded, 4)[0]
        if bwt_index < -1:
            raise NativeBzip3Error("malformed bzip3 BWT index")
        if len(encoded) == 8 and bwt_index != -1:
            raise NativeBzip3Error("truncated bzip3 transformed header")
        if len(encoded) >= 9 and bwt_index != -1 and (encoded[8] & ~0x06):
            raise NativeBzip3Error("malformed bzip3 model header")
        if len(encoded) > self.work_capacity:
            raise NativeBzip3Error(f"encoded block length {len(encoded)} exceeds work capacity {self.work_capacity}")
        # Zero the tail only when it exists; this makes any bounded look-ahead
        # deterministic without imposing a full-buffer memset on every block.
        ctypes.memset(ctypes.byref(self.work, len(encoded)), 0, self.work_capacity - len(encoded))
        ctypes.memmove(self.work, encoded, len(encoded))
        pointer = ctypes.cast(self.work, ctypes.POINTER(ctypes.c_uint8))
        result = int(self.bindings.lib.bz3_decode_block(self.decode_state.ptr, pointer, self.work_capacity, len(encoded), raw_bytes))
        error = int(self.bindings.lib.bz3_last_error(self.decode_state.ptr))
        if result < 0 or error != 0:
            raise NativeBzip3Error(f"bzip3 decode failed (code={result}, error={error}): {self.bindings.strerror(self.decode_state.ptr)}")
        if result != raw_bytes:
            raise NativeBzip3Error(f"bzip3 returned decoded length {result}, expected {raw_bytes}")
        return ctypes.string_at(self.work, raw_bytes)


@dataclass(frozen=True)
class Bzip3ControlResult:
    frame: bytes
    input_bytes: int
    block_bytes: int
    block_count: int
    payload_bytes: int
    total_bytes: int
    input_sha256: str
    frame_sha256: str
    max_encoded_block: int
    scratch_bytes: int
    session_purpose: str = "both"
    retained_state_count: int = 2
    library_sha256: str = ""
    startup_ns: int | None = None
    encode_ns: int | None = None
    decode_ns: int | None = None
    random_block_ns: int | None = None
    random_block_index: int | None = None
    random_block_sha256: str | None = None

    def record(self) -> dict[str, int | str | None]:
        return {
            "input_bytes": self.input_bytes,
            "block_bytes": self.block_bytes,
            "block_count": self.block_count,
            "payload_bytes": self.payload_bytes,
            "framing_bytes": 32 + 16 * self.block_count,
            "total_bytes": self.total_bytes,
            "input_sha256": self.input_sha256,
            "frame_sha256": self.frame_sha256,
            "max_encoded_block": self.max_encoded_block,
            "conservative_scratch_bytes": self.scratch_bytes,
            "session_purpose": self.session_purpose,
            "retained_state_count": self.retained_state_count,
            "control_library_sha256": self.library_sha256,
            "startup_ns": self.startup_ns,
            "encode_ns": self.encode_ns,
            "decode_ns": self.decode_ns,
            "random_block_ns": self.random_block_ns,
            "random_block_index": self.random_block_index,
            "random_block_sha256": self.random_block_sha256,
            "control_only": "ctypes-native-bzip3",
        }


def _split_blocks(data: bytes, block_bytes: int) -> list[bytes]:
    if block_bytes <= 0 or block_bytes > MAX_NATIVE_BLOCK_BYTES:
        raise NativeBzip3Error("block_bytes must be positive")
    if len(data) > MAX_RAW_BYTES:
        raise NativeBzip3Error(f"input exceeds {MAX_RAW_BYTES} byte limit")
    block_count = 0 if not data else (len(data) - 1) // block_bytes + 1
    if block_count > MAX_BLOCKS:
        raise NativeBzip3Error(f"block count exceeds {MAX_BLOCKS}")
    return [data[start : start + block_bytes] for start in range(0, len(data), block_bytes)]


def bzip3_encode_blocks(data: bytes, block_bytes: int) -> bytes:
    """Encode independent native blocks and return complete framed bytes."""

    if not isinstance(data, bytes):
        data = bytes(data)
    raw_blocks = _split_blocks(data, block_bytes)
    if not raw_blocks:
        return frame_blocks([], [], block_bytes)
    with Bzip3Session(block_bytes, purpose="encode") as session:
        encoded = [session.encode_block(raw) for raw in raw_blocks]
    return frame_blocks(encoded, raw_blocks, block_bytes)


def bzip3_decode_block(frame: bytes | Bzip3Frame, index: int) -> bytes:
    """Decode one independently framed block with a fresh native decoder."""

    parsed = frame if isinstance(frame, Bzip3Frame) else open_frame(frame)
    record = parsed.block_record(index)
    with Bzip3Session(parsed.block_bytes, purpose="decode") as session:
        raw = session.decode_block(parsed.block_encoded(index), record.raw_bytes)
    if block_crc32(raw) != record.crc32:
        raise ExactRoundtripError(f"directory checksum mismatch for block {index}")
    return raw


def bzip3_decode(frame: bytes | Bzip3Frame) -> bytes:
    """Retained-state decode of every frame block with checksum validation."""

    parsed = frame if isinstance(frame, Bzip3Frame) else open_frame(frame)
    if not parsed.records:
        return b""
    output = bytearray()
    with Bzip3Session(parsed.block_bytes, purpose="decode") as session:
        for index, record in enumerate(parsed.records):
            raw = session.decode_block(parsed.block_encoded(index), record.raw_bytes)
            if block_crc32(raw) != record.crc32:
                raise ExactRoundtripError(f"directory checksum mismatch for block {index}")
            output.extend(raw)
    if len(output) != parsed.raw_bytes:
        raise ExactRoundtripError("frame output length mismatch")
    return bytes(output)


def bzip3_control(data: bytes, block_bytes: int, *, measure: bool = False) -> Bzip3ControlResult:
    """Encode, retained-decode, and deterministic random-block check a control.

    Timing is opt-in and intentionally not part of screening calls.  A caller
    must supply its own quiet-gate policy before setting ``measure=True``;
    this low-level helper never decides that a final benchmark is authorized.
    """

    if not isinstance(data, bytes):
        data = bytes(data)
    raw_blocks = _split_blocks(data, block_bytes)
    startup_ns: int | None = None
    encode_ns: int | None = None
    decode_ns: int | None = None
    random_ns: int | None = None
    random_index: int | None = None
    random_sha256: str | None = None
    startup_started = time.perf_counter_ns() if measure else 0
    session = Bzip3Session(block_bytes)
    scratch_bytes = session.scratch_bytes
    if measure:
        startup_ns = time.perf_counter_ns() - startup_started
    try:
        encode_started = time.perf_counter_ns() if measure else 0
        encoded = [session.encode_block(raw) for raw in raw_blocks]
        if measure:
            encode_ns = time.perf_counter_ns() - encode_started
        frame = frame_blocks(encoded, raw_blocks, block_bytes)
        parsed = open_frame(frame)
        decode_started = time.perf_counter_ns() if measure else 0
        decoded = bytearray()
        for index, record in enumerate(parsed.records):
            raw = session.decode_block(parsed.block_encoded(index), record.raw_bytes)
            if block_crc32(raw) != record.crc32:
                raise ExactRoundtripError(f"directory checksum mismatch for block {index}")
            decoded.extend(raw)
        if measure:
            decode_ns = time.perf_counter_ns() - decode_started
        if bytes(decoded) != data:
            raise ExactRoundtripError("retained-state control did not roundtrip exactly")
    finally:
        session.close()
    if raw_blocks:
        random_index = (len(raw_blocks) - 1) // 2
        random_started = time.perf_counter_ns() if measure else 0
        random = bzip3_decode_block(frame, random_index)
        if random != raw_blocks[random_index]:
            raise ExactRoundtripError(f"random block {random_index} did not roundtrip exactly")
        random_sha256 = hashlib.sha256(random).hexdigest()
        if measure:
            random_ns = time.perf_counter_ns() - random_started
    return Bzip3ControlResult(
        frame=frame,
        input_bytes=len(data),
        block_bytes=block_bytes,
        block_count=len(raw_blocks),
        payload_bytes=len(frame) - 32 - 16 * len(raw_blocks),
        total_bytes=len(frame),
        input_sha256=hashlib.sha256(data).hexdigest(),
        frame_sha256=hashlib.sha256(frame).hexdigest(),
        max_encoded_block=max((len(block) for block in encoded), default=0),
        scratch_bytes=scratch_bytes,
        session_purpose=session.purpose,
        retained_state_count=session.retained_state_count,
        library_sha256=_library_sha256(session.bindings.path),
        startup_ns=startup_ns,
        encode_ns=encode_ns,
        decode_ns=decode_ns,
        random_block_ns=random_ns,
        random_block_index=random_index,
        random_block_sha256=random_sha256,
    )


# Worker-friendly aliases.  They make it obvious that these are complete
# frames while keeping the candidate convention easy to import in smoke code.
encode = bzip3_encode_blocks
decode = bzip3_decode
decode_block = bzip3_decode_block


__all__ = [
    "MIN_NATIVE_BLOCK_BYTES",
    "MAX_NATIVE_BLOCK_BYTES",
    "LIBSAIS_ACCOUNTED_BYTES",
    "MAX_RAW_BYTES",
    "MAX_BLOCKS",
    "NativeBzip3Error",
    "ExactRoundtripError",
    "Bzip3Session",
    "Bzip3ControlResult",
    "load_bindings",
    "library_path",
    "control_library_record",
    "bzip3_bound",
    "bzip3_min_memory",
    "bzip3_encode_blocks",
    "bzip3_decode",
    "bzip3_decode_block",
    "bzip3_control",
    "encode",
    "decode",
    "decode_block",
]
