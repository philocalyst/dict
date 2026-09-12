"""Artifact-only native LEX5 bridge and bounded correctness driver.

This module is a host orchestrator, not a second reader. The native executable
builds from canonical fixture input, but verify, audit, and server modes receive
only a unique frozen-attempt artifact. Expected answers stay in the imported
bench4 oracle and are compared in memory; no query schedule, answer table, or
native response stream is persisted.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable

REPO_ROOT = Path(__file__).resolve().parents[1]
BENCHMARK_ROOT = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "benchmark"
NATIVE_ROOT = BENCHMARK_ROOT / "native"
# This is a documentation/template path only. Correctness runs never overwrite it.
NATIVE_BIN = NATIVE_ROOT / "bin" / "lex5-native-release"
NATIVE_SOURCE = REPO_ROOT / "bench5" / "native_main.zig"
FROZEN_SRC5_ROOT = (
    REPO_ROOT
    / "experiments"
    / "frontier"
    / "lex5-20260909"
    / "reviews"
    / "foundation-11"
    / "source"
    / "src5"
    / "root.zig"
)

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench4.oracle import FIXTURE_NAMES, Oracle, expected, make_fixture, workload, write_fixture_json
from bench5.contracts import (
    PROTOCOL,
    RECORDS,
    REPETITIONS,
    has_releasefast_before_each_module,
    releasefast_module_command,
)


class NativeError(RuntimeError):
    """Raised when the native boundary fails or disagrees with the oracle."""


@dataclass(frozen=True)
class FrozenSources:
    attempt_dir: Path
    native_source: Path
    src5_root: Path
    provenance: dict[str, object]


@dataclass(frozen=True)
class ArtifactRecord:
    fixture: str
    path: Path
    bytes: int
    sha256: str
    semantic_sha256: str

    def as_dict(self) -> dict[str, object]:
        return {
            "fixture": self.fixture,
            "path": _repo_or_absolute(self.path),
            "bytes": self.bytes,
            "sha256": self.sha256,
            "semantic_sha256": self.semantic_sha256,
        }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest(root: Path) -> dict[str, object]:
    original = root.expanduser()
    if original.is_symlink():
        raise NativeError(f"source input is a symlink: {original}")
    for parent in original.parents:
        if parent.is_symlink():
            raise NativeError(f"source input has a symlink parent: {parent}")
    root = original.resolve(strict=True)
    if root.is_file():
        paths = [root]
        base = root.parent
    elif root.is_dir():
        all_items = sorted(root.rglob("*"))
        for item in all_items:
            if item.is_symlink():
                raise NativeError(f"source tree contains symlink: {item}")
        paths = [item for item in all_items if item.is_file()]
        base = root
    else:
        raise NativeError(f"source input is not a file/directory: {root}")
    files: list[dict[str, object]] = []
    tree = hashlib.sha256()
    total = 0
    for path in paths:
        if path.is_symlink():
            raise NativeError(f"source tree contains symlink: {path}")
        relative = path.relative_to(base).as_posix()
        size = path.stat().st_size
        digest = _sha256(path)
        total += size
        files.append({"path": relative, "bytes": size, "sha256": digest})
        tree.update(f"{relative}\0{size}\0{digest}\n".encode())
    return {
        "root": str(root),
        "file_count": len(files),
        "bytes": total,
        "tree_sha256": tree.hexdigest(),
        "files": files,
    }


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _repo_or_absolute(path: Path) -> str:
    path = path.resolve(strict=False)
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _attempt_dir() -> Path:
    NATIVE_ROOT.mkdir(parents=True, exist_ok=True)
    name = f"attempt-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}-{secrets.token_hex(4)}"
    path = NATIVE_ROOT / "attempts" / name
    path.mkdir(parents=True, exist_ok=False)
    return path


def _freeze_sources(source: Path, src5_root: Path, attempt_dir: Path) -> FrozenSources:
    # Validate the caller-supplied paths before canonicalizing them.  A
    # symlink must not become invisible merely because resolve() was called
    # before the manifest walk.
    source_input = Path(source).expanduser()
    src5_input = Path(src5_root).expanduser()
    before = {"native": _manifest(source_input), "src5": _manifest(src5_input.parent)}
    source = source_input.resolve(strict=True)
    src5_root = src5_input.resolve(strict=True)
    original_src5 = src5_root.parent

    frozen_root = attempt_dir / "source"
    frozen_native = frozen_root / "bench5" / "native_main.zig"
    frozen_src5 = frozen_root / "src5"
    frozen_native.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, frozen_native)
    shutil.copytree(original_src5, frozen_src5, symlinks=False)
    after = {"native": _manifest(frozen_native), "src5": _manifest(frozen_src5)}

    # Compare canonical file rows rather than absolute root names.
    same_native = before["native"]["tree_sha256"] == after["native"]["tree_sha256"]
    same_src5 = before["src5"]["tree_sha256"] == after["src5"]["tree_sha256"]
    provenance = {
        "original": before,
        "frozen": after,
        "same_hashes": bool(same_native and same_src5),
        "absolute_compile_inputs": {
            "root_source": str(frozen_native.resolve()),
            "library_source": str(frozen_src5.joinpath("root.zig").resolve()),
        },
    }
    _write_json(attempt_dir / "source-provenance.json", provenance)
    if not provenance["same_hashes"]:
        raise NativeError("frozen source hashes differ from originals")
    return FrozenSources(attempt_dir, frozen_native, frozen_src5 / "root.zig", provenance)


def _json_line(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _native_result(operation: Any, result: dict[str, Any]) -> dict[str, Any]:
    """Normalize the compact native result to the host oracle shape."""

    op = operation.op
    if op == "exact":
        return {"op": op, "ids": result["ids"], "cardinality": result["cardinality"]}
    if op == "prefix_interval":
        return {"op": op, "lo": result["lo"], "hi": result["hi"], "cardinality": result["cardinality"]}
    if op == "prefix_enumerate":
        return {
            "op": op,
            "ids": result["ids"],
            "lo": result["lo"],
            "hi": result["hi"],
            "cardinality": result["cardinality"],
        }
    if op == "select":
        return {"op": op, "id": result["id"], "key": result["key"], "rank": result["rank"]}
    if op in ("render", "snippet"):
        normalized = {"op": op, "id": operation.ident, "bytes_hex": result["bytes_hex"], "bytes": result["bytes"]}
        if op == "snippet":
            normalized["limit"] = operation.limit
        return normalized
    if op == "concept_members":
        return {"op": op, "id": operation.ident, "members": result["members"], "cardinality": result["cardinality"]}
    if op == "translations":
        return {
            "op": op,
            "id": operation.ident,
            "language": operation.language,
            "members": result["members"],
            "cardinality": result["cardinality"],
        }
    if op == "relations":
        return {"op": op, "id": operation.ident, "relations": result["relations"], "cardinality": result["cardinality"]}
    raise NativeError("unsupported host operation")


def _integrity_summary(snapshot: dict[str, object]) -> dict[str, object]:
    """Keep report metadata compact while full manifests stay in log files."""

    native = snapshot.get("native")
    src5 = snapshot.get("src5")
    binary = snapshot.get("binary")
    summary: dict[str, object] = {
        "stage": snapshot.get("stage"),
        "ok": snapshot.get("ok"),
        "native_tree_sha256": native.get("tree_sha256") if isinstance(native, dict) else None,
        "src5_tree_sha256": src5.get("tree_sha256") if isinstance(src5, dict) else None,
    }
    if isinstance(binary, dict):
        summary["binary_sha256"] = binary.get("sha256")
        summary["binary_bytes"] = binary.get("bytes")
    if "error" in snapshot:
        summary["error"] = snapshot["error"]
    return summary


class NativeBridge:
    """Build and exercise the real src5 Book through one frozen attempt."""

    def __init__(
        self,
        executable: Path,
        *,
        source: Path,
        src5_root: Path,
        attempt_dir: Path,
        source_provenance: dict[str, object] | None = None,
    ):
        self.executable = executable.resolve(strict=False)
        self.source = source.resolve(strict=True)
        self.src5_root = src5_root.resolve(strict=True)
        self.attempt_dir = attempt_dir.resolve(strict=True)
        self.log_dir = self.attempt_dir / "logs"
        self.cache_root = self.attempt_dir / "cache"
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.executable.parent.mkdir(parents=True, exist_ok=True)
        self.expected_native_tree_sha256: str | None = None
        self.expected_src5_tree_sha256: str | None = None
        self.expected_binary_sha256: str | None = None
        frozen = source_provenance.get("frozen") if isinstance(source_provenance, dict) else None
        if isinstance(frozen, dict):
            native = frozen.get("native")
            src5 = frozen.get("src5")
            if isinstance(native, dict) and isinstance(native.get("tree_sha256"), str):
                self.expected_native_tree_sha256 = native["tree_sha256"]
            if isinstance(src5, dict) and isinstance(src5.get("tree_sha256"), str):
                self.expected_src5_tree_sha256 = src5["tree_sha256"]

    def check_integrity(self, stage: str, require_binary: bool) -> dict[str, object]:
        """Re-manifest frozen inputs and executable at a campaign boundary."""

        snapshot: dict[str, object] = {
            "stage": stage,
            "expected_native_tree_sha256": self.expected_native_tree_sha256,
            "expected_src5_tree_sha256": self.expected_src5_tree_sha256,
            "expected_binary_sha256": self.expected_binary_sha256,
            "require_binary": require_binary,
        }
        try:
            native = _manifest(self.source)
            src5 = _manifest(self.src5_root.parent)
            snapshot["native"] = native
            snapshot["src5"] = src5
            source_ok = self.expected_native_tree_sha256 is None or native["tree_sha256"] == self.expected_native_tree_sha256
            src5_ok = self.expected_src5_tree_sha256 is None or src5["tree_sha256"] == self.expected_src5_tree_sha256
            snapshot["source_match"] = bool(source_ok and src5_ok)

            include_binary = require_binary or self.executable.exists()
            binary_ok = True
            if include_binary:
                binary = _manifest(self.executable)
                files = binary.get("files")
                if not isinstance(files, list) or len(files) != 1 or not isinstance(files[0], dict):
                    raise NativeError("binary manifest is not a single regular file")
                binary_sha256 = files[0].get("sha256")
                binary_bytes = files[0].get("bytes")
                snapshot["binary"] = {"bytes": binary_bytes, "sha256": binary_sha256}
                binary_ok = self.expected_binary_sha256 is None or binary_sha256 == self.expected_binary_sha256
            snapshot["ok"] = bool(source_ok and src5_ok and binary_ok)
        except Exception as exc:
            snapshot["ok"] = False
            snapshot["error"] = type(exc).__name__
            _write_json(self.log_dir / f"integrity-{stage}.json", snapshot)
            raise NativeError(f"integrity check failed at {stage}") from exc

        _write_json(self.log_dir / f"integrity-{stage}.json", snapshot)
        if not snapshot["ok"]:
            raise NativeError(f"integrity check failed at {stage}")
        return snapshot

    def build_command(self) -> list[str]:
        command = releasefast_module_command(
            root_source=self.source,
            library_source=self.src5_root,
            output=self.executable,
        )
        command[2:2] = [
            "--cache-dir",
            str((self.cache_root / "local").resolve()),
            "--global-cache-dir",
            str((self.cache_root / "global").resolve()),
        ]
        if not has_releasefast_before_each_module(command):
            raise NativeError("native build command lost per-module ReleaseFast flags")
        return command

    def _record_phase(
        self,
        phase: str,
        command: list[str],
        *,
        returncode: int | None,
        stdout: str = "",
        stderr: str = "",
        error: str | None = None,
        extra: dict[str, object] | None = None,
    ) -> None:
        safe = "".join(char if char.isalnum() or char in "-_." else "_" for char in phase)
        stderr_path = self.log_dir / f"{safe}.stderr"
        stderr_path.write_text(stderr, encoding="utf-8")
        metadata: dict[str, object] = {
            "phase": phase,
            "command": command,
            "returncode": returncode,
            "stdout_bytes": len(stdout.encode("utf-8")),
            "stderr_path": _repo_or_absolute(stderr_path),
            "stderr_bytes": len(stderr.encode("utf-8")),
        }
        if error is not None:
            metadata["error"] = error
        if extra:
            metadata.update(extra)
        _write_json(self.log_dir / f"{safe}.json", metadata)

    def _write_host_failure(
        self,
        *,
        phase: str,
        fixture: str,
        request_id: int | None = None,
        sample: int | None = None,
        operation: Any | None = None,
        actual: object | None = None,
        expected_value: object | None = None,
    ) -> None:
        """Persist one host-only mismatch; never send it to the native child."""

        path = self.attempt_dir / "host-failure.json"
        if path.exists():
            return
        payload: dict[str, object] = {
            "schema": "LEX5-NATIVE-HOST-FAILURE/1",
            "phase": phase,
            "fixture": fixture,
        }
        if request_id is not None:
            payload["request_id"] = request_id
            payload["operation_index"] = request_id
        if sample is not None:
            payload["sample"] = sample
        if operation is not None:
            payload["operation"] = operation.wire() if hasattr(operation, "wire") else str(operation)
        if actual is not None:
            payload["actual"] = actual
        if expected_value is not None:
            payload["expected"] = expected_value
        _write_json(path, payload)

    def compile(self) -> dict[str, object]:
        command = self.build_command()
        try:
            process = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, check=False)
        except OSError as exc:
            self._record_phase("compile", command, returncode=None, error=type(exc).__name__)
            raise NativeError("native compile could not start") from exc
        self._record_phase("compile", command, returncode=process.returncode, stdout=process.stdout, stderr=process.stderr)
        if process.returncode != 0:
            raise NativeError("native compile failed")
        if not self.executable.is_file() or self.executable.stat().st_size == 0:
            self._record_phase(
                "compile-postcondition",
                command,
                returncode=process.returncode,
                error="empty_or_missing_executable",
            )
            raise NativeError("native executable is missing or empty")
        self.expected_binary_sha256 = _sha256(self.executable)
        integrity = self.check_integrity("after_compile", require_binary=True)
        return {
            "command": command,
            "root_source": _repo_or_absolute(self.source),
            "root_sha256": _sha256(self.source),
            "src5_root": _repo_or_absolute(self.src5_root),
            "src5_tree_sha256": _manifest(self.src5_root.parent)["tree_sha256"],
            "executable": _repo_or_absolute(self.executable),
            "executable_bytes": self.executable.stat().st_size,
            "executable_sha256": self.expected_binary_sha256,
            "integrity_after_compile": _integrity_summary(integrity),
        }

    def _run(self, args: list[str], *, phase: str) -> subprocess.CompletedProcess[str]:
        command = [str(self.executable), *args]
        try:
            process = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, check=False)
        except OSError as exc:
            self._record_phase(phase, command, returncode=None, error=type(exc).__name__)
            raise NativeError(f"{phase} could not start") from exc
        self._record_phase(phase, command, returncode=process.returncode, stdout=process.stdout, stderr=process.stderr)
        if process.returncode != 0:
            raise NativeError(f"{phase} failed")
        return process

    def build_artifact(self, fixture: Any, path: Path) -> ArtifactRecord:
        path = path.resolve(strict=False)
        if path.exists():
            raise NativeError("attempt artifact already exists")
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="lex5-input-") as directory:
            semantic_path = Path(directory) / "fixture.json"
            write_fixture_json(fixture, semantic_path)
            self._run(
                ["--bench5-build", "--semantic-input", str(semantic_path), "--output", str(path)],
                phase=f"{fixture.name}-build",
            )
        if not path.is_file() or path.stat().st_size == 0:
            self._record_phase(
                f"{fixture.name}-build-postcondition",
                ["--bench5-build"],
                returncode=0,
                error="empty_or_missing_artifact",
            )
            raise NativeError("native artifact is missing or empty")
        return ArtifactRecord(fixture.name, path, path.stat().st_size, _sha256(path), fixture.semantic_digest())

    def verify(self, artifact: ArtifactRecord) -> None:
        self._run(
            ["--bench5-verify", "--artifact", str(artifact.path)],
            phase=f"{artifact.fixture}-verify",
        )

    def audit(self, artifact: ArtifactRecord) -> dict[str, Any]:
        process = self._run(
            ["--bench5-audit", "--artifact", str(artifact.path)],
            phase=f"{artifact.fixture}-audit",
        )
        try:
            value = json.loads(process.stdout)
        except json.JSONDecodeError as exc:
            self._record_phase(
                f"{artifact.fixture}-audit-postcondition",
                ["--bench5-audit", "--artifact", str(artifact.path)],
                returncode=process.returncode,
                error="audit_not_json",
            )
            raise NativeError("native audit was not JSON") from exc
        if not isinstance(value, dict):
            raise NativeError("native audit root is not an object")
        return value

    def query(self, artifact: ArtifactRecord, operations: Iterable[Any], oracle: Oracle) -> int:
        command = [str(self.executable), "--bench5-server", "--artifact", str(artifact.path)]
        stderr_path = self.log_dir / f"{artifact.fixture}-server.stderr"
        stderr_stream = stderr_path.open("w", encoding="utf-8")
        process: subprocess.Popen[str] | None = None
        count = 0
        ready = False
        ready_value: dict[str, Any] | None = None
        failure: str | None = None
        returncode: int | None = None
        try:
            process = subprocess.Popen(
                command,
                cwd=REPO_ROOT,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr_stream,
                text=True,
                bufsize=1,
            )
            if process.stdin is None or process.stdout is None:
                raise NativeError("native server pipes unavailable")
            ready_line = process.stdout.readline()
            try:
                ready_value = json.loads(ready_line)
            except json.JSONDecodeError as exc:
                raise NativeError("native server did not emit ready JSON") from exc
            ready_shape = {"artifact_bytes": artifact.bytes, "event": "ready", "protocol": PROTOCOL}
            if not isinstance(ready_value, dict) or any(ready_value.get(key) != value for key, value in ready_shape.items()):
                raise NativeError("unexpected native ready event")
            for field in ("book_bytes", "scratch_ids", "scratch_relations", "scratch_bytes", "scratch_key", "scratch_relation_text"):
                if type(ready_value.get(field)) is not int or ready_value[field] <= 0:
                    raise NativeError(f"native ready event has invalid {field}")
            ready = True
            for request_id, operation in enumerate(operations):
                wire = dict(operation.wire())
                wire.pop("category", None)
                wire.update({"protocol": PROTOCOL, "request_id": request_id})
                process.stdin.write(_json_line(wire) + "\n")
                process.stdin.flush()
                line = process.stdout.readline()
                if not line:
                    raise NativeError("native server exited before response")
                response = json.loads(line)
                if response.get("protocol") != PROTOCOL or response.get("request_id") != request_id or response.get("sample") != operation.sample:
                    raise NativeError("native response envelope mismatch")
                if not response.get("ok"):
                    raise NativeError("native query error")
                actual = _native_result(operation, response["result"])
                expected_value = expected(oracle, operation)
                if actual != expected_value:
                    self._write_host_failure(
                        phase="query",
                        fixture=artifact.fixture,
                        request_id=request_id,
                        sample=operation.sample,
                        operation=operation,
                        actual=actual,
                        expected_value=expected_value,
                    )
                    raise NativeError(f"oracle mismatch at request {request_id} ({operation.op})")
                count += 1
        except BaseException as exc:
            failure = type(exc).__name__
            if isinstance(exc, NativeError):
                raise
            raise NativeError("native server phase failed") from exc
        finally:
            if process is not None:
                try:
                    if process.stdin is not None:
                        process.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
                if process.poll() is None and failure is not None:
                    process.kill()
                try:
                    returncode = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    returncode = process.wait()
                if process.stdout is not None:
                    process.stdout.close()
            stderr_stream.close()
            self._record_phase(
                f"{artifact.fixture}-server",
                command,
                returncode=returncode,
                stderr=stderr_path.read_text(encoding="utf-8"),
                error=failure,
                extra={"ready": ready, "ready_event": ready_value, "query_count": count},
            )
        if returncode != 0:
            raise NativeError("native server exited nonzero")
        return count


def _audit_projection(fixture: Any) -> dict[str, object]:
    return {
        "entries": [entry.canonical() for entry in fixture.entries],
        "senses": [sense.canonical() for sense in fixture.senses],
        "concepts": [concept.canonical() for concept in fixture.concepts],
        "relations": [relation.canonical() for relation in fixture.relations],
    }


def run_correctness(
    bridge: NativeBridge | None = None,
    *,
    records: int = RECORDS,
    repetitions: int = REPETITIONS,
    fixtures: Iterable[str] = FIXTURE_NAMES,
    artifact_root: Path | None = None,
) -> dict[str, object]:
    """Run one unique, source-frozen correctness attempt.

    The returned document contains provenance, complete artifact ledgers, and
    pass counts only. It does not retain operations or expected responses.
    Failed attempts persist source manifests and every phase ledger before this
    function raises.
    """

    attempt_dir = _attempt_dir()
    template_source = bridge.source if bridge is not None else NATIVE_SOURCE
    template_src5 = bridge.src5_root if bridge is not None else FROZEN_SRC5_ROOT
    selected_artifacts = (
        artifact_root.resolve(strict=False)
        if artifact_root is not None
        else attempt_dir / "artifacts"
    )
    running: dict[str, object] = {
        "schema": "LEX5-NATIVE-CORRECTNESS/1",
        "status": "running",
        "attempt_dir": _repo_or_absolute(attempt_dir),
        "template_source": _repo_or_absolute(template_source),
        "template_src5_root": _repo_or_absolute(template_src5),
        "artifact_root": _repo_or_absolute(selected_artifacts),
        "timing_status": "not_run",
    }
    _write_json(attempt_dir / "attempt.json", running)

    frozen: FrozenSources | None = None
    native: NativeBridge | None = None
    completed: list[str] = []
    try:
        frozen = _freeze_sources(template_source, template_src5, attempt_dir)
        running["source_provenance"] = frozen.provenance
        _write_json(attempt_dir / "attempt.json", running)

        executable = attempt_dir / "bin" / "lex5-native-release"
        native = NativeBridge(
            executable,
            source=frozen.native_source,
            src5_root=frozen.src5_root,
            attempt_dir=attempt_dir,
            source_provenance=frozen.provenance,
        )
        if selected_artifacts.exists():
            raise NativeError("artifact root already exists; refusing overwrite")
        selected_artifacts.mkdir(parents=True, exist_ok=False)

        compilation = native.compile()
        rows: list[dict[str, object]] = []
        for name in fixtures:
            fixture = make_fixture(name, records)
            oracle = Oracle(fixture)
            path = selected_artifacts / name / "dictionary.lex5"
            artifact = native.build_artifact(fixture, path)
            native.verify(artifact)
            audit = native.audit(artifact)
            expected_audit = _audit_projection(fixture)
            if audit != expected_audit:
                native._write_host_failure(
                    phase="audit",
                    fixture=name,
                    actual=audit,
                    expected_value=expected_audit,
                )
                raise NativeError(f"archive audit mismatch for {name}")
            query_count = native.query(artifact, workload(fixture, repetitions), oracle)
            rows.append(
                {
                    **artifact.as_dict(),
                    "entries": len(fixture.entries),
                    "senses": len(fixture.senses),
                    "concepts": len(fixture.concepts),
                    "relations": len(fixture.relations),
                    "query_count": query_count,
                    "audit_fields": ["entries", "senses", "concepts", "relations"],
                    "audit_match": True,
                    "query_match": True,
                }
            )
            completed.append(name)

        campaign_integrity = native.check_integrity("after_campaign", require_binary=True)
        result: dict[str, object] = {
            "schema": "LEX5-NATIVE-CORRECTNESS/1",
            "status": "passed_root_review_pending",
            "attempt_dir": _repo_or_absolute(attempt_dir),
            "artifact_root": _repo_or_absolute(selected_artifacts),
            "labels": {"candidate": "LEX5", "control": "immutable accepted LEX4"},
            "records": records,
            "repetitions": repetitions,
            "fixtures": rows,
            "native": compilation,
            "integrity_after_campaign": _integrity_summary(campaign_integrity),
            "source_provenance": frozen.provenance,
            "answer_policy": "bench4.oracle expected(...) remained host-only; no schedule/answer table or native response stream was retained",
            "timing_status": "not_run",
        }
        _write_json(attempt_dir / "attempt.json", result)
        return result
    except BaseException as exc:
        failure: dict[str, object] = {
            "schema": "LEX5-NATIVE-CORRECTNESS/1",
            "status": "failed_root_review_pending",
            "attempt_dir": _repo_or_absolute(attempt_dir),
            "artifact_root": _repo_or_absolute(selected_artifacts),
            "completed_fixtures": completed,
            "error": type(exc).__name__,
            "timing_status": "not_run",
        }
        if frozen is not None:
            failure["source_provenance"] = frozen.provenance
        if native is not None:
            try:
                failure["integrity_failure_recheck"] = _integrity_summary(
                    native.check_integrity("failure", require_binary=native.expected_binary_sha256 is not None)
                )
            except BaseException as integrity_exc:
                failure["integrity_failure_recheck_error"] = type(integrity_exc).__name__
        _write_json(attempt_dir / "attempt.json", failure)
        raise

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=int, default=RECORDS)
    parser.add_argument("--repetitions", type=int, default=REPETITIONS)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    try:
        value = run_correctness(records=args.records, repetitions=args.repetitions)
        output = args.output.resolve(strict=False) if args.output is not None else Path(value["attempt_dir"]) / "correctness.json"
        if output.exists():
            raise NativeError("refusing to overwrite existing correctness report")
        _write_json(output, value)
        print(output)
        return 0
    except Exception as exc:
        print(f"LEX5 correctness attempt failed: {type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "ArtifactRecord",
    "FROZEN_SRC5_ROOT",
    "FrozenSources",
    "NativeBridge",
    "NativeError",
    "NATIVE_BIN",
    "run_correctness",
]
