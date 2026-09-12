#!/usr/bin/env python3
"""Reader adapters used by the LEX4 benchmark harness.

The adapters are intentionally behind a narrow interface.  The oracle never
calls these classes and these classes never call oracle answer methods.  A
reference adapter is useful before a native ``src4`` reader exists, but it is
always labelled as a reference adapter in reports.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import os
import selectors
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

try:  # Package import (``bench4.adapter``) and direct test discovery both work.
    from .oracle import Entry, Fixture, Operation
except ImportError:  # pragma: no cover - exercised by unittest discovery path
    from oracle import Entry, Fixture, Operation


class AdapterError(RuntimeError):
    """An adapter could not complete its declared operation."""


class SemanticMismatch(AdapterError):
    """An adapter answered a semantically checked operation incorrectly."""


@dataclass(frozen=True, slots=True)
class AdapterMetadata:
    label: str
    adapter_kind: str
    implementation: str
    native: bool
    projection: str = "entry/key/definition"
    note: str = ""
    timing_mode: str = "host_operation"

    def as_dict(self) -> dict[str, object]:
        return {
            "label": self.label,
            "adapter_kind": self.adapter_kind,
            "implementation": self.implementation,
            "native": self.native,
            "projection": self.projection,
            "note": self.note,
            "timing_mode": self.timing_mode,
        }


class Adapter(Protocol):
    metadata: AdapterMetadata

    def build(self, artifact: Path) -> None: ...
    def open(self, artifact: Path) -> None: ...
    def verify(self) -> None: ...
    def close(self) -> None: ...
    def exact(self, key: str) -> list[int]: ...
    def prefix_interval(self, prefix: str) -> tuple[int, int]: ...
    def prefix_enumerate(self, prefix: str) -> list[int]: ...
    def select(self, rank: int) -> dict[str, object]: ...
    def render(self, ident: int) -> bytes: ...
    def snippet(self, ident: int, limit: int) -> bytes: ...
    def concept_members(self, ident: int) -> list[int]: ...
    def translations(self, ident: int, language: str) -> list[int]: ...
    def relations(self, ident: int, predicate: str) -> list[dict[str, object]]: ...
    def structure_checksum(self) -> str: ...
    def query_checksum(self, operations: tuple[Operation, ...]) -> str: ...


def _key_bytes(value: str) -> bytes:
    return value.encode("utf-8", "surrogatepass")


def _prefix_upper(prefix: bytes) -> bytes | None:
    if not prefix:
        return None
    value = bytearray(prefix)
    index = len(value) - 1
    while index >= 0 and value[index] == 0xFF:
        index -= 1
    if index < 0:
        return None
    value[index] += 1
    del value[index + 1 :]
    return bytes(value)


def _response_digest(value: Any) -> str:
    if isinstance(value, bytes):
        data = value
    else:
        data = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    return hashlib.sha256(data).hexdigest()


class ReferenceAdapter:
    """Independent sorted-list adapter used as a labelled mock/reference."""

    def __init__(self, fixture: Fixture, *, label: str = "lex4-reference-mock", implementation: str = "python-reference"):
        self.fixture = fixture
        self.metadata = AdapterMetadata(
            label=label,
            adapter_kind="reference_adapter",
            implementation=implementation,
            native=False,
            note="Independent semantic reference/mock; not a native LEX4 implementation.",
        )
        self._ranked: tuple[Entry, ...] = ()
        self._keys: tuple[bytes, ...] = ()
        self._by_id: dict[int, Entry] = {}
        self._senses: dict[int, Any] = {}
        self._concepts: dict[int, Any] = {}
        self._relations: tuple[Any, ...] = ()
        self._artifact: Path | None = None

    def build(self, artifact: Path) -> None:
        artifact.parent.mkdir(parents=True, exist_ok=True)
        # The encoded reference artifact intentionally contains every semantic
        # field, not only fields needed by the flat query projection.  It gives
        # the size ledger a complete byte target and makes omission detectable.
        value = {
            "format": "LEX4-REFERENCE-1",
            "fixture": self.fixture.canonical(),
        }
        encoded = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        temporary = artifact.with_name(artifact.name + ".tmp")
        temporary.write_bytes(encoded)
        os.replace(temporary, artifact)
        self._artifact = artifact

    def open(self, artifact: Path) -> None:
        try:
            value = json.loads(artifact.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise AdapterError(f"reference artifact cannot be opened: {artifact}: {exc}") from exc
        if value.get("format") != "LEX4-REFERENCE-1":
            raise AdapterError(f"unexpected reference artifact format: {artifact}")
        self._ranked = tuple(sorted(self.fixture.entries, key=lambda entry: (_key_bytes(entry.key), entry.ident)))
        self._keys = tuple(_key_bytes(entry.key) for entry in self._ranked)
        self._by_id = {entry.ident: entry for entry in self.fixture.entries}
        self._senses = {sense.ident: sense for sense in self.fixture.senses}
        self._concepts = {concept.ident: concept for concept in self.fixture.concepts}
        self._relations = tuple(self.fixture.relations)
        self._artifact = artifact

    def verify(self) -> None:
        if self._artifact is None or not self._artifact.is_file():
            raise AdapterError("reference verify called before open")
        # Verify the bytes are still the artifact we would have written.  This
        # catches a staged artifact being replaced between open and verify.
        value = json.loads(self._artifact.read_text(encoding="utf-8"))
        expected = {"format": "LEX4-REFERENCE-1", "fixture": self.fixture.canonical()}
        if value != expected:
            raise AdapterError("reference artifact semantic content changed")

    def close(self) -> None:
        return None

    def exact(self, key: str) -> list[int]:
        needle = _key_bytes(key)
        return [entry.ident for entry in self._ranked if _key_bytes(entry.key) == needle]

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        needle = _key_bytes(prefix)
        lo = bisect.bisect_left(self._keys, needle)
        upper = _prefix_upper(needle)
        hi = len(self._ranked) if upper is None else bisect.bisect_left(self._keys, upper)
        while lo < hi and not self._ranked[lo].key.startswith(prefix):
            lo += 1
        while hi > lo and not self._ranked[hi - 1].key.startswith(prefix):
            hi -= 1
        return lo, hi

    def prefix_enumerate(self, prefix: str) -> list[int]:
        lo, hi = self.prefix_interval(prefix)
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
            raise AdapterError(f"unknown reference entry {ident}") from exc

    def snippet(self, ident: int, limit: int) -> bytes:
        return self.render(ident)[:limit]

    def concept_members(self, ident: int) -> list[int]:
        concept = self._concepts.get(ident)
        return list(concept.members) if concept is not None else []

    def translations(self, ident: int, language: str) -> list[int]:
        sense = self._senses.get(ident)
        if sense is None or sense.concept_id is None:
            return []
        members = self.concept_members(sense.concept_id)
        return [
            member
            for member in members
            if member != ident and (not language or self._senses.get(member) is not None and self._senses[member].language == language)
        ]

    def relations(self, ident: int, predicate: str) -> list[dict[str, object]]:
        return [
            relation.canonical()
            for relation in self._relations
            if relation.source == ident and (not predicate or relation.predicate == predicate)
        ]

    def structure_checksum(self) -> str:
        value = {
            "ranked": [(entry.ident, entry.key) for entry in self._ranked],
            "senses": [sense.canonical() for sense in sorted(self._senses.values(), key=lambda item: item.ident)],
            "concepts": [concept.canonical() for concept in sorted(self._concepts.values(), key=lambda item: item.ident)],
            "relations": [relation.canonical() for relation in sorted(self._relations, key=lambda item: (item.source, item.predicate, item.target))],
        }
        return _response_digest(value)

    def query_checksum(self, operations: tuple[Operation, ...]) -> str:
        # This is intentionally an adapter-side computation, not a call to
        # Oracle.query_checksum; the harness compares the two independently.
        value: list[object] = []
        for operation in operations:
            if operation.op == "exact":
                value.append((operation.op, operation.key, self.exact(operation.key)))
            elif operation.op == "prefix_interval":
                value.append((operation.op, operation.key, self.prefix_interval(operation.key)))
            elif operation.op == "prefix_enumerate":
                value.append((operation.op, operation.key, self.prefix_interval(operation.key), self.prefix_enumerate(operation.key)))
            elif operation.op == "select":
                value.append((operation.op, self.select(operation.ident or 0)))
            elif operation.op == "render":
                value.append((operation.op, operation.ident, operation.limit, self.render(operation.ident or 0).hex()))
            elif operation.op == "snippet":
                value.append((operation.op, operation.ident, operation.limit, self.snippet(operation.ident or 0, operation.limit or 0).hex()))
            elif operation.op == "concept_members":
                value.append((operation.op, operation.ident, self.concept_members(operation.ident or 0)))
            elif operation.op == "translations":
                value.append((operation.op, operation.ident, operation.language, self.translations(operation.ident or 0, operation.language or "")))
            elif operation.op == "relations":
                value.append((operation.op, operation.ident, operation.predicate, self.relations(operation.ident or 0, operation.predicate or "")))
            else:
                raise AdapterError(f"unknown operation {operation.op!r}")
        return _response_digest(value)


class SQLiteAdapter(ReferenceAdapter):
    """Measured SQLite artifact adapter.

    The artifact is a real SQLite file and the reader builds its sorted view
    from SQL rows at open.  The adapter remains explicitly external; timings
    must never be presented as native LEX4 numbers.
    """

    def __init__(self, fixture: Fixture, *, label: str = "sqlite/adapter"):
        super().__init__(fixture, label=label, implementation="python-sqlite3")
        self.metadata = AdapterMetadata(
            label=label,
            adapter_kind="external_format_adapter",
            implementation="python-sqlite3",
            native=False,
            note="Measured SQLite adapter; Python wrapper/interpreter overhead is included.",
        )
        self._db: sqlite3.Connection | None = None

    def build(self, artifact: Path) -> None:
        artifact.parent.mkdir(parents=True, exist_ok=True)
        temporary = artifact.with_name(artifact.name + ".tmp")
        if temporary.exists():
            temporary.unlink()
        with sqlite3.connect(temporary) as db:
            db.execute("PRAGMA journal_mode=OFF")
            db.execute("PRAGMA synchronous=OFF")
            db.execute("CREATE TABLE entries (id INTEGER PRIMARY KEY, key TEXT NOT NULL, definition BLOB NOT NULL, language TEXT NOT NULL, homograph INTEGER NOT NULL)")
            db.executemany(
                "INSERT INTO entries(id,key,definition,language,homograph) VALUES(?,?,?,?,?)",
                [(entry.ident, entry.key, entry.definition, entry.language, int(entry.homograph)) for entry in self.fixture.entries],
            )
            db.execute("CREATE INDEX entries_key_id ON entries(key COLLATE BINARY, id)")
            db.commit()
        os.replace(temporary, artifact)
        self._artifact = artifact

    def open(self, artifact: Path) -> None:
        try:
            self._db = sqlite3.connect(artifact)
            rows = self._db.execute("SELECT id,key,definition,language,homograph FROM entries ORDER BY key COLLATE BINARY, id").fetchall()
        except sqlite3.Error as exc:
            raise AdapterError(f"cannot open SQLite artifact {artifact}: {exc}") from exc
        self._ranked = tuple(Entry(int(row[0]), str(row[1]), bytes(row[2]), str(row[3]), homograph=bool(row[4])) for row in rows)
        self._keys = tuple(_key_bytes(entry.key) for entry in self._ranked)
        self._by_id = {entry.ident: entry for entry in self._ranked}
        self._artifact = artifact

    def verify(self) -> None:
        if self._db is None:
            raise AdapterError("SQLite verify called before open")
        count = int(self._db.execute("SELECT count(*) FROM entries").fetchone()[0])
        if count != len(self.fixture.entries):
            raise AdapterError(f"SQLite cardinality mismatch: {count} != {len(self.fixture.entries)}")

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None


class SubprocessAdapter:
    """Deterministic JSON-lines contract for a future/native LEX4 executable.

    Build and verify are separate CLI phases. Build receives only fixture
    input (the escaped TSV projection), never oracle answers. Query responses
    are one JSON object per request on a long-lived server process, so the
    timed boundary can be exactly one request/response operation. Every
    request carries a monotonically increasing request id and deterministic
    sample nonce; the response must echo both. ``query_checksum`` is
    intentionally not a wire operation because sending a complete schedule
    before timing permits precomputation or cache priming.
    """

    PROTOCOL = "LEX4-BENCH/1"
    READY_TIMEOUT_SECONDS = 30.0

    def __init__(
        self,
        fixture: Fixture,
        command: list[str],
        *,
        corpus: Path | None = None,
        fixture_json: Path | None = None,
        label: str = "lex4-native",
        implementation: str = "external-command",
        projection: str = "entry/key/definition; rich graph/concepts/relations when fixture=rich",
        note: str = "Native status is a caller assertion; executable hash is recorded in provenance. Protocol inputs contain fixture data and query fields only, never expected answers.",
    ):
        if not command:
            raise ValueError("native command cannot be empty")
        self.fixture = fixture
        self.command = list(command)
        self.corpus = corpus
        self.fixture_json = fixture_json
        self.metadata = AdapterMetadata(
            label=label,
            adapter_kind="native_implementation",
            implementation=implementation,
            native=True,
            projection=projection,
            note=note,
            timing_mode="native_self_timed",
        )
        self._process: subprocess.Popen[str] | None = None
        self._artifact: Path | None = None
        self._request_id = 0
        self._sample = 0

    def set_sample(self, sample: int) -> None:
        """Set the harness nonce used by the next operation request."""

        self._sample = int(sample)

    def _operation(self, op: str, **fields: object) -> Operation:
        return Operation(op, sample=self._sample, **fields)

    def _run_phase(self, args: list[str]) -> None:
        process = subprocess.run(self.command + args, check=False, text=True, capture_output=True)
        if process.returncode != 0:
            raise AdapterError(f"native phase failed ({process.returncode}): {process.stderr.strip() or process.stdout.strip()}")

    def build(self, artifact: Path) -> None:
        artifact.parent.mkdir(parents=True, exist_ok=True)
        args = ["--bench4-build", "--fixture", self.fixture.name, "--records", str(len(self.fixture.entries))]
        if self.corpus is not None:
            args.extend(("--corpus", str(self.corpus)))
        if self.fixture_json is not None:
            args.extend(("--semantic-input", str(self.fixture_json)))
        args.extend(("--output", str(artifact)))
        self._run_phase(args)
        if not artifact.is_file() or artifact.stat().st_size <= 0:
            raise AdapterError(f"native build produced no non-empty artifact: {artifact}")
        self._artifact = artifact

    def open(self, artifact: Path) -> None:
        self._artifact = artifact
        self._request_id = 0
        self._process = subprocess.Popen(
            self.command + ["--bench4-server", "--artifact", str(artifact)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="strict",
            bufsize=1,
            close_fds=True,
        )
        if self._process.poll() is not None:
            raise AdapterError("native server exited while opening")
        assert self._process.stdout is not None
        selector = selectors.DefaultSelector()
        try:
            selector.register(self._process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=self.READY_TIMEOUT_SECONDS):
                raise AdapterError(
                    f"native server did not become ready within {self.READY_TIMEOUT_SECONDS:g} seconds"
                )
            line = self._process.stdout.readline()
            if not line:
                error = self._process.stderr.read().strip() if self._process.stderr is not None else ""
                raise AdapterError(f"native server exited before readiness: {error}")
            try:
                ready = json.loads(line)
            except json.JSONDecodeError as exc:
                raise AdapterError(f"native readiness event is not JSON: {line!r}") from exc
            expected_bytes = artifact.stat().st_size
            if (
                not isinstance(ready, dict)
                or set(ready) != {"protocol", "event", "artifact_bytes"}
                or ready.get("protocol") != self.PROTOCOL
                or ready.get("event") != "ready"
                or type(ready.get("artifact_bytes")) is not int
                or ready.get("artifact_bytes") != expected_bytes
            ):
                raise AdapterError(
                    f"native readiness mismatch for {expected_bytes}-byte artifact: {ready!r}"
                )
        except Exception:
            process = self._process
            self._process = None
            if process is not None:
                process.kill()
                process.wait(timeout=5)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
            raise
        finally:
            selector.close()

    def verify(self) -> None:
        if self._artifact is None:
            raise AdapterError("native verify called before open")
        self._run_phase(["--bench4-verify", "--artifact", str(self._artifact)])

    def close(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return None
        try:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            try:
                returncode = process.wait(timeout=5)
            except subprocess.TimeoutExpired as exc:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
                raise AdapterError("native server did not exit after stdin close") from exc
            if returncode != 0:
                stderr = process.stderr.read().strip() if process.stderr is not None else ""
                raise AdapterError(f"native server exited with status {returncode}: {stderr}")
        finally:
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()

    def _request_envelope(self, operation: Operation, *, timing_mode: str | None = None) -> tuple[dict[str, object], int | None]:
        if self._process is None or self._process.stdin is None or self._process.stdout is None:
            raise AdapterError("native query before server open")
        request_id = self._request_id
        self._request_id += 1
        # ``category`` is benchmark bookkeeping and is deliberately removed
        # from native input. The remaining fields identify only the requested
        # operation; no expected result, digest, or oracle object is sent.
        request = operation.wire()
        request.pop("category", None)
        if timing_mode is not None:
            request["timing_mode"] = timing_mode
        request = {"protocol": self.PROTOCOL, "request_id": request_id, **request}
        self._process.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
        self._process.stdin.flush()
        line = self._process.stdout.readline()
        if not line:
            error = self._process.stderr.read().strip() if self._process.stderr is not None else ""
            raise AdapterError(f"native server closed its response stream: {error}")
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AdapterError(f"native response is not JSON: {line!r}") from exc
        if not isinstance(value, dict) or value.get("protocol") != self.PROTOCOL:
            raise AdapterError(f"native response has invalid protocol/version: {value!r}")
        if type(value.get("request_id")) is not int or value.get("request_id") != request_id:
            raise AdapterError(
                f"native response id mismatch: expected {request_id}, observed {value.get('request_id')!r}"
            )
        if type(value.get("sample")) is not int or value.get("sample") != request.get("sample"):
            raise AdapterError(
                f"native response sample mismatch: expected {request.get('sample')!r}, observed {value.get('sample')!r}"
            )
        if value.get("ok") is not True:
            raise AdapterError(f"native operation failed: {value.get('error', 'missing ok=true')}")
        result = value.get("result")
        if not isinstance(result, dict):
            raise AdapterError("native successful response must contain an object result")
        reader_elapsed: int | None = None
        if timing_mode is not None:
            if value.get("timing_mode") != timing_mode:
                raise AdapterError(
                    f"native response timing mode mismatch: expected {timing_mode!r}, observed {value.get('timing_mode')!r}"
                )
            raw_elapsed = value.get("reader_elapsed_ns")
            if type(raw_elapsed) is not int or raw_elapsed < 0:
                raise AdapterError("native self-timed response must contain nonnegative integer reader_elapsed_ns")
            reader_elapsed = raw_elapsed
        return result, reader_elapsed

    def _request(self, operation: Operation) -> dict[str, object]:
        result, _ = self._request_envelope(operation)
        return result

    def _request_reader_timed(self, operation: Operation) -> tuple[dict[str, object], int]:
        result, elapsed = self._request_envelope(operation, timing_mode="reader_self")
        # _request_envelope validates this branch, but keep the type contract
        # explicit for callers and future protocol implementations.
        if elapsed is None:
            raise AdapterError("native self-timed response omitted reader elapsed time")
        return result, elapsed

    @staticmethod
    def _decode_operation(operation: Operation, result: dict[str, object]) -> object:
        """Decode one native result without issuing a second request."""

        def strict_result(*keys: str) -> dict[str, object]:
            if set(result) != set(keys):
                raise AdapterError(
                    f"native {operation.op} result must contain exactly {sorted(keys)!r}, "
                    f"observed {sorted(result)!r}"
                )
            return result

        def required_list(key: str) -> list[object]:
            value = strict_result(key)[key]
            if not isinstance(value, list):
                raise AdapterError(f"native {operation.op} result field {key!r} must be an array")
            return list(value)

        if operation.op == "exact":
            return required_list("ids")
        if operation.op == "prefix_interval":
            value = strict_result("lo", "hi")
            lo, hi = value["lo"], value["hi"]
            if type(lo) is not int or type(hi) is not int:
                raise AdapterError("native prefix_interval result bounds must be integers")
            return lo, hi
        if operation.op == "prefix_enumerate":
            return required_list("ids")
        if operation.op == "select":
            value = dict(strict_result("id", "key", "rank"))
            # The wire payload stays a minimal select record; the harness's
            # canonical response includes the operation tag for parity with
            # the independent oracle and reference adapters.
            value["op"] = "select"
            return value
        if operation.op in ("render", "snippet"):
            value = strict_result("bytes_hex")["bytes_hex"]
            if not isinstance(value, str):
                raise AdapterError(f"native {operation.op} bytes_hex must be a string")
            try:
                return bytes.fromhex(value)
            except ValueError as exc:
                raise AdapterError(f"native {operation.op} bytes_hex is not valid hexadecimal") from exc
        if operation.op == "concept_members" or operation.op == "translations":
            return required_list("members")
        if operation.op == "relations":
            return required_list("relations")
        if operation.op == "structure_checksum":
            value = strict_result("sha256")["sha256"]
            if not isinstance(value, str):
                raise AdapterError("native structure_checksum sha256 must be a string")
            return {"sha256": value}
        raise AdapterError(f"unknown native operation {operation.op!r}")

    def reader_timed(self, operation: Operation) -> tuple[object, int]:
        """Run one operation with native-only reader timing.

        The outer harness still measures the complete request/response call as
        transport time.  The response's self-timed value is accepted only when
        the native process explicitly echoes ``timing_mode=reader_self``.
        """

        result, elapsed = self._request_reader_timed(operation)
        return self._decode_operation(operation, result), elapsed

    def exact(self, key: str) -> list[int]:
        operation = self._operation("exact", key=key)
        return list(self._decode_operation(operation, self._request(operation)))

    def prefix_interval(self, prefix: str) -> tuple[int, int]:
        operation = self._operation("prefix_interval", key=prefix)
        value = self._decode_operation(operation, self._request(operation))
        lo, hi = value
        return lo, hi

    def prefix_enumerate(self, prefix: str) -> list[int]:
        operation = self._operation("prefix_enumerate", key=prefix)
        return list(self._decode_operation(operation, self._request(operation)))

    def select(self, rank: int) -> dict[str, object]:
        operation = self._operation("select", ident=rank)
        return dict(self._decode_operation(operation, self._request(operation)))

    def render(self, ident: int) -> bytes:
        operation = self._operation("render", ident=ident)
        return bytes(self._decode_operation(operation, self._request(operation)))

    def snippet(self, ident: int, limit: int) -> bytes:
        operation = self._operation("snippet", ident=ident, limit=limit)
        return bytes(self._decode_operation(operation, self._request(operation)))

    def concept_members(self, ident: int) -> list[int]:
        operation = self._operation("concept_members", ident=ident)
        return list(self._decode_operation(operation, self._request(operation)))

    def translations(self, ident: int, language: str) -> list[int]:
        operation = self._operation("translations", ident=ident, language=language)
        return list(self._decode_operation(operation, self._request(operation)))

    def relations(self, ident: int, predicate: str) -> list[dict[str, object]]:
        operation = self._operation("relations", ident=ident, predicate=predicate)
        return list(self._decode_operation(operation, self._request(operation)))

    def structure_checksum(self) -> str:
        operation = self._operation("structure_checksum")
        value = self._decode_operation(operation, self._request(operation))
        return str(value["sha256"])

    def query_checksum(self, operations: tuple[Operation, ...]) -> str:
        raise AdapterError(
            "query_checksum is not part of the native protocol; the harness validates each response and computes the digest locally"
        )


class UnavailableAdapter:
    """Explicit unavailable baseline; never emits a fabricated zero metric."""

    def __init__(self, label: str, reason: str):
        self.metadata = AdapterMetadata(label, "unavailable", "none", False, note=reason)
        self.reason = reason

    def build(self, artifact: Path) -> None:
        raise AdapterError(self.reason)

    def open(self, artifact: Path) -> None:
        raise AdapterError(self.reason)

    def verify(self) -> None:
        raise AdapterError(self.reason)

    def close(self) -> None:
        return None


__all__ = [
    "Adapter",
    "AdapterError",
    "AdapterMetadata",
    "ReferenceAdapter",
    "SQLiteAdapter",
    "SemanticMismatch",
    "SubprocessAdapter",
    "UnavailableAdapter",
]
