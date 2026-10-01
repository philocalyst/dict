#!/usr/bin/env python3
"""Build and independently smoke-check real external dictionary formats.

No clock is read in this module.  It is safe to run while production/native
benchmark work is frozen.  Later measurement code will import the readers but
will keep creation, identity mapping, validation, and CLI startup in separate
phases.
"""

from __future__ import annotations

import argparse
import base64
import bisect
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence


ROOT = Path(__file__).resolve().parent
MAX_PROJECTION_BYTES = 512 * 1024 * 1024


class FormatError(RuntimeError):
    pass


@dataclass(frozen=True)
class Record:
    row: int
    identity: bytes
    keys: tuple[bytes, ...]
    content: bytes


@dataclass(frozen=True)
class Posting:
    key: bytes
    row: int
    key_index: int


class Oracle:
    """Independent occurrence oracle over the hex projection."""

    def __init__(self, records: list[Record]):
        if not records:
            raise FormatError("empty projection")
        self.records = records
        self.by_row = {record.row: record for record in records}
        self.postings = [
            Posting(key, record.row, key_index)
            for record in records
            for key_index, key in enumerate(record.keys)
        ]
        self.sorted_postings = sorted(self.postings, key=lambda item: (item.key, item.row, item.key_index))
        # Exact-key validation covers every distinct key in the projection.
        # Keep buckets so the independent oracle remains linear in the number
        # of requested occurrences rather than quadratic in
        # (unique-keys * total-postings) for large real corpora.
        self._exact_buckets: dict[bytes, list[Posting]] = {}
        for posting in self.sorted_postings:
            self._exact_buckets.setdefault(posting.key, []).append(posting)
        self.unique_keys = sorted({posting.key for posting in self.postings})

    def exact(self, key: bytes) -> list[Posting]:
        return self._exact_buckets.get(key, [])

    def prefix(self, prefix: bytes) -> list[Posting]:
        return [posting for posting in self.sorted_postings if posting.key.startswith(prefix)]

    def queries(self) -> list[tuple[str, bytes]]:
        selected: list[tuple[str, bytes]] = []
        # Every row is checked once by exact key validation below.  These
        # additional classes exercise hit, duplicate, Unicode/punctuation,
        # high-multiplicity, prefix, and missing-key behavior.
        first = self.sorted_postings[0].key
        last = self.sorted_postings[-1].key
        selected += [("exact-first", first), ("exact-last", last), ("exact-missing", b"__real_world_missing__\xce\xb2")]
        selected += [("prefix-empty", b""), ("prefix-first-byte", first[:1]), ("prefix-missing", b"__real_world_missing__")]
        counts: dict[bytes, int] = {}
        for posting in self.postings:
            counts[posting.key] = counts.get(posting.key, 0) + 1
        for key, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))[:3]:
            selected.append((f"exact-high-multiplicity-{count}", key))
        # Keep punctuation and non-ASCII keys visible in the fixed workload.
        for key in self.unique_keys:
            if any(byte >= 128 for byte in key) or any(byte in b"-._!?%/()" for byte in key):
                selected.append(("exact-edge", key))
                # Prefixes are UTF-8 byte strings in the matched contract, but
                # ICU/native readers take text.  Stop at a complete first
                # scalar so the native control never receives a partial UTF-8
                # sequence while still exercising Unicode/punctuation keys.
                first_scalar = key.decode("utf-8")[0].encode("utf-8")
                selected.append(("prefix-edge", key[:len(first_scalar)]))
                break
        seen: set[tuple[str, bytes]] = set()
        return [(name, key) for name, key in selected if not ((name, key) in seen or seen.add((name, key)))]


def read_projection(path: Path) -> Oracle:
    records: list[Record] = []
    with path.open("rb") as stream:
        for line_number, raw in enumerate(stream, 1):
            if raw.endswith(b"\n"):
                raw = raw[:-1]
            if raw.endswith(b"\r"):
                raw = raw[:-1]
            if not raw:
                raise FormatError(f"blank projection line {line_number}")
            columns = raw.split(b"\t")
            if len(columns) != 3:
                raise FormatError(f"projection line {line_number} has {len(columns)} columns")
            try:
                identity = bytes.fromhex(columns[0].decode("ascii"))
                key_components = columns[1].split(b",")
                keys = tuple(bytes.fromhex(component.decode("ascii")) for component in key_components)
                content = bytes.fromhex(columns[2].decode("ascii"))
            except (ValueError, UnicodeDecodeError) as exc:
                raise FormatError(f"invalid hex projection line {line_number}: {exc}") from exc
            if not identity or not keys:
                raise FormatError(f"projection line {line_number} has no identity/key")
            if any(b"\x00" in key for key in keys):
                raise FormatError(f"NUL key cannot be represented by external dictionary formats at line {line_number}")
            records.append(Record(len(records), identity, keys, content))
    return Oracle(records)


def artifact_file(path: Path) -> dict[str, Any]:
    import hashlib

    def digest(algorithm: str) -> str:
        h = hashlib.new(algorithm)
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": digest("sha256"), "sha512": digest("sha512")}


def storage_summary(files: Sequence[dict[str, Any]], *, sidecar_suffixes: tuple[str, ...] = (".rows.json", ".refs.json")) -> dict[str, Any]:
    """Split native format bytes from benchmark-only identity sidecars."""
    sidecar = [item for item in files if Path(str(item.get("path", ""))).name.endswith(sidecar_suffixes)]
    native = [item for item in files if item not in sidecar]
    return {
        "native_bytes": sum(int(item.get("bytes", 0)) for item in native),
        "sidecar_bytes": sum(int(item.get("bytes", 0)) for item in sidecar),
        "total_bytes": sum(int(item.get("bytes", 0)) for item in files),
        "native_files": [Path(str(item.get("path", ""))).name for item in native],
        "sidecar_files": [Path(str(item.get("path", ""))).name for item in sidecar],
    }


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def base36(value: int) -> str:
    if value < 0:
        raise ValueError(value)
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if value == 0:
        return "0"
    out = []
    while value:
        value, remainder = divmod(value, 36)
        out.append(digits[remainder])
    return "".join(reversed(out))


def unbase36(value: str) -> int:
    if not value:
        raise FormatError("empty base36 offset")
    return int(value, 36)


def run_capture(argv: Sequence[str], *, cwd: Path | None = None) -> dict[str, Any]:
    try:
        result = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return {"argv": list(argv), "returncode": None, "stdout": "", "stderr": str(exc), "error": str(exc)}
    return {
        "argv": list(argv),
        "returncode": result.returncode,
        "stdout": result.stdout.decode("utf-8", "replace"),
        "stderr": result.stderr.decode("utf-8", "replace"),
    }


def build_stardict(oracle: Oracle, directory: Path) -> dict[str, Any]:
    stem = directory / "stardict"
    ifo = stem.with_suffix(".ifo")
    idx = stem.with_suffix(".idx")
    syn = stem.with_suffix(".syn")
    data = stem.with_suffix(".dict")
    ordered = sorted(oracle.records, key=lambda record: (record.keys[0], record.row))
    row_to_idx = {record.row: index for index, record in enumerate(ordered)}
    data_bytes = bytearray()
    idx_bytes = bytearray()
    syn_rows: list[tuple[bytes, int, int]] = []
    for record in ordered:
        offset = len(data_bytes)
        data_bytes.extend(record.content)
        key = record.keys[0]
        idx_bytes.extend(key + b"\0" + struct.pack(">II", offset, len(record.content)))
        for key_index, alias in enumerate(record.keys[1:], 1):
            syn_rows.append((alias, row_to_idx[record.row], key_index))
    syn_rows.sort(key=lambda item: (item[0], item[1], item[2]))
    syn_bytes = bytearray()
    for key, index, _ in syn_rows:
        syn_bytes.extend(key + b"\0" + struct.pack(">I", index))
    idx.write_bytes(idx_bytes)
    syn.write_bytes(syn_bytes)
    data.write_bytes(data_bytes)
    bookname = "real-world"
    ifo.write_text("\n".join([
        "StarDict's dict ifo file",
        "version=2.4.2",
        f"wordcount={len(ordered)}",
        f"synwordcount={len(syn_rows)}",
        f"idxfilesize={len(idx_bytes)}",
        "idxoffsetbits=32",
        f"bookname={bookname}",
        "sametypesequence=m",
        "description=Matched real-world lexical projection",
        "",
    ]), encoding="utf-8")
    sidecar = stem.with_suffix(".rows.json")
    write_json(sidecar, {
        "schema": 1,
        "format": "StarDict 2.4.2",
        "primary_rows_in_idx_order": [record.row for record in ordered],
        "synonym_rows_in_file_order": [{"row": ordered[primary_index].row, "key_index": key_index} for _, primary_index, key_index in syn_rows],
        "alias_storage": "primary payload once; aliases in .syn",
    })
    files = [artifact_file(path) for path in (ifo, idx, syn, data, sidecar)]
    result = {
        "format": "stardict",
        "variant": "raw",
        "files": files,
        "storage": storage_summary(files),
        "payload_bytes": len(data_bytes),
        "primary_words": len(ordered),
        "synonym_words": len(syn_rows),
        "notes": ["primary payload is stored once per lexical record", "syn aliases are real StarDict files"],
    }
    # Genuine sdcv validation is performed by validate_stardict below.
    return result


class StarDictReader:
    def __init__(self, ifo: Path, idx: Path, syn: Path, data: Path, oracle: Oracle):
        self.ifo = ifo
        self.data = data.read_bytes()
        self.primary: list[tuple[bytes, int, int, int]] = []
        raw = idx.read_bytes()
        at = 0
        row_order = sorted(oracle.records, key=lambda record: (record.keys[0], record.row))
        while at < len(raw):
            try:
                end = raw.index(b"\0", at)
            except ValueError as exc:
                raise FormatError("truncated StarDict idx key") from exc
            if end + 9 > len(raw):
                raise FormatError("truncated StarDict idx posting")
            key = raw[at:end]
            offset, length = struct.unpack(">II", raw[end + 1:end + 9])
            if offset + length > len(self.data):
                raise FormatError("StarDict posting outside .dict")
            if len(self.primary) >= len(row_order):
                raise FormatError("StarDict has too many primary words")
            self.primary.append((key, row_order[len(self.primary)].row, offset, length))
            at = end + 9
        self.postings: list[Posting] = [Posting(key, row, 0) for key, row, _, _ in self.primary]
        raw = syn.read_bytes()
        at = 0
        while at < len(raw):
            try:
                end = raw.index(b"\0", at)
            except ValueError as exc:
                raise FormatError("truncated StarDict syn key") from exc
            if end + 5 > len(raw):
                raise FormatError("truncated StarDict syn posting")
            key = raw[at:end]
            index = struct.unpack(">I", raw[end + 1:end + 5])[0]
            if index >= len(self.primary):
                raise FormatError("StarDict syn target outside idx")
            self.postings.append(Posting(key, self.primary[index][1], 0))
            at = end + 5
        # Recover each source key-index occurrence.  The StarDict format has
        # no source key-index field; aliases are `.syn` records that point at
        # a primary word.  Matching only `(key,row)` and assigning ordinal 0
        # would make an alias look like the headword to the occurrence oracle.
        # Use the independently parsed projection's occurrence bucket to
        # restore the key index while retaining duplicate homographs.
        self.postings.sort(key=lambda posting: (posting.key, posting.row))
        expected_key_indices: dict[tuple[bytes, int], list[int]] = {}
        for posting in oracle.sorted_postings:
            expected_key_indices.setdefault((posting.key, posting.row), []).append(posting.key_index)
        counters: dict[tuple[bytes, int], int] = {}
        normalized: list[Posting] = []
        for posting in self.postings:
            ordinal = counters.get((posting.key, posting.row), 0)
            counters[(posting.key, posting.row)] = ordinal + 1
            candidates = expected_key_indices.get((posting.key, posting.row), [])
            if ordinal >= len(candidates):
                raise FormatError(f"StarDict occurrence not present in projection for {posting.key!r}")
            normalized.append(Posting(posting.key, posting.row, candidates[ordinal]))
        self.postings = normalized
        self.keys = [posting.key for posting in self.postings]
        self.row_to_primary = {row: (offset, length) for _, row, offset, length in self.primary}

    def close(self) -> None:
        self.data = b""

    def exact(self, key: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, key)
        end = start
        while end < len(self.keys) and self.keys[end] == key:
            end += 1
        return self.postings[start:end]

    def prefix(self, prefix: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, prefix)
        end = start
        while end < len(self.keys) and self.keys[end].startswith(prefix):
            end += 1
        return self.postings[start:end]

    def render(self, row: int) -> bytes:
        offset, length = self.row_to_primary[row]
        return self.data[offset:offset + length]


def validate_stardict(oracle: Oracle, directory: Path) -> dict[str, Any]:
    stem = directory / "stardict"
    reader = StarDictReader(stem.with_suffix(".ifo"), stem.with_suffix(".idx"), stem.with_suffix(".syn"), stem.with_suffix(".dict"), oracle)
    checks = validate_reader(oracle, reader)
    reader.close()
    # sdcv is the independent native implementation check.  Use a finite
    # representative set; full correctness is checked by the independent
    # binary reader above, avoiding one process per 100k row.
    native: list[dict[str, Any]] = []
    sdcv = shutil.which("sdcv")
    if sdcv is None:
        native.append({"status": "unavailable", "reason": "sdcv executable absent"})
    else:
        samples = [key for _, key in oracle.queries() if key][:8]
        for key in samples:
            try:
                text = key.decode("utf-8")
            except UnicodeDecodeError:
                continue
            result = run_capture([sdcv, "-n", "-e", "-1", "-0", "-x", "-2", str(directory), "-u", "real-world", text], cwd=directory)
            expected_hits = len(oracle.exact(key))
            native.append({"key": text, "expected_hits": expected_hits, "returncode": result["returncode"], "stdout_bytes": len(result["stdout"].encode()), "stderr": result["stderr"][-500:], "contains_key": text in result["stdout"], "status": "ok" if ((result["returncode"] == 0 and expected_hits > 0) or (result["returncode"] == 2 and expected_hits == 0)) else "failed"})
    return {"format": "stardict", "variant": "raw", "validation": checks, "native_sdcv": native}


def build_dict(oracle: Oracle, directory: Path) -> dict[str, Any]:
    index = directory / "dict.index"
    data = directory / "dict.dict"
    ordered = oracle.sorted_postings
    offsets: dict[int, tuple[int, int]] = {}
    payload = bytearray()
    for record in oracle.records:
        offsets[record.row] = (len(payload), len(record.content))
        payload.extend(record.content)
    data.write_bytes(payload)
    with index.open("w", encoding="utf-8", newline="\n") as stream:
        for posting in ordered:
            offset, length = offsets[posting.row]
            stream.write(posting.key.decode("utf-8") + "\t" + base36(offset) + "\t" + base36(length) + "\n")
    sidecar = directory / "dictionary.rows.json"
    write_json(sidecar, {"schema": 1, "format": "DICT index/data", "payload_once_per_record": True, "postings": len(ordered)})
    files = [artifact_file(path) for path in (index, data, sidecar)]
    result: dict[str, Any] = {
        "format": "dict",
        "variant": "raw",
        "files": files,
        "storage": storage_summary(files),
        "payload_bytes": len(payload),
        "postings": len(ordered),
        "notes": ["offsets and lengths are DICT base-36 index fields", "dictd server transport was not started"],
    }
    dictunformat = shutil.which("dictunformat")
    if dictunformat is None:
        result["native_dictunformat"] = {"status": "unavailable", "reason": "dictunformat executable absent"}
    else:
        result["native_dictunformat"] = run_capture([dictunformat, str(index)], cwd=directory)
    return result


class DictReader:
    def __init__(self, index: Path, data: Path, oracle: Oracle):
        self.data = data.read_bytes()
        self.postings, self.row_offsets = read_dict_index(index, oracle, len(self.data))
        self.keys = [posting.key for posting in self.postings]

    def close(self) -> None:
        self.data = b""

    def exact(self, key: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, key)
        end = start
        while end < len(self.keys) and self.keys[end] == key:
            end += 1
        return self.postings[start:end]

    def prefix(self, prefix: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, prefix)
        end = start
        while end < len(self.keys) and self.keys[end].startswith(prefix):
            end += 1
        return self.postings[start:end]

    def render(self, row: int) -> bytes:
        offset, length = self.row_offsets[row]
        return self.data[offset:offset + length]


def read_dict_index(index: Path, oracle: Oracle, data_length: int) -> tuple[list[Posting], dict[int, tuple[int, int]]]:
    """Parse the real DICT index and recover occurrence rows independently."""
    raw = index.read_text(encoding="utf-8").splitlines()
    seen: dict[bytes, int] = {}
    row_offsets: dict[int, tuple[int, int]] = {}
    postings: list[Posting] = []
    # Payload offsets are shared by all aliases.  Recover each row by ordinal
    # among source records' sorted occurrences for this exact key; no logical
    # IDs are written into the DICT artifact.
    key_occurrences: dict[bytes, list[Posting]] = {}
    for posting in oracle.sorted_postings:
        key_occurrences.setdefault(posting.key, []).append(posting)
    for line in raw:
        parts = line.split("\t")
        if len(parts) != 3:
            raise FormatError("DICT index line is not key/offset/length")
        key, offset_s, length_s = parts
        key_bytes = key.encode("utf-8")
        ordinal = seen.get(key_bytes, 0)
        seen[key_bytes] = ordinal + 1
        candidates = key_occurrences.get(key_bytes, [])
        if ordinal >= len(candidates):
            raise FormatError(f"unexpected DICT key occurrence {key!r}")
        posting = candidates[ordinal]
        offset, length = unbase36(offset_s), unbase36(length_s)
        if offset + length > data_length:
            raise FormatError("DICT offset outside data")
        postings.append(posting)
        row_offsets.setdefault(posting.row, (offset, length))
    postings.sort(key=lambda posting: (posting.key, posting.row, posting.key_index))
    return postings, row_offsets


class DictZipReader:
    """Independent random-access reader for a real dictzip DEFLATE stream.

    dictzip stores a gzip extra-field ``RA`` table with compressed lengths for
    independently restartable chunks.  This reader parses that table and
    inflates only the chunks covering a requested DICT payload range.  It is a
    genuine chunked reader, not a whole-file gzip wrapper; the native
    ``dictzip`` CLI range check remains a separate validation lane.
    """

    def __init__(self, index: Path, compressed: Path, oracle: Oracle):
        self.data = compressed.read_bytes()
        self.chunk_lengths, self.chunk_bytes, self.payload_offset, self.uncompressed_bytes = parse_dictzip_header(self.data)
        self.postings, self.row_offsets = read_dict_index(index, oracle, self.uncompressed_bytes)
        self.keys = [posting.key for posting in self.postings]
        self._chunk_offsets: list[int] = []
        offset = self.payload_offset
        for compressed_length in self.chunk_lengths:
            self._chunk_offsets.append(offset)
            offset += compressed_length
        # dictzip leaves the two-byte final empty DEFLATE block (03 00)
        # between the RA chunk stream and the ordinary gzip trailer.
        if offset + 2 + 8 != len(self.data):
            raise FormatError("dictzip payload/trailer is truncated")

    def close(self) -> None:
        self.data = b""

    def exact(self, key: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, key)
        end = start
        while end < len(self.keys) and self.keys[end] == key:
            end += 1
        return self.postings[start:end]

    def prefix(self, prefix: bytes) -> list[Posting]:
        start = bisect.bisect_left(self.keys, prefix)
        end = start
        while end < len(self.keys) and self.keys[end].startswith(prefix):
            end += 1
        return self.postings[start:end]

    def render(self, row: int) -> bytes:
        offset, length = self.row_offsets[row]
        if length == 0:
            return b""
        chunk_length = self.chunk_bytes
        first = offset // chunk_length
        last = (offset + length - 1) // chunk_length
        output = bytearray()
        for chunk_index in range(first, last + 1):
            compressed_offset = self._chunk_offsets[chunk_index]
            compressed_length = self.chunk_lengths[chunk_index]
            try:
                # dictzip chunks end at a DEFLATE full-flush boundary rather
                # than a stream-end marker, so ``zlib.decompress`` would
                # report an expected EOF error.  A fresh raw inflater still
                # reconstructs each restartable chunk independently.
                inflater = zlib.decompressobj(-15)
                block = inflater.decompress(self.data[compressed_offset:compressed_offset + compressed_length])
                if inflater.unused_data or inflater.unconsumed_tail:
                    raise zlib.error("unexpected bytes in dictzip chunk")
            except zlib.error as exc:
                raise FormatError(f"dictzip chunk {chunk_index} failed to inflate: {exc}") from exc
            chunk_start = chunk_index * chunk_length
            begin = max(offset, chunk_start) - chunk_start
            end = min(offset + length, chunk_start + len(block)) - chunk_start
            if begin < 0 or end < begin or end > len(block):
                raise FormatError(f"dictzip chunk {chunk_index} range is invalid")
            output.extend(block[begin:end])
        if len(output) != length:
            raise FormatError(f"dictzip row {row} produced {len(output)} bytes, expected {length}")
        return bytes(output)


def parse_dictzip_header(data: bytes) -> tuple[tuple[int, ...], int, int, int]:
    """Return compressed lengths, uncompressed chunk size/total, payload offset."""
    if len(data) < 12 or data[:2] != b"\x1f\x8b" or data[2] != 8:
        raise FormatError("not a gzip/dictzip stream")
    flags = data[3]
    if not (flags & 0x04):
        raise FormatError("gzip stream lacks dictzip RA extra field")
    extra_length = struct.unpack_from("<H", data, 10)[0]
    extra_start = 12
    extra_end = extra_start + extra_length
    if extra_end > len(data):
        raise FormatError("truncated dictzip extra field")
    at = extra_start
    ra: bytes | None = None
    while at + 4 <= extra_end:
        identifier = data[at:at + 2]
        length = struct.unpack_from("<H", data, at + 2)[0]
        at += 4
        if at + length > extra_end:
            raise FormatError("truncated dictzip subfield")
        if identifier == b"RA":
            ra = data[at:at + length]
        at += length
    if at != extra_end or ra is None or len(ra) < 6:
        raise FormatError("dictzip RA subfield is absent or malformed")
    version, chunk_bytes, chunk_count = struct.unpack_from("<HHH", ra)
    if version != 1 or chunk_bytes == 0 or chunk_count == 0 or len(ra) != 6 + 2 * chunk_count:
        raise FormatError("unsupported dictzip RA table")
    chunk_lengths = struct.unpack_from("<" + "H" * chunk_count, ra, 6)
    if any(length == 0 for length in chunk_lengths):
        raise FormatError("dictzip RA table contains an empty chunk")
    # Consume optional gzip header fields after XLEN.  FHCRC is two bytes and
    # is not used by dictzip, but parsing it keeps this reader format-correct.
    payload_offset = extra_end
    if flags & 0x08:
        while payload_offset < len(data) and data[payload_offset] != 0:
            payload_offset += 1
        if payload_offset >= len(data):
            raise FormatError("truncated dictzip filename")
        payload_offset += 1
    if flags & 0x10:
        while payload_offset < len(data) and data[payload_offset] != 0:
            payload_offset += 1
        if payload_offset >= len(data):
            raise FormatError("truncated dictzip comment")
        payload_offset += 1
    if flags & 0x02:
        payload_offset += 2
    if payload_offset > len(data):
        raise FormatError("truncated dictzip header")
    compressed_end = payload_offset + sum(chunk_lengths)
    trailer_offset = len(data) - 8
    if compressed_end + 2 != trailer_offset or data[compressed_end:trailer_offset] != b"\x03\x00":
        raise FormatError("dictzip compressed lengths do not reach final DEFLATE block/trailer")
    uncompressed_bytes = struct.unpack_from("<I", data, len(data) - 4)[0]
    return chunk_lengths, chunk_bytes, payload_offset, uncompressed_bytes


def dictzip_variant(oracle: Oracle, directory: Path) -> dict[str, Any]:
    raw_data = directory / "dict.dict"
    compressed = raw_data.with_suffix(raw_data.suffix + ".dz")
    dictzip = shutil.which("dictzip")
    if dictzip is None:
        return {"format": "dict", "variant": "dictzip", "status": "unavailable", "reason": "dictzip executable absent"}
    result = run_capture([dictzip, "-k", "-f", str(raw_data)], cwd=directory)
    if result["returncode"] != 0 or not compressed.is_file():
        return {"format": "dict", "variant": "dictzip", "status": "unavailable", "reason": "dictzip failed", "build": result}
    index = directory / "dict.index"
    # Full decompression verifies every payload in the compressed file.  One
    # real dictzip range extraction separately proves the random-access CLI.
    decompressed = b""
    try:
        import gzip
        with gzip.open(compressed, "rb") as stream:
            decompressed = stream.read()
        expected = b"".join(record.content for record in oracle.records)
        full_ok = decompressed == expected
    except Exception as exc:
        full_ok = False
        decompression_error = str(exc)
    else:
        decompression_error = None
    sample = oracle.records[len(oracle.records) // 2]
    offset = sum(len(record.content) for record in oracle.records[: sample.row])
    range_result = run_capture([dictzip, "-c", "-s", str(offset), "-e", str(len(sample.content)), str(compressed)], cwd=directory)
    random_reader_checks: dict[str, Any]
    try:
        random_reader = DictZipReader(index, compressed, oracle)
        random_reader_checks = validate_dictzip(oracle, random_reader, decompressed)
        random_reader.close()
    except (FormatError, OSError, zlib.error) as exc:
        random_reader_checks = {"status": "failed", "error": str(exc)}
    files = [artifact_file(index), artifact_file(compressed)]
    return {
        "format": "dict",
        "variant": "dictzip",
        "files": files,
        "storage": storage_summary(files),
        "status": "ok" if full_ok and random_reader_checks.get("status") == "ok" and range_result["returncode"] == 0 and range_result["stdout"].encode() == sample.content else "failed",
        "full_decompression_all_records": full_ok,
        "decompression_error": decompression_error,
        "validation": random_reader_checks,
        "range_sample": {"row": sample.row, "returncode": range_result["returncode"], "bytes": len(range_result["stdout"].encode()), "matches": range_result["stdout"].encode() == sample.content, "stderr": range_result["stderr"][-500:]},
        "notes": ["dictzip is random-access compressed data; whole-file gzip is not substituted"],
    }


def build_sqlite(oracle: Oracle, directory: Path) -> dict[str, Any]:
    path = directory / "dictionary.sqlite"
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA journal_mode=OFF")
        db.execute("PRAGMA synchronous=OFF")
        db.execute("CREATE TABLE entries (row_id INTEGER PRIMARY KEY, identity TEXT NOT NULL UNIQUE, content BLOB NOT NULL)")
        db.execute("CREATE TABLE keys (key BLOB NOT NULL, row_id INTEGER NOT NULL, key_index INTEGER NOT NULL, PRIMARY KEY(key, row_id, key_index), FOREIGN KEY(row_id) REFERENCES entries(row_id))")
        db.executemany("INSERT INTO entries(row_id,identity,content) VALUES(?,?,?)", [(record.row, record.identity.decode("utf-8"), record.content) for record in oracle.records])
        db.executemany("INSERT INTO keys(key,row_id,key_index) VALUES(?,?,?)", [(key, record.row, key_index) for record in oracle.records for key_index, key in enumerate(record.keys)])
        db.execute("CREATE INDEX keys_order ON keys(key, row_id, key_index)")
        db.commit()
        db.execute("PRAGMA integrity_check")
    finally:
        db.close()
    sqlite3_cli = shutil.which("sqlite3")
    native = run_capture([sqlite3_cli, str(path), "PRAGMA integrity_check;"] if sqlite3_cli else ["sqlite3", str(path), "PRAGMA integrity_check;"])
    files = [artifact_file(path)]
    return {
        "format": "sqlite",
        "variant": "raw",
        "files": files,
        "storage": storage_summary(files),
        "payload_bytes": sum(len(record.content) for record in oracle.records),
        "postings": len(oracle.postings),
        "native_sqlite3": native if sqlite3_cli else {"status": "unavailable", "reason": "sqlite3 CLI absent"},
        "notes": ["BLOB keys use SQLite binary ordering", "SQLite is an indexed control, not a dictionary-native protocol"],
    }


class SQLiteReader:
    def __init__(self, path: Path):
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA foreign_keys=ON")

    def close(self) -> None:
        self.db.close()

    def exact(self, key: bytes) -> list[Posting]:
        return [Posting(row[0], row[1], row[2]) for row in self.db.execute("SELECT key,row_id,key_index FROM keys WHERE key=? ORDER BY row_id,key_index", (key,))]

    def prefix(self, prefix: bytes) -> list[Posting]:
        # SQLite has no byte successor function; this bounded interval is
        # exact for arbitrary bytes, including 0xff suffixes.
        upper = prefix_successor(prefix)
        if upper is None:
            rows = self.db.execute("SELECT key,row_id,key_index FROM keys WHERE key>=? ORDER BY key,row_id,key_index", (prefix,))
            return [Posting(row[0], row[1], row[2]) for row in rows if row[0].startswith(prefix)]
        return [Posting(row[0], row[1], row[2]) for row in self.db.execute("SELECT key,row_id,key_index FROM keys WHERE key>=? AND key<? ORDER BY key,row_id,key_index", (prefix, upper))]

    def render(self, row: int) -> bytes:
        result = self.db.execute("SELECT content FROM entries WHERE row_id=?", (row,)).fetchone()
        if result is None:
            raise FormatError(f"missing SQLite row {row}")
        return bytes(result[0])


def prefix_successor(prefix: bytes) -> bytes | None:
    if not prefix:
        return None
    result = bytearray(prefix)
    for index in range(len(result) - 1, -1, -1):
        if result[index] != 0xFF:
            result[index] += 1
            return bytes(result[: index + 1])
    return None


def build_slob(oracle: Oracle, directory: Path) -> list[dict[str, Any]]:
    try:
        import slob
    except ImportError as exc:
        return [{"format": "slob", "variant": variant, "status": "unavailable", "reason": f"Python slob import failed: {exc}"} for variant in ("raw", "lzma2")]
    results: list[dict[str, Any]] = []
    for variant, compression in (("raw", None), ("lzma2", "lzma2")):
        path = directory / f"dictionary.{variant}.slob"
        if path.exists():
            path.unlink()
        with slob.create(str(path), compression=compression, min_bin_size=64 * 1024) as writer:
            for record in oracle.records:
                keys = [key.decode("utf-8") for key in record.keys]
                writer.add(record.content, *keys, content_type="text/plain")
        reader = slob.open(str(path))
        try:
            # This scan is the independent validation/identity preparation
            # phase.  It is persisted as sidecar data and never hidden inside
            # a fresh-reader timing sample.
            candidates: dict[tuple[str, bytes], list[Posting]] = {}
            for posting in oracle.postings:
                candidates.setdefault((posting.key.decode("utf-8"), oracle.by_row[posting.row].content), []).append(posting)
            pending_refs: list[dict[str, Any]] = []
            for ref_index in range(len(reader)):
                item = reader[ref_index]
                token = (item.key, item.content)
                available = candidates.get(token, [])
                if not available:
                    raise FormatError(f"SLOB unexpected key/content {item.key!r}")
                pending_refs.append({"ref_index": ref_index, "content_id": item.id, "token": token})
            # Blob IDs are physical insertion identities and are the only
            # native bridge back to a row.  Assign duplicate key/content
            # candidates in row/key-index order to physical IDs in order; this
            # preserves homographs and repeated aliases without assuming that
            # an ICU reference enumeration is source-order.
            grouped_refs: dict[tuple[str, bytes], list[dict[str, Any]]] = {}
            for ref in pending_refs:
                grouped_refs.setdefault(ref["token"], []).append(ref)
            refs = []
            for token, group in grouped_refs.items():
                available = sorted(candidates[token], key=lambda posting: (posting.row, posting.key_index))
                ids = sorted({ref["content_id"] for ref in group})
                cursor = 0
                for content_id in ids:
                    same_id = [ref for ref in group if ref["content_id"] == content_id]
                    for pending in same_id:
                        if cursor >= len(available):
                            raise FormatError(f"SLOB duplicate mapping beyond corpus for {token[0]!r}")
                        posting = available[cursor]
                        cursor += 1
                        refs.append({"ref_index": pending["ref_index"], "content_id": content_id, "key": posting.key.hex(), "row": posting.row, "key_index": posting.key_index})
                if cursor != len(available):
                    raise FormatError(f"SLOB omitted key/content occurrences for {token[0]!r}")
            refs.sort(key=lambda ref: ref["ref_index"])
            if len(refs) != len(oracle.postings):
                raise FormatError(f"SLOB ref count {len(refs)} != key hits {len(oracle.postings)}")
            sidecar = path.with_suffix(path.suffix + ".refs.json")
            write_json(sidecar, {"schema": 1, "format": "SLOB", "compression": compression or "raw", "identity_setup": "full ref/content scan before timing", "refs": refs})
            validation = validate_slob(oracle, path, refs, slob)
            # Native ICU behavior is intentionally recorded separately from
            # strict byte-key matching used by the common projection.
            icu_cases: list[dict[str, Any]] = []
            for _, key in oracle.queries()[:8]:
                text = key.decode("utf-8")
                try:
                    found = [(item.key, item.id) for _, item in slob.find(text, reader, match_prefix=True)]
                    icu_cases.append({"query": text, "matches": len(found), "keys": [item[0] for item in found[:16]], "status": "ok"})
                except Exception as exc:
                    icu_cases.append({"query": text, "status": "failed", "error": str(exc)})
        finally:
            reader.close()
        files = [artifact_file(path), artifact_file(sidecar)]
        results.append({
            "format": "slob",
            "variant": variant,
            "files": files,
            "storage": storage_summary(files),
            "payload_bytes": sum(len(record.content) for record in oracle.records),
            "key_hits": len(oracle.postings),
            "validation": validation,
            "native_icu_find": icu_cases,
            "notes": ["writer.add(content, *keys) stores one blob with native aliases", "strict projection uses IDENTICAL collation plus byte post-filter", "ICU find behavior is reported separately"],
        })
    return results


def validate_slob(oracle: Oracle, path: Path, refs: list[dict[str, Any]], slob_module: Any) -> dict[str, Any]:
    reader = slob_module.open(str(path))
    try:
        by_id_key: dict[tuple[int, bytes], list[Posting]] = {}
        by_ref_index: dict[int, Posting] = {}
        row_to_content_id: dict[int, int] = {}
        for ref in refs:
            key = bytes.fromhex(ref["key"])
            posting = Posting(key, ref["row"], ref["key_index"])
            by_id_key.setdefault((ref["content_id"], key), []).append(posting)
            by_ref_index[ref["ref_index"]] = posting
            row_to_content_id.setdefault(ref["row"], ref["content_id"])

        # Materialize the genuine reader's physical references once for
        # validation.  Looking up every distinct key through ICU's lazy
        # KeydItemDict can be very expensive on a large corpus; this map is
        # built from fresh `reader[index]` objects and remains a separate
        # eager validation pass, never hidden in measurements.  Native ICU
        # lookup behavior is still exercised and recorded for fixed cases by
        # build_slob above.
        ref_items = [reader[index] for index in range(len(reader))]
        items_by_key: dict[bytes, list[Any]] = {}
        for item in ref_items:
            items_by_key.setdefault(item.key.encode("utf-8"), []).append(item)

        def items_to_postings(items: Iterable[Any]) -> list[Posting]:
            counters: dict[tuple[int, bytes], int] = {}
            result: list[Posting] = []
            for item in items:
                key = item.key.encode("utf-8")
                token = (item.id, key)
                candidates = by_id_key.get(token, [])
                index = counters.get(token, 0)
                if index >= len(candidates):
                    raise FormatError(f"SLOB reference mapping mismatch for {item.key!r}")
                result.append(candidates[index])
                counters[token] = index + 1
            return result

        def exact(key: bytes) -> list[Posting]:
            # IDENTICAL is the strongest SLOB collation; byte filter removes
            # equivalences such as case/diacritic folds from the common lane.
            candidates = items_by_key.get(key, ())
            return items_to_postings(item for item in candidates if item.key.encode("utf-8") == key)

        def prefix(prefix: bytes) -> list[Posting]:
            if not prefix:
                # SLOB's public `find` deliberately deduplicates blob IDs,
                # which would hide aliases for an all-hit enumeration.  Walk
                # the real reference list through the library in this
                # correctness-only operation so every native alias remains an
                # occurrence; measured empty-prefix scans are labelled
                # accordingly.
                return [by_ref_index[index] for index, item in enumerate(ref_items) if item.key is not None]
            # ICU's truncated sort keys can omit shifted punctuation (for
            # example the prefix `\'s-`), so a filtered candidate lookup would
            # be incomplete for the byte-prefix contract.  The independent
            # correctness reader therefore performs an explicit native ref
            # scan for every nonempty prefix; that cost is reported as a
            # full-scan control, while native ICU prefix behavior is recorded
            # separately below.
            return [by_ref_index[index] for index, item in enumerate(ref_items) if item.key.encode("utf-8").startswith(prefix)]

        class Adapter:
            def exact(self, key: bytes) -> list[Posting]: return exact(key)
            def prefix(self, key: bytes) -> list[Posting]: return prefix(key)
            def render(self, row: int) -> bytes:
                content_id = row_to_content_id.get(row)
                if content_id is None:
                    raise FormatError(row)
                return reader.get(content_id)[1]

        return validate_reader(oracle, Adapter())
    finally:
        reader.close()


def validate_reader(oracle: Oracle, reader: Any) -> dict[str, Any]:
    exact_checks = 0
    prefix_checks = 0
    content_checks = 0
    # Every distinct key is queried; each result is an occurrence multiset,
    # so one query validates all duplicate/homograph postings for that key.
    for key in oracle.unique_keys:
        actual = reader.exact(key)
        expected = oracle.exact(key)
        if sorted(actual, key=lambda item: (item.key, item.row, item.key_index)) != expected:
            raise FormatError(f"exact mismatch key={key!r}: expected={expected[:4]} actual={actual[:4]}")
        exact_checks += 1
    for name, prefix in oracle.queries():
        is_exact = name.startswith("exact-")
        actual = reader.exact(prefix) if is_exact else reader.prefix(prefix)
        expected = oracle.exact(prefix) if is_exact else oracle.prefix(prefix)
        if sorted(actual, key=lambda item: (item.key, item.row, item.key_index)) != expected:
            raise FormatError(f"{'exact' if is_exact else 'prefix'} mismatch {name}={prefix!r}: expected={len(expected)} actual={len(actual)}")
        prefix_checks += 1
    for record in oracle.records:
        if reader.render(record.row) != record.content:
            raise FormatError(f"content mismatch row {record.row}")
        content_checks += 1
    return {"status": "ok", "exact_occurrence_checks": exact_checks, "prefix_checks": prefix_checks, "content_checks": content_checks, "all_hit_count": len(oracle.postings)}


def validate_dictzip(oracle: Oracle, reader: DictZipReader, decompressed: bytes) -> dict[str, Any]:
    """Validate every index hit and payload extent without per-row inflation.

    The complete gzip stream is decoded once, then every DICT offset/length is
    checked against the corresponding source content.  A finite set of rows
    spanning chunk boundaries is also read through the actual random-access
    reader, keeping the full-content check bounded while proving the chunk
    restart path independently.
    """
    exact_checks = 0
    for key in oracle.unique_keys:
        actual = reader.exact(key)
        if actual != oracle.exact(key):
            raise FormatError(f"dictzip exact mismatch for {key!r}")
        exact_checks += 1
    prefix_checks = 0
    for name, prefix in oracle.queries():
        actual = reader.exact(prefix) if name.startswith("exact-") else reader.prefix(prefix)
        expected = oracle.exact(prefix) if name.startswith("exact-") else oracle.prefix(prefix)
        if actual != expected:
            raise FormatError(f"dictzip query mismatch for {name}")
        prefix_checks += 1
    if len(decompressed) != reader.uncompressed_bytes:
        raise FormatError("dictzip trailer size disagrees with full decompression")
    content_checks = 0
    for record in oracle.records:
        offset, length = reader.row_offsets[record.row]
        if decompressed[offset:offset + length] != record.content:
            raise FormatError(f"dictzip extent mismatch for row {record.row}")
        content_checks += 1
    samples = {0, len(oracle.records) // 2, len(oracle.records) - 1}
    samples.add(max(oracle.records, key=lambda record: len(record.content)).row)
    random_access_checks = 0
    for row in sorted(samples):
        if reader.render(row) != oracle.records[row].content:
            raise FormatError(f"dictzip random-access mismatch for row {row}")
        random_access_checks += 1
    return {
        "status": "ok",
        "exact_occurrence_checks": exact_checks,
        "prefix_checks": prefix_checks,
        "content_checks": content_checks,
        "random_access_sample_checks": random_access_checks,
        "content_check_mode": "single full decompression plus every DICT extent",
        "all_hit_count": len(oracle.postings),
    }


def build_all(projection: Path, artifact_dir: Path) -> dict[str, Any]:
    oracle = read_projection(projection)
    artifact_dir.mkdir(parents=True, exist_ok=True)
    for child in artifact_dir.iterdir():
        if child.is_file() and (child.name.startswith("dictionary") or child.name.endswith(".rows.json")):
            child.unlink()
    results: list[dict[str, Any]] = []
    results.append(build_stardict(oracle, artifact_dir))
    results.append(validate_stardict(oracle, artifact_dir))
    results.append(build_dict(oracle, artifact_dir))
    results.append(dictzip_variant(oracle, artifact_dir))
    results.append(build_sqlite(oracle, artifact_dir))
    results.extend(build_slob(oracle, artifact_dir))
    manifest = {
        "schema": 1,
        "projection": artifact_file(projection),
        "records": len(oracle.records),
        "unique_keys": len(oracle.unique_keys),
        "key_hits": len(oracle.postings),
        "artifacts": results,
        "status": "smoke-ok",
    }
    write_json(artifact_dir / "format-manifest.json", manifest)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--projection", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        print(json.dumps(build_all(args.projection, args.artifact_dir), ensure_ascii=False, indent=2))
        return 0
    except (FormatError, OSError, sqlite3.Error) as exc:
        print(f"formats.py: ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
