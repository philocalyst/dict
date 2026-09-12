"""Small, honest readers for the flat external-format baselines.

The benchmark oracle owns the answers; these adapters only build and read the
format they claim to measure.  In particular, none of the readers retain a
copy of :class:`~bench4.oracle.Fixture` in the artifact.  The only mapping
kept in memory is the ordinary format index (and an ID map needed because the
fixture deliberately uses sparse IDs).

The public factory returns StarDict/raw, SLOB/raw + SLOB/lzma2 when the SLOB
module is importable, and the local ``dict-index`` raw offset reader.  Rich
fixtures are intentionally not supported: these formats are flat key/content
containers and must never receive graph-capable labels by accident.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import struct
from pathlib import Path
from typing import Any

try:
    from .adapter import AdapterError, AdapterMetadata
    from .oracle import Entry, Fixture
except ImportError:  # pragma: no cover - direct script/test discovery
    from adapter import AdapterError, AdapterMetadata
    from oracle import Entry, Fixture


def _key_bytes(value: str) -> bytes:
    return value.encode("utf-8", "surrogatepass")


def _prefix_upper(prefix: bytes) -> bytes | None:
    if not prefix:
        return None
    result = bytearray(prefix)
    index = len(result) - 1
    while index >= 0 and result[index] == 0xFF:
        index -= 1
    if index < 0:
        return None
    result[index] += 1
    del result[index + 1 :]
    return bytes(result)


def _digest(value: Any) -> str:
    encoded = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


_IDS_MAGIC = b"LEX4-ID/1\0"


def _write_ids(path: Path, ids: list[int]) -> None:
    """Write the benchmark's explicit source-ID sidecar.

    StarDict and a local offset index do not have a source-ID field.  The
    sidecar makes that unavoidable projection explicit and measurable instead
    of letting the reader recover IDs from the Fixture object.  IDs are
    aligned with the format's record order and use a fixed-width signed
    representation so opening remains a bounded, deterministic operation.
    """

    if len(ids) != len(set(ids)):
        raise AdapterError("source-ID sidecar contains duplicate IDs")
    payload = bytearray(_IDS_MAGIC)
    payload.extend(struct.pack("<I", len(ids)))
    for ident in ids:
        payload.extend(struct.pack("<q", int(ident)))
    path.write_bytes(payload)


def _read_ids(path: Path) -> list[int]:
    raw = path.read_bytes()
    header = len(_IDS_MAGIC) + 4
    if len(raw) < header or raw[: len(_IDS_MAGIC)] != _IDS_MAGIC:
        raise AdapterError(f"invalid source-ID sidecar: {path.name}")
    count = struct.unpack("<I", raw[len(_IDS_MAGIC) : header])[0]
    expected = header + count * 8
    if len(raw) != expected:
        raise AdapterError(f"truncated source-ID sidecar: {path.name}")
    ids = [struct.unpack("<q", raw[offset : offset + 8])[0] for offset in range(header, expected, 8)]
    if len(ids) != len(set(ids)):
        raise AdapterError(f"source-ID sidecar contains duplicate IDs: {path.name}")
    return ids


class _FlatAdapter:
    """Common flat projection and the canonical rank/ID surface.

    Format-specific subclasses fill ``_records`` with ``(key, definition,
    source_id)`` tuples during :meth:`open`.  All public answers are then
    derived from that opened index, never from the fixture object.
    """

    def __init__(self, fixture: Fixture | None, *, label: str, implementation: str, note: str):
        if fixture is not None and (fixture.senses or fixture.concepts or fixture.relations):
            raise ValueError("flat external adapters cannot be constructed for the rich graph fixture")
        self.fixture = fixture
        self.metadata = AdapterMetadata(
            label=label,
            adapter_kind="external_format_adapter",
            implementation=implementation,
            native=False,
            projection="entry/key/definition (flat only)",
            note=note,
            timing_mode="host_operation",
        )
        self._artifact: Path | None = None
        self._files: dict[Path, str] = {}
        self._ranked: tuple[Entry, ...] = ()
        self._keys: tuple[bytes, ...] = ()
        self._by_id: dict[int, Entry] = {}
        self._positions: dict[int, int] = {}
        self._row_by_id: dict[int, tuple[str, int, int, int]] = {}
        self._by_key: dict[bytes, tuple[int, ...]] = {}
        self._records: tuple[tuple[str, bytes, int], ...] = ()

    def _remember_files(self, artifact: Path) -> None:
        root = artifact.parent
        self._files = {
            path: _file_digest(path)
            for path in root.rglob("*")
            if path.is_file() and not path.is_symlink()
        }

    def _check_files(self) -> None:
        if not self._files:
            raise AdapterError(f"{self.metadata.label} was not opened")
        current = {
            path: _file_digest(path)
            for path in self._files
            if path.is_file() and not path.is_symlink()
        }
        if current != self._files:
            raise AdapterError(f"{self.metadata.label} artifact bytes changed")

    def _finish_open(self, artifact: Path, records: list[tuple[str, bytes, int]]) -> None:
        if not records:
            raise AdapterError(f"{self.metadata.label} contains no records")
        observed_ids = [ident for _, _, ident in records]
        if len(observed_ids) != len(set(observed_ids)):
            raise AdapterError(f"{self.metadata.label} contains duplicate source IDs")
        ranked = sorted(
            (Entry(ident, key, definition) for key, definition, ident in records),
            key=lambda entry: (_key_bytes(entry.key), entry.ident),
        )
        self._records = tuple(records)
        self._ranked = tuple(ranked)
        self._keys = tuple(_key_bytes(entry.key) for entry in ranked)
        self._by_id = {entry.ident: entry for entry in ranked}
        self._positions = {entry.ident: index for index, entry in enumerate(ranked)}
        # Format subclasses may populate this with their offset rows after
        # parsing.  Keeping the hook here makes source-ID lookup explicit and
        # avoids a hidden scan in render().
        self._row_by_id = {}
        grouped: dict[bytes, list[int]] = {}
        for entry in ranked:
            grouped.setdefault(_key_bytes(entry.key), []).append(entry.ident)
        self._by_key = {key: tuple(values) for key, values in grouped.items()}
        self._artifact = artifact
        self._remember_files(artifact)

    def _ids_path(self, artifact: Path) -> Path:
        return artifact.with_name("source-ids.bin")

    def close(self) -> None:
        self._files = {}
        self._ranked = ()
        self._keys = ()
        self._by_id = {}
        self._positions = {}
        self._row_by_id = {}
        self._by_key = {}

    def verify(self) -> None:
        self._check_files()
        if self._artifact is None or not self._artifact.is_file():
            raise AdapterError(f"{self.metadata.label} verify called before open")
        self._verify_format()

    def _verify_format(self) -> None:
        """Subclass hook for format-level checks."""

    def _interval(self, prefix: str) -> tuple[int, int]:
        needle = _key_bytes(prefix)
        lo = bisect.bisect_left(self._keys, needle)
        upper = _prefix_upper(needle)
        hi = len(self._ranked) if upper is None else bisect.bisect_left(self._keys, upper)
        # Keep the contract defensive if a future format applies a key
        # normalisation rather than storing the exact UTF-8 spelling.
        while lo < hi and not self._ranked[lo].key.startswith(prefix):
            lo += 1
        while hi > lo and not self._ranked[hi - 1].key.startswith(prefix):
            hi -= 1
        return lo, hi

    def exact(self, key: str) -> list[int]:
        return list(self._by_key.get(_key_bytes(key), ()))

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        return self._interval(prefix)

    def prefix_enumerate(self, prefix: str) -> list[int]:
        lo, hi = self._interval(prefix)
        return [entry.ident for entry in self._ranked[lo:hi]]

    def select(self, rank: int) -> dict[str, object]:
        try:
            entry = self._ranked[rank]
        except IndexError as exc:
            raise AdapterError(f"rank {rank} outside reader range") from exc
        return {"op": "select", "id": entry.ident, "key": entry.key, "rank": rank}

    def render(self, ident: int) -> bytes:
        try:
            return self._by_id[ident].definition
        except KeyError as exc:
            raise AdapterError(f"unknown entry ID {ident}") from exc

    def snippet(self, ident: int, limit: int) -> bytes:
        if limit < 0:
            raise AdapterError("snippet limit cannot be negative")
        return self.render(ident)[:limit]

    # Flat external formats have no graph projection.  These methods are
    # deliberately present to satisfy the narrow adapter protocol, but graph
    # fixtures are rejected by construction and run.py marks them unavailable.
    def concept_members(self, ident: int) -> list[int]:
        return []

    def translations(self, ident: int, language: str) -> list[int]:
        return []

    def relations(self, ident: int, predicate: str) -> list[dict[str, object]]:
        return []

    def structure_checksum(self) -> str:
        payload = {"ranked": [(entry.ident, entry.key) for entry in self._ranked], "senses": [], "concepts": [], "relations": []}
        return _digest(payload)

    def query_checksum(self, operations: object) -> str:
        raise AdapterError("external adapters do not accept a benchmark schedule preflight")


class StarDictAdapter(_FlatAdapter):
    """A real StarDict 2.4.2 raw ``.ifo/.idx/.dict`` bundle."""

    def __init__(self, fixture: Fixture | None, *, label: str = "stardict/adapter"):
        super().__init__(
            fixture,
            label=label,
            implementation="python-stardict-raw",
            note="StarDict 2.4.2 raw index/data; gzip is intentionally not claimed as random-access dictzip.",
        )
        self._index: Path | None = None
        self._index_rows: tuple[tuple[str, int, int, int], ...] = ()
        self._index_keys: tuple[bytes, ...] = ()

    def build(self, artifact: Path) -> None:
        fixture = self.fixture
        if fixture is None:
            raise AdapterError("StarDict build requires a Fixture; open is artifact-only")
        artifact.parent.mkdir(parents=True, exist_ok=True)
        index = artifact.with_name("stardict.idx")
        info = artifact.with_name("stardict.ifo")
        ids_path = self._ids_path(artifact)
        ordered = sorted(fixture.entries, key=lambda entry: (_key_bytes(entry.key), entry.ident))
        offset = 0
        index_bytes = bytearray()
        payload = bytearray()
        for entry in ordered:
            key = _key_bytes(entry.key)
            index_bytes.extend(key + b"\0" + struct.pack(">II", offset, len(entry.definition)))
            payload.extend(entry.definition)
            offset += len(entry.definition)
        artifact.write_bytes(bytes(payload))
        index.write_bytes(bytes(index_bytes))
        _write_ids(ids_path, [entry.ident for entry in ordered])
        info.write_text(
            "\n".join(
                (
                    "StarDict's dict ifo file",
                    "version=2.4.2",
                    f"wordcount={len(ordered)}",
                    f"idxfilesize={len(index_bytes)}",
                    "bookname=lex4-bench4",
                    "sametypesequence=m",
                    "",
                )
            ),
            encoding="utf-8",
        )

    def open(self, artifact: Path) -> None:
        index = artifact.with_name("stardict.idx")
        info = artifact.with_name("stardict.ifo")
        ids_path = self._ids_path(artifact)
        try:
            raw = index.read_bytes()
            records: list[tuple[str, bytes, int]] = []
            rows: list[tuple[str, int, int, int]] = []
            at = 0
            payload = artifact.read_bytes()
            ids = _read_ids(ids_path)
            record_index = 0
            while at < len(raw):
                end = raw.index(b"\0", at)
                key = raw[at:end].decode("utf-8")
                if end + 9 > len(raw):
                    raise AdapterError("truncated StarDict index record")
                offset, length = struct.unpack(">II", raw[end + 1 : end + 9])
                if offset + length > len(payload):
                    raise AdapterError("StarDict data offset outside payload")
                if record_index >= len(ids):
                    raise AdapterError("StarDict index has more records than source-ID sidecar")
                rows.append((key, offset, length, ids[record_index]))
                records.append((key, payload[offset : offset + length], ids[record_index]))
                record_index += 1
                at = end + 9
            if record_index != len(ids):
                raise AdapterError("source-ID sidecar has more records than StarDict index")
        except (OSError, UnicodeError, ValueError, IndexError, struct.error) as exc:
            raise AdapterError(f"cannot open StarDict bundle: {exc}") from exc
        if not info.is_file():
            raise AdapterError("StarDict .ifo sidecar is missing")
        self._index = index
        self._index_rows = tuple(rows)
        self._index_keys = tuple(_key_bytes(row[0]) for row in rows)
        self._finish_open(artifact, records)
        self._row_by_id = {row[3]: row for row in rows}

    def exact(self, key: str) -> list[int]:
        needle = _key_bytes(key)
        lo = bisect.bisect_left(self._index_keys, needle)
        out: list[int] = []
        while lo < len(self._index_rows) and self._index_keys[lo] == needle:
            out.append(self._index_rows[lo][3])
            lo += 1
        return sorted(out, key=self._positions.__getitem__)

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        # The format's index order is the canonical rank order for this
        # adapter, so this is the actual bounded index operation.
        keys = self._index_keys
        needle = _key_bytes(prefix)
        lo = bisect.bisect_left(keys, needle)
        upper = _prefix_upper(needle)
        hi = len(keys) if upper is None else bisect.bisect_left(keys, upper)
        while lo < hi and not self._index_rows[lo][0].startswith(prefix):
            lo += 1
        while hi > lo and not self._index_rows[hi - 1][0].startswith(prefix):
            hi -= 1
        return lo, hi

    def prefix_enumerate(self, prefix: str) -> list[int]:
        lo, hi = self.prefix_interval(prefix)
        return [self._index_rows[index][3] for index in range(lo, hi)]

    def render(self, ident: int) -> bytes:
        try:
            _, offset, length, _ = self._row_by_id[ident]
        except KeyError as exc:
            raise AdapterError(f"unknown entry ID {ident}") from exc
        if self._artifact is None:
            raise AdapterError("StarDict render before open")
        with self._artifact.open("rb") as stream:
            stream.seek(offset)
            return stream.read(length)

    def _verify_format(self) -> None:
        if self._index is None or not self._index.is_file():
            raise AdapterError("StarDict index is not open")


class OffsetIndexAdapter(_FlatAdapter):
    """The local deterministic ``dict-index`` raw offset baseline."""

    def __init__(self, fixture: Fixture | None, *, label: str = "dict-index/adapter"):
        super().__init__(
            fixture,
            label=label,
            implementation="python-offset-index-raw",
            note="Local UTF-8 sorted offset index; this is not a dictd daemon or dictzip reader.",
        )
        self._index: Path | None = None
        self._index_rows: tuple[tuple[str, int, int, int], ...] = ()
        self._index_keys: tuple[bytes, ...] = ()

    def build(self, artifact: Path) -> None:
        fixture = self.fixture
        if fixture is None:
            raise AdapterError("dict-index build requires a Fixture; open is artifact-only")
        artifact.parent.mkdir(parents=True, exist_ok=True)
        index = artifact.with_name("offset.index")
        ids_path = self._ids_path(artifact)
        ordered = sorted(fixture.entries, key=lambda entry: (_key_bytes(entry.key), entry.ident))
        offset = 0
        lines: list[str] = []
        with artifact.open("wb") as stream:
            for entry in ordered:
                stream.write(entry.definition)
                lines.append(f"{entry.key}\t{offset}\t{len(entry.definition)}\n")
                offset += len(entry.definition)
        index.write_text("".join(lines), encoding="utf-8")
        _write_ids(ids_path, [entry.ident for entry in ordered])

    def open(self, artifact: Path) -> None:
        index = artifact.with_name("offset.index")
        ids_path = self._ids_path(artifact)
        try:
            payload = artifact.read_bytes()
            records: list[tuple[str, bytes, int]] = []
            rows: list[tuple[str, int, int, int]] = []
            ids = _read_ids(ids_path)
            for row_index, line in enumerate(index.read_text(encoding="utf-8").splitlines()):
                key, raw_offset, raw_length = line.split("\t")
                offset, length = int(raw_offset), int(raw_length)
                if offset < 0 or length < 0 or offset + length > len(payload):
                    raise AdapterError("offset index points outside payload")
                if row_index >= len(ids):
                    raise AdapterError("offset index has more records than source-ID sidecar")
                ident = ids[row_index]
                rows.append((key, offset, length, ident))
                records.append((key, payload[offset : offset + length], ident))
            if len(rows) != len(ids):
                raise AdapterError("source-ID sidecar has more records than offset index")
        except (OSError, UnicodeError, ValueError) as exc:
            raise AdapterError(f"cannot open local dict-index bundle: {exc}") from exc
        self._index = index
        self._index_rows = tuple(rows)
        self._index_keys = tuple(_key_bytes(row[0]) for row in rows)
        self._finish_open(artifact, records)
        self._row_by_id = {row[3]: row for row in rows}

    def exact(self, key: str) -> list[int]:
        needle = _key_bytes(key)
        lo = bisect.bisect_left(self._index_keys, needle)
        out: list[int] = []
        while lo < len(self._index_rows) and self._index_keys[lo] == needle:
            out.append(self._index_rows[lo][3])
            lo += 1
        return sorted(out, key=self._positions.__getitem__)

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        keys = self._index_keys
        needle = _key_bytes(prefix)
        lo = bisect.bisect_left(keys, needle)
        upper = _prefix_upper(needle)
        hi = len(keys) if upper is None else bisect.bisect_left(keys, upper)
        while lo < hi and not self._index_rows[lo][0].startswith(prefix):
            lo += 1
        while hi > lo and not self._index_rows[hi - 1][0].startswith(prefix):
            hi -= 1
        return lo, hi

    def prefix_enumerate(self, prefix: str) -> list[int]:
        lo, hi = self.prefix_interval(prefix)
        return [self._index_rows[index][3] for index in range(lo, hi)]

    def render(self, ident: int) -> bytes:
        try:
            _, offset, length, _ = self._row_by_id[ident]
        except KeyError as exc:
            raise AdapterError(f"unknown entry ID {ident}") from exc
        if self._artifact is None:
            raise AdapterError("dict-index render before open")
        with self._artifact.open("rb") as stream:
            stream.seek(offset)
            return stream.read(length)

    def _verify_format(self) -> None:
        if self._index is None or not self._index.is_file():
            raise AdapterError("dict-index index is not open")


class SlobAdapter(_FlatAdapter):
    """SLOB reader with an optional LZMA2 payload variant."""

    def __init__(self, fixture: Fixture | None, *, compression: str | None, label: str):
        implementation = "python-slob" + ("-lzma2" if compression else "-raw")
        super().__init__(
            fixture,
            label=label,
            implementation=implementation,
            note="SLOB flat key/content reader; graph fields are intentionally outside this profile.",
        )
        self.compression = compression
        self._reader: Any = None
        self._ref_by_id: dict[int, int] = {}
        self._entry_by_content_id: dict[int, int] = {}

    @staticmethod
    def available() -> tuple[bool, str]:
        try:
            import slob  # type: ignore
        except ImportError as exc:
            return False, f"Python SLOB import failed: {exc}"
        return True, ""

    def build(self, artifact: Path) -> None:
        fixture = self.fixture
        if fixture is None:
            raise AdapterError("SLOB build requires a Fixture; open is artifact-only")
        try:
            import slob  # type: ignore
        except ImportError as exc:
            raise AdapterError(f"Python SLOB import failed: {exc}") from exc
        artifact.parent.mkdir(parents=True, exist_ok=True)
        with slob.create(str(artifact), compression=self.compression, min_bin_size=64 * 1024) as writer:
            for entry in fixture.entries:
                writer.add(entry.definition, entry.key, content_type="text/plain")
        # SLOB exposes its sorted key index on reopen, independent of the
        # insertion order used by the writer.  Keep the counted ID sidecar in
        # that reader order so no Fixture lookup is needed by ``open``.
        ordered = sorted(fixture.entries, key=lambda entry: (_key_bytes(entry.key), entry.ident))
        _write_ids(self._ids_path(artifact), [entry.ident for entry in ordered])

    def open(self, artifact: Path) -> None:
        try:
            import slob  # type: ignore
            reader = slob.open(str(artifact))
            records: list[tuple[str, bytes, int]] = []
            ids = _read_ids(self._ids_path(artifact))
            if len(reader) != len(ids):
                raise AdapterError("SLOB record count does not match source-ID sidecar")
            self._ref_by_id = {}
            self._entry_by_content_id = {}
            for ref_index in range(len(reader)):
                item = reader[ref_index]
                key = str(item.key)
                content = bytes(item.content)
                ident = ids[ref_index]
                self._ref_by_id[ident] = ref_index
                self._entry_by_content_id[int(item.id)] = ident
                records.append((key, content, ident))
            self._reader = reader
            self._finish_open(artifact, records)
        except AdapterError:
            if self._reader is not None:
                self._reader.close()
                self._reader = None
            raise
        except (OSError, UnicodeError, ValueError, IndexError) as exc:
            raise AdapterError(f"cannot open SLOB bundle: {exc}") from exc

    def close(self) -> None:
        reader, self._reader = self._reader, None
        if reader is not None:
            reader.close()
        super().close()

    def render(self, ident: int) -> bytes:
        if self._reader is None:
            raise AdapterError("SLOB render before open")
        try:
            return bytes(self._reader[self._ref_by_id[ident]].content)
        except KeyError as exc:
            raise AdapterError(f"unknown entry ID {ident}") from exc

    def exact(self, key: str) -> list[int]:
        if self._reader is None:
            raise AdapterError("SLOB exact before open")
        values = [self._id_for_ref(item.id) for _, item in self._find(key, match_prefix=False) if str(item.key) == key]
        return sorted(values, key=self._positions.__getitem__)

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        if self._reader is None:
            raise AdapterError("SLOB prefix interval before open")
        # SLOB's reopened index is already in the same UTF-8 key/rank order
        # used by the oracle.  Keep interval lookup a genuine bounded index
        # operation; calling prefix_enumerate here would silently charge a
        # complete result walk to the interval timing class.
        return self._interval(prefix)

    def prefix_enumerate(self, prefix: str) -> list[int]:
        if self._reader is None:
            raise AdapterError("SLOB prefix before open")
        values = [self._id_for_ref(item.id) for _, item in self._find(prefix, match_prefix=True) if str(item.key).startswith(prefix)]
        return sorted(values, key=self._positions.__getitem__)

    def _find(self, key: str, *, match_prefix: bool):
        import slob  # type: ignore

        return slob.find(key, self._reader, match_prefix=match_prefix)

    def _id_for_ref(self, content_id: int) -> int:
        try:
            return self._entry_by_content_id[int(content_id)]
        except KeyError as exc:
            raise AdapterError(f"unknown SLOB content ID {content_id}") from exc

    def _verify_format(self) -> None:
        if self._reader is None:
            raise AdapterError("SLOB reader is not open")


def external_adapters(fixture: Fixture) -> list[object]:
    """Return current external profiles, including honest unavailable rows."""

    if fixture.name == "rich":
        return []
    values: list[object] = [StarDictAdapter(fixture), OffsetIndexAdapter(fixture)]
    available, reason = SlobAdapter.available()
    if available:
        values.extend(
            (
                SlobAdapter(fixture, compression=None, label="slob/adapter"),
                SlobAdapter(fixture, compression="lzma2", label="slob/adapter-lzma2"),
            )
        )
    else:
        try:
            from .adapter import UnavailableAdapter
        except ImportError:  # pragma: no cover - direct script execution
            from adapter import UnavailableAdapter

        values.extend(
            (
                UnavailableAdapter("slob/adapter", reason),
                UnavailableAdapter("slob/adapter-lzma2", reason),
            )
        )
    return values


__all__ = [
    "OffsetIndexAdapter",
    "SlobAdapter",
    "StarDictAdapter",
    "external_adapters",
]
