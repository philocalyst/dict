"""Prepared, archive-only LEX5 reader timing boundary.

This module is deliberately inert until a caller explicitly opts into a
campaign.  It owns the LEX5 JSONL adapter boundary and the chronological
control/candidate pairing rules; it does not invent answers or put a query
schedule in an artifact.  The native clock is reported by ``native_main.zig``
around one dispatched operation, while this module retains the outer request
transport wall time separately.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import time
import traceback
from typing import Any, Iterable

if str(Path(__file__).resolve().parents[1]) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bench4.oracle import FIXTURE_NAMES, Operation, Oracle, expected, make_fixture, workload
from bench5.contracts import PROTOCOL, RECORDS, REPETITIONS, WARMUP


REPO_ROOT = Path(__file__).resolve().parents[1]
BENCHMARK_ROOT = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "benchmark"
ATTEMPTS_ROOT = BENCHMARK_ROOT / "native" / "attempts"
CONTROL_EXECUTABLE = REPO_ROOT / "experiments" / "frontier" / "unification-20260908" / "final" / "bin" / "lex4-final-release"
CONTROL_SOURCE = REPO_ROOT / "experiments" / "frontier" / "unification-20260908" / "final" / "source" / "bench4" / "bench_main.zig"
CONTROL_HARNESS = REPO_ROOT / "experiments" / "frontier" / "unification-20260908" / "final" / "source" / "bench4" / "harness.py"
CONTROL_SHA256 = "f8ac567dede75a8a0de9913d0cf77b9d70d149433023f10d83933833174d416e"
CONTROL_PROTOCOL = "LEX4-BENCH/1"
FOUNDATION13_REPORT = BENCHMARK_ROOT / "native" / "foundation13-correctness.json"
FOUNDATION13_LEDGER = BENCHMARK_ROOT / "foundation13-byte-scratch-ledger.json"
FOUNDATION13_SOURCE_MANIFEST = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "reviews" / "foundation-13" / "source-manifest.json"
FOUNDATION15_REPORT = BENCHMARK_ROOT / "native" / "foundation15-correctness.json"
FOUNDATION15_LEDGER = BENCHMARK_ROOT / "foundation15-byte-scratch-ledger.json"
FOUNDATION15_SOURCE_MANIFEST = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "reviews" / "foundation-15-final" / "source-manifest.json"
FOUNDATION16_REPORT = BENCHMARK_ROOT / "native" / "foundation16-correctness.json"
FOUNDATION16_LEDGER = BENCHMARK_ROOT / "foundation16-byte-scratch-ledger.json"
FOUNDATION16_SOURCE_MANIFEST = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "reviews" / "foundation-16" / "source-manifest.json"
CONTROL_READINESS = BENCHMARK_ROOT / "readiness.json"
HOST_DEPENDENCIES = (
    REPO_ROOT / "bench5" / "native.py",
    REPO_ROOT / "bench5" / "timing.py",
    REPO_ROOT / "bench5" / "contracts.py",
    REPO_ROOT / "bench4" / "oracle.py",
)


@dataclass(frozen=True)
class NativeCheckpoint:
    """Immutable candidate pin consumed by a future timing campaign.

    The checkpoint keeps the correctness report, byte/state ledger, and the
    captured source manifest together.  ``run_paired`` defaults to the
    accepted Foundation-13 replay pin, while a caller can explicitly select a
    later checkpoint after independently reviewing its correctness evidence.
    """

    label: str
    correctness_report: Path
    byte_state_ledger: Path
    source_manifest: Path

    def as_dict(self) -> dict[str, str]:
        return {
            "label": self.label,
            "correctness_report": str(self.correctness_report),
            "byte_state_ledger": str(self.byte_state_ledger),
            "source_manifest": str(self.source_manifest),
        }


FOUNDATION13_CHECKPOINT = NativeCheckpoint(
    label="Foundation-13",
    correctness_report=FOUNDATION13_REPORT,
    byte_state_ledger=FOUNDATION13_LEDGER,
    source_manifest=FOUNDATION13_SOURCE_MANIFEST,
)
FOUNDATION15_CHECKPOINT = NativeCheckpoint(
    label="Foundation-15-final",
    correctness_report=FOUNDATION15_REPORT,
    byte_state_ledger=FOUNDATION15_LEDGER,
    source_manifest=FOUNDATION15_SOURCE_MANIFEST,
)
FOUNDATION16_CHECKPOINT = NativeCheckpoint(
    label="Foundation-16",
    correctness_report=FOUNDATION16_REPORT,
    byte_state_ledger=FOUNDATION16_LEDGER,
    source_manifest=FOUNDATION16_SOURCE_MANIFEST,
)


class TimingError(RuntimeError):
    """The prepared timing boundary cannot produce trustworthy evidence."""


class MeasurementNotAuthorized(TimingError):
    """Raised when a campaign is requested without explicit timing admission."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repo_path(value: str | Path) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def _write_json(path: Path, value: object) -> None:
    """Persist a phase/report record without overwriting an existing file."""

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise TimingError(f"refusing to overwrite timing evidence: {path}")
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _file_record(path: Path) -> dict[str, object]:
    resolved = _safe_file(path)
    return {
        "path": str(resolved),
        "bytes": resolved.stat().st_size,
        "sha256": _sha256(resolved),
    }


def _tree_files(root: Path) -> tuple[Path, ...]:
    original = root.expanduser()
    if original.is_symlink() or any(parent.is_symlink() for parent in original.parents):
        raise TimingError(f"timing source tree cannot traverse a symlink: {original}")
    resolved = original.resolve(strict=True)
    if not resolved.is_dir():
        raise TimingError(f"timing source tree is not a directory: {resolved}")
    files: list[Path] = []
    for path in sorted(resolved.rglob("*")):
        if path.is_symlink():
            raise TimingError(f"timing source tree contains symlink: {path}")
        if path.is_file():
            files.append(path)
    if not files:
        raise TimingError(f"timing source tree is empty: {resolved}")
    return tuple(files)


def _verify_manifest_tree(
    root: Path,
    expected_rows: object,
    expected_tree_sha256: object,
    *,
    label: str,
) -> tuple[Path, ...]:
    """Verify an exact frozen source manifest, including additions/removals."""

    if not isinstance(expected_rows, list) or not isinstance(expected_tree_sha256, str):
        raise TimingError(f"{label} frozen manifest is malformed")
    resolved_root = root.expanduser().resolve(strict=True)
    if resolved_root.is_file():
        base = resolved_root.parent
    elif resolved_root.is_dir():
        base = resolved_root
    else:
        raise TimingError(f"{label} frozen manifest root is not a file/directory")
    actual_files = _tree_files(resolved_root)
    actual: dict[str, tuple[int, str, Path]] = {}
    for path in actual_files:
        relative = path.relative_to(base).as_posix()
        actual[relative] = (path.stat().st_size, _sha256(path), path)
    expected: dict[str, tuple[int, str]] = {}
    for row in expected_rows:
        if not isinstance(row, dict):
            raise TimingError(f"{label} frozen manifest contains a non-object row")
        relative, size, digest = row.get("path"), row.get("bytes"), row.get("sha256")
        if not isinstance(relative, str) or type(size) is not int or not isinstance(digest, str) or relative in expected:
            raise TimingError(f"{label} frozen manifest row is malformed")
        expected[relative] = (size, digest)
    if set(actual) != set(expected):
        raise TimingError(f"{label} frozen manifest file set drifted: actual={sorted(actual)!r} expected={sorted(expected)!r}")
    tree = hashlib.sha256()
    for relative in sorted(expected):
        size, digest = expected[relative]
        actual_size, actual_digest, _ = actual[relative]
        if (actual_size, actual_digest) != (size, digest):
            raise TimingError(f"{label} frozen manifest row drifted: {relative}")
        tree.update(f"{relative}\0{size}\0{digest}\n".encode())
    if tree.hexdigest() != expected_tree_sha256:
        raise TimingError(f"{label} frozen manifest tree hash drifted")
    return tuple(actual[relative][2] for relative in sorted(actual))


def _bundle_files(primary: Path) -> tuple[Path, ...]:
    """Return every regular file in one immutable artifact bundle."""

    parent = primary.expanduser().parent
    if parent.is_symlink() or any(ancestor.is_symlink() for ancestor in parent.parents):
        raise TimingError(f"timing artifact bundle cannot traverse a symlink: {parent}")
    resolved_parent = parent.resolve(strict=True)
    if not resolved_parent.is_dir():
        raise TimingError(f"timing artifact bundle is not a directory: {resolved_parent}")
    files: list[Path] = []
    for path in sorted(resolved_parent.rglob("*")):
        if path.is_symlink():
            raise TimingError(f"timing artifact bundle contains symlink: {path}")
        if path.is_file():
            files.append(path)
    if not files:
        raise TimingError(f"timing artifact bundle is empty: {resolved_parent}")
    resolved_primary = _safe_file(primary)
    if resolved_primary not in files:
        raise TimingError(f"timing primary artifact is outside its bundle: {resolved_primary}")
    return tuple(files)


def _safe_file(path: Path) -> Path:
    original = path.expanduser()
    if original.is_symlink() or any(parent.is_symlink() for parent in original.parents):
        raise TimingError(f"timing input cannot traverse a symlink: {original}")
    resolved = original.resolve(strict=True)
    if not resolved.is_file():
        raise TimingError(f"timing input is not a regular file: {resolved}")
    return resolved


def control_provenance() -> dict[str, object]:
    """Return and verify the immutable accepted LEX4 control identity."""

    executable = _safe_file(CONTROL_EXECUTABLE)
    digest = _sha256(executable)
    if digest != CONTROL_SHA256:
        raise TimingError(f"accepted LEX4 control hash drifted: {digest} != {CONTROL_SHA256}")
    return {
        "label": "immutable accepted LEX4",
        "executable": str(executable),
        "bytes": executable.stat().st_size,
        "sha256": digest,
        "source": str(_safe_file(CONTROL_SOURCE)),
        "source_sha256": _sha256(_safe_file(CONTROL_SOURCE)),
        "harness": str(_safe_file(CONTROL_HARNESS)),
        "harness_sha256": _sha256(_safe_file(CONTROL_HARNESS)),
    }


def _read_json(path: Path) -> dict[str, object]:
    resolved = _safe_file(path)
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise TimingError(f"timing provenance is not valid JSON: {resolved}") from exc
    if not isinstance(value, dict):
        raise TimingError(f"timing provenance root is not an object: {resolved}")
    return value


def _pinned_candidate(checkpoint: NativeCheckpoint = FOUNDATION13_CHECKPOINT) -> dict[str, object]:
    """Load one exact machine-generated immutable native checkpoint.

    Artifact paths, byte counts, state/scratch fields, and hashes come from
    the checkpoint's correctness report and byte/state ledger rather than
    being copied into this driver.  The captured source manifest and the
    frozen source manifests in the report are reconciled before the candidate
    can enter a future timing attempt.
    """

    if not isinstance(checkpoint, NativeCheckpoint):
        raise TimingError("native checkpoint must be a NativeCheckpoint")
    label = checkpoint.label
    report_path = _safe_file(checkpoint.correctness_report)
    source_manifest = _safe_file(checkpoint.source_manifest)
    ledger_path = _safe_file(checkpoint.byte_state_ledger)
    report = _read_json(report_path)
    ledger = _read_json(ledger_path)
    ledger_report = ledger.get("correctness_report")
    if isinstance(ledger_report, str) and _safe_file(_repo_path(ledger_report)) != report_path:
        raise TimingError(f"{label} byte/state ledger points to a different correctness report")
    ledger_candidate = ledger.get("candidate")
    if not isinstance(ledger_candidate, dict):
        raise TimingError(f"{label} byte/state ledger lacks candidate provenance")
    manifest_sha256 = ledger_candidate.get("source_manifest_sha256")
    if not isinstance(manifest_sha256, str) or _sha256(source_manifest) != manifest_sha256:
        raise TimingError(f"{label} source manifest drifted from byte/state ledger")
    report_manifest_sha256 = report.get("foundation15_source_manifest_sha256")
    if report_manifest_sha256 is not None and report_manifest_sha256 != manifest_sha256:
        raise TimingError(f"{label} correctness report disagrees with its source manifest")
    manifest_rows = _read_json(source_manifest)
    if not manifest_rows or any(
        not isinstance(row, dict)
        or type(row.get("bytes")) is not int
        or not isinstance(row.get("sha256"), str)
        for row in manifest_rows.values()
    ):
        raise TimingError(f"{label} source manifest has malformed rows")
    native = report.get("native")
    fixtures = report.get("fixtures")
    if not isinstance(native, dict) or not isinstance(fixtures, list):
        raise TimingError(f"{label} correctness report has no native/fixtures records")
    if report.get("status") not in ("passed", "passed_root_review_pending"):
        raise TimingError(f"{label} correctness report is not a pass: {report.get('status')!r}")
    executable_value = native.get("executable")
    executable_sha = native.get("executable_sha256")
    root_source_value = native.get("root_source")
    src5_root_value = native.get("src5_root")
    if not all(isinstance(value, str) for value in (executable_value, executable_sha, root_source_value, src5_root_value)):
        raise TimingError(f"{label} correctness report lacks frozen executable/source paths")
    executable = _safe_file(_repo_path(executable_value))
    if _sha256(executable) != executable_sha:
        raise TimingError(f"{label} executable hash drifted from correctness report")
    artifact_records: dict[str, dict[str, object]] = {}
    seen: set[str] = set()
    for item in fixtures:
        if not isinstance(item, dict):
            raise TimingError(f"{label} correctness report contains a non-object fixture")
        name = item.get("fixture")
        path_value = item.get("path")
        artifact_bytes = item.get("bytes")
        artifact_sha = item.get("sha256")
        if not isinstance(name, str) or name in seen or not isinstance(path_value, str):
            raise TimingError(f"{label} correctness report has invalid or duplicate fixture identity")
        if type(artifact_bytes) is not int or not isinstance(artifact_sha, str):
            raise TimingError(f"{label} correctness report has invalid byte/hash fields: {name!r}")
        artifact = _safe_file(_repo_path(path_value))
        if artifact.stat().st_size != artifact_bytes or _sha256(artifact) != artifact_sha:
            raise TimingError(f"{label} artifact drifted from correctness report: {name}")
        seen.add(name)
        artifact_records[name] = {
            "fixture": name,
            "path": artifact,
            "bytes": artifact_bytes,
            "sha256": artifact_sha,
        }
    if tuple(sorted(seen)) != tuple(sorted(FIXTURE_NAMES)):
        raise TimingError(f"{label} fixture set differs from canonical five: {sorted(seen)!r}")
    ledger_fixtures = ledger.get("fixtures")
    state_sizes = ledger.get("state_sizes")
    if not isinstance(ledger_fixtures, list) or not isinstance(state_sizes, dict):
        raise TimingError(f"{label} byte/state ledger lacks full fixture/state records")
    ledger_by_fixture: dict[str, dict[str, object]] = {}
    for item in ledger_fixtures:
        if not isinstance(item, dict) or not isinstance(item.get("fixture"), str):
            raise TimingError(f"{label} byte/state ledger has malformed fixture records")
        name = item["fixture"]
        if name in ledger_by_fixture:
            raise TimingError(f"{label} byte/state ledger repeats fixture: {name}")
        ledger_bytes = item.get("lex5_artifact_bytes")
        ledger_sha = item.get("lex5_artifact_sha256")
        if type(ledger_bytes) is not int or not isinstance(ledger_sha, str):
            raise TimingError(f"{label} byte/state ledger has invalid artifact fields: {name}")
        actual = artifact_records.get(name)
        if actual is None or actual["bytes"] != ledger_bytes or actual["sha256"] != ledger_sha:
            raise TimingError(f"{label} byte/state ledger disagrees with correctness artifact: {name}")
        ledger_by_fixture[name] = item
    if tuple(sorted(ledger_by_fixture)) != tuple(sorted(FIXTURE_NAMES)):
        raise TimingError(f"{label} byte/state ledger fixture set differs from canonical five")
    report_ready = report.get("ready_states")
    for name, item in ledger_by_fixture.items():
        ledger_ready = item.get("ready")
        if not isinstance(ledger_ready, dict):
            raise TimingError(f"{label} byte/state ledger lacks ready state: {name}")
        if isinstance(report_ready, dict) and report_ready.get(name) != ledger_ready:
            raise TimingError(f"{label} correctness report disagrees with ready state ledger: {name}")
        report_item = next(row for row in fixtures if row.get("fixture") == name)
        fixture_ready = report_item.get("ready")
        if isinstance(fixture_ready, dict) and fixture_ready != ledger_ready:
            raise TimingError(f"{label} fixture report disagrees with ready state ledger: {name}")
    provenance = report.get("source_provenance")
    if not isinstance(provenance, dict):
        raise TimingError(f"{label} correctness report lacks source provenance")
    frozen = provenance.get("frozen")
    if not isinstance(frozen, dict):
        raise TimingError(f"{label} correctness report lacks frozen source manifests")
    native_frozen = frozen.get("native")
    src5_frozen = frozen.get("src5")
    if not isinstance(native_frozen, dict) or not isinstance(src5_frozen, dict):
        raise TimingError(f"{label} correctness report lacks native/src5 frozen manifests")
    if not isinstance(native_frozen.get("tree_sha256"), str) or not isinstance(src5_frozen.get("tree_sha256"), str):
        raise TimingError(f"{label} correctness report lacks source tree hashes")
    root_source = _safe_file(_repo_path(root_source_value))
    src5_root = _safe_file(_repo_path(src5_root_value))
    native_files = _verify_manifest_tree(
        root_source.parent,
        native_frozen.get("files"),
        native_frozen["tree_sha256"],
        label=f"{label} native adapter source",
    )
    src5_files = _verify_manifest_tree(
        src5_root.parent,
        src5_frozen.get("files"),
        src5_frozen["tree_sha256"],
        label=f"{label} src5 source",
    )
    # Reconcile the frozen attempt's two compile inputs against the selected
    # checkpoint's source manifest as well as the correctness report.
    # The manifest contains probes/build metadata too, but the native adapter
    # dependency subset must have an exact file set and byte/hash match here.
    native_manifest_rows = {
        path.removeprefix("bench5/"): row
        for path, row in manifest_rows.items()
        if path.startswith("bench5/")
    }
    src5_manifest_rows = {
        path.removeprefix("src5/"): row
        for path, row in manifest_rows.items()
        if path.startswith("src5/")
    }
    native_relatives = {path.relative_to(root_source.parent).as_posix() for path in native_files}
    src5_relatives = {path.relative_to(src5_root.parent).as_posix() for path in src5_files}
    if set(native_manifest_rows) != native_relatives or set(src5_manifest_rows) != src5_relatives:
        raise TimingError(f"{label} native/src5 dependency set differs from source manifest")
    for relative, path in ((path.relative_to(root_source.parent).as_posix(), path) for path in native_files):
        row = native_manifest_rows[relative]
        if path.stat().st_size != row["bytes"] or _sha256(path) != row["sha256"]:
            raise TimingError(f"{label} native dependency differs from source manifest: {relative}")
    for relative, path in ((path.relative_to(src5_root.parent).as_posix(), path) for path in src5_files):
        row = src5_manifest_rows[relative]
        if path.stat().st_size != row["bytes"] or _sha256(path) != row["sha256"]:
            raise TimingError(f"{label} src5 dependency differs from source manifest: {relative}")
    return {
        "label": "LEX5",
        "checkpoint_label": label,
        "checkpoint": checkpoint.as_dict(),
        "report": report_path,
        "ledger": ledger_path,
        "source_manifest": source_manifest,
        "source_manifest_sha256": manifest_sha256,
        "attempt_dir": _repo_path(report.get("attempt_dir")) if isinstance(report.get("attempt_dir"), str) else None,
        "executable": executable,
        "executable_sha256": executable_sha,
        "root_source": root_source,
        "native_source_files": native_files,
        "src5_root": src5_files,
        "src5_dir": src5_root.parent,
        "native_tree_sha256": native_frozen.get("tree_sha256"),
        "src5_tree_sha256": src5_frozen.get("tree_sha256"),
        "artifacts": artifact_records,
    }


def _pinned_control() -> dict[str, object]:
    """Load the accepted paired-release LEX4 artifact ledger read-only."""

    identity = control_provenance()
    readiness = _read_json(CONTROL_READINESS)
    ledger = readiness.get("control_artifact_ledger")
    if not isinstance(ledger, dict) or not isinstance(ledger.get("artifacts"), list):
        raise TimingError("accepted LEX4 readiness ledger lacks artifact records")
    records: dict[str, dict[str, object]] = {}
    for item in ledger["artifacts"]:
        if not isinstance(item, dict):
            raise TimingError("accepted LEX4 artifact ledger contains a non-object")
        name, path_value = item.get("fixture"), item.get("path")
        artifact_bytes, artifact_sha = item.get("bytes"), item.get("sha256")
        if not isinstance(name, str) or not isinstance(path_value, str) or type(artifact_bytes) is not int or not isinstance(artifact_sha, str):
            raise TimingError("accepted LEX4 artifact ledger has invalid fields")
        artifact = _safe_file(_repo_path(path_value))
        if artifact.stat().st_size != artifact_bytes or _sha256(artifact) != artifact_sha:
            raise TimingError(f"accepted LEX4 artifact drifted from readiness ledger: {name}")
        records[name] = {"fixture": name, "path": artifact, "bytes": artifact_bytes, "sha256": artifact_sha}
    if tuple(sorted(records)) != tuple(sorted(FIXTURE_NAMES)):
        raise TimingError(f"accepted LEX4 fixture set differs from canonical five: {sorted(records)!r}")
    return {
        "label": "immutable accepted LEX4",
        "readiness": _safe_file(CONTROL_READINESS),
        "executable": Path(identity["executable"]),
        "executable_sha256": identity["sha256"],
        "source": Path(identity["source"]),
        "source_sha256": identity["source_sha256"],
        "harness": Path(identity["harness"]),
        "harness_sha256": identity["harness_sha256"],
        "identity": identity,
        "artifacts": records,
    }


@dataclass(frozen=True)
class MeasurementPlan:
    """A compact plan which records counts/order policy, never operations."""

    records: int
    repetitions: int
    warmup: int
    fixtures: tuple[str, ...]
    batch_count: int = 1
    lane_labels: tuple[str, str] = ("lex4-control", "lex5-candidate")

    def pair_count(self) -> int:
        return self.batch_count * len(self.fixtures) * (self.warmup + self.repetitions)

    def lane_order(self, pair_index: int) -> tuple[str, str]:
        if pair_index < 0 or pair_index >= self.pair_count():
            raise TimingError(f"pair index out of range: {pair_index}")
        return self.lane_labels if pair_index % 2 == 0 else (self.lane_labels[1], self.lane_labels[0])

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "LEX5-PAIRED-MEASUREMENT-PLAN/1",
            "records": self.records,
            "repetitions": self.repetitions,
            "warmup": self.warmup,
            "fixtures": list(self.fixtures),
            "batch_count": self.batch_count,
            "lane_labels": list(self.lane_labels),
            "pair_count": self.pair_count(),
            "pair_order": "chronological; alternates within each batch and flips the first lane on each batch",
            "selection": "all raw observations retained; no best-of-runs selection",
            "query_schedule": "not retained in plan or artifacts",
        }


def build_plan(
    *,
    records: int = RECORDS,
    repetitions: int = REPETITIONS,
    warmup: int = WARMUP,
    fixtures: Iterable[str] = FIXTURE_NAMES,
    batch_count: int = 1,
) -> MeasurementPlan:
    selected = tuple(fixtures)
    if selected != tuple(FIXTURE_NAMES):
        raise TimingError(f"paired campaign must use the unchanged five fixtures: {selected!r}")
    if records <= 0 or repetitions <= 0 or warmup < 0 or batch_count <= 0:
        raise TimingError("records/repetitions must be positive and warmup cannot be negative")
    return MeasurementPlan(records, repetitions, warmup, selected, batch_count=batch_count)


def new_attempt_dir() -> Path:
    """Allocate a unique attempt directory without overwriting prior runs."""

    ATTEMPTS_ROOT.mkdir(parents=True, exist_ok=True)
    name = f"attempt-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}-{secrets.token_hex(4)}"
    path = ATTEMPTS_ROOT / name
    path.mkdir(parents=True, exist_ok=False)
    return path


@dataclass(frozen=True)
class HashGuard:
    """Expected immutable bytes checked before and after a future campaign."""

    expected_sha256: dict[str, str]

    def verify(self, paths: dict[str, Path], *, stage: str) -> dict[str, object]:
        observed: dict[str, str] = {}
        for label, path in paths.items():
            resolved = _safe_file(path)
            observed[label] = _sha256(resolved)
            expected_digest = self.expected_sha256.get(label)
            if expected_digest is None or observed[label] != expected_digest:
                raise TimingError(f"frozen hash drift at {stage}/{label}: {observed[label]} != {expected_digest}")
        return {"stage": stage, "ok": True, "sha256": observed}


_COMMON_FIELDS = frozenset({"protocol", "request_id", "op", "sample", "timing_mode"})
_OP_FIELDS = {
    "exact": frozenset({"key"}),
    "prefix_interval": frozenset({"key"}),
    "prefix_enumerate": frozenset({"key"}),
    "select": frozenset({"id"}),
    "render": frozenset({"id"}),
    "snippet": frozenset({"id", "limit"}),
    "concept_members": frozenset({"id"}),
    "translations": frozenset({"id", "language"}),
    "relations": frozenset({"id", "predicate"}),
}


def timed_request(operation: Operation, request_id: int, *, protocol: str = PROTOCOL) -> dict[str, object]:
    """Build a strict answer-free ``reader_self`` request."""

    if operation.op not in _OP_FIELDS:
        raise TimingError(f"operation is not admitted to reader_self timing: {operation.op!r}")
    request = dict(operation.wire())
    request.pop("category", None)
    request.update({"protocol": protocol, "request_id": request_id, "timing_mode": "reader_self"})
    allowed = _COMMON_FIELDS | _OP_FIELDS[operation.op]
    forbidden = {"expected", "oracle", "answers", "query_checksum", "schedule", "workload", "category"}
    if set(request) - allowed or set(request) & forbidden:
        raise TimingError(f"request fields are outside strict timing allowlist: {sorted(request)!r}")
    return request


def validate_timed_response(value: object, *, request_id: int, sample: int, protocol: str = PROTOCOL) -> dict[str, object]:
    """Validate the complete self-timed response envelope before normalization."""

    if not isinstance(value, dict):
        raise TimingError("native timed response is not an object")
    required = {"protocol", "request_id", "sample", "ok", "timing_mode", "reader_elapsed_ns", "result"}
    if set(value) != required:
        raise TimingError(f"native timed response fields differ: {sorted(value)!r}")
    if value["protocol"] != protocol or type(value["request_id"]) is not int or value["request_id"] != request_id:
        raise TimingError("native timed response protocol/request id mismatch")
    if type(value["sample"]) is not int or value["sample"] != sample:
        raise TimingError("native timed response sample mismatch")
    if value["ok"] is not True or value["timing_mode"] != "reader_self":
        raise TimingError("native timed response did not affirm reader_self")
    if type(value["reader_elapsed_ns"]) is not int or value["reader_elapsed_ns"] < 0:
        raise TimingError("native timed response elapsed time is not a nonnegative integer")
    if not isinstance(value["result"], dict):
        raise TimingError("native timed result is not an object")
    return value


def _digest(value: object) -> str:
    return hashlib.sha256((json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()


def normalize_result(operation: Operation, result: dict[str, object], *, lane: str) -> dict[str, object]:
    """Normalize wire results after timing; bounds are native for LEX5."""

    candidate = lane == "lex5-candidate"

    def list_value(name: str) -> list[object]:
        value = result.get(name)
        if not isinstance(value, list):
            raise TimingError(f"{lane} {operation.op} result field {name!r} is not an array")
        return list(value)

    if operation.op == "exact":
        ids = list_value("ids")
        if candidate and result.get("cardinality") != len(ids):
            raise TimingError("LEX5 exact cardinality mismatch")
        return {"op": operation.op, "ids": ids, "cardinality": len(ids)}
    if operation.op == "prefix_interval":
        lo, hi = result.get("lo"), result.get("hi")
        if type(lo) is not int or type(hi) is not int:
            raise TimingError("prefix interval bounds must be integers")
        if candidate and (lo < 0 or hi < lo or result.get("cardinality") != hi - lo):
            raise TimingError("LEX5 prefix interval bounds/cardinality mismatch")
        return {"op": operation.op, "lo": lo, "hi": hi, "cardinality": hi - lo}
    if operation.op == "prefix_enumerate":
        ids = list_value("ids")
        lo, hi = result.get("lo"), result.get("hi")
        if type(lo) is int and type(hi) is int:
            if lo < 0 or hi < lo or hi - lo != len(ids):
                raise TimingError(f"{lane} prefix enumeration bounds/metadata mismatch")
            if result.get("cardinality") is not None and result.get("cardinality") != len(ids):
                raise TimingError(f"{lane} prefix enumeration cardinality mismatch")
            return {"op": operation.op, "ids": ids, "lo": lo, "hi": hi, "cardinality": len(ids)}
        if candidate:
            raise TimingError("LEX5 prefix enumeration omitted native bounds")
        # The accepted LEX4 wire returns only the enumeration.  Preserve that
        # native shape instead of manufacturing interval metadata from the
        # host oracle; the control comparison below projects only the fields
        # the control reader actually emitted.
        return {"op": operation.op, "ids": ids, "cardinality": len(ids)}
    if operation.op == "select":
        return {"op": operation.op, "id": result["id"], "key": result["key"], "rank": result["rank"]}
    if operation.op in ("render", "snippet"):
        encoded = result.get("bytes_hex")
        if not isinstance(encoded, str):
            raise TimingError(f"{lane} {operation.op} omitted bytes_hex")
        try:
            raw = bytes.fromhex(encoded)
        except ValueError as exc:
            raise TimingError(f"{lane} {operation.op} returned invalid hex") from exc
        normalized: dict[str, object] = {"op": operation.op, "id": operation.ident, "bytes_hex": raw.hex(), "bytes": len(raw)}
        if operation.op == "snippet":
            normalized["limit"] = operation.limit
        return normalized
    if operation.op in ("concept_members", "translations"):
        values = list_value("members")
        return {
            "op": operation.op,
            "id": operation.ident,
            **({"language": operation.language} if operation.op == "translations" else {}),
            "members": values,
            "cardinality": len(values),
        }
    if operation.op == "relations":
        values = list_value("relations")
        return {"op": operation.op, "id": operation.ident, "relations": values, "cardinality": len(values)}
    raise TimingError(f"unsupported timed operation: {operation.op!r}")


def _raw_line_record(value: bytes | None) -> dict[str, object] | None:
    """Make malformed/partial JSONL bytes safe to persist in a host failure."""

    if value is None:
        return None
    return {
        "bytes": len(value),
        "hex": value.hex(),
        "text": value.decode("utf-8", "replace"),
    }


class JsonlTimedClient:
    """One already-open native server; construction performs no subprocess work."""

    READY_TIMEOUT_SECONDS = 30.0
    RESPONSE_TIMEOUT_SECONDS = 30.0
    MAX_LINE_BYTES = 16 * 1024 * 1024

    def __init__(self, *, label: str, command: list[str], artifact: Path, stderr_path: Path | None = None):
        self.label = label
        self.command = list(command)
        self.artifact = artifact
        self.protocol = CONTROL_PROTOCOL if label == "lex4-control" else PROTOCOL
        self.stderr_path = stderr_path
        self.stderr_stream: Any | None = None
        self.process: subprocess.Popen[bytes] | None = None
        self.request_id = 0
        self.ready: dict[str, object] | None = None
        self.open_wall_ns: int | None = None
        self.close_wall_ns: int | None = None
        self.returncode: int | None = None
        self._stdout_buffer = bytearray()
        self._last_raw_line: bytes | None = None
        self.last_ready_raw: bytes | None = None
        self.last_request_record: dict[str, object] | None = None

    def _readline_with_timeout(self, timeout_seconds: float) -> bytes:
        """Read one bounded JSONL line, including a partial-line timeout."""

        if self.process is None or self.process.stdout is None:
            raise TimingError(f"{self.label} stdout is unavailable")
        descriptor = self.process.stdout.fileno()
        deadline = time.monotonic() + timeout_seconds
        selector = selectors.DefaultSelector()
        try:
            selector.register(descriptor, selectors.EVENT_READ)
            while True:
                newline = self._stdout_buffer.find(b"\n")
                if newline >= 0:
                    line = bytes(self._stdout_buffer[:newline])
                    del self._stdout_buffer[: newline + 1]
                    self._last_raw_line = line
                    return line
                if len(self._stdout_buffer) > self.MAX_LINE_BYTES:
                    self._last_raw_line = bytes(self._stdout_buffer)
                    raise TimingError(f"{self.label} JSONL line exceeds {self.MAX_LINE_BYTES} bytes")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._last_raw_line = bytes(self._stdout_buffer)
                    raise TimingError(
                        f"{self.label} JSONL response timed out after {timeout_seconds:g}s "
                        f"with {len(self._stdout_buffer)} partial bytes"
                    )
                if not selector.select(timeout=remaining):
                    self._last_raw_line = bytes(self._stdout_buffer)
                    raise TimingError(
                        f"{self.label} JSONL response timed out after {timeout_seconds:g}s "
                        f"with {len(self._stdout_buffer)} partial bytes"
                    )
                try:
                    chunk = os.read(descriptor, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    self._last_raw_line = bytes(self._stdout_buffer)
                    if self._stdout_buffer:
                        line = bytes(self._stdout_buffer)
                        self._stdout_buffer.clear()
                        return line
                    return b""
                self._stdout_buffer.extend(chunk)
        finally:
            selector.close()

    def _abort_process(self) -> None:
        process = self.process
        self.process = None
        if process is None:
            if self.stderr_stream is not None:
                self.stderr_stream.close()
                self.stderr_stream = None
            return
        try:
            if process.stdin is not None:
                try:
                    process.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
            if process.poll() is None:
                process.kill()
            try:
                self.returncode = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                self.returncode = process.wait(timeout=5)
        finally:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
            if self.stderr_stream is not None:
                self.stderr_stream.close()
                self.stderr_stream = None

    def open(self) -> dict[str, object]:
        if self.process is not None:
            raise TimingError(f"{self.label} server already open")
        stderr: Any = subprocess.DEVNULL
        if self.stderr_path is not None:
            self.stderr_path.parent.mkdir(parents=True, exist_ok=True)
            self.stderr_stream = self.stderr_path.open("w", encoding="utf-8")
            stderr = self.stderr_stream
        started = time.perf_counter_ns()
        line: bytes | None = None
        try:
            self.process = subprocess.Popen(
                [*self.command, "--bench4-server" if self.label == "lex4-control" else "--bench5-server", "--artifact", str(self.artifact)],
                cwd=REPO_ROOT,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr,
                text=False,
                bufsize=0,
            )
            assert self.process.stdout is not None
            os.set_blocking(self.process.stdout.fileno(), False)
            line = self._readline_with_timeout(self.READY_TIMEOUT_SECONDS)
            # The ready line boundary is the open measurement endpoint.  All
            # decoding, JSON validation, artifact stat, and readiness checks
            # below are deliberately outside open_wall_ns.
            ready_arrival = time.perf_counter_ns()
            self.open_wall_ns = ready_arrival - started
            self.last_ready_raw = line
            if not line:
                raise TimingError(f"{self.label} exited before ready")
            try:
                value = json.loads(line.decode("utf-8", "strict"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise TimingError(f"{self.label} ready event is not JSON") from exc
            if not isinstance(value, dict) or value.get("protocol") != self.protocol or value.get("event") != "ready" or value.get("artifact_bytes") != self.artifact.stat().st_size:
                raise TimingError(f"{self.label} ready event mismatch")
            if self.label == "lex5-candidate":
                for field in ("book_bytes", "scratch_ids", "scratch_relations", "scratch_bytes", "scratch_key", "scratch_relation_text"):
                    if type(value.get(field)) is not int or value[field] <= 0:
                        raise TimingError(f"LEX5 ready event omitted valid {field}")
            self.ready = value
            return value
        except BaseException:
            if self.last_ready_raw is None:
                self.last_ready_raw = self._last_raw_line
            self._abort_process()
            if self.open_wall_ns is None:
                self.open_wall_ns = time.perf_counter_ns() - started
            raise

    def timed_request(self, operation: Operation) -> tuple[dict[str, object], int, int]:
        if self.process is None or self.process.stdin is None or self.process.stdout is None:
            raise TimingError(f"{self.label} request before open")
        request_id = self.request_id
        self.request_id += 1
        request = timed_request(operation, request_id, protocol=self.protocol)
        started = time.perf_counter_ns()
        self._last_raw_line = None
        self.last_request_record = {
            "request_id": request_id,
            "sample": operation.sample,
            "op": operation.op,
            "reader_elapsed_ns": None,
            "outer_elapsed_ns": None,
            "raw_response": None,
        }
        try:
            encoded_request = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
            self.process.stdin.write(encoded_request)
            self.process.stdin.flush()
            line = self._readline_with_timeout(self.RESPONSE_TIMEOUT_SECONDS)
            response_arrival = time.perf_counter_ns()
            outer_elapsed = response_arrival - started
            self.last_request_record["outer_elapsed_ns"] = outer_elapsed
            self.last_request_record["raw_response"] = _raw_line_record(line)
            if not line:
                raise TimingError(f"{self.label} exited before timed response")
            try:
                response = json.loads(line.decode("utf-8", "strict"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise TimingError(f"{self.label} timed response is not JSON") from exc
            value = validate_timed_response(response, request_id=request_id, sample=operation.sample, protocol=self.protocol)
            reader_elapsed = value["reader_elapsed_ns"]
            if reader_elapsed > outer_elapsed:
                raise TimingError(f"{self.label} reader time exceeds outer request time")
            self.last_request_record["reader_elapsed_ns"] = reader_elapsed
            return value["result"], reader_elapsed, outer_elapsed
        except BaseException as exc:
            if self.last_request_record["outer_elapsed_ns"] is None:
                self.last_request_record["outer_elapsed_ns"] = time.perf_counter_ns() - started
            if self.last_request_record["raw_response"] is None:
                self.last_request_record["raw_response"] = _raw_line_record(self._last_raw_line)
            self.last_request_record["error"] = type(exc).__name__
            self._abort_process()
            raise

    def close(self) -> None:
        process = self.process
        self.process = None
        if process is None:
            return
        started = time.perf_counter_ns()
        close_error: BaseException | None = None
        try:
            if process.stdin is not None:
                try:
                    process.stdin.close()
                except (BrokenPipeError, OSError) as exc:
                    close_error = exc
            try:
                self.returncode = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                    self.returncode = process.wait(timeout=5)
                except BaseException as exc:
                    close_error = close_error or exc
        except BaseException as exc:
            close_error = close_error or exc
        finally:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
            if self.stderr_stream is not None:
                self.stderr_stream.close()
                self.stderr_stream = None
            self.close_wall_ns = time.perf_counter_ns() - started
        if close_error is not None:
            raise TimingError(f"{self.label} server close failed") from close_error
        if self.returncode != 0:
            raise TimingError(f"{self.label} server exited with status {self.returncode}")

    def lifecycle(self) -> dict[str, object]:
        return {
            "label": self.label,
            "command": list(self.command),
            "artifact": str(self.artifact),
            "ready": self.ready,
            "ready_raw": _raw_line_record(self.last_ready_raw),
            "open_wall_ns": self.open_wall_ns,
            "close_wall_ns": self.close_wall_ns,
            "returncode": self.returncode,
            "last_request": self.last_request_record,
        }


def _persist_text(path: Path, value: str | bytes | None) -> int:
    if value is None:
        data = b""
    elif isinstance(value, bytes):
        data = value
    else:
        data = value.encode("utf-8", "replace")
    if path.exists():
        raise TimingError(f"refusing to overwrite timing phase output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return len(data)


def _run_wall_phase(
    command: list[str],
    *,
    phase: str,
    logs_dir: Path,
    timeout_seconds: float = 120.0,
) -> tuple[dict[str, object], str]:
    """Run one non-query subprocess phase and persist every result first."""

    stdout_path = logs_dir / f"{phase}.stdout"
    stderr_path = logs_dir / f"{phase}.stderr"
    record_path = logs_dir / f"{phase}.json"
    started = time.perf_counter_ns()
    process: subprocess.CompletedProcess[str] | None = None
    error: str | None = None
    try:
        process = subprocess.run(
            command,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        error = "TimeoutExpired"
        stdout_value = exc.stdout
        stderr_value = exc.stderr
        elapsed = time.perf_counter_ns() - started
        stdout_bytes = _persist_text(stdout_path, stdout_value)
        stderr_bytes = _persist_text(stderr_path, stderr_value)
        record = {
            "phase": phase,
            "command": command,
            "returncode": None,
            "wall_ns": elapsed,
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "stdout_bytes": stdout_bytes,
            "stderr_bytes": stderr_bytes,
            "error": error,
        }
        _write_json(record_path, record)
        raise TimingError(f"timing phase timed out: {phase}") from exc
    except BaseException as exc:
        error = type(exc).__name__
        elapsed = time.perf_counter_ns() - started
        stdout_bytes = _persist_text(stdout_path, None)
        stderr_bytes = _persist_text(stderr_path, None)
        record = {
            "phase": phase,
            "command": command,
            "returncode": None,
            "wall_ns": elapsed,
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "stdout_bytes": stdout_bytes,
            "stderr_bytes": stderr_bytes,
            "error": error,
        }
        _write_json(record_path, record)
        raise TimingError(f"timing phase could not start: {phase}") from exc
    elapsed = time.perf_counter_ns() - started
    stdout_bytes = _persist_text(stdout_path, process.stdout)
    stderr_bytes = _persist_text(stderr_path, process.stderr)
    record = {
        "phase": phase,
        "command": command,
        "returncode": process.returncode,
        "wall_ns": elapsed,
        "stdout_path": str(stdout_path),
        "stderr_path": str(stderr_path),
        "stdout_bytes": stdout_bytes,
        "stderr_bytes": stderr_bytes,
        "error": error,
    }
    _write_json(record_path, record)
    if process.returncode != 0:
        raise TimingError(f"timing phase failed: {phase} (exit {process.returncode})")
    return record, process.stdout


def _campaign_hash_paths(candidate: dict[str, object], control: dict[str, object]) -> dict[str, Path]:
    paths: dict[str, Path] = {}

    def add(label: str, value: object) -> None:
        if not isinstance(value, Path):
            raise TimingError(f"campaign provenance path is not a Path: {label}")
        paths[label] = value

    add("candidate-correctness-report", candidate["report"])
    add("candidate-byte-ledger", candidate["ledger"])
    add("candidate-source-manifest", candidate["source_manifest"])
    add("candidate-executable", candidate["executable"])
    for source in candidate["native_source_files"]:
        if not isinstance(source, Path):
            raise TimingError("candidate native source provenance contains a non-path")
        add(f"candidate-native-source/{source.name}", source)
    for source in candidate["src5_root"]:
        if not isinstance(source, Path):
            raise TimingError("candidate src5 provenance contains a non-path")
        add(f"candidate-src5/{source.name}-{_sha256(source)[:16]}", source)
    add("control-readiness", control["readiness"])
    add("control-executable", control["executable"])
    add("control-source", control["source"])
    add("control-harness", control["harness"])
    for dependency in HOST_DEPENDENCIES:
        add(f"host-dependency/{dependency.relative_to(REPO_ROOT).as_posix()}", dependency)
    for lane, source in (("candidate", candidate), ("control", control)):
        artifacts = source.get("artifacts")
        if not isinstance(artifacts, dict):
            raise TimingError(f"{lane} artifact provenance is missing")
        for fixture_name, item in artifacts.items():
            if not isinstance(item, dict) or not isinstance(item.get("path"), Path):
                raise TimingError(f"{lane} artifact provenance is invalid: {fixture_name}")
            primary = item["path"]
            for path in _bundle_files(primary):
                relative = path.relative_to(primary.parent).as_posix()
                add(f"{lane}-artifact/{fixture_name}/{relative}", path)
    return paths


def _hash_snapshot(paths: dict[str, Path]) -> dict[str, object]:
    return {
        label: _file_record(path)
        for label, path in sorted(paths.items())
    }


def _campaign_tree_roots(candidate: dict[str, object], control: dict[str, object]) -> dict[str, Path]:
    del control
    native_files = candidate.get("native_source_files")
    src5_dir = candidate.get("src5_dir")
    if not isinstance(native_files, tuple) or not native_files or not isinstance(native_files[0], Path):
        raise TimingError("candidate native source tree provenance is missing")
    if not isinstance(src5_dir, Path):
        raise TimingError("candidate src5 source tree provenance is missing")
    return {
        "candidate-native-source": native_files[0].parent,
        "candidate-src5-source": src5_dir,
    }


def _tree_snapshot(roots: dict[str, Path]) -> dict[str, object]:
    result: dict[str, object] = {}
    for label, root in sorted(roots.items()):
        resolved = root.resolve(strict=True)
        files = _tree_files(resolved)
        rows: list[dict[str, object]] = []
        for path in files:
            rows.append(
                {
                    "path": path.relative_to(resolved).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": _sha256(path),
                }
            )
        result[label] = {"root": str(resolved), "files": rows}
    return result


def _assert_hash_snapshot(before: dict[str, object], after: dict[str, object]) -> None:
    if before != after:
        changed: list[str] = []
        for label in sorted(set(before) | set(after)):
            if before.get(label) != after.get(label):
                changed.append(label)
        raise TimingError(f"frozen input bytes changed during campaign: {changed!r}")


def _audit_expected(fixture: Any) -> dict[str, object]:
    return {
        "entries": [entry.canonical() for entry in fixture.entries],
        "senses": [sense.canonical() for sense in fixture.senses],
        "concepts": [concept.canonical() for concept in fixture.concepts],
        "relations": [relation.canonical() for relation in fixture.relations],
    }


def _candidate_audit(
    fixture_name: str,
    records: int,
    artifact: Path,
    executable: Path,
    logs_dir: Path,
    phase_suffix: str = "",
) -> dict[str, object]:
    command = [str(executable), "--bench5-audit", "--artifact", str(artifact)]
    prefix = f"{phase_suffix}-{fixture_name}" if phase_suffix else fixture_name
    phase, stdout = _run_wall_phase(command, phase=f"{prefix}-candidate-audit", logs_dir=logs_dir)
    try:
        actual = json.loads(stdout)
    except json.JSONDecodeError as exc:
        failure = {"phase": phase["phase"], "error": "audit_not_json", "actual_stdout": stdout}
        _write_json(logs_dir / f"{prefix}-candidate-audit.failure.json", failure)
        raise TimingError(f"candidate audit was not JSON: {fixture_name}") from exc
    if not isinstance(actual, dict):
        failure = {"phase": phase["phase"], "error": "audit_not_object", "actual": actual}
        _write_json(logs_dir / f"{prefix}-candidate-audit.failure.json", failure)
        raise TimingError(f"candidate audit root was not an object: {fixture_name}")
    fixture = make_fixture(fixture_name, records)
    expected_audit = _audit_expected(fixture)
    if actual != expected_audit:
        failure = {
            "phase": phase["phase"],
            "error": "audit_mismatch",
            "actual": actual,
            "expected": expected_audit,
        }
        _write_json(logs_dir / f"{prefix}-candidate-audit.failure.json", failure)
        raise TimingError(f"candidate full audit mismatch: {fixture_name}")
    return {
        "fixture": fixture_name,
        "records": records,
        "audit_match": True,
        "audit_sha256": _digest(actual),
        "phase": phase,
    }


def paired_stream(
    plan: MeasurementPlan,
    fixture_name: str,
    *,
    control: JsonlTimedClient,
    candidate: JsonlTimedClient,
    raw_path: Path,
    pair_offset: int = 0,
    lane_flip: bool = False,
) -> dict[str, object]:
    """Run one fixture's warmup/measure stream in alternating lane order.

    This function is the campaign's only clocked query path. Expected answers
    are used after each response in memory and only result digests/counts are
    written to the chronological raw ledger. A semantic or protocol failure
    also gets a host-only single-operation failure record beside the raw file.
    """

    fixture = make_fixture(fixture_name, plan.records)
    oracle = Oracle(fixture)
    warm = tuple(workload(fixture, max(1, plan.warmup))[: plan.warmup])
    warm = tuple(Operation(item.op, item.key, item.ident, item.limit, item.language, item.predicate, item.category, -(index + 1)) for index, item in enumerate(warm))
    measured = workload(fixture, plan.repetitions)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with raw_path.open("w", encoding="utf-8") as stream:
        for phase, operations in (("warmup", warm), ("measure", measured)):
            for index, operation in enumerate(operations):
                pair_index = pair_offset + count
                order = plan.lane_order(pair_index)
                if lane_flip:
                    order = (order[1], order[0])
                for order_index, label in enumerate(order):
                    client = control if label == "lex4-control" else candidate
                    try:
                        result, reader_ns, outer_ns = client.timed_request(operation)
                        normalized = normalize_result(operation, result, lane=label)
                        expected_value = expected(oracle, operation)
                        if label == "lex4-control" and operation.op == "prefix_enumerate":
                            expected_value = {
                                "op": operation.op,
                                "ids": expected_value["ids"],
                                "cardinality": len(expected_value["ids"]),
                            }
                        if normalized != expected_value:
                            failure = {
                                "fixture": fixture_name,
                                "lane": label,
                                "phase": phase,
                                "pair_index": pair_index,
                                "order_index": order_index,
                                "operation": operation.wire(),
                                "actual": normalized,
                                "expected": expected_value,
                                "request_timing": client.last_request_record,
                                "error": "semantic_mismatch",
                            }
                            _write_json(raw_path.with_suffix(raw_path.suffix + ".failure.json"), failure)
                            raise TimingError(f"{fixture_name}/{label} semantic mismatch at pair {pair_index}")
                    except BaseException as exc:
                        if not isinstance(exc, TimingError) or "semantic mismatch" not in str(exc):
                            failure = {
                                "fixture": fixture_name,
                                "lane": label,
                                "phase": phase,
                                "pair_index": pair_index,
                                "order_index": order_index,
                                "operation": operation.wire(),
                                "error": type(exc).__name__,
                                "message": str(exc),
                                "request_timing": client.last_request_record,
                            }
                            failure_path = raw_path.with_suffix(raw_path.suffix + ".failure.json")
                            if not failure_path.exists():
                                _write_json(failure_path, failure)
                        raise
                    stream.write(json.dumps({
                        "fixture": fixture_name,
                        "lane": label,
                        "phase": phase,
                        "pair_index": pair_index,
                        "order_index": order_index,
                        "index": index,
                        "op": operation.op,
                        "sample": operation.sample,
                        "reader_elapsed_ns": reader_ns,
                        "transport_elapsed_ns": outer_ns,
                        "result_sha256": _digest(normalized),
                        "cardinality": normalized.get("cardinality"),
                    }, ensure_ascii=True, sort_keys=True) + "\n")
                    stream.flush()
                count += 1
    return {
        "fixture": fixture_name,
        "pair_offset": pair_offset,
        "lane_flip": lane_flip,
        "pair_count": count,
        "next_pair_offset": pair_offset + count,
        "observation_count": count * 2,
        "raw_observations": str(raw_path),
    }


def run_paired(
    *,
    authorize_timing: bool = False,
    plan: MeasurementPlan | None = None,
    attempt_dir: Path | None = None,
    native_checkpoint: NativeCheckpoint | None = None,
) -> dict[str, object]:
    """Run one pinned, chronological control/candidate timing attempt.

    The explicit ``authorize_timing`` gate is intentionally the first action.
    Once admitted, this driver never builds or replaces either executable or
    artifact: by default it replays the exact Foundation-13 correctness
    attempt, while an explicitly supplied ``native_checkpoint`` selects a
    separately reviewed immutable candidate.  In either case the paired-
    release LEX4 controls are unchanged.  Every subprocess phase and raw
    query ledger is retained under a new attempt directory, including failed
    attempts.  No native cryptographic-integrity endpoint is used here.
    """

    if not authorize_timing:
        raise MeasurementNotAuthorized("native timing campaign is prepared but not authorized")
    selected_checkpoint = native_checkpoint or FOUNDATION13_CHECKPOINT
    if not isinstance(selected_checkpoint, NativeCheckpoint):
        raise TimingError("native checkpoint must be a NativeCheckpoint")
    selected_plan = plan or build_plan(batch_count=5)
    if (
        selected_plan.records != RECORDS
        or selected_plan.repetitions != REPETITIONS
        or selected_plan.warmup != WARMUP
        or selected_plan.batch_count != 5
        or selected_plan.fixtures != tuple(FIXTURE_NAMES)
    ):
        raise TimingError("timing campaign must use the canonical 2048-record/five-fixture plan")

    if attempt_dir is None:
        run_dir = new_attempt_dir()
    else:
        run_dir = attempt_dir.expanduser()
        if run_dir.exists():
            raise TimingError(f"refusing to overwrite timing attempt directory: {run_dir}")
        run_dir.mkdir(parents=True, exist_ok=False)
    logs_dir = run_dir / "logs"
    raw_dir = run_dir / "raw"
    logs_dir.mkdir(parents=True, exist_ok=False)
    raw_dir.mkdir(parents=True, exist_ok=False)

    attempt_record: dict[str, object] = {
        "schema": "LEX5-PAIRED-MEASUREMENT/1",
        "status": "running",
        "timing_status": "authorized_not_yet_complete",
        "attempt_dir": str(run_dir),
        "authorization": "explicit authorize_timing=True",
        "plan": selected_plan.as_dict(),
        "selection": "all chronological raw observations retained; no best-of-runs selection",
        "native_checkpoint": selected_checkpoint.as_dict(),
        "build_policy": f"not run; pinned {selected_checkpoint.label} and immutable LEX4 artifacts are not rebuilt or overwritten",
        "native_lex5_cryptintegrity": "not_exposed",
    }
    _write_json(run_dir / "attempt.json", attempt_record)

    candidate: dict[str, object] | None = None
    control: dict[str, object] | None = None
    hash_paths: dict[str, Path] | None = None
    tree_roots: dict[str, Path] | None = None
    before_hashes: dict[str, object] | None = None
    after_hashes: dict[str, object] | None = None
    batches: list[dict[str, object]] = []
    pair_offset = 0
    current_phase: dict[str, object] = {"phase": "provenance"}
    live_clients: list[JsonlTimedClient] = []

    def close_clients(clients: list[JsonlTimedClient]) -> list[str]:
        errors: list[str] = []
        for client in reversed(clients):
            try:
                client.close()
            except BaseException as exc:
                errors.append(f"{client.label}:{type(exc).__name__}:{exc}")
        clients.clear()
        return errors

    try:
        candidate = _pinned_candidate(selected_checkpoint)
        control = _pinned_control()
        hash_paths = _campaign_hash_paths(candidate, control)
        tree_roots = _campaign_tree_roots(candidate, control)
        before_hashes = {"files": _hash_snapshot(hash_paths), "trees": _tree_snapshot(tree_roots)}
        _write_json(run_dir / "provenance-before.json", before_hashes)
        attempt_record["candidate"] = {
            "label": candidate["label"],
            "checkpoint_label": candidate["checkpoint_label"],
            "checkpoint": candidate["checkpoint"],
            "correctness_report": str(candidate["report"]),
            "byte_ledger": str(candidate["ledger"]),
            "source_manifest": str(candidate["source_manifest"]),
            "source_manifest_sha256": candidate["source_manifest_sha256"],
            "executable": str(candidate["executable"]),
            "executable_sha256": candidate["executable_sha256"],
            "root_source": str(candidate["root_source"]),
            "native_source_files": [str(path) for path in candidate["native_source_files"]],
            "native_tree_sha256": candidate["native_tree_sha256"],
            "src5_tree_sha256": candidate["src5_tree_sha256"],
            "src5_files": [str(path) for path in candidate["src5_root"]],
        }
        attempt_record["control"] = {
            "label": control["label"],
            "readiness": str(control["readiness"]),
            "executable": str(control["executable"]),
            "executable_sha256": control["executable_sha256"],
            "source": str(control["source"]),
            "source_sha256": control["source_sha256"],
            "harness": str(control["harness"]),
            "harness_sha256": control["harness_sha256"],
        }
        _write_json(
            run_dir / "pins.json",
            {
                "candidate": attempt_record["candidate"],
                "control": attempt_record["control"],
                "host_dependencies": [str(path) for path in HOST_DEPENDENCIES],
            },
        )

        for batch_index in range(selected_plan.batch_count):
            batch_pair_start = pair_offset
            batch_results: list[dict[str, object]] = []
            lane_order = (
                ("lex4-control", "lex5-candidate")
                if batch_index % 2 == 0
                else ("lex5-candidate", "lex4-control")
            )
            for fixture_name in selected_plan.fixtures:
                current_phase = {
                    "phase": "fixture",
                    "batch_index": batch_index,
                    "fixture": fixture_name,
                    "pair_offset": pair_offset,
                    "lane_order": list(lane_order),
                }
                candidate_item = candidate["artifacts"][fixture_name]
                control_item = control["artifacts"][fixture_name]
                if not isinstance(candidate_item, dict) or not isinstance(control_item, dict):
                    raise TimingError(f"missing pinned artifacts for {fixture_name}")
                candidate_artifact = candidate_item["path"]
                control_artifact = control_item["path"]
                if not isinstance(candidate_artifact, Path) or not isinstance(control_artifact, Path):
                    raise TimingError(f"invalid pinned artifact paths for {fixture_name}")

                # The full archive audit is performed before any timed server
                # is opened. Its full JSON is retained in the phase stdout
                # ledger, while the report keeps only the digest/count result.
                current_phase["phase"] = "candidate_audit"
                audit = _candidate_audit(
                    fixture_name,
                    selected_plan.records,
                    candidate_artifact,
                    candidate["executable"],
                    logs_dir,
                    phase_suffix=f"batch-{batch_index:02d}",
                )

                current_phase["phase"] = "standalone_verify"
                verify_records: dict[str, dict[str, object]] = {}
                for label in lane_order:
                    if label == "lex4-control":
                        verify_command = [str(control["executable"]), "--bench4-verify", "--artifact", str(control_artifact)]
                    else:
                        verify_command = [str(candidate["executable"]), "--bench5-verify", "--artifact", str(candidate_artifact)]
                    verify_records[label] = _run_wall_phase(
                        verify_command,
                        phase=f"batch-{batch_index:02d}-{fixture_name}-{label}-verify",
                        logs_dir=logs_dir,
                    )[0]

                # Build is deliberately represented, not executed: this
                # timing attempt is pinned to already-built bytes.
                build_phase = {
                    "status": "not_run_pinned_artifact",
                    "wall_ns": None,
                    "control_artifact": str(control_artifact),
                    "candidate_artifact": str(candidate_artifact),
                }
                control_client = JsonlTimedClient(
                    label="lex4-control",
                    command=[str(control["executable"])],
                    artifact=control_artifact,
                    stderr_path=logs_dir / f"batch-{batch_index:02d}-{fixture_name}-control-server.stderr",
                )
                candidate_client = JsonlTimedClient(
                    label="lex5-candidate",
                    command=[str(candidate["executable"])],
                    artifact=candidate_artifact,
                    stderr_path=logs_dir / f"batch-{batch_index:02d}-{fixture_name}-candidate-server.stderr",
                )
                live_clients.extend((control_client, candidate_client))
                current_phase["phase"] = "server_open"
                ready_records: dict[str, dict[str, object]] = {}
                try:
                    for label in lane_order:
                        client = control_client if label == "lex4-control" else candidate_client
                        ready_records[label] = client.open()
                except BaseException as exc:
                    _write_json(
                        logs_dir / f"batch-{batch_index:02d}-{fixture_name}-server-open.failure.json",
                        {
                            "fixture": fixture_name,
                            "batch_index": batch_index,
                            "phase": "server_open",
                            "error": type(exc).__name__,
                            "message": str(exc),
                            "control": control_client.lifecycle(),
                            "candidate": candidate_client.lifecycle(),
                        },
                    )
                    raise
                current_phase["phase"] = "queries"
                stream = paired_stream(
                    selected_plan,
                    fixture_name,
                    control=control_client,
                    candidate=candidate_client,
                    raw_path=raw_dir / f"batch-{batch_index:02d}-{fixture_name}.jsonl",
                    pair_offset=pair_offset,
                    lane_flip=batch_index % 2 == 1,
                )
                pair_offset = int(stream["next_pair_offset"])
                close_errors = close_clients(live_clients)
                if close_errors:
                    raise TimingError(f"server close failure: {close_errors!r}")
                candidate_ready = ready_records["lex5-candidate"]
                candidate_state = {
                    "artifact_bytes": candidate_ready["artifact_bytes"],
                    "book_bytes": candidate_ready["book_bytes"],
                    "ready_capacities": {
                        "ids": candidate_ready["scratch_ids"],
                        "relations": candidate_ready["scratch_relations"],
                        "bytes": candidate_ready["scratch_bytes"],
                        "key": candidate_ready["scratch_key"],
                        "relation_text": candidate_ready["scratch_relation_text"],
                    },
                    "capacity_units": {
                        "ids": "i64 slots",
                        "relations": "NativeRelation slots",
                        "bytes": "u8 bytes",
                        "key": "u8 bytes",
                        "relation_text": "u8 bytes",
                    },
                }
                batch_results.append(
                    {
                        "batch_index": batch_index,
                        "fixture": fixture_name,
                        "lane_order": list(lane_order),
                        "artifacts": {
                            "control": {
                                "path": str(control_artifact),
                                "bytes": control_item["bytes"],
                                "sha256": control_item["sha256"],
                            },
                            "candidate": {
                                "path": str(candidate_artifact),
                                "bytes": candidate_item["bytes"],
                                "sha256": candidate_item["sha256"],
                            },
                        },
                        "build": build_phase,
                        "audit": audit,
                        "verify": verify_records,
                        "open": {
                            "control": control_client.lifecycle(),
                            "candidate": {
                                **candidate_client.lifecycle(),
                                "native_state": candidate_state,
                            },
                        },
                        "ready": ready_records,
                        "stream": stream,
                    }
                )
            batches.append(
                {
                    "batch_index": batch_index,
                    "lane_order": list(lane_order),
                    "pair_offset_start": batch_pair_start,
                    "pair_offset_end": pair_offset,
                    "fixtures": batch_results,
                }
            )

        current_phase = {"phase": "provenance_after"}
        if hash_paths is None or tree_roots is None or before_hashes is None:
            raise TimingError("campaign provenance was not initialized")
        after_hashes = {"files": _hash_snapshot(hash_paths), "trees": _tree_snapshot(tree_roots)}
        _assert_hash_snapshot(before_hashes, after_hashes)
        _write_json(run_dir / "provenance-after.json", after_hashes)
        result: dict[str, object] = {
            **attempt_record,
            "status": "passed_root_review_pending",
            "timing_status": "raw_observations_complete",
            "pair_count": pair_offset,
            "observation_count": pair_offset * 2,
            "batches": batches,
            "provenance_before": str(run_dir / "provenance-before.json"),
            "provenance_after": str(run_dir / "provenance-after.json"),
            "raw_root": str(raw_dir),
        }
        _write_json(run_dir / "result.json", result)
        return result
    except BaseException as exc:
        close_errors = close_clients(live_clients)
        if hash_paths is not None and tree_roots is not None:
            try:
                after_hashes = {"files": _hash_snapshot(hash_paths), "trees": _tree_snapshot(tree_roots)}
                if not (run_dir / "provenance-after.json").exists():
                    _write_json(run_dir / "provenance-after.json", after_hashes)
            except BaseException as hash_exc:
                close_errors.append(f"after_hash:{type(hash_exc).__name__}:{hash_exc}")
        failure = {
            **attempt_record,
            "status": "failed",
            "timing_status": "failed_with_raw_failure_record",
            "current_phase": current_phase,
            "completed_batches": batches,
            "pair_offset": pair_offset,
            "error": {"type": type(exc).__name__, "message": str(exc)},
            "traceback": traceback.format_exc(),
            "close_errors": close_errors,
            "provenance_before": str(run_dir / "provenance-before.json") if before_hashes is not None else None,
            "provenance_after": str(run_dir / "provenance-after.json") if after_hashes is not None else None,
            "raw_root": str(raw_dir),
        }
        if not (run_dir / "failure.json").exists():
            _write_json(run_dir / "failure.json", failure)
        if not (run_dir / "result.json").exists():
            _write_json(run_dir / "result.json", failure)
        raise


__all__ = [
    "CONTROL_EXECUTABLE",
    "CONTROL_HARNESS",
    "CONTROL_READINESS",
    "CONTROL_PROTOCOL",
    "CONTROL_SHA256",
    "CONTROL_SOURCE",
    "FOUNDATION13_CHECKPOINT",
    "FOUNDATION13_LEDGER",
    "FOUNDATION13_REPORT",
    "FOUNDATION13_SOURCE_MANIFEST",
    "FOUNDATION15_CHECKPOINT",
    "FOUNDATION15_LEDGER",
    "FOUNDATION15_REPORT",
    "FOUNDATION15_SOURCE_MANIFEST",
    "FOUNDATION16_CHECKPOINT",
    "FOUNDATION16_LEDGER",
    "FOUNDATION16_REPORT",
    "FOUNDATION16_SOURCE_MANIFEST",
    "HashGuard",
    "JsonlTimedClient",
    "MeasurementNotAuthorized",
    "MeasurementPlan",
    "NativeCheckpoint",
    "TimingError",
    "build_plan",
    "control_provenance",
    "new_attempt_dir",
    "normalize_result",
    "paired_stream",
    "run_paired",
    "timed_request",
    "validate_timed_response",
]
