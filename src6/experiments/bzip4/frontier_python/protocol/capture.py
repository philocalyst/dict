"""Lossless subprocess capture helpers used by protocol measurements.

The order is intentional: bytes and process status are written to disk before
any parser is called.  A malformed or partial stdout can therefore never
silently replace the raw evidence.  The helper does not retry, reorder, or
discard a scheduled process.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
from typing import Any, Sequence


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class CapturedProcess:
    argv: tuple[str, ...]
    cwd: str
    returncode: int | None
    stdout: bytes
    stderr: bytes
    elapsed_ns: int
    timed_out: bool = False
    error: str | None = None

    @property
    def status(self) -> str:
        if self.timed_out:
            return "timeout"
        if self.returncode is None:
            return "spawn-error"
        return "ok" if self.returncode == 0 else "failed"

    def record(self) -> dict[str, Any]:
        return {
            "argv": list(self.argv),
            "cwd": self.cwd,
            "returncode": self.returncode,
            "elapsed_ns": self.elapsed_ns,
            "timed_out": self.timed_out,
            "error": self.error,
            "status": self.status,
            "stdout": {"bytes": len(self.stdout), "sha256": sha256_bytes(self.stdout)},
            "stderr": {"bytes": len(self.stderr), "sha256": sha256_bytes(self.stderr)},
        }


def run_captured(
    argv: Sequence[str | Path],
    *,
    cwd: str | Path,
    timeout: float | None = 600.0,
    env: dict[str, str] | None = None,
) -> CapturedProcess:
    """Run one deterministic serial child with stdout/stderr as raw bytes."""

    command = tuple(str(part) for part in argv)
    started = time.perf_counter_ns()
    try:
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
            timeout=timeout,
            env=env,
        )
        return CapturedProcess(command, str(cwd), completed.returncode, completed.stdout, completed.stderr, time.perf_counter_ns() - started)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, bytes) else (exc.stdout or "").encode("utf-8", "replace")
        stderr = exc.stderr if isinstance(exc.stderr, bytes) else (exc.stderr or "").encode("utf-8", "replace")
        return CapturedProcess(command, str(cwd), None, stdout, stderr, time.perf_counter_ns() - started, True, f"TimeoutExpired({timeout}s)")
    except OSError as exc:
        return CapturedProcess(command, str(cwd), None, b"", str(exc).encode("utf-8", "replace"), time.perf_counter_ns() - started, False, f"{type(exc).__name__}: {exc}")


def save_raw_capture(capture: CapturedProcess, root: str | Path, stem: str) -> dict[str, Any]:
    """Persist stdout, stderr, and status before returning a parse record."""

    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    stdout_path = root / f"{stem}.stdout.bin"
    stderr_path = root / f"{stem}.stderr.bin"
    status_path = root / f"{stem}.status.json"
    existing = [path for path in (stdout_path, stderr_path, status_path) if path.exists()]
    if existing:
        raise FileExistsError("refusing to overwrite existing raw capture: " + ", ".join(map(str, existing)))
    stdout_path.write_bytes(capture.stdout)
    stderr_path.write_bytes(capture.stderr)
    status = capture.record()
    status.update(
        {
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "status_path": str(status_path),
        }
    )
    # The status file is deliberately written only after both raw streams.
    status_path.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return status


def run_and_save(
    argv: Sequence[str | Path],
    *,
    cwd: str | Path,
    raw_root: str | Path,
    stem: str,
    timeout: float | None = 600.0,
    env: dict[str, str] | None = None,
) -> CapturedProcess:
    root = Path(raw_root)
    if any((root / f"{stem}.{suffix}").exists() for suffix in ("stdout.bin", "stderr.bin", "status.json")):
        raise FileExistsError(f"refusing to overwrite existing raw capture stem {stem!r} under {root}")
    capture = run_captured(argv, cwd=cwd, timeout=timeout, env=env)
    save_raw_capture(capture, root, stem)
    return capture


def serial_runs(commands: Sequence[Sequence[str | Path]], *, cwd: str | Path, raw_root: str | Path, stem_prefix: str, timeout: float | None = 600.0, env: dict[str, str] | None = None) -> list[CapturedProcess]:
    """Execute a fixed command list in order without retries or concurrency."""

    return [
        run_and_save(command, cwd=cwd, raw_root=raw_root, stem=f"{stem_prefix}-{index:02d}", timeout=timeout, env=env)
        for index, command in enumerate(commands, 1)
    ]


def snapshot_sources(
    paths: Sequence[str | Path],
    destination: str | Path,
    *,
    destination_names: Sequence[str] | None = None,
) -> dict[str, Any]:
    """Copy an explicit source list once and record before/after hashes.

    ``destination`` must not exist.  The helper is intended for the final
    candidate evidence checkpoint: an accepted revision is reconstructible
    even if the live untracked worker changes while a serial matrix runs.

    ``destination_names`` is an optional parallel list of flat, unique names
    for the copies.  It is used when several package trees contain a common
    basename such as ``__init__.py``; the manifest always retains each live
    source path, so the rename is unambiguous and does not hide provenance.
    """

    destination = Path(destination)
    if destination.exists():
        raise FileExistsError(f"refusing to overwrite source snapshot {destination}")
    source_paths = [Path(path).resolve() for path in paths]
    if len({str(path) for path in source_paths}) != len(source_paths):
        raise ValueError("source snapshot contains duplicate paths")
    if destination_names is None:
        names = [path.name for path in source_paths]
    else:
        names = [str(name) for name in destination_names]
        if len(names) != len(source_paths):
            raise ValueError("destination_names must match source paths")
        if any(not name or Path(name).name != name for name in names):
            raise ValueError("destination names must be non-empty flat filenames")
    if len(set(names)) != len(names):
        raise ValueError("source snapshot destination names must be unique")
    destination.mkdir(parents=True, exist_ok=False)
    records: list[dict[str, Any]] = []
    used_names: set[str] = set()
    try:
        for source, name in zip(source_paths, names):
            if not source.is_file():
                raise FileNotFoundError(source)
            if name in used_names:
                raise ValueError(f"snapshot destination collision: {name}")
            used_names.add(name)
            target = destination / name
            before = _file_sha256(source)
            shutil.copyfile(source, target)
            after = _file_sha256(target)
            if before != after:
                raise OSError(f"source changed while snapshotting: {source}")
            target.chmod(0o444)
            records.append({"source": str(source), "snapshot": str(target), "bytes": target.stat().st_size, "sha256": after})
        manifest = {"schema": 1, "sources": records}
        manifest_path = destination / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        manifest_path.chmod(0o444)
        destination.chmod(0o555)
        return manifest
    except Exception:
        # Preserve a partial snapshot for forensic inspection, but do not
        # silently present it as complete: callers receive the original error.
        raise


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_snapshot_sources(manifest: str | Path | dict[str, Any]) -> dict[str, Any]:
    """Check both live sources and read-only copies against a snapshot manifest."""

    if isinstance(manifest, (str, Path)):
        manifest_path = Path(manifest)
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    else:
        manifest_path = None
        payload = manifest
    mismatches: list[dict[str, str]] = []
    for record in payload.get("sources", []):
        expected = str(record.get("sha256", ""))
        source = Path(str(record.get("source", "")))
        snapshot = Path(str(record.get("snapshot", "")))
        for label, path in (("source", source), ("snapshot", snapshot)):
            if not path.is_file():
                mismatches.append({"kind": f"missing-{label}", "path": str(path)})
                continue
            actual = _file_sha256(path)
            if actual != expected:
                mismatches.append({"kind": f"hash-{label}", "path": str(path), "expected": expected, "actual": actual})
    return {"manifest": str(manifest_path) if manifest_path is not None else None, "ok": not mismatches, "mismatches": mismatches}


__all__ = ["CapturedProcess", "sha256_bytes", "run_captured", "save_raw_capture", "run_and_save", "serial_runs", "snapshot_sources", "verify_snapshot_sources"]
