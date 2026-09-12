#!/usr/bin/env python3
"""Run the reproducible LEX4 benchmark matrix.

The harness builds independent SQLite, StarDict, dict-index, SLOB, and native
LEX4 artifacts from one deterministic semantic fixture, reopens each retained
artifact without the fixture, and rejects any semantic checksum mismatch.
Native reader time and JSON transport time remain separate; cross-runtime
latency ratios are intentionally unavailable when their timing boundaries do
not match. The subprocess contract lives in :class:`adapter.SubprocessAdapter`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid

if __package__ in (None, ""):
    BENCH_DIR = Path(__file__).resolve().parent
    if str(BENCH_DIR) not in sys.path:
        sys.path.insert(0, str(BENCH_DIR))

try:
    from .adapter import AdapterError, ReferenceAdapter, SQLiteAdapter, SubprocessAdapter, UnavailableAdapter
    from .bench2_reference import Bench2ReferenceError, load as load_bench2_reference, verify as verify_bench2_reference
    from .external import external_adapters
    from .harness import HarnessError, aggregate_process_metadata, current_rss_bytes, measure_adapter, write_observations
    from .oracle import FIXTURE_NAMES, Fixture, make_fixture, write_fixture_json, write_tsv
    from .provenance import ProvenanceError, artifact_manifest, capture, verify, verify_artifact_manifest, write_artifact_manifest
    from .report import build_document, write_json, write_markdown
except ImportError:  # direct ``python bench4/run.py`` execution
    from adapter import AdapterError, ReferenceAdapter, SQLiteAdapter, SubprocessAdapter, UnavailableAdapter
    from bench2_reference import Bench2ReferenceError, load as load_bench2_reference, verify as verify_bench2_reference
    from external import external_adapters
    from harness import HarnessError, aggregate_process_metadata, current_rss_bytes, measure_adapter, write_observations
    from oracle import FIXTURE_NAMES, Fixture, make_fixture, write_fixture_json, write_tsv
    from provenance import ProvenanceError, artifact_manifest, capture, verify, verify_artifact_manifest, write_artifact_manifest
    from report import build_document, write_json, write_markdown


def _run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8]


def _tool_version(command: list[str]) -> str | None:
    try:
        process = subprocess.run(command, check=False, text=True, capture_output=True)
    except OSError:
        return None
    if process.returncode != 0:
        return None
    return (process.stdout.strip() or process.stderr.strip()).splitlines()[0] if (process.stdout.strip() or process.stderr.strip()) else None


def machine_snapshot() -> dict[str, object]:
    return {
        "platform": platform.platform(),
        "python": sys.version,
        "zig": _tool_version(["zig", "version"]),
        "nix": _tool_version(["nix", "--version"]),
        "sqlite": _tool_version(["sqlite3", "--version"]),
        "cpu": platform.processor(),
    }


def _safe_name(value: str) -> str:
    return "".join(character if character.isalnum() or character in "._-" else "_" for character in value)


def _component_evidence(
    *,
    repo: Path,
    stage: Path,
    command: list[str],
    records: int,
    repetitions: int,
) -> dict[str, object]:
    """Run the canonical component probe and retain auditable evidence.

    The probe owns construction/reopen/verify/equality and emits one JSON
    object per lane.  This wrapper is deliberately only a staging boundary:
    it never invents metrics, copies bytes outside the completed run, or
    trusts a digest without checking the retained file.
    """

    artifact_dir = stage / "artifacts" / "component-ablations"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = stage / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    raw_path = raw_dir / "component-ablations.jsonl"
    stderr_path = raw_dir / "component-ablations.stderr"
    probe_command = [
        *command,
        "--records",
        str(records),
        "--repetitions",
        str(repetitions),
        "--output-dir",
        str(artifact_dir),
    ]
    try:
        completed = subprocess.run(
            probe_command,
            cwd=repo,
            check=False,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        raise HarnessError(f"component ablation executable failed to start: {exc}") from exc
    raw_path.write_text(completed.stdout, encoding="utf-8")
    stderr_path.write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise HarnessError(f"component ablation probe failed ({completed.returncode}); see {stderr_path.relative_to(stage)}")

    rows: list[dict[str, object]] = []
    for line_number, line in enumerate(completed.stdout.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"component ablation emitted invalid JSON on line {line_number}") from exc
        if not isinstance(value, dict) or value.get("protocol") != "LEX4-COMPONENT-ABLATION/1":
            raise HarnessError(f"component ablation emitted an unexpected record on line {line_number}")
        rows.append(value)
    entropy_rows = [row.get("entropy_vs_packed") for row in rows if row.get("record") == "entropy-vs-packed"]
    if not entropy_rows:
        raise HarnessError("component ablation emitted no entropy-vs-packed rows")

    normalized_lanes: list[dict[str, object]] = []
    all_evidence_paths: dict[str, str] = {
        "ledger": raw_path.relative_to(stage).as_posix(),
        "stderr": stderr_path.relative_to(stage).as_posix(),
        "provenance": "provenance.json",
    }
    for row_index, candidate in enumerate(entropy_rows):
        if not isinstance(candidate, dict) or candidate.get("status") not in {"measured", "pass"}:
            raise HarnessError(f"component ablation entropy row {row_index} did not pass its own checks")
        variants = candidate.get("variants")
        if not isinstance(variants, dict):
            raise HarnessError(f"component ablation entropy row {row_index} omitted variants")
        normalized_variants: dict[str, dict[str, object]] = {}
        for name in ("entropy", "packed"):
            variant = variants.get(name)
            if not isinstance(variant, dict):
                raise HarnessError(f"component ablation entropy row {row_index} omitted {name}")
            artifact_value = variant.get("artifact")
            if not isinstance(artifact_value, str) or not artifact_value or artifact_value.startswith("memory://"):
                raise HarnessError(f"component ablation entropy row {row_index}/{name} has no retained artifact path")
            artifact_path = Path(artifact_value)
            if not artifact_path.is_absolute():
                artifact_path = repo / artifact_path
            artifact_path = artifact_path.resolve(strict=True)
            try:
                artifact_path.relative_to(stage.resolve())
            except ValueError as exc:
                raise HarnessError(f"component ablation artifact escapes staged run: {artifact_path}") from exc
            actual_bytes = artifact_path.read_bytes()
            actual_digest = hashlib.sha256(actual_bytes).hexdigest()
            if variant.get("artifact_sha256") != actual_digest:
                raise HarnessError(f"component ablation artifact digest mismatch for {name} lane {candidate.get('lane')}")
            if variant.get("artifact_bytes") != len(actual_bytes):
                raise HarnessError(f"component ablation artifact byte mismatch for {name} lane {candidate.get('lane')}")
            if variant.get("verified") is not True or variant.get("semantic_equal") is not True:
                raise HarnessError(f"component ablation {name} lane {candidate.get('lane')} was not verified/equal")
            relative_artifact = artifact_path.relative_to(stage.resolve()).as_posix()
            normalized = dict(variant)
            normalized["artifact"] = relative_artifact
            normalized["raw_observations"] = raw_path.relative_to(stage).as_posix()
            normalized_variants[name] = normalized
            all_evidence_paths[f"{candidate.get('lane', row_index)}_{name}_artifact"] = relative_artifact
        oracle = candidate.get("oracle_digest")
        if not isinstance(oracle, str) or not oracle:
            raise HarnessError(f"component ablation entropy row {row_index} omitted oracle digest")
        if any(variant.get("oracle_digest") != oracle for variant in normalized_variants.values()):
            raise HarnessError(f"component ablation entropy row {row_index} oracle mismatch")
        boundaries = {variant.get("timing_boundary") for variant in normalized_variants.values()}
        if len(boundaries) != 1 or None in boundaries:
            raise HarnessError(f"component ablation entropy row {row_index} timing boundaries do not match")
        normalized_lanes.append(
            {
                "status": "measured",
                "lane": candidate.get("lane", row_index),
                "oracle_digest": oracle,
                "timing_boundary": next(iter(boundaries)),
                "variants": normalized_variants,
            }
        )
    return {
        "entropy_vs_packed": {
            "status": "measured",
            "control": "same canonical src4/entropy.zig values/options; forced strategies",
            "variants": ["entropy", "packed"],
            "lanes": normalized_lanes,
            "evidence_paths": all_evidence_paths,
        }
    }


def _make_adapters(
    fixture: Fixture,
    *,
    corpus: Path,
    native_command: list[str] | None,
    src2_command: list[str] | None,
    include_sqlite: bool,
    semantic_input: Path | None = None,
) -> list[object]:
    adapters: list[object] = [
        ReferenceAdapter(fixture, label="lex4-reference-mock", implementation="python-reference"),
    ]
    if src2_command:
        adapters.append(
            SubprocessAdapter(
                fixture,
                src2_command,
                corpus=corpus,
                fixture_json=semantic_input,
                label="lex2-current-native",
                implementation="actual-src2-zig",
                note="Current src2 compiler and reader executed through the same native self-timed protocol; complete executable and source provenance is retained.",
            )
        )
    else:
        adapters.append(UnavailableAdapter("lex2-current-native", "actual src2 executable not supplied; projection rows do not satisfy this baseline"))
    if native_command:
        adapters.append(
            SubprocessAdapter(
                fixture,
                native_command,
                corpus=corpus,
                fixture_json=semantic_input,
                label="lex4-native",
            )
        )
    else:
        adapters.append(UnavailableAdapter("lex4-native", "src4 executable not supplied; native measurement unavailable"))
    if include_sqlite and fixture.name != "rich":
        adapters.append(SQLiteAdapter(fixture))
    elif not include_sqlite:
        adapters.append(UnavailableAdapter("sqlite/adapter", "SQLite adapter disabled by --skip-sqlite"))
    else:
        adapters.append(UnavailableAdapter("sqlite/adapter", "rich graph fixture is outside the flat external projection"))
    # Flat external formats are built from this exact Fixture by their own
    # readers.  Rich is intentionally returned empty by the factory because
    # these formats have no graph projection; the loop below records explicit
    # unavailable rows for it instead of silently dropping the comparison.
    adapters.extend(external_adapters(fixture))
    return adapters


def run(args: argparse.Namespace) -> Path:
    repo = args.repo.resolve(strict=True)
    out_root = args.out_root.resolve()
    if out_root in {repo / "src4", repo / "bench4"}:
        raise HarnessError("--out-root cannot be a declared source root (use a child results directory)")
    out_root.mkdir(parents=True, exist_ok=True)
    run_id = args.run_id or _run_id()
    setattr(args, "_resolved_run_id", run_id)
    final = out_root / run_id
    stage = out_root / (".staging-" + run_id)
    if final.exists() or stage.exists():
        raise HarnessError(f"run destination already exists: {final}")
    stage.mkdir(parents=True)
    started_ns = time.perf_counter_ns()
    started_rss = current_rss_bytes()
    native_command = [args.native_executable] if args.native_executable else None
    if args.native_arg:
        native_command = (native_command or []) + list(args.native_arg)
    src2_command = [args.src2_executable] if args.src2_executable else None
    if args.src2_arg:
        src2_command = (src2_command or []) + list(args.src2_arg)
    component_command = [args.component_executable] if args.component_executable else None
    if args.component_arg:
        component_command = (component_command or []) + list(args.component_arg)
    executable = native_command[0] if native_command else None
    src2_executable = src2_command[0] if src2_command else None
    component_executable = component_command[0] if component_command else None
    extra_executables: dict[str, str] = {}
    if src2_executable:
        extra_executables["lex2-current-native"] = src2_executable
    if component_executable:
        extra_executables["lex4-component-ablations"] = component_executable
    bench2_path = args.bench2_results.resolve(strict=False) if args.bench2_results is not None else repo / "bench2" / "results" / "benchmark.json"
    try:
        bench2_reference = load_bench2_reference(
            bench2_path,
            current_seed="0x4c45583400040001",
            current_records=args.records,
        )
    except Bench2ReferenceError as exc:
        raise HarnessError(str(exc)) from exc
    cli = [str(item) for item in sys.argv]
    provenance_start = capture(
        root=repo,
        output=stage / "provenance.json",
        executable=executable,
        extra_executables=extra_executables,
        cli=cli,
        env_overrides=args.env,
        excluded_roots=(out_root,),
    )
    config: dict[str, object] = {
        "records": args.records,
        "repetitions": args.repetitions,
        "warmup": args.warmup,
        "fixtures": list(args.fixtures),
        "seed": "0x4c45583400040001",
        "native_executable": executable,
        "src2_executable": src2_executable,
        "component_executable": component_executable,
        "component_records": args.component_records if component_command else None,
        "component_repetitions": args.component_repetitions if component_command else None,
        "semantic_projection": "entry/key/definition; rich adds graph/concepts for graph-capable profiles",
        "timing_boundary": "reader operation time and native outer transport time are separate; host-operation profiles have no transport metric; oracle/comparison/checksum and prefix-enumeration interval metadata are outside both",
        "timing_work_definition": "in-process adapters use host timing around one reader call; native adapters self-report reader_elapsed_ns while the harness retains perf_counter_ns request/response transport; unique sample nonces and no preflight query schedule are sent",
        "machine": machine_snapshot(),
        "bench2_reference": str(bench2_path),
    }
    (stage / "config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    component_evidence: dict[str, object] | None = None
    if component_command:
        component_evidence = _component_evidence(
            repo=repo,
            stage=stage,
            command=component_command,
            records=args.component_records,
            repetitions=args.component_repetitions,
        )

    measurements = []
    unavailable: list[dict[str, object]] = []
    for fixture_name in args.fixtures:
        fixture = make_fixture(fixture_name, args.records)
        corpus_path = stage / "raw" / f"corpus-{fixture_name}.tsv"
        semantic_input_path = stage / "raw" / f"fixture-{fixture_name}.json"
        write_tsv(fixture, corpus_path)
        write_fixture_json(fixture, semantic_input_path)
        for adapter in _make_adapters(
            fixture,
            corpus=corpus_path,
            semantic_input=semantic_input_path,
            native_command=native_command,
            src2_command=src2_command,
            include_sqlite=not args.skip_sqlite,
        ):
            label = adapter.metadata.label
            if adapter.metadata.adapter_kind == "unavailable":
                unavailable.append({"fixture": fixture_name, "adapter": label, "reason": adapter.metadata.note})
                continue
            # A private directory makes the artifact-byte ledger include all
            # retained sidecars emitted by an adapter without accidentally
            # charging bytes belonging to another adapter in the fixture.
            artifact_dir = stage / "artifacts" / fixture_name / _safe_name(label)
            artifact = artifact_dir / "payload.bin"
            if fixture_name == "rich" and adapter.metadata.adapter_kind == "external_format_adapter":
                unavailable.append({"fixture": fixture_name, "adapter": label, "reason": "rich graph semantics are not represented by this external flat projection"})
                continue
            try:
                measurement = measure_adapter(fixture, adapter, artifact, repetitions=args.repetitions, warmup=args.warmup)
            except (AdapterError, HarnessError) as exc:
                # Semantic mismatch, native process failure, and verify drift
                # are all fatal.  Continuing would produce an incomparable
                # report with one adapter silently missing work.
                raise HarnessError(f"fatal adapter failure {fixture_name}/{label}: {exc}") from exc
            # Reports are portable within a completed run directory.  Never
            # retain the transient staging absolute path in JSON.
            measurement.artifact = artifact.relative_to(stage).as_posix()
            measurements.append(measurement)
        if fixture_name == "rich":
            # Keep every named external baseline explicit in the report even
            # though a flat format cannot represent senses, concepts, or
            # relations.  This is an unavailable semantic profile, not a
            # fabricated zero measurement.
            for label in ("stardict/adapter", "slob/adapter", "slob/adapter-lzma2", "dict-index/adapter"):
                if not any(item.get("fixture") == fixture_name and item.get("adapter") == label for item in unavailable):
                    unavailable.append({"fixture": fixture_name, "adapter": label, "reason": "rich graph semantics are not represented by this external flat projection"})

    write_observations(measurements, stage / "raw" / "observations.jsonl")
    process = aggregate_process_metadata(started_rss=started_rss, ended_rss=current_rss_bytes(), elapsed_ns=time.perf_counter_ns() - started_ns)
    # The report is written before hashes.tsv; the manifest is the
    # authoritative full-byte list and excludes only its own self-hash.  A
    # second report write below fills the final manifest count after all other
    # retained bytes (including COMPLETE) exist.
    manifest_before_report = artifact_manifest(stage, stage / "hashes.tsv")
    document = build_document(
        run_id=run_id,
        config=config,
        measurements=measurements,
        unavailable=unavailable,
        process=process,
        provenance=provenance_start,
        artifact_manifest=manifest_before_report,
        historical_bench2=bench2_reference,
        component_evidence=component_evidence,
    )
    write_json(document, stage / "benchmark.json")
    write_markdown(document, stage / "BENCHMARKS.md")
    # Verify source/executable/flakes after all measured work, before staging
    # can become visible as a completed run.
    ok, mismatches, provenance_end = verify(
        root=repo,
        manifest=stage / "provenance.json",
        executable=executable,
        extra_executables=extra_executables,
    )
    if not ok:
        raise HarnessError("provenance drift detected: " + "; ".join(mismatches))
    bench2_ok, bench2_reason = verify_bench2_reference(bench2_reference)
    if not bench2_ok:
        raise HarnessError("bench2 reference drift detected: " + str(bench2_reason))
    (stage / "raw" / "provenance-end.json").write_text(json.dumps(provenance_end, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (stage / "COMPLETE").write_text("LEX4 benchmark completed; hashes.tsv excludes only itself.\n", encoding="utf-8")
    final_manifest = artifact_manifest(stage, stage / "hashes.tsv")
    document_manifest = document.get("artifact_manifest")
    if isinstance(document_manifest, dict):
        document_manifest["file_count"] = len(final_manifest)
        document_manifest["file_count_before_report"] = len(manifest_before_report)
    # Rewriting does not alter the number of retained files, only the report's
    # bytes. Recompute once for audit clarity before producing the manifest.
    write_json(document, stage / "benchmark.json")
    write_markdown(document, stage / "BENCHMARKS.md")
    final_manifest = artifact_manifest(stage, stage / "hashes.tsv")
    # COMPLETE is part of the run bytes and therefore must exist before the
    # manifest is generated.  Only hashes.tsv excludes its own self-hash.
    write_artifact_manifest(stage, stage / "hashes.tsv")
    ok_manifest, manifest_mismatches = verify_artifact_manifest(stage, stage / "hashes.tsv")
    if not ok_manifest:
        raise HarnessError("artifact manifest verification failed: " + "; ".join(manifest_mismatches))
    os.replace(stage, final)
    latest_tmp = out_root / (".latest-" + run_id)
    try:
        latest_tmp.unlink()
    except FileNotFoundError:
        pass
    latest_tmp.symlink_to(final.name)
    os.replace(latest_tmp, out_root / "latest")
    return final


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    value.add_argument("--out-root", type=Path, default=Path(__file__).resolve().parent / "results")
    value.add_argument("--run-id")
    value.add_argument("--records", type=int, default=64)
    value.add_argument("--repetitions", type=int, default=64)
    value.add_argument("--warmup", type=int, default=16)
    value.add_argument("--fixtures", nargs="+", choices=FIXTURE_NAMES, default=list(FIXTURE_NAMES))
    value.add_argument("--skip-sqlite", action="store_true")
    value.add_argument("--native-executable")
    value.add_argument("--native-arg", action="append", default=[])
    value.add_argument("--src2-executable", help="actual current src2 benchmark executable; never a reference projection")
    value.add_argument("--src2-arg", action="append", default=[])
    value.add_argument("--component-executable", help="canonical entropy-vs-packed component probe executable")
    value.add_argument("--component-arg", action="append", default=[])
    value.add_argument("--component-records", type=int, default=8192)
    value.add_argument("--component-repetitions", type=int, default=256)
    value.add_argument("--env", action="append", default=[])
    value.add_argument("--bench2-results", type=Path, help="historical bench2 benchmark.json to retain separately; never merged into current timings")
    return value


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        path = run(args)
    except (OSError, ValueError, TypeError, HarnessError, AdapterError, KeyError, ProvenanceError) as exc:
        failed_run = getattr(args, "_resolved_run_id", None)
        if failed_run:
            staging = args.out_root.resolve() / (".staging-" + failed_run)
            if staging.is_dir():
                shutil.rmtree(staging)
        print(f"LEX4 benchmark failed: {exc}", file=sys.stderr)
        return 2
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
