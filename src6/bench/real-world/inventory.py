#!/usr/bin/env python3
"""Record reproducibility inputs and retained artifact inventories.

This is deliberately a non-timed bookkeeping command.  It hashes the source
archives and extracted trees retained by ``prepare.py``, the projection and
evidence artifacts, the exact harness/native sources used by the smoke, the
LEX6 runner binary, fixed measurement plans, and the external executables/Python modules.  The output
is kept in the owned real-world evidence directory so a later timed run can
refer to one immutable environment record.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.util
import json
import os
import platform
import shutil
import sqlite3
import subprocess
import sys
import sysconfig
import time
from pathlib import Path
from typing import Any, Iterable, Sequence


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
DEFAULT_CACHE = Path("/tmp/dictionary-real-world-cache")
DEFAULT_EVIDENCE = Path("/tmp/dictionary-real-world-evidence")
DEFAULT_SWEEP = Path("/tmp/dictionary-real-world-sweep")
DEFAULT_TIMED_BUILDS = Path("/tmp/dictionary-real-world-timed-builds")


def digest(path: Path, algorithm: str = "sha256") -> str:
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_record(path: Path, *, label: str | None = None) -> dict[str, Any]:
    resolved = path.resolve()
    result: dict[str, Any] = {
        "path": str(path),
        "resolved_path": str(resolved),
        "exists": resolved.is_file(),
    }
    if label:
        result["label"] = label
    if resolved.is_file():
        result.update({
            "bytes": resolved.stat().st_size,
            "sha256": digest(resolved, "sha256"),
            "sha512": digest(resolved, "sha512"),
        })
    return result


def tree_record(root: Path, *, include_files: bool = True) -> dict[str, Any]:
    resolved = root.resolve()
    files: list[dict[str, Any]] = []
    total = 0
    if resolved.is_dir():
        candidates = sorted((path for path in resolved.rglob("*") if path.is_file()), key=lambda path: str(path))
        for path in candidates:
            record = file_record(path)
            total += int(record.get("bytes", 0))
            if include_files:
                files.append(record)
    return {
        "path": str(root),
        "resolved_path": str(resolved),
        "exists": resolved.is_dir(),
        "files": len(files) if include_files else sum(1 for path in resolved.rglob("*") if path.is_file()) if resolved.is_dir() else 0,
        "bytes": total,
        **({"file_records": files} if include_files else {}),
    }


def run_version(argv: Sequence[str]) -> dict[str, Any]:
    try:
        result = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"argv": list(argv), "returncode": None, "stdout": "", "stderr": str(exc), "error": type(exc).__name__}
    return {
        "argv": list(argv),
        "returncode": result.returncode,
        "stdout": result.stdout.decode("utf-8", "replace")[:4000],
        "stderr": result.stderr.decode("utf-8", "replace")[:4000],
    }


def command_inventory(name: str, version_args: Sequence[str]) -> dict[str, Any]:
    executable = shutil.which(name)
    result: dict[str, Any] = {
        "name": name,
        "path": executable,
        "available": executable is not None,
    }
    if executable:
        path = Path(executable)
        result["binary"] = file_record(path)
        result["version"] = run_version([executable, *version_args])
    return result


def module_inventory(name: str) -> dict[str, Any]:
    spec = importlib.util.find_spec(name)
    result: dict[str, Any] = {"name": name, "available": spec is not None}
    if spec is None:
        return result
    result["origin"] = spec.origin
    try:
        module = importlib.import_module(name)
    except Exception as exc:  # pragma: no cover - environment dependent
        result["import_error"] = f"{type(exc).__name__}: {exc}"
        return result
    result["file"] = str(Path(module.__file__).resolve()) if getattr(module, "__file__", None) else None
    for attribute in ("__version__", "VERSION", "ICU_VERSION", "LIBRARY_VERSION"):
        if hasattr(module, attribute):
            value = getattr(module, attribute)
            result[attribute] = str(value)
    return result


def source_inputs(cache: Path) -> dict[str, Any]:
    source_manifest_path = cache / "source-manifest.json"
    result: dict[str, Any] = {
        "source_manifest": file_record(source_manifest_path),
        "sources": [],
    }
    if not source_manifest_path.is_file():
        result["status"] = "unavailable-source-manifest"
        return result
    manifest = json.loads(source_manifest_path.read_text(encoding="utf-8"))
    for source in manifest.get("sources", []):
        entry: dict[str, Any] = {
            "id": source.get("id"),
            "url": source.get("url"),
            "archive": file_record(Path(source["archive"]["path"]), label="downloaded-source-archive"),
            "license": file_record(Path(source["license"]["path"]), label="retained-license"),
            "extracted": tree_record(Path(source["extracted_root"])),
        }
        result["sources"].append(entry)
    result["status"] = "ok"
    return result


def harness_sources() -> dict[str, Any]:
    # Keep this list explicit: it documents the production inputs imported by
    # runner.zig without sweeping unrelated source or generated cache files.
    owned_names = (
        ".gitignore", "README.md", "manifest.json", "prepare.py", "formats.py",
        "smoke.py", "sweep.py", "runner.zig", "build.zig", "test_prepare.py",
        "legacy_probe.py", "inventory.py", "measure.py", "report.py", "verification.py", "fairness_audit.py",
    )
    owned = [file_record(ROOT / name, label="owned-harness-source") for name in owned_names]
    production_names = (
        "src6/root.zig", "src6/archive.zig", "src6/compression.zig", "src6/model.zig",
        "src6/packet.zig", "src6/query.zig", "src6/render.zig", "src6/validate.zig",
        "src6/walk.zig", "build6.zig", "flake.nix", "flake.lock",
    )
    production = [file_record(REPO / name, label="production-or-build-input") for name in production_names]
    return {
        "owned_harness": owned,
        "production_and_build_inputs": production,
        "bzip3_vendor_tree": tree_record(REPO / "vendor" / "bzip3"),
    }


def evidence_inventory(root: Path) -> dict[str, Any]:
    resolved = root.resolve()
    if not resolved.is_dir():
        return {"path": str(root), "exists": False, "files": 0, "bytes": 0, "file_records": []}
    return tree_record(resolved)


def projection_inventory(corpora_root: Path) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    for manifest_path in sorted(corpora_root.glob("*/projection-manifest.json")):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            entries.append({"manifest": file_record(manifest_path), "error": str(exc)})
            continue
        entries.append({
            "corpus": manifest.get("corpus"),
            "manifest": file_record(manifest_path),
            "projection": file_record(Path(manifest["projection_tsv"]["path"])),
            "rows": file_record(Path(manifest["rows_jsonl"]["path"])),
            "counts": {key: manifest.get(key) for key in ("rows", "unique_keys", "key_hits", "duplicate_key_hits")},
        })
    return {"path": str(corpora_root), "entries": entries}


def ledger_inventory() -> list[dict[str, Any]]:
    """Hash retained JSON/report ledgers without recursively hashing this file.

    ``environment.json`` is being written by this invocation, so it is
    intentionally excluded from its own input list.  The next invocation can
    still hash the previous environment through the explicit run list if
    desired; all benchmark raw samples and manifests are included here.
    """
    names = (
        "main-smoke.json", "all-exact-smoke.json", "gcide-smoke.json",
        "omw-ja-smoke.json", "page-sweep.json", "legacy-availability.json",
        "verification.json", "timing-results.json", "baseline-pre-refactor.json",
        "main-smoke-post-review.json", "post-review-interrupted-smoke.json",
        "fairness-audit-post-review.json", "timing-results-post-review.json",
        "timing-results-post-review-final.json", "timing-results-post-review-failed-label-collision.json",
        "page-sweep-post-review.json", "../reports/real-world-report.md", "../reports/real-world-report-post-review.md",
        "../corpora/manifest.json",
    )
    records = []
    for name in names:
        path = (ROOT / "evidence" / "runs" / name).resolve()
        if path.is_file():
            records.append(file_record(path, label="retained-ledger"))
    return records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--corpora-root", type=Path, default=ROOT / "evidence" / "corpora")
    parser.add_argument("--evidence-root", type=Path, default=DEFAULT_EVIDENCE)
    parser.add_argument("--sweep-root", type=Path, default=DEFAULT_SWEEP)
    parser.add_argument("--timed-build-root", type=Path, default=DEFAULT_TIMED_BUILDS)
    parser.add_argument("--measurement-plan-root", type=Path, default=ROOT / "evidence" / "runs" / "measurement-plans")
    parser.add_argument("--legacy-json", type=Path, default=ROOT / "evidence" / "runs" / "legacy-availability.json")
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "environment.json")
    args = parser.parse_args(argv)

    commands = [
        ("zig", ("version",)),
        ("nix", ("--version",)),
        ("sdcv", ("--version",)),
        ("dict", ("--version",)),
        ("dictunformat", ("--version",)),
        ("dictzip", ("--version",)),
        ("sqlite3", ("--version",)),
        ("python3", ("--version",)),
    ]
    report: dict[str, Any] = {
        "schema": 1,
        "status": "environment-inventory",
        "timing": "not run",
        "recorded_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": sys.version,
            "python_executable": sys.executable,
            "python_prefix": sys.prefix,
            "sysconfig_purelib": sysconfig.get_paths().get("purelib"),
        },
        "commands": [command_inventory(name, version_args) for name, version_args in commands],
        "python_modules": [module_inventory(name) for name in ("slob", "icu")],
        "runtime_versions": {
            "sqlite3_python": sqlite3.sqlite_version,
            "python_zlib": __import__("zlib").ZLIB_VERSION,
        },
        "source_inputs": source_inputs(args.cache_dir.resolve()),
        "harness_sources": harness_sources(),
        "compiled_binaries": [file_record(ROOT / "zig-out" / "bin" / "real-lex6", label="compiled-independent-runner")],
        "projections": projection_inventory(args.corpora_root.resolve()),
        "retained_ledgers": ledger_inventory(),
        "legacy_probe": file_record(args.legacy_json),
        "retained_evidence": evidence_inventory(args.evidence_root),
        "retained_page_sweep": evidence_inventory(args.sweep_root),
        "retained_timed_builds": evidence_inventory(args.timed_build_root),
        "retained_measurement_plans": evidence_inventory(args.measurement_plan_root),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "output": str(args.output.resolve())}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
