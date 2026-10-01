#!/usr/bin/env python3
"""Gate-controlled real-world format measurements.

This file is intentionally separate from the non-timed smoke/sweep harness.
It refuses to read a clock unless ``--quiet-gate
ROOT-EXPLICIT-QUIET-GATE`` is present.  The schedule is fixed in
``manifest.json``: three paired fresh-process samples, one warmup, 256 fast
operations, three prefix batches, and explicit first/cold versus warm phases.
Native CLI process wall time, custom Python reader time, and LEX6 in-process
phase time are retained as different measurements and are never ranked as
cross-language microsecond results.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
GATE = "ROOT-EXPLICIT-QUIET-GATE"
CORPORA = ("freedict-eng-spa", "gcide-054", "omw-ja-20")
CODECS = ("raw", "adaptive", "bzip3")
EXTERNAL_LANES = ("stardict", "dict", "dictzip", "sqlite", "slob-raw", "slob-lzma2")
BATCH_OPS = 256
PROCESS_RUNS = 3
PREFIX_BATCHES = 3

sys.path.insert(0, str(ROOT))
import formats  # noqa: E402


def digest_hex(values: Iterable[bytes], marker: bytes) -> str:
    state = hashlib.sha256()
    state.update(marker)
    state.update(b"\0")
    for value in values:
        state.update(len(value).to_bytes(8, "little"))
        state.update(value)
    return state.hexdigest()


def posting_digest(postings: Sequence[formats.Posting], key: bytes, marker: bytes = b"timed-query-v1") -> str:
    values: list[bytes] = [key]
    for posting in postings:
        values.extend((posting.row.to_bytes(4, "little"), posting.key, posting.key_index.to_bytes(4, "little")))
    return digest_hex(values, marker)


def reader_content_digest(content: bytes, *, snippet: bool) -> str:
    selected = content[:256] if snippet else content
    return digest_hex((selected,), b"timed-content-snippet-v1" if snippet else b"timed-content-v1")


def lex6_query_digest(oracle: formats.Oracle, mode: str, key: bytes, *, repeat: int = 1, selected: Sequence[dict[str, Any]] | None = None) -> tuple[int, int, str]:
    """Mirror the runner's length-framed query checksum independently."""
    queries = selected or [{"mode": mode, "key": key}]
    state = hashlib.sha256()
    state.update(b"measure-query-hits-v1\0")
    hits = key_bytes = 0
    for index in range(repeat):
        query = queries[index % len(queries)]
        query_key = query["key"]
        postings = oracle.exact(query_key) if query["mode"] == "exact" else oracle.prefix(query_key)
        state.update(len(query_key).to_bytes(8, "little"))
        state.update(query_key)
        for posting in postings:
            row = posting.row.to_bytes(4, "little")
            state.update(len(row).to_bytes(8, "little")); state.update(row)
            state.update(len(posting.key).to_bytes(8, "little")); state.update(posting.key)
            state.update(b"form:null\0")
            hits += 1
            key_bytes += len(posting.key)
    return hits, key_bytes, state.hexdigest()


def lex6_render_digest(oracle: formats.Oracle, rows: Sequence[dict[str, Any]], *, repeat: int, snippet: bool, marker: bytes) -> tuple[int, str]:
    state = hashlib.sha256()
    state.update(marker); state.update(b"\0")
    output_bytes = 0
    for index in range(repeat):
        content = oracle.by_row[rows[index % len(rows)]["row"]].content
        selected = content[:256] if snippet else content
        state.update(len(selected).to_bytes(8, "little")); state.update(selected)
        output_bytes += len(selected)
    return output_bytes, state.hexdigest()


def validate_lex6_timed_result(oracle: formats.Oracle, queries: Sequence[dict[str, Any]], rows: Sequence[dict[str, Any]], result: dict[str, Any]) -> None:
    """Require every LEX6 timed phase to consume the fixed oracle workload."""
    exact_queries = [query for query in queries if query["mode"] == "exact"]
    prefix_queries = [query for query in queries if query["mode"] == "prefix"]
    render_rows = [row for row in rows if row["label"].startswith("render-")]
    snippet_rows = [row for row in rows if row["label"].startswith("snippet-")]
    first_exact = result.get("first_exact", [])
    if len(first_exact) != len(exact_queries):
        raise RuntimeError("LEX6 timed result omitted a first exact case")
    for actual, query in zip(first_exact, exact_queries):
        hits, key_bytes, digest = lex6_query_digest(oracle, "exact", query["key"])
        expected = {"label": query["label"], "hits": hits, "key_bytes": key_bytes, "digest": digest}
        for field, value in expected.items():
            if actual.get(field) != value:
                raise RuntimeError(f"LEX6 first exact mismatch {query['label']} field={field}: expected={value!r} actual={actual.get(field)!r}")
    hits, key_bytes, digest = lex6_query_digest(oracle, "exact", b"", repeat=BATCH_OPS, selected=exact_queries)
    expected_exact = {"operations": BATCH_OPS, "hits": hits, "key_bytes": key_bytes, "digest": digest}
    for field, value in expected_exact.items():
        if result.get("exact_batch", {}).get(field) != value:
            raise RuntimeError(f"LEX6 exact batch mismatch field={field}: expected={value!r} actual={result.get('exact_batch', {}).get(field)!r}")
    expected_prefix = lex6_query_digest(oracle, "prefix", b"", repeat=1, selected=prefix_queries)
    expected_prefix_ops = len(prefix_queries)
    # The runner emits each predefined prefix exactly once per batch.
    prefix_hits, prefix_key_bytes, prefix_digest = lex6_query_digest(oracle, "prefix", b"", repeat=expected_prefix_ops, selected=prefix_queries)
    for actual in result.get("prefix_batches", []):
        expected = {"operations": expected_prefix_ops, "hits": prefix_hits, "key_bytes": prefix_key_bytes, "digest": prefix_digest}
        for field, value in expected.items():
            if actual.get(field) != value:
                raise RuntimeError(f"LEX6 prefix batch mismatch field={field}: expected={value!r} actual={actual.get(field)!r}")
    if len(result.get("prefix_batches", [])) != PREFIX_BATCHES:
        raise RuntimeError("LEX6 timed result omitted a prefix batch")
    for label, selected_rows, snippet, marker in (
        ("first_render", render_rows, False, b"measure-render-v1"),
        ("first_snippet", snippet_rows, True, b"measure-snippet-v1"),
    ):
        actual_items = result.get(label, [])
        if len(actual_items) != len(selected_rows):
            raise RuntimeError(f"LEX6 timed result omitted {label} cases")
        for actual, row in zip(actual_items, selected_rows):
            content = oracle.by_row[row["row"]].content
            selected = content[:256] if snippet else content
            expected = {"label": row["label"], "output_bytes": len(selected), "digest": digest_hex((selected,), marker)}
            for field, value in expected.items():
                if actual.get(field) != value:
                    raise RuntimeError(f"LEX6 {label} mismatch row={row['row']} field={field}: expected={value!r} actual={actual.get(field)!r}")
    for label, selected_rows, snippet, marker in (
        ("uncached_render_batch", render_rows, False, b"measure-render-v1"),
        ("uncached_snippet_batch", snippet_rows, True, b"measure-snippet-v1"),
    ):
        output_bytes, digest = lex6_render_digest(oracle, selected_rows, repeat=BATCH_OPS, snippet=snippet, marker=marker)
        expected = {"operations": BATCH_OPS, "output_bytes": output_bytes, "digest": digest}
        for field, value in expected.items():
            if result.get(label, {}).get(field) != value:
                raise RuntimeError(f"LEX6 {label} mismatch field={field}: expected={value!r} actual={result.get(label, {}).get(field)!r}")
    session_specs = (
        ("session_first_cold", [render_rows[0]], 1, False, b"measure-session-first-cold-v1"),
        ("session_same_page_render", [render_rows[0]], BATCH_OPS, False, b"measure-session-same-page-v1"),
        ("session_mixed_page_render", render_rows, BATCH_OPS, False, b"measure-session-mixed-page-v1"),
        ("session_mixed_page_snippet", snippet_rows, BATCH_OPS, True, b"measure-session-mixed-page-snippet-v1"),
    )
    for label, selected_rows, count, snippet, marker in session_specs:
        output_bytes, digest = lex6_render_digest(oracle, selected_rows, repeat=count, snippet=snippet, marker=marker)
        actual = result.get(label, {})
        for field, value in {"operations": count, "output_bytes": output_bytes, "digest": digest}.items():
            if actual.get(field) != value:
                raise RuntimeError(f"LEX6 {label} mismatch field={field}: expected={value!r} actual={actual.get(field)!r}")
    first = result.get("session_first_cold", {})
    same = result.get("session_same_page_render", {})
    mixed = result.get("session_mixed_page_render", {})
    if first.get("page_loads", 0) < 1 or first.get("cache_hits", 0) != 0:
        raise RuntimeError(f"LEX6 session cold phase did not show a cold page decode: {first}")
    if same.get("page_loads") != 0 or same.get("cache_hits") != BATCH_OPS:
        raise RuntimeError(f"LEX6 session same-page phase did not show cache hits: {same}")
    if mixed.get("page_loads", 0) < 1:
        raise RuntimeError(f"LEX6 session mixed-page phase did not cross a page boundary: {mixed}")


def run_capture(argv: Sequence[str], *, cwd: Path | None = None) -> dict[str, Any]:
    """Run a child process and record wall time plus complete text output."""
    started = time.perf_counter_ns()
    try:
        result = subprocess.run(
            list(argv), cwd=cwd, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            timeout=300,
        )
    except subprocess.TimeoutExpired as exc:
        def decode(value: bytes | str | None) -> str:
            if value is None:
                return ""
            return value.decode("utf-8", "replace") if isinstance(value, bytes) else value
        return {"argv": list(argv), "cwd": str(cwd) if cwd else None, "returncode": None, "wall_ns": time.perf_counter_ns() - started, "stdout": decode(exc.stdout), "stderr": decode(exc.stderr), "error": "TimeoutExpired", "timeout_s": 300}
    except OSError as exc:
        return {"argv": list(argv), "cwd": str(cwd) if cwd else None, "returncode": None, "wall_ns": time.perf_counter_ns() - started, "stdout": "", "stderr": str(exc), "error": type(exc).__name__}
    return {
        "argv": list(argv),
        "cwd": str(cwd) if cwd else None,
        "returncode": result.returncode,
        "wall_ns": time.perf_counter_ns() - started,
        "stdout": result.stdout.decode("utf-8", "replace"),
        "stderr": result.stderr.decode("utf-8", "replace"),
    }


def write_measure_plan(oracle: formats.Oracle, query_path: Path, rows_path: Path) -> dict[str, Any]:
    """Write a fixed labeled plan; expected answers never enter the reader."""
    exact: list[tuple[str, bytes]] = []
    prefixes: list[tuple[str, bytes]] = []
    seen_exact: set[bytes] = set()
    seen_prefix: set[bytes] = set()
    label_counts: dict[str, int] = {}

    def unique_label(name: str) -> str:
        ordinal = label_counts.get(name, 0) + 1
        label_counts[name] = ordinal
        return name if ordinal == 1 else f"{name}-{ordinal}"

    for name, key in oracle.queries():
        if name.startswith("exact-") and key not in seen_exact:
            exact.append((unique_label(name), key))
            seen_exact.add(key)
        elif name.startswith("prefix-") and key and key not in seen_prefix:
            prefixes.append((unique_label(name), key))
            seen_prefix.add(key)
    if not exact or not prefixes:
        raise formats.FormatError("timed plan lacks exact or nonempty prefix cases")
    query_path.parent.mkdir(parents=True, exist_ok=True)
    with query_path.open("w", encoding="ascii", newline="\n") as stream:
        for name, key in exact + prefixes:
            stream.write(f"{name}\t{'exact' if name.startswith('exact-') else 'prefix'}\t{key.hex()}\n")

    # The render rows are fixed by source order and one content-size edge.  A
    # separate snippet operation takes the first 256 rendered bytes.
    largest = max(oracle.records, key=lambda record: len(record.content))
    render_rows: list[int] = []
    for row in (0, len(oracle.records) // 2, len(oracle.records) - 1, largest.row):
        if row not in render_rows:
            render_rows.append(row)
    rows_path.parent.mkdir(parents=True, exist_ok=True)
    with rows_path.open("w", encoding="ascii", newline="\n") as stream:
        for row in render_rows:
            stream.write(f"render-{row}\t{row}\n")
        for row in render_rows:
            stream.write(f"snippet-{row}\t{row}\n")
    return {
        "exact": [{"label": name, "key": key.hex()} for name, key in exact],
        "prefix": [{"label": name, "key": key.hex()} for name, key in prefixes],
        "render_rows": render_rows,
        "query_file": formats.artifact_file(query_path),
        "rows_file": formats.artifact_file(rows_path),
    }


def load_measure_plan(query_path: Path, rows_path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    queries: list[dict[str, Any]] = []
    with query_path.open(encoding="ascii") as stream:
        for line in stream:
            if not line.strip():
                continue
            label, mode, key_hex = line.rstrip("\r\n").split("\t")
            queries.append({"label": label, "mode": mode, "key": bytes.fromhex(key_hex)})
    rows: list[dict[str, Any]] = []
    with rows_path.open(encoding="ascii") as stream:
        for line in stream:
            if not line.strip():
                continue
            label, row = line.rstrip("\r\n").split("\t")
            rows.append({"label": label, "row": int(row)})
    if not queries or not rows:
        raise formats.FormatError("empty timed query/row plan")
    return queries, rows


def parse_runner_output(text: str) -> dict[str, Any]:
    """Parse the stable tab protocol while retaining raw stdout separately."""
    result: dict[str, Any] = {"first_exact": [], "first_render": [], "first_snippet": [], "prefix_batches": []}
    for line in text.splitlines():
        fields = line.split("\t")
        if not fields:
            continue
        label = fields[0]
        if label in {"measure_status", "input_read_ns", "input_parse_ns", "artifact_read_ns", "query_plan_parse_ns", "metadata_open_ns", "reader_init_ns", "post_verify_all_ns"} and len(fields) >= 2:
            result[label] = fields[1] if label == "measure_status" else int(fields[1])
        elif label == "first_exact" and len(fields) >= 11:
            values = dict(zip(fields[1::2], fields[2::2]))
            result["first_exact"].append({"label": values["label"], "ns": int(values["ns"]), "hits": int(values["hits"]), "key_bytes": int(values["key_bytes"]), "digest": values["digest"]})
        elif label in {"exact_batch", "uncached_render_batch", "uncached_snippet_batch", "session_same_page_render", "session_mixed_page_render", "session_mixed_page_snippet"} and len(fields) >= 9:
            values = dict(zip(fields[1::2], fields[2::2]))
            result[label] = {key: int(value) if key in {"operations", "ns", "hits", "key_bytes", "output_bytes", "page_loads", "bzip3_decodes", "decoded_bytes", "cache_hits"} else value for key, value in values.items()}
        elif label == "prefix_batch" and len(fields) >= 11:
            values = dict(zip(fields[1::2], fields[2::2]))
            result["prefix_batches"].append({key: int(value) if key in {"batch", "operations", "ns", "hits", "key_bytes"} else value for key, value in values.items()})
        elif label in {"first_render", "first_snippet"} and len(fields) >= 9:
            values = dict(zip(fields[1::2], fields[2::2]))
            result[label].append({"label": values["label"], "ns": int(values["ns"]), "output_bytes": int(values["output_bytes"]), "digest": values["digest"]})
        elif label == "session_first_cold" and len(fields) >= 17:
            values = dict(zip(fields[1::2], fields[2::2]))
            result[label] = {key: int(value) if key in {"ns", "operations", "output_bytes", "page_loads", "bzip3_decodes", "decoded_bytes", "cache_hits"} else value for key, value in values.items()}
    if result.get("measure_status") != "ok" or "exact_batch" not in result or "uncached_render_batch" not in result or "uncached_snippet_batch" not in result:
        raise RuntimeError(f"invalid timed LEX6 output: {result}")
    return result


def run_lex6_samples(corpus: str, codec: str, oracle: formats.Oracle, artifact: Path, projection: Path, query_path: Path, rows_path: Path, runner: Path) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    plan_queries, plan_rows = load_measure_plan(query_path, rows_path)
    argv = [str(runner), "--mode", "measure", "--quiet-gate", GATE, "--input", str(projection), "--artifact", str(artifact), "--queries", str(query_path), "--rows", str(rows_path)]
    for sample_index in range(PROCESS_RUNS):
        process = run_capture(argv)
        if process["returncode"] != 0:
            raise RuntimeError(f"LEX6 timed lane failed {corpus}/{codec}/sample-{sample_index}: {process}")
        parsed = parse_runner_output(process["stdout"])
        validate_lex6_timed_result(oracle, plan_queries, plan_rows, parsed)
        samples.append({"sample": sample_index, "process": process, "phases": parsed})
    return {"format": "lex6", "codec": codec, "artifact": formats.artifact_file(artifact), "samples": samples}


class SlobMappedReader:
    """Strict byte-key view over a real SLOB reader and its charged sidecar."""

    def __init__(self, path: Path, refs_path: Path, slob_module: Any):
        self._slob = slob_module
        self.reader = slob_module.open(str(path))
        refs = json.loads(refs_path.read_text(encoding="utf-8"))["refs"]
        self.refs = refs
        self.by_key: dict[bytes, list[formats.Posting]] = {}
        self.postings: list[formats.Posting] = []
        self.row_to_content: dict[int, int] = {}
        for ref in refs:
            key = bytes.fromhex(ref["key"])
            posting = formats.Posting(key, int(ref["row"]), int(ref["key_index"]))
            self.postings.append(posting)
            self.row_to_content.setdefault(posting.row, int(ref["content_id"]))
        # SLOB's native reference order is a physical writer order, not the
        # common projection order.  Timed exact/prefix digests must therefore
        # use the same deterministic occurrence order as every other reader;
        # this is ordering normalization, not an expected-answer lookup.
        self.postings.sort(key=lambda posting: (posting.key, posting.row, posting.key_index))
        for posting in self.postings:
            self.by_key.setdefault(posting.key, []).append(posting)

    def close(self) -> None:
        self.reader.close()

    def exact(self, key: bytes) -> list[formats.Posting]:
        return list(self.by_key.get(key, ()))

    def prefix(self, prefix: bytes) -> list[formats.Posting]:
        return [posting for posting in self.postings if posting.key.startswith(prefix)]

    def render(self, row: int) -> bytes:
        content_id = self.row_to_content.get(row)
        if content_id is None:
            raise formats.FormatError(f"SLOB row {row} absent from refs")
        return bytes(self.reader.get(content_id)[1])

    def native_icu_find(self, text: str) -> int:
        return sum(1 for _ in self._slob.find(text, self.reader, match_prefix=True))


def open_external(lane: str, artifact_dir: Path, oracle: formats.Oracle) -> tuple[Any, dict[str, int], Any | None]:
    """Open a real artifact; SLOB reports native open and sidecar setup separately."""
    if lane == "stardict":
        stem = artifact_dir / "stardict"
        started = time.perf_counter_ns()
        reader = formats.StarDictReader(stem.with_suffix(".ifo"), stem.with_suffix(".idx"), stem.with_suffix(".syn"), stem.with_suffix(".dict"), oracle)
        return reader, {"open_ns": time.perf_counter_ns() - started, "identity_setup_ns": 0}, None
    if lane == "dict":
        started = time.perf_counter_ns()
        reader = formats.DictReader(artifact_dir / "dict.index", artifact_dir / "dict.dict", oracle)
        return reader, {"open_ns": time.perf_counter_ns() - started, "identity_setup_ns": 0}, None
    if lane == "dictzip":
        started = time.perf_counter_ns()
        reader = formats.DictZipReader(artifact_dir / "dict.index", artifact_dir / "dict.dict.dz", oracle)
        return reader, {"open_ns": time.perf_counter_ns() - started, "identity_setup_ns": 0}, None
    if lane == "sqlite":
        started = time.perf_counter_ns()
        reader = formats.SQLiteReader(artifact_dir / "dictionary.sqlite")
        return reader, {"open_ns": time.perf_counter_ns() - started, "identity_setup_ns": 0}, None
    if lane.startswith("slob-"):
        import slob
        variant = lane.removeprefix("slob-")
        path = artifact_dir / f"dictionary.{variant}.slob"
        refs = path.with_suffix(path.suffix + ".refs.json")
        started = time.perf_counter_ns()
        reader = slob.open(str(path))
        open_ns = time.perf_counter_ns() - started
        identity_started = time.perf_counter_ns()
        # The sidecar is the explicitly charged identity bridge required by the
        # common projection.  Keep the already-timed native reader for the
        # operation phases; do not rescan/validate the SLOB here.
        mapped = SlobMappedReader.__new__(SlobMappedReader)
        mapped._slob = slob
        mapped.reader = reader
        refs_data = json.loads(refs.read_text(encoding="utf-8"))["refs"]
        mapped.refs = refs_data
        mapped.by_key = {}
        mapped.postings = []
        mapped.row_to_content = {}
        for ref in refs_data:
            key = bytes.fromhex(ref["key"])
            posting = formats.Posting(key, int(ref["row"]), int(ref["key_index"]))
            mapped.postings.append(posting)
            mapped.row_to_content.setdefault(posting.row, int(ref["content_id"]))
        mapped.postings.sort(key=lambda posting: (posting.key, posting.row, posting.key_index))
        for posting in mapped.postings:
            mapped.by_key.setdefault(posting.key, []).append(posting)
        identity_ns = time.perf_counter_ns() - identity_started
        return mapped, {"open_ns": open_ns, "identity_setup_ns": identity_ns}, slob
    raise formats.FormatError(f"unknown timed external lane {lane}")


def timed_query_batch(reader: Any, queries: Sequence[dict[str, Any]], *, count: int, include_prefix: bool = False) -> dict[str, Any]:
    started = time.perf_counter_ns()
    state = hashlib.sha256()
    state.update(b"timed-query-batch-v1\0")
    operations = hits = key_bytes = 0
    selected = [query for query in queries if query["mode"] == ("prefix" if include_prefix else "exact")]
    if not selected:
        raise formats.FormatError("empty timed query selection")
    for index in range(count):
        query = selected[index % len(selected)]
        postings = reader.prefix(query["key"]) if query["mode"] == "prefix" else reader.exact(query["key"])
        state.update(query["key"])
        for posting in postings:
            state.update(posting.row.to_bytes(4, "little"))
            state.update(posting.key)
            state.update(posting.key_index.to_bytes(4, "little"))
            hits += 1
            key_bytes += len(posting.key)
        operations += 1
    return {"operations": operations, "ns": time.perf_counter_ns() - started, "hits": hits, "key_bytes": key_bytes, "digest": state.hexdigest()}


def timed_render_batch(reader: Any, rows: Sequence[dict[str, Any]], *, count: int, snippet: bool) -> dict[str, Any]:
    started = time.perf_counter_ns()
    state = hashlib.sha256()
    state.update(b"timed-snippet-batch-v1\0" if snippet else b"timed-render-batch-v1\0")
    output_bytes = 0
    for index in range(count):
        row = rows[index % len(rows)]
        content = bytes(reader.render(row["row"]))
        selected = content[:256] if snippet else content
        state.update(selected)
        output_bytes += len(selected)
    return {"operations": count, "ns": time.perf_counter_ns() - started, "output_bytes": output_bytes, "digest": state.hexdigest()}


def expected_external_query_batch(oracle: formats.Oracle, queries: Sequence[dict[str, Any]], *, count: int, include_prefix: bool) -> dict[str, Any]:
    """Compute the finite batch checksum without invoking the timed reader."""
    selected = [query for query in queries if query["mode"] == ("prefix" if include_prefix else "exact")]
    if not selected:
        raise formats.FormatError("empty expected timed query selection")
    state = hashlib.sha256()
    state.update(b"timed-query-batch-v1\0")
    operations = hits = key_bytes = 0
    for index in range(count):
        query = selected[index % len(selected)]
        postings = oracle.prefix(query["key"]) if include_prefix else oracle.exact(query["key"])
        state.update(query["key"])
        for posting in postings:
            state.update(posting.row.to_bytes(4, "little"))
            state.update(posting.key)
            state.update(posting.key_index.to_bytes(4, "little"))
            hits += 1
            key_bytes += len(posting.key)
        operations += 1
    return {"operations": operations, "hits": hits, "key_bytes": key_bytes, "digest": state.hexdigest()}


def expected_external_render_batch(oracle: formats.Oracle, rows: Sequence[dict[str, Any]], *, count: int, snippet: bool) -> dict[str, Any]:
    """Compute the finite render/snippet checksum from the independent oracle."""
    if not rows:
        raise formats.FormatError("empty expected render selection")
    state = hashlib.sha256()
    state.update(b"timed-snippet-batch-v1\0" if snippet else b"timed-render-batch-v1\0")
    output_bytes = 0
    for index in range(count):
        record = oracle.by_row[rows[index % len(rows)]["row"]]
        selected = record.content[:256] if snippet else record.content
        state.update(selected)
        output_bytes += len(selected)
    return {"operations": count, "output_bytes": output_bytes, "digest": state.hexdigest()}


def validate_external_timed_result(oracle: formats.Oracle, queries: Sequence[dict[str, Any]], rows: Sequence[dict[str, Any]], result: dict[str, Any]) -> None:
    """Reject a timed reader sample whose consumed output is not oracle-exact.

    The check runs after the timed child has completed and uses only the
    independently parsed projection.  It keeps a reader that returns the right
    counts but wrong occurrence/content bytes from entering the timing ledger.
    """
    exact_queries = [query for query in queries if query["mode"] == "exact"]
    prefix_queries = [query for query in queries if query["mode"] == "prefix"]
    render_rows = [row for row in rows if row["label"].startswith("render-")]
    snippet_rows = [row for row in rows if row["label"].startswith("snippet-")]
    for actual in result.get("first_exact", []):
        query = next((query for query in exact_queries if query["label"] == actual.get("label")), None)
        if query is None:
            raise RuntimeError(f"timed reader emitted an unknown exact label {actual.get('label')!r}")
        expected_postings = oracle.exact(query["key"])
        expected = {
            "hits": len(expected_postings),
            "key_bytes": sum(len(posting.key) for posting in expected_postings),
            "digest": posting_digest(expected_postings, query["key"]),
        }
        for field, value in expected.items():
            if actual.get(field) != value:
                raise RuntimeError(f"timed exact mismatch {query['label']} field={field}: expected={value!r} actual={actual.get(field)!r}")
    if len(result.get("first_exact", [])) != len(exact_queries):
        raise RuntimeError("timed reader omitted a first exact case")
    expected_exact = expected_external_query_batch(oracle, queries, count=BATCH_OPS, include_prefix=False)
    actual_exact = result.get("exact_batch", {})
    for field, value in expected_exact.items():
        if actual_exact.get(field) != value:
            raise RuntimeError(f"timed exact batch mismatch field={field}: expected={value!r} actual={actual_exact.get(field)!r}")
    expected_prefix = expected_external_query_batch(oracle, queries, count=len(prefix_queries), include_prefix=True)
    prefix_batches = result.get("prefix_batches", [])
    if len(prefix_batches) != PREFIX_BATCHES:
        raise RuntimeError(f"timed reader returned {len(prefix_batches)} prefix batches, expected {PREFIX_BATCHES}")
    for actual in prefix_batches:
        for field, value in expected_prefix.items():
            if actual.get(field) != value:
                raise RuntimeError(f"timed prefix batch mismatch field={field}: expected={value!r} actual={actual.get(field)!r}")
    expected_render = expected_external_render_batch(oracle, render_rows, count=BATCH_OPS, snippet=False)
    expected_snippet = expected_external_render_batch(oracle, snippet_rows, count=BATCH_OPS, snippet=True)
    for label, expected in (("render_batch", expected_render), ("snippet_batch", expected_snippet)):
        actual = result.get(label, {})
        for field, value in expected.items():
            if actual.get(field) != value:
                raise RuntimeError(f"timed {label} mismatch field={field}: expected={value!r} actual={actual.get(field)!r}")
    for label, selected_rows, snippet in (("first_render", render_rows, False), ("first_snippet", snippet_rows, True)):
        actual_items = result.get(label, [])
        if len(actual_items) != len(selected_rows):
            raise RuntimeError(f"timed reader omitted {label} cases")
        for actual, row in zip(actual_items, selected_rows):
            content = oracle.by_row[row["row"]].content
            expected = {"label": row["label"], "output_bytes": len(content) if not snippet else min(256, len(content)), "digest": reader_content_digest(content, snippet=snippet)}
            for field, value in expected.items():
                if actual.get(field) != value:
                    raise RuntimeError(f"timed {label} mismatch row={row['row']} field={field}: expected={value!r} actual={actual.get(field)!r}")


def timed_external_once(lane: str, oracle: formats.Oracle, artifact_dir: Path, queries: Sequence[dict[str, Any]], rows: Sequence[dict[str, Any]], *, startup_phases: dict[str, int]) -> dict[str, Any]:
    exact_queries = [query for query in queries if query["mode"] == "exact"]
    prefix_queries = [query for query in queries if query["mode"] == "prefix"]
    render_rows = [row for row in rows if row["label"].startswith("render-")]
    snippet_rows = [row for row in rows if row["label"].startswith("snippet-")]
    reader_started = time.perf_counter_ns()
    reader, open_phases, slob_module = open_external(lane, artifact_dir, oracle)
    startup_phases["reader_ready_ns"] = time.perf_counter_ns() - reader_started
    try:
        first_exact = []
        for query in exact_queries:
            started = time.perf_counter_ns()
            postings = reader.exact(query["key"])
            first_exact.append({"label": query["label"], "ns": time.perf_counter_ns() - started, "hits": len(postings), "key_bytes": sum(len(posting.key) for posting in postings), "digest": posting_digest(postings, query["key"])})
        warmup = timed_query_batch(reader, exact_queries, count=BATCH_OPS)
        exact_batch = timed_query_batch(reader, exact_queries, count=BATCH_OPS)
        prefix_batches = [timed_query_batch(reader, prefix_queries, count=len(prefix_queries), include_prefix=True) for _ in range(PREFIX_BATCHES)]
        first_render = []
        first_snippet = []
        for row in render_rows:
            started = time.perf_counter_ns(); content = bytes(reader.render(row["row"])); first_render.append({"label": row["label"], "ns": time.perf_counter_ns() - started, "output_bytes": len(content), "digest": reader_content_digest(content, snippet=False)})
        for row in snippet_rows:
            started = time.perf_counter_ns(); content = bytes(reader.render(row["row"])); first_snippet.append({"label": row["label"], "ns": time.perf_counter_ns() - started, "output_bytes": min(256, len(content)), "digest": reader_content_digest(content, snippet=True)})
        render_warmup = timed_render_batch(reader, render_rows, count=BATCH_OPS, snippet=False)
        snippet_warmup = timed_render_batch(reader, snippet_rows, count=BATCH_OPS, snippet=True)
        render_batch = timed_render_batch(reader, render_rows, count=BATCH_OPS, snippet=False)
        snippet_batch = timed_render_batch(reader, snippet_rows, count=BATCH_OPS, snippet=True)
        native_icu: list[dict[str, Any]] = []
        if slob_module is not None:
            for query in exact_queries[:4]:
                started = time.perf_counter_ns()
                count = reader.native_icu_find(query["key"].decode("utf-8"))
                native_icu.append({"label": query["label"], "ns": time.perf_counter_ns() - started, "matches": count})
        return {
            "open_phases": open_phases,
            "startup_phases": startup_phases,
            "first_exact": first_exact,
            "warmup_exact": warmup,
            "exact_batch": exact_batch,
            "prefix_batches": prefix_batches,
            "first_render": first_render,
            "first_snippet": first_snippet,
            "warmup_render": render_warmup,
            "warmup_snippet": snippet_warmup,
            "render_batch": render_batch,
            "snippet_batch": snippet_batch,
            "native_icu": native_icu,
        }
    finally:
        reader.close()


def run_external_child(argv: argparse.Namespace) -> int:
    corpus_root = Path(argv.corpora_root)
    projection = corpus_root / argv.corpus / "projection.tsv"
    oracle_started = time.perf_counter_ns()
    oracle = formats.read_projection(projection)
    oracle_parse_ns = time.perf_counter_ns() - oracle_started
    plan_started = time.perf_counter_ns()
    queries, rows = load_measure_plan(Path(argv.query_plan), Path(argv.rows_plan))
    plan_parse_ns = time.perf_counter_ns() - plan_started
    result = timed_external_once(
        argv.lane,
        oracle,
        Path(argv.artifact_dir),
        queries,
        rows,
        startup_phases={
            "oracle_parse_ns": oracle_parse_ns,
            "query_plan_parse_ns": plan_parse_ns,
            # This is the actual fresh-reader-ready boundary.  It includes
            # native open plus any explicitly charged sidecar identity map,
            # but excludes the oracle and plan setup above.
            "reader_ready_ns": 0,
        },
    )
    print(json.dumps({"status": "ok", "lane": argv.lane, "corpus": argv.corpus, "result": result}, ensure_ascii=False, separators=(",", ":")))
    return 0


def run_external_build_child(argv: argparse.Namespace) -> int:
    """Build every external artifact once and time each declared build call.

    Some helpers intentionally include an independent native validation (for
    example dictunformat, dictzip range/decompression, SQLite integrity, and
    SLOB identity validation).  Those boundaries are retained in the phase
    names instead of being presented as a pure encoder benchmark.
    """
    projection = Path(argv.corpora_root) / argv.corpus / "projection.tsv"
    oracle = formats.read_projection(projection)
    destination = Path(argv.build_dir)
    destination.mkdir(parents=True, exist_ok=True)
    phases: list[dict[str, Any]] = []

    def phase(name: str, callback: Callable[[], Any]) -> Any:
        started = time.perf_counter_ns()
        value = callback()
        phases.append({"phase": name, "ns": time.perf_counter_ns() - started})
        return value

    phase("stardict-build-only", lambda: formats.build_stardict(oracle, destination))
    phase("dict-build-plus-dictunformat", lambda: formats.build_dict(oracle, destination))
    phase("dictzip-build-plus-full-range-validation", lambda: formats.dictzip_variant(oracle, destination))
    phase("sqlite-build-plus-integrity-cli", lambda: formats.build_sqlite(oracle, destination))
    slob_results = phase("slob-build-plus-identity-and-reader-validation", lambda: formats.build_slob(oracle, destination))
    print(json.dumps({"status": "ok", "corpus": argv.corpus, "build_dir": str(destination.resolve()), "phases": phases, "slob_results": slob_results}, ensure_ascii=False, separators=(",", ":")))
    return 0


def run_external_samples(corpus: str, lane: str, oracle: formats.Oracle, projection: Path, artifact_dir: Path, query_path: Path, rows_path: Path) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    plan_queries, plan_rows = load_measure_plan(query_path, rows_path)
    child = [sys.executable, str(Path(__file__).resolve()), "--quiet-gate", GATE, "--child-external", "--corpus", corpus, "--corpora-root", str(projection.parents[1]), "--lane", lane, "--artifact-dir", str(artifact_dir), "--query-plan", str(query_path), "--rows-plan", str(rows_path)]
    for sample_index in range(PROCESS_RUNS):
        process = run_capture(child)
        if process["returncode"] != 0:
            raise RuntimeError(f"external timed lane failed {corpus}/{lane}/sample-{sample_index}: {process}")
        try:
            child_result = json.loads(process["stdout"])
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid external child output: {process}") from exc
        if child_result.get("status") != "ok":
            raise RuntimeError(f"external child failed: {child_result}")
        # Reconstruct the same fixed plan from the projection in this parent
        # process and reject any digest/count/content mismatch before retaining
        # this fresh-process sample as evidence.
        validate_external_timed_result(oracle, plan_queries, plan_rows, child_result["result"])
        samples.append({"sample": sample_index, "process": process, "phases": child_result["result"]})
    return {"format": lane.split("-", 1)[0], "lane": lane, "artifact_dir": str(artifact_dir.resolve()), "samples": samples}


def run_external_build(corpus: str, projection: Path, build_root: Path) -> dict[str, Any]:
    destination = build_root / corpus
    child = [sys.executable, str(Path(__file__).resolve()), "--quiet-gate", GATE, "--child-external-build", "--corpus", corpus, "--corpora-root", str(projection.parents[1]), "--build-dir", str(destination)]
    process = run_capture(child)
    if process["returncode"] != 0:
        raise RuntimeError(f"external build timing failed {corpus}: {process}")
    try:
        child_result = json.loads(process["stdout"])
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid external build child output: {process}") from exc
    if child_result.get("status") != "ok":
        raise RuntimeError(f"external build child failed: {child_result}")
    return {"corpus": corpus, "process": process, "result": child_result}


def run_native_cli_samples(corpus: str, oracle: formats.Oracle, artifact_dir: Path) -> dict[str, Any]:
    """Measure only genuine CLI process/transport lanes, separately labeled."""
    results: dict[str, Any] = {}
    sdcv = shutil.which("sdcv")
    if sdcv:
        cases = [(name, key) for name, key in oracle.queries() if name.startswith("exact-")][:3]
        samples = []
        for sample in range(PROCESS_RUNS):
            case_results = []
            for name, key in cases:
                try:
                    text = key.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                process = run_capture([sdcv, "-n", "-e", "-1", "-0", "-x", "-2", str(artifact_dir), "-u", "real-world", text], cwd=artifact_dir)
                case_results.append({"label": name, "expected_key": text, "expected_hits": len(oracle.exact(key)), "process": process})
            samples.append({"sample": sample, "cases": case_results})
        results["sdcv_cli"] = {"status": "ok", "samples": samples}
    else:
        results["sdcv_cli"] = {"status": "unavailable", "reason": "sdcv executable absent"}

    dictzip = shutil.which("dictzip")
    compressed = artifact_dir / "dict.dict.dz"
    if dictzip and compressed.is_file():
        middle = oracle.records[len(oracle.records) // 2]
        offset = sum(len(record.content) for record in oracle.records[:middle.row])
        samples = []
        for sample in range(PROCESS_RUNS):
            process = run_capture([dictzip, "-c", "-s", str(offset), "-e", str(len(middle.content)), str(compressed)], cwd=artifact_dir)
            samples.append({"sample": sample, "row": middle.row, "process": process, "output_matches": process["stdout"].encode() == middle.content})
        results["dictzip_cli"] = {"status": "ok", "samples": samples}
    else:
        results["dictzip_cli"] = {"status": "unavailable", "reason": "dictzip executable or .dz artifact absent"}
    return results


def run_lex6_build_samples(corpus: str, codec: str, projection: Path, runner: Path, root: Path) -> dict[str, Any]:
    destination = root / corpus / f"lex6-{codec}-64k-timed.lex6"
    destination.parent.mkdir(parents=True, exist_ok=True)
    process = run_capture([str(runner), "--mode", "build", "--input", str(projection), "--artifact", str(destination), "--compression", codec, "--target-page-bytes", "65536", "--max-page-bytes", "1048576", "--max-document-bytes", "1048576"])
    if process["returncode"] != 0:
        raise RuntimeError(f"LEX6 timed build failed {corpus}/{codec}: {process}")
    return {"format": "lex6", "codec": codec, "process": process, "artifact": formats.artifact_file(destination)}


def main_measure(args: argparse.Namespace) -> dict[str, Any]:
    corpora_root = Path(args.corpora_root)
    artifact_root = Path(args.artifact_root)
    runner = Path(args.runner)
    output = Path(args.output)
    temporary = Path(args.plan_root) if args.plan_root else ROOT / "evidence" / "runs" / "measurement-plans"
    temporary.mkdir(parents=True, exist_ok=True)
    result: dict[str, Any] = {
        "schema": 1,
        "status": "timed-results",
        "timing": "gate-granted",
        "gate": GATE,
        "schedule_manifest": formats.artifact_file(ROOT / "manifest.json"),
        "schedule": {"process_runs": PROCESS_RUNS, "warmups": 1, "batch_ops": BATCH_OPS, "prefix_batches": PREFIX_BATCHES, "main_page_bytes": 65536, "os_cache": "not forcibly evicted; fresh process is not cold disk"},
        "corpora": [],
        "builds": [],
        "failures": [],
    }

    def failed(label: str, exc: BaseException) -> dict[str, Any]:
        failure = {
            "status": "failed",
            "lane": label,
            "error_type": type(exc).__name__,
            "error": str(exc),
        }
        result["failures"].append(failure)
        return failure

    for corpus in CORPORA:
        projection = corpora_root / corpus / "projection.tsv"
        oracle = formats.read_projection(projection)
        plan_dir = temporary / corpus
        plan = write_measure_plan(oracle, plan_dir / "timed-queries.tsv", plan_dir / "timed-rows.tsv")
        corpus_result: dict[str, Any] = {"corpus": corpus, "projection": formats.artifact_file(projection), "plan": plan, "lex6": [], "external": [], "native_cli": {}}
        for codec in CODECS:
            artifact = artifact_root / corpus / f"lex6-{codec}-64k.lex6"
            try:
                corpus_result["lex6"].append(run_lex6_samples(corpus, codec, oracle, artifact, projection, plan_dir / "timed-queries.tsv", plan_dir / "timed-rows.tsv", runner))
            except (OSError, RuntimeError, formats.FormatError) as exc:
                corpus_result["lex6"].append(failed(f"{corpus}/lex6/{codec}/queries", exc))
            try:
                result["builds"].append(run_lex6_build_samples(corpus, codec, projection, runner, Path(args.build_root)))
            except (OSError, RuntimeError, formats.FormatError) as exc:
                result["builds"].append(failed(f"{corpus}/lex6/{codec}/build", exc))
        external_dir = artifact_root / corpus / "external"
        for lane in EXTERNAL_LANES:
            try:
                corpus_result["external"].append(run_external_samples(corpus, lane, oracle, projection, external_dir, plan_dir / "timed-queries.tsv", plan_dir / "timed-rows.tsv"))
            except (OSError, RuntimeError, formats.FormatError, ImportError) as exc:
                corpus_result["external"].append(failed(f"{corpus}/{lane}/queries", exc))
        try:
            corpus_result["native_cli"] = run_native_cli_samples(corpus, oracle, external_dir)
        except (OSError, RuntimeError, formats.FormatError, ImportError) as exc:
            corpus_result["native_cli"] = {"status": "failed", "error": str(exc)}
            failed(f"{corpus}/native-cli", exc)
        try:
            corpus_result["external_build"] = run_external_build(corpus, projection, Path(args.build_root))
        except (OSError, RuntimeError, formats.FormatError, ImportError) as exc:
            corpus_result["external_build"] = failed(f"{corpus}/external/build", exc)
        result["corpora"].append(corpus_result)
    if result["failures"]:
        result["status"] = "timed-results-with-failures"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet-gate", required=True)
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--artifact-root", type=Path, default=Path("/tmp/dictionary-real-world-evidence"))
    parser.add_argument("--runner", type=Path, default=ROOT / "zig-out" / "bin" / "real-lex6")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "timing-results.json")
    parser.add_argument("--plan-root", type=Path)
    parser.add_argument("--build-root", type=Path, default=Path("/tmp/dictionary-real-world-timed-builds"))
    parser.add_argument("--child-external", action="store_true")
    parser.add_argument("--child-external-build", action="store_true")
    parser.add_argument("--corpus", choices=CORPORA)
    parser.add_argument("--lane", choices=EXTERNAL_LANES)
    parser.add_argument("--artifact-dir", type=Path)
    parser.add_argument("--query-plan", type=Path)
    parser.add_argument("--rows-plan", type=Path)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args(argv)
    if args.quiet_gate != GATE:
        print(f"measure.py: refusing timing: expected literal {GATE!r}", file=sys.stderr)
        return 2
    if args.child_external:
        if not all((args.corpus, args.lane, args.artifact_dir, args.query_plan, args.rows_plan)):
            print("measure.py: child external requires corpus/lane/artifact/query/rows", file=sys.stderr)
            return 2
        return run_external_child(args)
    if args.child_external_build:
        if not all((args.corpus, args.build_dir)):
            print("measure.py: child external build requires corpus/build-dir", file=sys.stderr)
            return 2
        return run_external_build_child(args)
    if not args.runner.is_file():
        print(f"measure.py: runner not found: {args.runner}", file=sys.stderr)
        return 2
    try:
        report = main_measure(args)
    except (OSError, RuntimeError, formats.FormatError, ImportError) as exc:
        print(f"measure.py: ERROR: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"status": report["status"], "output": str(Path(args.output).resolve()), "corpora": CORPORA, "failures": len(report.get("failures", []))}, indent=2))
    return 0 if not report.get("failures") else 2


if __name__ == "__main__":
    raise SystemExit(main())
