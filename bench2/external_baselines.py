#!/usr/bin/env python3
"""Build and measure independent dictionary formats over a bench2 corpus.

The corpus is deliberately a plain TSV projection.  Every reader below is
checked against the corpus digest and the same exact/prefix/render workload as
the Zig driver.  Formats that cannot provide a real random-access operation
are emitted as an explicit unavailable row instead of a made-up number.
"""

from __future__ import annotations

import argparse
import bisect
import gzip
import hashlib
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


def hash_bytes(value: int, data: bytes) -> int:
    for byte in data:
        value = ((value ^ byte) * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


def hash_u64(value: int, number: int) -> int:
    return hash_bytes(value, number.to_bytes(8, "little"))


@dataclass
class Corpus:
    fixture: str
    rows: list[tuple[int, str, bytes]]
    digest: int
    logical_prose_bytes: int

    @property
    def by_key(self) -> dict[str, list[int]]:
        result: dict[str, list[int]] = {}
        for ident, key, _ in self.rows:
            result.setdefault(key, []).append(ident)
        return result

    @property
    def by_id(self) -> dict[int, bytes]:
        return {ident: definition for ident, _, definition in self.rows}

    def exact_expected(self, key: str) -> list[int]:
        return [ident for ident, candidate, _ in self.rows if candidate == key]

    def prefix_expected(self, prefix: str) -> list[int]:
        return [ident for ident, key, _ in self.rows if key.startswith(prefix)]


def read_corpus(path: Path) -> Corpus:
    fixture = path.stem
    rows: list[tuple[int, str, bytes]] = []
    digest = FNV_OFFSET
    prose_bytes = 0
    with path.open("rb") as stream:
        for raw in stream:
            if raw.startswith(b"# fixture="):
                fixture = raw.rstrip(b"\r\n").decode().split("=", 1)[1]
                continue
            if not raw.strip():
                continue
            ident_raw, key_raw, definition_raw = raw.rstrip(b"\r\n").split(b"\t", 2)
            ident = int(ident_raw)
            key = key_raw.decode("utf-8")
            definition = definition_raw
            rows.append((ident, key, definition))
            digest = hash_bytes(digest, key_raw)
            digest = hash_bytes(digest, definition)
            prose_bytes += len(definition)
    if not rows:
        raise ValueError(f"empty corpus: {path}")
    return Corpus(fixture, rows, digest, prose_bytes)


def workload(corpus: Corpus, repetitions: int):
    exact: list[tuple[str, int, str]] = []
    prefix: list[tuple[str, int, str]] = []
    render = []
    for i in range(repetitions):
        source = (i * 7919 + 17) % len(corpus.rows)
        ident, key, _ = corpus.rows[source]
        exact_key = (
            key if i % 8 in (0, 2, 4, 6) else
            "missing-entry-key" if i % 8 == 1 else
            "" if i % 8 == 3 else
            "absent-ß-東京" if i % 8 == 5 else
            corpus.rows[0][1]
        )
        exact_count = len(corpus.exact_expected(exact_key))
        exact.append((exact_key, exact_count, "hit" if exact_count else "miss"))
        prefix_key = (
            "zzzz-missing" if i % 8 == 0 else
            key if i % 8 == 1 else
            "entry-" if i % 8 == 2 else
            key[:6] if i % 8 == 3 else
            "entry-00000000-" if i % 8 == 4 else
            "absent-ß-東京" if i % 8 == 5 else
            "pathological-prefix-" if i % 8 == 6 and corpus.fixture == "pathological_prefix" else
            "entry-" if i % 8 == 6 else
            key[:3]
        )
        prefix_count = len(corpus.prefix_expected(prefix_key))
        if prefix_count == 0:
            prefix_class = "zero"
        elif prefix_count == 1:
            prefix_class = "one"
        elif corpus.fixture == "pathological_prefix" and prefix_count >= max(2, len(corpus.rows) * 3 // 4):
            prefix_class = "pathological"
        else:
            prefix_class = "many"
        prefix.append((prefix_key, prefix_count, prefix_class))
        render.append(ident)
    return exact, prefix, render


def percentile(values: list[int], pctl: int) -> int:
    ordered = sorted(values)
    return ordered[(len(ordered) * pctl) // 100]


def emit(rows: list[tuple[str, str, str, str, str, object]], fixture: str, fmt: str,
         variant: str, metric: str, value: object) -> None:
    rows.append(("result", fixture, fmt, variant, metric, value))


def emit_sample(rows, fixture: str, fmt: str, variant: str, metric: str, index: int, value: int) -> None:
    rows.append(("sample", fixture, fmt, variant, metric, index, value))


def emit_unavailable(rows, fixture: str, fmt: str, variant: str, reason: str) -> None:
    rows.append(("unavailable", fixture, fmt, variant, "reason", reason))


def open_samples(open_fn, repeats: int = 25) -> list[int]:
    values = []
    for _ in range(repeats):
        started = time.perf_counter_ns()
        handle = open_fn()
        close = getattr(handle, "close", None)
        if close is not None:
            close()
        values.append(time.perf_counter_ns() - started)
    return values


def measure(rows, corpus: Corpus, fmt: str, variant: str, artifact_bytes: int,
            build_ns: int, open_fn, exact_fn, prefix_fn, render_fn,
            repetitions: int, warmup: int) -> None:
    exact_queries, prefix_queries, render_ids = workload(corpus, repetitions)
    definitions = corpus.by_id

    # Run the full semantic contract before timing.  This catches stale or
    # partially rebuilt artifacts, duplicate keys, special/Unicode spellings,
    # and the pathological-prefix cardinality fixture without contaminating
    # the measured path with reference checks.
    validate_reader(corpus, exact_fn, prefix_fn, render_fn)

    def check_exact(key: str) -> list[int]:
        value = sorted(exact_fn(key))
        if value != corpus.exact_expected(key):
            raise RuntimeError(f"{fmt}.{variant} exact mismatch for {key!r}: {value}")
        return value

    def check_prefix(prefix: str) -> list[int]:
        value = sorted(prefix_fn(prefix))
        if value != corpus.prefix_expected(prefix):
            raise RuntimeError(f"{fmt}.{variant} prefix mismatch for {prefix!r}")
        return value

    for i in range(warmup):
        check_exact(exact_queries[i % repetitions][0])
        check_prefix(prefix_queries[i % repetitions][0])
        ident = render_ids[i % repetitions]
        if render_fn(ident) != definitions[ident]:
            raise RuntimeError(f"{fmt}.{variant} warm render mismatch")

    exact_times = []
    prefix_times = []
    render_times = []
    checksum = 0
    outputs = 0
    exact_class_times: dict[str, list[int]] = {"hit": [], "miss": []}
    prefix_class_times: dict[str, list[int]] = {"zero": [], "one": [], "many": [], "pathological": []}
    for key, _, category in exact_queries:
        started = time.perf_counter_ns()
        # Keep the timed region to the reader operation.  Sorting, reference
        # comparison, and duplicate/cardinality validation are semantic
        # checks and intentionally happen after the clock stops.
        values = exact_fn(key)
        elapsed = time.perf_counter_ns() - started
        values = sorted(values)
        expected = corpus.exact_expected(key)
        if values != expected:
            raise RuntimeError(f"{fmt}.{variant} exact mismatch for {key!r}: {values}")
        exact_times.append(elapsed)
        exact_class_times[category].append(elapsed)
        outputs += len(values)
        for ident in values:
            checksum = hash_u64(checksum, ident)
    for prefix, _, category in prefix_queries:
        started = time.perf_counter_ns()
        values = prefix_fn(prefix)
        elapsed = time.perf_counter_ns() - started
        values = sorted(values)
        expected = corpus.prefix_expected(prefix)
        if values != expected:
            raise RuntimeError(f"{fmt}.{variant} prefix mismatch for {prefix!r}")
        prefix_times.append(elapsed)
        prefix_class_times[category].append(elapsed)
        outputs += len(values)
        for ident in values:
            checksum = hash_u64(checksum, ident)
    for ident in render_ids:
        started = time.perf_counter_ns()
        definition = render_fn(ident)
        render_times.append(time.perf_counter_ns() - started)
        if definition != definitions[ident]:
            raise RuntimeError(f"{fmt}.{variant} render mismatch")
        checksum = hash_bytes(checksum, definition)

    emit(rows, corpus.fixture, fmt, variant, "artifact_bytes", artifact_bytes)
    emit(rows, corpus.fixture, fmt, variant, "build_ns", build_ns)
    opens = open_samples(open_fn)
    for index, elapsed in enumerate(opens):
        emit_sample(rows, corpus.fixture, fmt, variant, "open", index, elapsed)
    emit(rows, corpus.fixture, fmt, variant, "open_ns", percentile(opens, 50))
    emit(rows, corpus.fixture, fmt, variant, "semantic_digest", corpus.digest)
    emit(rows, corpus.fixture, fmt, variant, "query_checksum", checksum)
    emit(rows, corpus.fixture, fmt, variant, "outputs", outputs)
    emit(rows, corpus.fixture, fmt, variant, "logical_prose_bytes", corpus.logical_prose_bytes)
    for name, values in (("exact", exact_times), ("prefix", prefix_times), ("render", render_times)):
        for index, elapsed in enumerate(values):
            emit_sample(rows, corpus.fixture, fmt, variant, name, index, elapsed)
    for name, values in (("exact", exact_times), ("prefix", prefix_times), ("render", render_times)):
        for pctl in (50, 95, 99):
            emit(rows, corpus.fixture, fmt, variant, f"{name}.p{pctl}_ns", percentile(values, pctl))
    for category, values in exact_class_times.items():
        emit_category(rows, corpus.fixture, fmt, variant, "exact", category, values)
    for category, values in prefix_class_times.items():
        emit_category(rows, corpus.fixture, fmt, variant, "prefix", category, values)


def emit_category(rows, fixture: str, fmt: str, variant: str, name: str, category: str, values: list[int]) -> None:
    for pctl in (50, 95, 99):
        metric = f"{name}.{category}.p{pctl}_ns"
        rows.append(("result", fixture, fmt, variant, metric, percentile(values, pctl) if values else "-"))


def validate_reader(corpus: Corpus, exact_fn, prefix_fn, render_fn) -> None:
    def exact_check(key: str) -> None:
        actual = sorted(exact_fn(key))
        expected = corpus.exact_expected(key)
        if actual != expected:
            raise RuntimeError(f"artifact exact mismatch for {key!r}: {actual} != {expected}")

    def prefix_check(prefix: str) -> None:
        actual = sorted(prefix_fn(prefix))
        expected = corpus.prefix_expected(prefix)
        if actual != expected:
            raise RuntimeError(f"artifact prefix mismatch for {prefix!r}: {actual} != {expected}")

    # Every row checks duplicate posting membership, including all generated
    # Unicode and punctuation keys.  The extra spellings exercise misses and
    # empty/special prefixes independently of the workload sequence.
    for _, key, _ in corpus.rows:
        exact_check(key)
    for key in ("", "missing-entry-key", "absent-ß-東京", "entry-00000000-special.%_!?"):
        exact_check(key)
    for prefix in (
        "",
        "entry-",
        "repeat-",
        "pathological-prefix-",
        "entry-00000000-",
        "absent-ß-東京",
    ):
        prefix_check(prefix)
    for ident, _, definition in corpus.rows:
        if render_fn(ident) != definition:
            raise RuntimeError(f"artifact render mismatch for id {ident}")


class SQLiteReader:
    def __init__(self, path: Path):
        self.path = path
        self.db = sqlite3.connect(str(path))
        self.db.execute("PRAGMA case_sensitive_like=ON")

    def close(self):
        self.db.close()

    def exact(self, key):
        return [row[0] for row in self.db.execute("SELECT id FROM entries WHERE key=? ORDER BY id", (key,))]

    def prefix(self, prefix):
        upper = prefix_upper_bound(prefix)
        if upper is None:
            # No finite scalar successor exists for an all-U+10FFFF suffix.
            # The lower bound still uses the key index; the final scalar
            # filter preserves the exact prefix contract for that rare case.
            rows = self.db.execute(
                "SELECT id, key FROM entries WHERE key COLLATE BINARY >= ? ORDER BY id",
                (prefix,),
            )
            return [row[0] for row in rows if row[1].startswith(prefix)]
        return [row[0] for row in self.db.execute(
            "SELECT id FROM entries "
            "WHERE key COLLATE BINARY >= ? AND key COLLATE BINARY < ? "
            "ORDER BY id",
            (prefix, upper),
        )]

    def render(self, ident):
        return self.db.execute("SELECT definition FROM entries WHERE id=?", (ident,)).fetchone()[0]


def prefix_upper_bound(prefix: str) -> str | None:
    """Return the smallest Unicode scalar string strictly above a prefix range.

    SQLite's default BINARY TEXT collation compares UTF-8 bytes, whose order
    preserves Unicode scalar order.  Incrementing the rightmost scalar that
    is not U+10FFFF therefore gives an indexable half-open interval without
    LIKE wildcards (and without treating '%' or '_' in a key specially).
    """

    if not prefix:
        return None
    scalars = list(prefix)
    for index in range(len(scalars) - 1, -1, -1):
        codepoint = ord(scalars[index])
        if codepoint < 0x10FFFF:
            successor = codepoint + 1
            # UTF-16 surrogate code points are not Unicode scalar values and
            # cannot be bound as SQLite UTF-8 text.  Skip the reserved range
            # when the rightmost scalar is U+D7FF.
            if 0xD800 <= successor <= 0xDFFF:
                successor = 0xE000
            return "".join(scalars[:index]) + chr(successor)
    return None


def validate_sqlite_prefix_index(reader: SQLiteReader, prefixes: list[str]) -> None:
    """Require the bounded prefix query to use the key index before timing."""

    for prefix in prefixes:
        upper = prefix_upper_bound(prefix)
        if upper is None:
            continue
        plan = reader.db.execute(
            "EXPLAIN QUERY PLAN SELECT id FROM entries "
            "WHERE key COLLATE BINARY >= ? AND key COLLATE BINARY < ?",
            (prefix, upper),
        ).fetchall()
        details = " ".join(str(row[-1]) for row in plan)
        if "entries_key" not in details:
            raise RuntimeError(f"SQLite prefix query plan does not use entries_key for {prefix!r}: {details}")


def build_sqlite(corpus: Corpus, directory: Path, rows, repetitions: int, warmup: int) -> None:
    path = directory / f"{corpus.fixture}.sqlite"
    if path.exists():
        path.unlink()
    started = time.perf_counter_ns()
    db = sqlite3.connect(str(path))
    db.execute("PRAGMA journal_mode=OFF")
    db.execute("PRAGMA synchronous=OFF")
    db.execute("PRAGMA temp_store=MEMORY")
    db.execute("CREATE TABLE entries (id INTEGER PRIMARY KEY, key TEXT NOT NULL, definition BLOB NOT NULL)")
    db.executemany("INSERT INTO entries(id,key,definition) VALUES(?,?,?)", corpus.rows)
    db.execute("CREATE INDEX entries_key ON entries(key, id)")
    db.commit()
    db.close()
    build_ns = time.perf_counter_ns() - started

    def open_reader():
        return SQLiteReader(path)

    reader = open_reader()
    validate_sqlite_prefix_index(reader, ["", "entry-", "entry-00000000-", "absent-ß-東京"])
    measure(rows, corpus, "sqlite", "raw", path.stat().st_size, build_ns,
            open_reader, reader.exact, reader.prefix, reader.render, repetitions, warmup)
    reader.close()

    zlib_path = directory / f"{corpus.fixture}.sqlite.gz"
    with path.open("rb") as source, gzip.open(zlib_path, "wb", compresslevel=9) as target:
        shutil.copyfileobj(source, target)
    emit(rows, corpus.fixture, "sqlite", "zlib", "artifact_bytes", zlib_path.stat().st_size)
    emit_unavailable(rows, corpus.fixture, "sqlite", "zlib", "SQLite cannot seek compressed pages without a decompression staging policy")

    zstd_path = directory / f"{corpus.fixture}.sqlite.zst"
    zstd = shutil.which("zstd")
    if zstd:
        subprocess.run([zstd, "-q", "-f", "-19", str(path), "-o", str(zstd_path)], check=True)
        emit(rows, corpus.fixture, "sqlite", "zstd", "artifact_bytes", zstd_path.stat().st_size)
        emit_unavailable(rows, corpus.fixture, "sqlite", "zstd", "SQLite cannot seek compressed pages without a decompression staging policy")
    else:
        emit_unavailable(rows, corpus.fixture, "sqlite", "zstd", "zstd executable absent from Nix shell")


class StarDictReader:
    def __init__(self, index_path: Path, data_path: Path):
        self.index = []
        self.data = data_path.read_bytes()
        raw = index_path.read_bytes()
        at = 0
        while at < len(raw):
            end = raw.index(b"\0", at)
            key = raw[at:end].decode("utf-8")
            offset, length = struct.unpack(">II", raw[end + 1:end + 9])
            self.index.append((key, offset, length))
            at = end + 9
        self.keys = [item[0] for item in self.index]

    def close(self):
        self.data = b""

    def exact(self, key):
        pos = bisect.bisect_left(self.keys, key)
        out = []
        while pos < len(self.index) and self.index[pos][0] == key:
            out.append(pos)
            pos += 1
        return out

    def prefix(self, prefix):
        pos = bisect.bisect_left(self.keys, prefix)
        out = []
        while pos < len(self.index) and self.index[pos][0].startswith(prefix):
            out.append(pos)
            pos += 1
        return out

    def render(self, ident):
        _, offset, length = self.index[ident]
        return self.data[offset:offset + length]


def build_stardict(corpus: Corpus, directory: Path, rows, repetitions: int, warmup: int) -> None:
    base = directory / corpus.fixture
    ifo = base.with_suffix(".ifo")
    idx = base.with_suffix(".idx")
    data = base.with_suffix(".dict")
    started = time.perf_counter_ns()
    ordered = sorted(corpus.rows, key=lambda item: item[1])
    offset = 0
    idx_bytes = bytearray()
    data_bytes = bytearray()
    for ident, key, definition in ordered:
        encoded_key = key.encode("utf-8")
        idx_bytes.extend(encoded_key + b"\0" + struct.pack(">II", offset, len(definition)))
        data_bytes.extend(definition)
        offset += len(definition)
    idx.write_bytes(bytes(idx_bytes))
    data.write_bytes(bytes(data_bytes))
    ifo.write_text("\n".join([
        "StarDict's dict ifo file", "version=2.4.2", f"wordcount={len(ordered)}",
        f"idxfilesize={len(idx_bytes)}", "bookname=bench2", "sametypesequence=m", "",
    ]), encoding="utf-8")
    build_ns = time.perf_counter_ns() - started
    artifact_bytes = sum(path.stat().st_size for path in (ifo, idx, data))

    def open_reader():
        return StarDictReader(idx, data)

    reader = open_reader()
    by_key = corpus.by_key

    def ids(fn):
        return lambda key: [ordered[item][0] for item in fn(key)]

    ordered_pos_by_id = {ident: index for index, (ident, _, _) in enumerate(ordered)}

    def render(ident):
        return reader.render(ordered_pos_by_id[ident])

    measure(rows, corpus, "stardict", "raw", artifact_bytes, build_ns,
            open_reader, ids(reader.exact), ids(reader.prefix), render, repetitions, warmup)
    reader.close()

    gz = base.with_suffix(".dict.gz")
    with data.open("rb") as source, gzip.open(gz, "wb", compresslevel=9) as target:
        shutil.copyfileobj(source, target)
    compressed_bytes = ifo.stat().st_size + idx.stat().st_size + gz.stat().st_size
    emit(rows, corpus.fixture, "stardict", "gzip", "artifact_bytes", compressed_bytes)
    emit_unavailable(rows, corpus.fixture, "stardict", "gzip", "gzip is not StarDict dictzip random access; raw reader is the measured query baseline")


class OffsetIndexReader:
    def __init__(self, index_path: Path, data_path: Path, compressed: bool = False):
        self.index_path = index_path
        self.data_path = data_path
        self.compressed = compressed
        self.items = []
        for line in index_path.read_text(encoding="utf-8").splitlines():
            key, offset, length = line.split("\t")
            self.items.append((key, int(offset), int(length)))
        self.keys = [item[0] for item in self.items]
        self.data = data_path.read_bytes() if not compressed else None

    def close(self):
        self.data = None

    def exact(self, key):
        pos = bisect.bisect_left(self.keys, key)
        out = []
        while pos < len(self.keys) and self.keys[pos] == key:
            out.append(pos)
            pos += 1
        return out

    def prefix(self, prefix):
        pos = bisect.bisect_left(self.keys, prefix)
        out = []
        while pos < len(self.keys) and self.keys[pos].startswith(prefix):
            out.append(pos)
            pos += 1
        return out

    def render(self, ident):
        _, offset, length = self.items[ident]
        if not self.compressed:
            return self.data[offset:offset + length]
        command = ["dictzip", "-c", "-s", str(offset), "-e", str(length), str(self.data_path)]
        return subprocess.run(command, check=True, capture_output=True).stdout


def build_dict_index(corpus: Corpus, directory: Path, rows, repetitions: int, warmup: int) -> None:
    # This builder emits a deliberately named local index baseline.  It is
    # not a dictd daemon and must not be reported as one.  A real dictfmt/
    # dictd client baseline can be added when the environment provides both
    # tools and a service policy; relabeling this file layout keeps the result
    # honest on portable Nix shells.
    # Keep the local offset baseline's payload separate from StarDict's
    # ``<fixture>.dict`` payload.  Both readers share the fixture directory,
    # so a basename collision would overwrite a measured artifact after its
    # timing and invalidate retention/hashes.
    index = directory / f"{corpus.fixture}.offset.index"
    data = directory / f"{corpus.fixture}.offset.dict"
    ordered = sorted(corpus.rows, key=lambda item: item[1])
    started = time.perf_counter_ns()
    offset = 0
    index_lines = []
    with data.open("wb") as stream:
        for _, key, definition in ordered:
            stream.write(definition)
            index_lines.append(f"{key}\t{offset}\t{len(definition)}")
            offset += len(definition)
    index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    build_ns = time.perf_counter_ns() - started
    artifact_bytes = index.stat().st_size + data.stat().st_size
    reader = OffsetIndexReader(index, data)
    id_map = [row[0] for row in ordered]
    id_to_pos = {ident: index for index, (ident, _, _) in enumerate(ordered)}
    measure(rows, corpus, "dict-index", "raw", artifact_bytes, build_ns,
            lambda: OffsetIndexReader(index, data),
            lambda key: [id_map[i] for i in reader.exact(key)],
            lambda key: [id_map[i] for i in reader.prefix(key)],
            lambda ident: reader.render(id_to_pos[ident]), repetitions, warmup)
    reader.close()

    if shutil.which("dictzip") is None:
        emit_unavailable(rows, corpus.fixture, "dict-index", "dictzip", "dictzip executable absent; raw local index retained")
        return
    zip_started = time.perf_counter_ns()
    subprocess.run(["dictzip", "-k", "-f", str(data)], check=True, capture_output=True)
    zip_build_ns = time.perf_counter_ns() - zip_started
    compressed = data.with_suffix(data.suffix + ".dz")
    compressed_bytes = index.stat().st_size + compressed.stat().st_size
    compressed_map = [row[0] for row in ordered]
    compressed_reader = OffsetIndexReader(index, compressed, compressed=True)
    measure(rows, corpus, "dict-index", "dictzip", compressed_bytes, zip_build_ns,
            lambda: OffsetIndexReader(index, compressed, compressed=True),
            lambda key: [compressed_map[i] for i in compressed_reader.exact(key)],
            lambda key: [compressed_map[i] for i in compressed_reader.prefix(key)],
            lambda ident: compressed_reader.render(id_to_pos[ident]), repetitions, warmup)
    compressed_reader.close()


def build_slob(corpus: Corpus, directory: Path, rows, repetitions: int, warmup: int) -> None:
    try:
        import slob
    except ImportError as error:
        reason = f"Python SLOB import failed: {error}"
        emit_unavailable(rows, corpus.fixture, "slob", "raw", reason)
        emit_unavailable(rows, corpus.fixture, "slob", "lzma2", reason)
        return

    ids_by_key_and_definition: dict[tuple[str, bytes], list[int]] = {}
    for ident, key, definition in corpus.rows:
        ids_by_key_and_definition.setdefault((key, definition), []).append(ident)
    for variant, compression in (("raw", None), ("lzma2", "lzma2")):
        path = directory / f"{corpus.fixture}.{variant}.slob"
        if path.exists():
            path.unlink()
        started = time.perf_counter_ns()
        with slob.create(str(path), compression=compression, min_bin_size=64 * 1024) as writer:
            for _, key, definition in corpus.rows:
                writer.add(definition, key, content_type="text/plain")
        build_ns = time.perf_counter_ns() - started

        def open_reader():
            return slob.open(str(path))

        reader = open_reader()

        # Resolve each stable SLOB content id once, outside warmup/timing.
        # Querying item.content inside exact/prefix would decompress prose and
        # reconstruct a key/definition map for every request.  The ref list is
        # scanned once here, retaining O(1) content-id -> corpus-id and
        # corpus-id -> ref-index maps for the timed public workload.
        token_cursors: dict[tuple[str, bytes], int] = {}
        content_id_to_record: dict[int, int] = {}
        record_to_ref: dict[int, int] = {}
        for ref_index in range(len(reader)):
            item = reader[ref_index]
            token = (item.key, item.content)
            candidates = ids_by_key_and_definition.get(token)
            if candidates is None:
                raise RuntimeError(f"SLOB artifact contains unexpected key/content {token[0]!r}")
            cursor = token_cursors.get(token, 0)
            if cursor >= len(candidates):
                raise RuntimeError(f"SLOB artifact contains duplicate key/content beyond corpus: {token[0]!r}")
            ident = candidates[cursor]
            token_cursors[token] = cursor + 1
            content_id_to_record[item.id] = ident
            record_to_ref[ident] = ref_index
        if len(content_id_to_record) != len(corpus.rows) or len(record_to_ref) != len(corpus.rows):
            raise RuntimeError("SLOB artifact omitted one or more corpus records")

        def exact(key):
            return [content_id_to_record[item.id] for _, item in slob.find(key, reader, match_prefix=False) if item.key == key]

        def prefix(prefix):
            return [content_id_to_record[item.id] for _, item in slob.find(prefix, reader, match_prefix=True) if item.key.startswith(prefix)]

        def render(ident):
            return reader[record_to_ref[ident]].content

        measure(rows, corpus, "slob", variant, path.stat().st_size, build_ns,
                open_reader, exact, prefix, render, repetitions, warmup)
        reader.close()


def write_rows(path: Path, rows) -> None:
    with path.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write("\t".join(str(item) for item in row) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=500)
    parser.add_argument("--warmup", type=int, default=100)
    args = parser.parse_args()
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    corpus = read_corpus(args.corpus)
    rows = []
    rows.append(("meta", corpus.fixture, "records", len(corpus.rows)))
    rows.append(("meta", corpus.fixture, "semantic_digest", corpus.digest))
    for builder in (build_sqlite, build_stardict, build_dict_index, build_slob):
        # Semantic, index-plan, and artifact failures are fatal.  Optional
        # dependencies emit explicit unavailable rows inside their builders;
        # swallowing any other exception would turn a broken baseline into a
        # misleading omission.
        builder(corpus, args.artifact_dir, rows, args.repetitions, args.warmup)
    write_rows(args.out, rows)
    for row in rows:
        print("\t".join(str(item) for item in row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
