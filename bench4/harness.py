#!/usr/bin/env python3
"""Measurement and semantic-check engine for the LEX4 benchmark campaign."""

from __future__ import annotations

import json
import hashlib
import os
import resource
import time
from collections import Counter
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Iterable

try:
    from .adapter import Adapter, AdapterError, AdapterMetadata, SemanticMismatch
    from .oracle import Fixture, Operation, Oracle, expected, workload
except ImportError:  # pragma: no cover - exercised by direct script discovery
    from adapter import Adapter, AdapterError, AdapterMetadata, SemanticMismatch
    from oracle import Fixture, Operation, Oracle, expected, workload


class HarnessError(RuntimeError):
    """A run cannot produce a trustworthy report."""


# This text is persisted in the run configuration.  Keeping the boundary in
# one place prevents a future refactor from quietly charging oracle work,
# JSON comparison, or a second planning call to a reader operation.
TIMING_WORK_DEFINITION = (
    "reader time is around exactly one in-process adapter operation or is "
    "reported by the native reader around that operation; outer_call_ns is "
    "perf_counter_ns around the complete adapter call. For native JSONL "
    "profiles only, outer_call_ns is retained as transport_elapsed_ns; "
    "host-operation profiles have no transport metric. For prefix_enumerate "
    "the reader operation is only prefix_enumerate(prefix); response "
    "normalization/serialization, validation, oracle work, interval metadata, "
    "and checksums are outside both boundaries"
)


def _digest(value: Any) -> str:
    import hashlib

    if isinstance(value, bytes):
        payload = value
    else:
        payload = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def _artifact_bundle_snapshot(artifact: Path) -> tuple[dict[str, object], ...]:
    """Return a complete, immutable snapshot of one adapter's retained bytes.

    An adapter may legitimately emit sidecar/index files next to its primary
    output.  Counting only ``artifact.stat().st_size`` under-reports those
    bytes and checking only the primary digest lets a sidecar change during a
    run.  The parent directory is a per-adapter bundle boundary; every
    regular file beneath it is counted and hashed, while symlinks are rejected
    so bytes outside the run cannot hide behind a tiny link.
    """

    if artifact.parent.is_symlink():
        raise HarnessError(f"artifact bundle directory cannot be a symlink: {artifact.parent}")
    root = artifact.parent.resolve(strict=False)
    if not root.is_dir():
        raise HarnessError(f"artifact bundle directory does not exist: {root}")
    rows: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise HarnessError(f"artifact bundle contains symlink: {path}")
        if not path.is_file():
            continue
        rows.append(
            {
                "path": path.relative_to(root).as_posix(),
                "size": path.stat().st_size,
                "sha256": _file_digest(path),
            }
        )
    if not rows:
        raise HarnessError(f"adapter produced no retained artifact bytes under {root}")
    return tuple(rows)


def _bundle_bytes(snapshot: tuple[dict[str, object], ...]) -> int:
    return sum(int(row["size"]) for row in snapshot)


def _rss_bytes() -> int | None:
    try:
        value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except (AttributeError, OSError, ValueError):
        return None
    # macOS reports bytes; Linux/BSD report KiB.  Keep this caveat explicit in
    # the report rather than pretending this is an adapter-local measurement.
    return value if os.sys.platform == "darwin" else value * 1024


def _call_adapter(adapter: Adapter, operation: Operation) -> object:
    if operation.op == "exact":
        return adapter.exact(operation.key)
    if operation.op == "prefix_interval":
        return adapter.prefix_interval(operation.key)
    if operation.op == "prefix_enumerate":
        return adapter.prefix_enumerate(operation.key)
    if operation.op == "select":
        return adapter.select(operation.ident or 0)
    if operation.op == "render":
        return adapter.render(operation.ident or 0)
    if operation.op == "snippet":
        return adapter.snippet(operation.ident or 0, operation.limit or 0)
    if operation.op == "concept_members":
        return adapter.concept_members(operation.ident or 0)
    if operation.op == "translations":
        return adapter.translations(operation.ident or 0, operation.language or "")
    if operation.op == "relations":
        return adapter.relations(operation.ident or 0, operation.predicate or "")
    raise HarnessError(f"unknown benchmark operation {operation.op!r}")


def _timed_reader_call(adapter: Adapter, operation: Operation) -> tuple[object, int, int | None, int]:
    """Return raw result, reader-core time, transport time, and outer time.

    In-process adapters are timed by the harness around their operation call.
    A native/process adapter may expose ``reader_timed``; in that case the
    harness still measures the complete request/response call separately,
    while the adapter reports a validated duration around only its reader
    operation. This keeps IPC visible without presenting it as lookup cost.
    """

    started_ns = time.perf_counter_ns()
    reader_timed = getattr(adapter, "reader_timed", None)
    if callable(reader_timed):
        raw, reader_elapsed = reader_timed(operation)
    else:
        raw = _call_adapter(adapter, operation)
        reader_elapsed = None
    outer_elapsed = time.perf_counter_ns() - started_ns
    if reader_elapsed is None:
        reader_elapsed = outer_elapsed
    if type(reader_elapsed) is not int or reader_elapsed < 0:
        raise HarnessError(
            f"adapter {adapter.metadata.label} returned invalid reader_elapsed_ns={reader_elapsed!r}"
        )
    # A self-timed reader operation is nested inside the request/response
    # boundary.  Reject an impossible report instead of allowing a native
    # adapter to claim an arbitrarily large (or clock-domain-inconsistent)
    # duration that cannot have occurred during this call.  Zero remains
    # valid for a clock whose resolution is coarser than the operation; it is
    # a measured value, not a missing-metric sentinel.
    if reader_elapsed > outer_elapsed:
        raise HarnessError(
            f"adapter {adapter.metadata.label} reported reader_elapsed_ns={reader_elapsed} "
            f"outside outer_call_ns={outer_elapsed}"
        )
    transport_elapsed = outer_elapsed if adapter.metadata.timing_mode == "native_self_timed" else None
    return raw, reader_elapsed, transport_elapsed, outer_elapsed


def _invoke(adapter: Adapter, operation: Operation, *, include_interval: bool = True) -> dict[str, object]:
    """Invoke and normalize one operation (untimed compatibility helper)."""

    raw = _call_adapter(adapter, operation)
    response = _normalize(operation, raw)
    if operation.op == "prefix_enumerate" and include_interval:
        lo, hi = adapter.prefix_interval(operation.key)
        response.update({"lo": int(lo), "hi": int(hi)})
    return response


def _normalize(operation: Operation, raw: object) -> dict[str, object]:
    """Convert a raw adapter result after the timed call has ended."""

    if operation.op == "exact":
        values = list(raw)
        return {"op": operation.op, "ids": values, "cardinality": len(values)}
    if operation.op == "prefix_interval":
        lo, hi = raw
        return {"op": operation.op, "lo": int(lo), "hi": int(hi), "cardinality": int(hi) - int(lo)}
    if operation.op == "prefix_enumerate":
        values = list(raw)
        return {"op": operation.op, "ids": values, "cardinality": len(values)}
    if operation.op == "select":
        return dict(raw)
    if operation.op == "render":
        value = bytes(raw)
        return {"op": operation.op, "id": operation.ident, "bytes_hex": value.hex(), "bytes": len(value)}
    if operation.op == "snippet":
        value = bytes(raw)
        return {"op": operation.op, "id": operation.ident, "limit": operation.limit, "bytes_hex": value.hex(), "bytes": len(value)}
    if operation.op == "concept_members":
        values = list(raw)
        return {"op": operation.op, "id": operation.ident, "members": values, "cardinality": len(values)}
    if operation.op == "translations":
        values = list(raw)
        return {"op": operation.op, "id": operation.ident, "language": operation.language, "members": values, "cardinality": len(values)}
    if operation.op == "relations":
        values = list(raw)
        return {"op": operation.op, "id": operation.ident, "relations": values, "cardinality": len(values)}
    raise HarnessError(f"unknown benchmark operation {operation.op!r}")


def _cardinality(value: dict[str, object]) -> int | None:
    if isinstance(value.get("cardinality"), int):
        return int(value["cardinality"])
    if isinstance(value.get("ids"), list):
        return len(value["ids"])
    if isinstance(value.get("members"), list):
        return len(value["members"])
    if isinstance(value.get("relations"), list):
        return len(value["relations"])
    if isinstance(value.get("bytes"), int):
        return int(value["bytes"])
    if value.get("op") == "select":
        return 1
    return None


def _percentile(values: list[int], percent: int) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    # nearest-rank pctl; deterministic and matches the existing bench2 reports.
    index = min(len(ordered) - 1, (len(ordered) * percent) // 100)
    return ordered[index]


@dataclass(slots=True)
class Measurement:
    fixture: str
    adapter: AdapterMetadata
    artifact: str
    artifact_bytes: int
    build_ns: int
    open_ns: int
    verify_ns: int
    observations: list[dict[str, object]] = field(default_factory=list)
    metrics: dict[str, object] = field(default_factory=dict)
    available: bool = True
    unavailable_reason: str | None = None

    def json(self) -> dict[str, object]:
        return {
            "fixture": self.fixture,
            "adapter": self.adapter.as_dict(),
            "artifact": self.artifact,
            "artifact_bytes": self.artifact_bytes,
            "build_ns": self.build_ns,
            "open_ns": self.open_ns,
            "verify_ns": self.verify_ns,
            "metrics": self.metrics,
            "available": self.available,
            "unavailable_reason": self.unavailable_reason,
        }


def _validate_response(oracle: Oracle, operation: Operation, response: dict[str, object]) -> dict[str, object]:
    expected_response = expected(oracle, operation)
    if response != expected_response:
        raise SemanticMismatch(
            f"{operation.op} semantic mismatch category={operation.category!r}: "
            f"expected={expected_response!r} observed={response!r}"
        )
    return expected_response


def measure_adapter(
    fixture: Fixture,
    adapter: Adapter,
    artifact: Path,
    *,
    repetitions: int,
    warmup: int,
) -> Measurement:
    """Build/open/verify and measure one adapter with fatal semantic checks."""

    if repetitions <= 0:
        raise ValueError("repetitions must be positive")
    if warmup < 0:
        raise ValueError("warmup cannot be negative")
    oracle = Oracle(fixture)
    operations = workload(fixture, repetitions)
    warm_operations = tuple(
        replace(operation, sample=-(index + 1))
        for index, operation in enumerate(workload(fixture, max(1, warmup))[:warmup])
    )
    scheduled_samples = [operation.sample for operation in (*warm_operations, *operations)]
    if len(scheduled_samples) != len(set(scheduled_samples)):
        raise HarnessError("workload contains duplicate sample nonces")
    artifact.parent.mkdir(parents=True, exist_ok=True)

    started = time.perf_counter_ns()
    adapter.build(artifact)
    build_ns = time.perf_counter_ns() - started
    if not artifact.is_file():
        raise HarnessError(f"adapter {adapter.metadata.label} did not produce artifact {artifact}")
    artifact_digest = _file_digest(artifact)
    bundle_snapshot = _artifact_bundle_snapshot(artifact)
    bundle_digest = _digest(bundle_snapshot)

    started = time.perf_counter_ns()
    adapter.open(artifact)
    open_ns = time.perf_counter_ns() - started
    try:
        started = time.perf_counter_ns()
        adapter.verify()
        verify_ns = time.perf_counter_ns() - started
        if _file_digest(artifact) != artifact_digest or _artifact_bundle_snapshot(artifact) != bundle_snapshot:
            raise HarnessError(f"adapter {adapter.metadata.label} changed encoded bytes during open/verify")

        # Structural checks are outside the timing boundary and run before
        # warmup. A bad index can never produce an apparently good latency. Do
        # not send a query schedule to the adapter for a preflight checksum:
        # doing so would disclose every measured key/ID and permit a native
        # process to precompute or cache timed answers. The query digest is
        # checked from independently validated responses below.
        structure_checksum = adapter.structure_checksum()
        expected_structure = oracle.structure_checksum()
        if structure_checksum != expected_structure:
            raise SemanticMismatch(
                f"structure checksum mismatch for {adapter.metadata.label}: "
                f"expected={expected_structure} observed={structure_checksum}"
            )
        expected_query = oracle.query_checksum(operations)
    except BaseException:
        # A failed verify/checksum must not leave a native child running while
        # the caller cleans up its staging directory.
        adapter.close()
        raise

    observations: list[dict[str, object]] = []

    def exercise(operation: Operation, phase: str, index: int, timed: bool) -> None:
        # Native adapters receive the deterministic sample nonce without
        # changing the narrow semantic method signatures used by reference
        # adapters. Setting it is bookkeeping outside the timed call.
        set_sample = getattr(adapter, "set_sample", None)
        if callable(set_sample):
            set_sample(operation.sample)
        raw, reader_elapsed_ns, transport_elapsed_ns, outer_elapsed_ns = _timed_reader_call(adapter, operation)
        response = _normalize(operation, raw)
        # Enumeration is intentionally a distinct timed operation.  Its
        # interval metadata is derived from the oracle after the clock stops;
        # calling adapter.prefix_interval here would both charge no time and
        # warm/cache a second query before later measured work.
        if operation.op == "prefix_enumerate":
            lo, hi = oracle.prefix_interval(operation.key)
            response.update({"lo": int(lo), "hi": int(hi)})
        # The semantic comparison intentionally occurs after the end timestamp;
        # oracle work and JSON comparison are never charged to the adapter.
        expected_response = _validate_response(oracle, operation, response)
        observations.append(
            {
                "fixture": fixture.name,
                "adapter": adapter.metadata.label,
                "phase": phase,
                "index": index,
                "op": operation.op,
                "category": operation.category,
                "key": operation.key if operation.op in ("exact", "prefix_interval", "prefix_enumerate") else None,
                "id": operation.ident,
                "limit": operation.limit,
                "language": operation.language,
                "predicate": operation.predicate,
                "sample": operation.sample,
                "timed": timed,
                # elapsed_ns remains a reader-time compatibility alias. The
                # explicit fields below are authoritative for reporting.
                "elapsed_ns": reader_elapsed_ns,
                "reader_elapsed_ns": reader_elapsed_ns,
                "transport_elapsed_ns": transport_elapsed_ns,
                "outer_call_ns": outer_elapsed_ns,
                "timing_source": adapter.metadata.timing_mode,
                "expected_cardinality": _cardinality(expected_response),
                "observed_cardinality": _cardinality(response),
                "result_sha256": _digest(response),
            }
        )

    try:
        for index, operation in enumerate(warm_operations):
            exercise(operation, "warmup", index, False)
        for index, operation in enumerate(operations):
            exercise(operation, "measure", index, True)
    finally:
        adapter.close()
    if _file_digest(artifact) != artifact_digest or _artifact_bundle_snapshot(artifact) != bundle_snapshot:
        raise HarnessError(f"adapter {adapter.metadata.label} changed encoded bytes during measurement")

    measured = [row for row in observations if row["phase"] == "measure"]
    by_name: dict[str, list[int]] = {}
    by_class: dict[str, list[int]] = {}
    transport_by_name: dict[str, list[int]] = {}
    transport_by_class: dict[str, list[int]] = {}
    for row in measured:
        elapsed = int(row["reader_elapsed_ns"])
        transport_elapsed_value = row.get("transport_elapsed_ns")
        name = str(row["op"])
        by_name.setdefault(name, []).append(elapsed)
        if type(transport_elapsed_value) is int:
            transport_by_name.setdefault(name, []).append(transport_elapsed_value)
        category = str(row.get("category") or "uncategorized")
        by_class.setdefault(f"{name}.{category}", []).append(elapsed)
        if type(transport_elapsed_value) is int:
            transport_by_class.setdefault(f"{name}.{category}", []).append(transport_elapsed_value)
    metrics: dict[str, object] = {
        "semantic_digest": fixture.semantic_digest(),
        "structure_checksum": expected_structure,
        "query_checksum": expected_query,
        "cardinality": oracle.cardinality,
        "logical_prose_bytes": fixture.prose_bytes(),
        "artifact_sha256": artifact_digest,
        "artifact_bundle_sha256": bundle_digest,
        "artifact_file_count": len(bundle_snapshot),
        "operation_count": len(measured),
        "warmup_count": len(warm_operations),
        "requested_repetitions": repetitions,
        "timing_work_definition": TIMING_WORK_DEFINITION,
        "timing_mode": adapter.metadata.timing_mode,
        "unique_sample_nonce_count": len({operation.sample for operation in operations}),
    }
    sample_counts = Counter(str(row["op"]) for row in measured)
    class_counts = Counter(
        f"{row['op']}.{row.get('category') or 'uncategorized'}" for row in measured
    )
    warmup_sample_counts = Counter(str(row["op"]) for row in observations if row["phase"] == "warmup")
    metrics["sample_counts"] = dict(sorted(sample_counts.items()))
    metrics["class_sample_counts"] = dict(sorted(class_counts.items()))
    metrics["warmup_sample_counts"] = dict(sorted(warmup_sample_counts.items()))
    for name, count in sorted(sample_counts.items()):
        metrics[f"{name}.sample_count"] = count
    for name, count in sorted(class_counts.items()):
        metrics[f"{name}.sample_count"] = count
    missing_operations = sorted({operation.op for operation in operations} - set(sample_counts))
    if missing_operations:
        raise HarnessError(
            f"adapter {adapter.metadata.label} omitted measured operation classes: {missing_operations}"
        )
    if metrics["unique_sample_nonce_count"] != len(measured):
        raise HarnessError("measured operation samples are not uniquely nonce-tagged")
    for name, values in by_name.items():
        for percentile in (50, 95, 99):
            # Existing metric names remain reader-time aliases. New reports
            # should use the explicit reader/transport variants.
            metrics[f"{name}.p{percentile}_ns"] = _percentile(values, percentile)
            metrics[f"{name}.reader_p{percentile}_ns"] = _percentile(values, percentile)
            if transport_by_name.get(name):
                metrics[f"{name}.transport_p{percentile}_ns"] = _percentile(transport_by_name[name], percentile)
    for name, values in by_class.items():
        for percentile in (50, 95, 99):
            metrics[f"{name}.p{percentile}_ns"] = _percentile(values, percentile)
            metrics[f"{name}.reader_p{percentile}_ns"] = _percentile(values, percentile)
            if transport_by_class.get(name):
                metrics[f"{name}.transport_p{percentile}_ns"] = _percentile(transport_by_class[name], percentile)
    metrics["query_result_checksum"] = _digest([row["result_sha256"] for row in measured])
    # This digest is assembled from semantic responses that have already
    # passed _validate_response; the adapter never receives expected answers
    # or this checksum as input.
    observed_query_values = []
    for operation, row in zip(operations, measured):
        observed_query_values.append((operation.wire(), row["result_sha256"]))
    # Keep the oracle's canonical query checksum as a report-level anchor and
    # retain a separate response-sequence digest for auditability.
    metrics["validated_query_checksum"] = expected_query
    metrics["validated_response_sequence_checksum"] = _digest(observed_query_values)
    # Re-check the full response sequence from the semantic rows.  A child
    # that exits or changes state after an individual operation therefore
    # cannot leave a seemingly complete report.
    if len(measured) != len(operations):
        raise HarnessError("measured operation count changed during collection")
    return Measurement(
        fixture.name,
        adapter.metadata,
        str(artifact),
        _bundle_bytes(bundle_snapshot),
        build_ns,
        open_ns,
        verify_ns,
        observations,
        metrics,
    )


def write_observations(measurements: Iterable[Measurement], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as stream:
        for measurement in measurements:
            for row in measurement.observations:
                stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def aggregate_process_metadata(*, started_rss: int | None, ended_rss: int | None, elapsed_ns: int) -> dict[str, object]:
    peak = None if started_rss is None or ended_rss is None else max(started_rss, ended_rss)
    return {
        "scope": "entire-driver-process",
        "wall_ns": elapsed_ns,
        "peak_rss_bytes": peak,
        "rss_caveat": "Aggregate RSS for this benchmark process; not attributable to one adapter or format.",
    }


def current_rss_bytes() -> int | None:
    """Return process aggregate RSS when the platform exposes it."""

    return _rss_bytes()


__all__ = [
    "HarnessError",
    "Measurement",
    "SemanticMismatch",
    "TIMING_WORK_DEFINITION",
    "aggregate_process_metadata",
    "current_rss_bytes",
    "measure_adapter",
    "write_observations",
]
