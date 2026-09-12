#!/usr/bin/env python3
"""LEX5 host readiness ledger and immutable control inventory.

This module reuses the unchanged bench4 oracle and host boundary by import,
exercises all five semantic fixture shapes in memory, verifies the immutable
accepted LEX4 artifact ledger, and records the protocol/timing/build contract.
The admitted archive-only native bridge lives in ``bench5.native``; this
readiness command itself does not launch it or measure timings.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
BENCHMARK_ROOT = REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "benchmark"
FINAL_ROOT = REPO_ROOT / "experiments" / "frontier" / "unification-20260908" / "final"
PAIRED_RELEASE_ROOT = REPO_ROOT / "experiments" / "frontier" / "unification-20260908" / "paired-release"
PAIRED_RELEASE_MANIFEST = PAIRED_RELEASE_ROOT / "manifest.json"

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench4.external import external_adapters
from bench4.harness import TIMING_WORK_DEFINITION
from bench4.oracle import FIXTURE_NAMES, Oracle, expected, make_fixture, workload
from bench4.provenance import digest_file, environment_snapshot, git_snapshot

try:
    from .contracts import (
        FIXTURES,
        RECORDS,
        REPETITIONS,
        WARMUP,
        comparison_entrypoints,
        coverage_contract,
        has_releasefast_before_each_module,
        protocol_contract,
        releasefast_module_command,
        timing_contract,
    )
except ImportError:  # direct ``python bench5/host.py`` execution
    from contracts import (
        FIXTURES,
        RECORDS,
        REPETITIONS,
        WARMUP,
        comparison_entrypoints,
        coverage_contract,
        has_releasefast_before_each_module,
        protocol_contract,
        releasefast_module_command,
        timing_contract,
    )


GENERATED_PARTS = frozenset({"__pycache__", ".zig-cache", "zig-out", "results", ".staging"})
CONTROL_ARTIFACT_BYTES = {
    "flat": 64848,
    "repeated": 36104,
    "prose_heavy": 35240,
    "pathological_prefix": 59080,
    "rich": 74912,
}


class ReadinessError(RuntimeError):
    """The host boundary is not safe to retain as a readiness result."""


def _canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _digest_rows(rows: Iterable[object]) -> str:
    digest = hashlib.sha256()
    for row in rows:
        digest.update(_canonical(row))
    return digest.hexdigest()


def _tool_version(command: list[str]) -> str | None:
    try:
        process = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, check=False)
    except OSError:
        return None
    if process.returncode != 0:
        return None
    text = process.stdout.strip() or process.stderr.strip()
    return text.splitlines()[0] if text else None


def _repo_relative(path: Path) -> str:
    try:
        return path.resolve(strict=False).relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(path.resolve(strict=False))


def _file_record(path: Path, *, required: bool = True) -> dict[str, object]:
    # Inspect the caller-supplied path before canonicalizing it.  Resolving
    # first would turn a hostile file or parent-directory symlink into the
    # target path and make the later is_symlink check meaningless.
    original = Path(path).expanduser()
    if original.is_symlink():
        raise ReadinessError(f"retained input cannot be a symlink: {original}")
    for parent in original.parents:
        if parent.is_symlink():
            raise ReadinessError(f"retained input has a symlink parent: {parent}")
    path = original.resolve(strict=False)
    if not path.is_file():
        if required:
            raise ReadinessError(f"required file missing: {path}")
        return {"path": _repo_relative(path), "missing": True}
    if path.is_symlink():
        raise ReadinessError(f"retained input cannot be a symlink: {path}")
    return {"path": _repo_relative(path), "bytes": path.stat().st_size, "sha256": digest_file(path)}


def _skip_generated(path: Path) -> bool:
    return any(part in GENERATED_PARTS for part in path.parts)


def _tree_record(label: str, root: Path, *, required: bool = True) -> dict[str, object]:
    root = root.resolve(strict=False)
    if not root.is_dir():
        if required:
            raise ReadinessError(f"required source root missing: {root}")
        return {"label": label, "root": _repo_relative(root), "missing": True, "files": []}
    rows: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if _skip_generated(path.relative_to(root)):
            continue
        if path.is_symlink():
            raise ReadinessError(f"source tree contains symlink: {path}")
        if not path.is_file():
            continue
        rows.append(
            {
                "path": _repo_relative(path),
                "bytes": path.stat().st_size,
                "sha256": digest_file(path),
            }
        )
    if not rows:
        raise ReadinessError(f"source tree is empty: {root}")
    return {
        "label": label,
        "root": _repo_relative(root),
        "file_count": len(rows),
        "tree_sha256": _digest_rows(rows),
        "files": rows,
    }


def source_hashes() -> dict[str, object]:
    """Hash every source boundary relevant to the future host campaign."""

    trees = [
        _tree_record("bench5 host scaffold", REPO_ROOT / "bench5"),
        _tree_record("unchanged bench4 host imports", REPO_ROOT / "bench4"),
        _tree_record("immutable accepted LEX4 src4", FINAL_ROOT / "source" / "src4"),
        _tree_record("immutable accepted LEX4 bench4", FINAL_ROOT / "source" / "bench4"),
        _tree_record("source2 comparison source", REPO_ROOT / "src2"),
        _tree_record("pending src5 source snapshot", REPO_ROOT / "src5", required=False),
    ]
    design_files = [
        REPO_ROOT / "docs" / "lex5-design.md",
        REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "implementation" / "api-contract.md",
        REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "EXPERIMENTS.md",
        REPO_ROOT / "experiments" / "frontier" / "lex5-20260909" / "semantic-audit" / "cases.json",
    ]
    return {
        "trees": trees,
        "design_inputs": [_file_record(path) for path in design_files],
        "flake": {
            "nix": _file_record(REPO_ROOT / "flake.nix", required=False),
            "lock": _file_record(REPO_ROOT / "flake.lock", required=False),
        },
    }


def executable_hashes() -> dict[str, object]:
    """Record immutable control and available comparison executable bytes."""

    value: dict[str, object] = {
        "accepted_lex4_control": _file_record(FINAL_ROOT / "bin" / "lex4-final-release"),
        "source2_comparison_entrypoint": _file_record(REPO_ROOT / "bench4" / "zig-out" / "bin" / "src2-bench", required=False),
    }
    attempt = _latest_native_attempt()
    native_executable = attempt / "bin" / "lex5-native-release" if attempt is not None else BENCHMARK_ROOT / "native" / "bin" / "lex5-native-release"
    value["lex5_native_correctness"] = _file_record(native_executable, required=False)
    return value


def _latest_native_attempt() -> Path | None:
    attempts_root = BENCHMARK_ROOT / "native" / "attempts"
    attempts = sorted(path for path in attempts_root.glob("attempt-*") if path.is_dir()) if attempts_root.is_dir() else []
    return attempts[-1] if attempts else None


def native_correctness_record() -> dict[str, object]:
    """Expose the native pass ledger when one has been explicitly produced."""

    attempt = _latest_native_attempt()
    report = (attempt / "correctness.json") if attempt is not None and (attempt / "correctness.json").is_file() else ((attempt / "attempt.json") if attempt is not None else BENCHMARK_ROOT / "native" / "correctness.json")
    record = _file_record(report, required=False)
    if not record.get("missing"):
        try:
            record["status"] = json.loads(report.read_text(encoding="utf-8")).get("status")
        except (OSError, UnicodeError, json.JSONDecodeError):
            record["status"] = "unreadable"
    return record


def control_artifact_ledger() -> dict[str, object]:
    """Verify and record the five complete accepted LEX4 control artifacts."""

    if not PAIRED_RELEASE_MANIFEST.is_file():
        raise ReadinessError(f"accepted artifact manifest missing: {PAIRED_RELEASE_MANIFEST}")
    try:
        manifest = json.loads(PAIRED_RELEASE_MANIFEST.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ReadinessError(f"cannot read accepted artifact manifest: {exc}") from exc
    by_path = {
        str(row.get("path")): row
        for row in manifest
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    }
    artifacts: list[dict[str, object]] = []
    for fixture in FIXTURES:
        relative = f"artifacts/{fixture}/0/candidate/dictionary.lex4"
        expected = by_path.get(relative)
        if expected is None:
            raise ReadinessError(f"accepted artifact manifest has no {relative}")
        path = PAIRED_RELEASE_ROOT / relative
        actual = _file_record(path)
        if actual.get("bytes") != CONTROL_ARTIFACT_BYTES[fixture]:
            raise ReadinessError(f"accepted {fixture} bytes drifted: {actual.get('bytes')} != {CONTROL_ARTIFACT_BYTES[fixture]}")
        if actual.get("bytes") != expected.get("bytes") or actual.get("sha256") != expected.get("sha256"):
            raise ReadinessError(f"accepted {fixture} does not match paired-release manifest")
        artifacts.append(
            {
                "fixture": fixture,
                "label": "immutable accepted LEX4",
                "format": "LEX4",
                "path": actual["path"],
                "bytes": actual["bytes"],
                "sha256": actual["sha256"],
                "paired_release_manifest": _repo_relative(PAIRED_RELEASE_MANIFEST),
            }
        )
    return {
        "status": "verified_read_only",
        "manifest": _file_record(PAIRED_RELEASE_MANIFEST),
        "artifacts": artifacts,
        "total_bytes": sum(int(item["bytes"]) for item in artifacts),
        "candidate_semantics": "accepted LEX4 candidate artifacts are the immutable controls; paired-release /0/control artifacts are not substituted",
    }


def _fixture_record(name: str, *, records: int, repetitions: int) -> dict[str, object]:
    fixture = make_fixture(name, records)
    oracle = Oracle(fixture)
    operations = workload(fixture, repetitions)
    expected_digest = _digest_rows(
        {
            "index": index,
            "wire": operation.wire(),
            "expected": expected(oracle, operation),
        }
        for index, operation in enumerate(operations)
    )
    operation_counts = Counter(operation.op for operation in operations)
    category_counts = Counter(f"{operation.op}.{operation.category or 'uncategorized'}" for operation in operations)
    return {
        "fixture": name,
        "seed": f"0x{fixture.seed:016x}",
        "base_records": records,
        "entry_count": len(fixture.entries),
        "sense_count": len(fixture.senses),
        "concept_count": len(fixture.concepts),
        "relation_count": len(fixture.relations),
        "logical_prose_bytes": fixture.prose_bytes(),
        "semantic_digest": fixture.semantic_digest(),
        "oracle_structure_checksum": oracle.structure_checksum(),
        "oracle_query_checksum": oracle.query_checksum(operations),
        "expected_answer_digest": expected_digest,
        "operation_count": len(operations),
        "operation_counts": dict(sorted(operation_counts.items())),
        "category_counts": dict(sorted(category_counts.items())),
        "accepted_answer_check": "all expected(...) values computed in memory from bench4.oracle; no answer table retained",
        "schedule_retained": False,
    }


def fixture_matrix(*, records: int = RECORDS, repetitions: int = REPETITIONS) -> dict[str, object]:
    """Exercise the canonical five fixtures without serializing their schedule."""

    if tuple(FIXTURE_NAMES) != FIXTURES:
        raise ReadinessError(f"fixture set drifted: bench4={FIXTURE_NAMES!r}, contract={FIXTURES!r}")
    return {
        "fixtures": [_fixture_record(name, records=records, repetitions=repetitions) for name in FIXTURES],
        "records": records,
        "repetitions": repetitions,
        "warmup": WARMUP,
        "oracle_source": "bench4.oracle imported read-only",
        "expected_answers": "computed independently in memory; no query schedule or expected-answer payload is written",
    }


def external_profile_snapshot() -> dict[str, object]:
    """Discover the unchanged external factory without building an artifact."""

    flat = make_fixture("flat", 8)
    profiles = external_adapters(flat)
    return {
        "flat_profiles": [
            {
                "label": profile.metadata.label,
                "adapter_kind": profile.metadata.adapter_kind,
                "implementation": profile.metadata.implementation,
                "timing_mode": profile.metadata.timing_mode,
            }
            for profile in profiles
        ],
        "rich_profile_rule": "bench4 external_adapters returns no graph-capable profiles; rich comparisons remain unavailable rather than projected",
        "source": "bench4.external imported read-only",
    }


def build_contract_snapshot() -> dict[str, object]:
    command = releasefast_module_command(
        root_source="<LEX5_ROOT_SOURCE>",
        library_source="<SRC5_ROOT_SOURCE>",
        output="<LEX5_EXECUTABLE>",
    )
    return {
        "status": "shape_recorded_not_executed",
        "zig_module_command": command,
        "releasefast_before_each_module": has_releasefast_before_each_module(command),
        "mode_companion": {
            "required": True,
            "output_rule": "both root and src5 modules must report ReleaseFast before any benchmark result is accepted",
            "status": "pending native adapter/build authorization",
        },
        "source": "bench5.contracts; no src5 module was compiled by this scaffold",
    }


def machine_snapshot() -> dict[str, object]:
    environment, environment_sha256 = environment_snapshot([])
    return {
        "platform": platform.platform(),
        "processor": platform.processor(),
        "python": sys.version,
        "zig": _tool_version(["zig", "version"]),
        "nix": _tool_version(["nix", "--version"]),
        "environment_allowlist": environment,
        "environment_sha256": environment_sha256,
    }


def build_readiness(*, records: int = RECORDS, repetitions: int = REPETITIONS) -> dict[str, object]:
    """Build a complete host readiness document with no benchmark metrics."""

    if records <= 0 or repetitions <= 0:
        raise ValueError("records and repetitions must be positive")
    native_report = native_correctness_record()
    native_passed = native_report.get("status") == "passed_root_review_pending"
    return {
        "schema": "LEX5-BENCH-READINESS/1",
        "status": "candidate_correctness_passed_root_review_pending" if native_passed else "ready_for_native_correctness",
        "measurement_status": {
            "status": "not_run",
            "reason": "candidate archive-only native correctness passed locally; root review and timing remain explicitly pending" if native_passed else "native correctness bridge has not been run",
            "fake_results_emitted": False,
        },
        "labels": {
            "candidate": "LEX5",
            "control": "immutable accepted LEX4",
            "rejected_intermediate": "current interrupted src4 is never a control or candidate",
        },
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "repository": _repo_relative(REPO_ROOT),
        "fixture_matrix": fixture_matrix(records=records, repetitions=repetitions),
        "control_artifact_ledger": control_artifact_ledger(),
        "native_correctness": native_report,
        "semantic_mapping_ledger": _file_record(BENCHMARK_ROOT / "semantic-mapping-ledger.md"),
        "input_lowering_contract": _file_record(BENCHMARK_ROOT / "input-lowering-contract.md"),
        "source_hashes": source_hashes(),
        "executable_hashes": executable_hashes(),
        "build_contract": build_contract_snapshot(),
        "protocol_contract": protocol_contract(),
        "coverage_contract": coverage_contract(),
        "timing_contract": {
            **timing_contract(),
            "bench4_reference_definition": TIMING_WORK_DEFINITION,
        },
        "comparison_entrypoints": comparison_entrypoints(REPO_ROOT),
        "external_profile_snapshot": external_profile_snapshot(),
        "git": git_snapshot(REPO_ROOT),
        "artifact_policy": {
            "candidate_artifacts": "LEX5 artifacts are retained for archive-only correctness; no timing result" if native_passed else "none produced by this readiness command",
            "query_schedule": "never written",
            "expected_answers": "never written; only in-memory digests/counts retained",
            "production_algorithms": "none; host code contains no LEX5 encoder, reader, cache, or query implementation",
        },
    }


def write_readiness(value: dict[str, object], output: Path) -> Path:
    output = output.expanduser().resolve(strict=False)
    benchmark_root = BENCHMARK_ROOT.resolve(strict=False)
    try:
        output.relative_to(benchmark_root)
    except ValueError as exc:
        raise ReadinessError(f"readiness output must stay beneath {_repo_relative(BENCHMARK_ROOT)}: {output}") from exc
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, output)
    return output


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=int, default=RECORDS)
    parser.add_argument("--repetitions", type=int, default=REPETITIONS)
    parser.add_argument(
        "--output",
        type=Path,
        default=BENCHMARK_ROOT / "readiness.json",
        help="readiness output beneath experiments/frontier/lex5-20260909/benchmark",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        output = write_readiness(build_readiness(records=args.records, repetitions=args.repetitions), args.output)
    except (OSError, ValueError, TypeError, ReadinessError) as exc:
        print(f"LEX5 readiness failed: {exc}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "BENCHMARK_ROOT",
    "CONTROL_ARTIFACT_BYTES",
    "FINAL_ROOT",
    "PAIRED_RELEASE_ROOT",
    "ReadinessError",
    "build_readiness",
    "control_artifact_ledger",
    "executable_hashes",
    "fixture_matrix",
    "main",
    "source_hashes",
    "write_readiness",
]
