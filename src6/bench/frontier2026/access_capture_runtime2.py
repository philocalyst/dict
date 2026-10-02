#!/usr/bin/env python3
"""Launch the identical final capture against the immutable reclaim backend.

This wrapper deliberately imports the baseline capture driver and only redirects
its backend paths. The manifest pin remains unset until the parent accepts the
resource-only encoder's byte-identical development evidence and Sol freezes the
runtime-2 manifest.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from functools import lru_cache
from pathlib import Path
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))
import access_capture as capture  # noqa: E402

# Filled from Sol's final immutable manifest before any run. No fallback to the
# old backend is allowed by this separate protocol.
RUNTIME2_BACKEND = Path("/workspace/scratch/wgp6/frozen-backend-runtime2")
RUNTIME2_MANIFEST = RUNTIME2_BACKEND / "manifest.json"
RUNTIME2_MANIFEST_SHA256 = "0eaba336be7a1019a80865941a19c4ffc03b6022ef96318c77bca42b4d9b67ff"
PROTOCOL = HERE / "runtime2_capture_protocol.json"
RUNTIME1_RESULTS = Path("/workspace/scratch/frontier2026-access-final-20261001/results.jsonl")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@lru_cache(maxsize=1)
def numpy_runtime_paths() -> tuple[Path, ...]:
    import numpy

    package = Path(numpy.__file__).resolve().parent
    files = {path.resolve() for path in package.rglob("*")
             if path.is_file() and (path.suffix == ".py" or ".so" in path.name)}
    shared_objects = [path for path in files if ".so" in path.name]
    for shared_object in shared_objects:
        result = subprocess.run(["ldd", str(shared_object)], capture_output=True,
                                text=True, check=False)
        for line in result.stdout.splitlines():
            if "=>" not in line:
                continue
            value = line.split("=>", 1)[1].strip().split()
            if value and value[0].startswith("/"):
                dependency = Path(value[0]).resolve()
                if dependency.is_file():
                    files.add(dependency)
    return tuple(sorted(files))


@lru_cache(maxsize=1)
def zlib_runtime_paths() -> tuple[Path, ...]:
    origin = getattr(zlib.__spec__, "origin", None)
    files: set[Path] = set()
    if origin and origin not in ("built-in", "frozen"):
        module = Path(origin).resolve()
        if module.is_file():
            files.add(module)
            linked = subprocess.run(["ldd", str(module)], capture_output=True,
                                    text=True, check=False)
            for line in linked.stdout.splitlines():
                if "=>" not in line:
                    continue
                value = line.split("=>", 1)[1].strip().split()
                if value and value[0].startswith("/"):
                    dependency = Path(value[0]).resolve()
                    if dependency.is_file():
                        files.add(dependency)
    return tuple(sorted(files))


def hardware_identity() -> dict:
    cpu_model = "unknown"
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith(("model name", "hardware")) and ":" in line:
                cpu_model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    try:
        affinity = sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity = None
    return {"machine": platform.machine(), "processor": platform.processor(),
            "cpu_model": cpu_model, "logical_cpu_count": os.cpu_count(),
            "process_cpu_affinity": affinity}


_original_resolved_fingerprint = capture.resolved_fingerprint


def resolved_fingerprint(paths, runtime_libraries):
    libraries = list(runtime_libraries)
    if "libz.so.1" not in libraries:
        libraries.append("libz.so.1")
    result = _original_resolved_fingerprint(paths, libraries)
    import numpy

    result["encoder_runtime"] = {
        "numpy_version": numpy.__version__,
        "numpy_package_root": str(Path(numpy.__file__).resolve().parent),
        "numpy_frozen_files": len(numpy_runtime_paths()),
        "numpy_file_bytes": sum(path.stat().st_size for path in numpy_runtime_paths()),
        "zlib_module_origin": str(getattr(zlib.__spec__, "origin", "built-in")),
        "zlib_frozen_files": [
            {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in zlib_runtime_paths()
        ],
        "zlib_build_version": zlib.ZLIB_VERSION,
        "zlib_runtime_version": zlib.ZLIB_RUNTIME_VERSION,
        "hardware": hardware_identity(),
    }
    return result


def verify_runtime2_manifest() -> None:
    if not RUNTIME2_MANIFEST.is_file() or sha256(RUNTIME2_MANIFEST) != RUNTIME2_MANIFEST_SHA256:
        raise capture.CaptureError("runtime-2 backend manifest pin mismatch")
    manifest = json.loads(RUNTIME2_MANIFEST.read_text())
    if not isinstance(manifest, dict):
        raise capture.CaptureError("runtime-2 manifest must be a JSON object")
    for name, expected in manifest.items():
        if not isinstance(expected, str):
            continue
        entry = Path(name)
        path = entry if entry.is_absolute() else RUNTIME2_BACKEND / entry
        if not path.is_file() or sha256(path) != expected:
            raise capture.CaptureError(f"runtime-2 backend dependency mismatch: {path}")


_original_source_list = capture.source_list


def source_list(candidate_rows):
    paths = _original_source_list(candidate_rows)
    paths.update((Path(__file__).resolve(), PROTOCOL.resolve(), RUNTIME2_MANIFEST.resolve(),
                  RUNTIME1_RESULTS.resolve()))
    paths.update(numpy_runtime_paths())
    paths.update(zlib_runtime_paths())
    if RUNTIME1_RESULTS.is_file():
        for line in RUNTIME1_RESULTS.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                if row.get("phase") == "size" and row.get("status") == "complete":
                    paths.add(Path(row["frame_path"]).resolve())
    manifest = json.loads(RUNTIME2_MANIFEST.read_text()) if RUNTIME2_MANIFEST.is_file() else {}
    for name, expected in manifest.items():
        if isinstance(expected, str):
            entry = Path(name)
            path = entry if entry.is_absolute() else RUNTIME2_BACKEND / entry
            paths.add(path.resolve())
    return paths


_original_verify_declared_manifests = capture.verify_declared_manifests


def verify_declared_manifests() -> None:
    _original_verify_declared_manifests()
    verify_runtime2_manifest()


_original_candidates = capture.candidates


def runtime2_candidates():
    rows = _original_candidates()
    reclaim_source = Path("/workspace/dict/src6/experiments/wordgrammar/wgp6/m_reference_reclaim.zig")
    for row in rows:
        if row.get("kind") == "raw-m":
            row["source_files"] = [str(reclaim_source)]
    return rows


def validate_runtime2_size_capture(out: Path) -> None:
    out = out.resolve()
    results_path = out / "results.jsonl"
    status_path = out / "status.json"
    start_path = out / "environment-start.json"
    end_path = out / "environment-end.json"
    for path in (results_path, status_path, start_path, end_path):
        if not path.is_file():
            raise capture.CaptureError(f"runtime-2 size capture artifact missing: {path}")

    status = json.loads(status_path.read_text())
    if (status.get("phase") != "size" or status.get("error") or status.get("active_cell")
            or status.get("completed_cells") != 352 or status.get("total_cells") != 352):
        raise capture.CaptureError("runtime-2 size status is not complete for all 352 cells")

    rows = []
    seen = set()
    for line in results_path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("phase") != "size":
            continue
        if row.get("status") != "complete":
            raise capture.CaptureError("runtime-2 size results contain a failed or incomplete cell")
        key = row.get("cell_key")
        if not isinstance(key, str) or key in seen:
            raise capture.CaptureError("runtime-2 size results have a missing or duplicate cell key")
        seen.add(key)
        frame = Path(row.get("frame_path", ""))
        if not frame.is_file() or frame.stat().st_size != row.get("frame_bytes"):
            raise capture.CaptureError(f"runtime-2 size frame missing or wrong-sized: {frame}")
        rows.append(row)
    if len(rows) != 352 or len(seen) != 352:
        raise capture.CaptureError(f"runtime-2 size results contain {len(seen)} complete cells; expected 352")

    start = json.loads(start_path.read_text())
    end = json.loads(end_path.read_text())
    if start != end:
        raise capture.CaptureError("runtime-2 size environment start/end fingerprints differ")
    for name in start.get("files", {}):
        if not Path(name).is_file():
            raise capture.CaptureError(f"runtime-2 frozen dependency is missing after size capture: {name}")


_original_run_timing = capture.run_timing


def run_runtime2_timing(args) -> None:
    validate_runtime2_size_capture(args.out)
    return _original_run_timing(args)


def load_runtime1_rows() -> dict[tuple[str, str, str], dict]:
    rows: dict[tuple[str, str, str], dict] = {}
    if not RUNTIME1_RESULTS.is_file():
        raise capture.CaptureError("runtime-1 size results are missing")
    for line in RUNTIME1_RESULTS.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("phase") == "size" and row.get("status") == "complete":
            lane = row.get("corpus", {})
            rows[(lane.get("name", ""), row.get("candidate", ""), row.get("block_mode", ""))] = row
    return rows


def add_runtime1_parity():
    baseline_rows = load_runtime1_rows()
    original_commit = capture.Store.commit

    def commit(store, row):
        if row.get("phase") == "size" and row.get("status") == "complete":
            corpus = row["corpus"]
            key = (corpus["name"], row["candidate"], row["block_mode"])
            baseline = baseline_rows.get(key)
            if baseline is None:
                row["runtime1_frame_parity"] = {
                    "status": "no-complete-runtime1-counterpart",
                    "explanation": "the old capture had not completed this exact lane/candidate/block cell",
                }
            else:
                baseline_frame = Path(baseline["frame_path"])
                if (not baseline_frame.is_file() or
                        capture.file_sha(baseline_frame) != baseline.get("frame_sha256")):
                    raise capture.CaptureError(f"runtime-1 comparison frame missing or changed: {baseline_frame}")
                if row.get("source_sha256", corpus.get("sha256")) != baseline["corpus"].get("sha256"):
                    raise capture.CaptureError(f"runtime-1 source identity differs for {key[0]}")
                if row.get("frame_sha256") != baseline.get("frame_sha256"):
                    raise capture.CaptureError(
                        f"resource-only runtime-2 frame mismatch for {key}: "
                        f"runtime1={baseline.get('frame_sha256')} runtime2={row.get('frame_sha256')}")
                row["runtime1_frame_parity"] = {
                    "status": "byte-identical",
                    "runtime1_frame_sha256": baseline["frame_sha256"],
                    "runtime1_frame_bytes": baseline["frame_bytes"],
                }
        return original_commit(store, row)

    capture.Store.commit = commit
    return original_commit


def main() -> None:
    capture.DEFAULT_BACKEND = RUNTIME2_BACKEND
    capture.BACKEND_MANIFEST = RUNTIME2_MANIFEST
    capture.candidates = runtime2_candidates
    capture.source_list = source_list
    capture.resolved_fingerprint = resolved_fingerprint
    capture.verify_declared_manifests = verify_declared_manifests
    capture.run_timing = run_runtime2_timing
    add_runtime1_parity()
    capture.main()


if __name__ == "__main__":
    try:
        main()
    except (capture.CaptureError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"access_capture_runtime2: {error}", file=sys.stderr)
        sys.exit(1)
