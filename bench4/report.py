#!/usr/bin/env python3
"""Machine and human report generation for completed LEX4 runs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

try:
    from .harness import Measurement
except ImportError:  # pragma: no cover - exercised by direct script discovery
    from harness import Measurement


REPORT_SCHEMA_VERSION = 1
# These are deliberately evidence-bearing specifications, not promises that a
# number exists.  ``_build_ablations`` below turns the entropy/packed row into
# a measured row only when a retained component probe proves both variants.
# The two cross-generation comparisons are kept in a separate section: a
# src4 snapshot and the current src2 snapshot differ in many implementation
# choices and therefore are not controlled component ablations.
ABLATIONS = (
    {
        "name": "automaton_vs_front_code",
        "variants": ("automaton", "front_code"),
        "status": "unavailable",
        "control": "same_compiler_required",
        "reason": (
            "No same-compiler switch exists: src4/automaton.zig exposes only "
            "automaton.Builder, while src2/keys.zig::Builder is a separate "
            "front-coded wire. The matched native rows are retained as a "
            "cross-generation observation, not an ablation."
        ),
        "source_evidence": ("src4/automaton.zig:Builder", "src2/keys.zig:Builder"),
    },
    {
        "name": "outputs",
        "variants": ("explicit_output_deltas", "permutation"),
        "status": "unavailable",
        "control": "same_builder_required",
        "reason": (
            "src4/axes.zig selects single-target delta mode versus the generic "
            "directory from input collisions; it exposes no API to force either "
            "wire on the same keys. axes_test.zig's generic-directory number is "
            "arithmetic, not a second encoded artifact."
        ),
        "source_evidence": ("src4/axes.zig:AxisBuilder.build", "src4/axes_test.zig:output-directory ablation"),
    },
    {
        "name": "grammar_vs_blocks",
        "variants": ("grammar", "blocks"),
        "status": "unavailable",
        "control": "same_compiler_required",
        "reason": (
            "src4/grammar.zig has only the L4GC grammar builder/view; it has no "
            "raw/block mode. src2/prose.zig is an independent block store, so "
            "the matched native rows are retained as a cross-generation "
            "observation, not a controlled grammar ablation."
        ),
        "source_evidence": ("src4/grammar.zig:build", "src2/prose.zig:Builder", "src2/prose.zig:View"),
    },
    {
        "name": "entropy_vs_packed",
        "variants": ("entropy", "packed"),
        "status": "unavailable",
        "control": "canonical_component",
        "reason": (
            "src4/entropy.zig exposes buildForced for both strategies, but no "
            "number is admitted without a retained component probe that builds, "
            "reopens, verifies, and compares both encodings to one oracle."
        ),
        "source_evidence": ("src4/entropy.zig:Strategy", "src4/entropy.zig:buildForced", "src4/entropy_test.zig:assertRoundTrip"),
    },
    {
        "name": "memberships_vs_pairwise",
        "variants": ("memberships", "pairwise"),
        "status": "unavailable",
        "control": "semantic_equivalent_wire_required",
        "reason": (
            "src4/concepts.zig has a verified membership wire and only a "
            "PairwiseBaseline byte-arithmetic helper; it has no pairwise graph "
            "builder/view that can be reopened and verified on the same rich "
            "graph. The concepts test is therefore not a controlled number."
        ),
        "source_evidence": ("src4/concepts.zig:build", "src4/concepts.zig:pairwiseBaseline", "src4/concepts_test.zig:membership cluster ablation"),
    },
    {
        "name": "interval_planner",
        "variants": ("on", "off"),
        "status": "unavailable",
        "control": "same_query_engine_required",
        "reason": (
            "src4/rank.zig's operatorPlan is a comptime trait and src4/snapshot.zig "
            "always projects prefix roots to intervals; no runtime planner-off "
            "switch or alternate reader exists. src2/query.zig::allow_scan is a "
            "different generation's scan budget, not an LEX4 planner variant."
        ),
        "source_evidence": ("src4/rank.zig:operatorPlan", "src4/snapshot.zig:nodesForPrefix", "src2/query.zig:Options.allow_scan"),
    },
)
COMPARISON_BASELINES = (
    "lex2-current-native",
    "sqlite/adapter",
    "stardict/adapter",
    "slob/adapter",
    "dict-index/adapter",
)


def _required_operations(fixture: str) -> set[str]:
    required = {
        "exact",
        "prefix_interval",
        "prefix_enumerate",
        "select",
        "render",
        "snippet",
    }
    if fixture == "rich":
        required.update({"concept_members", "translations", "relations"})
    return required


def _available_metrics(measurement: Measurement) -> dict[str, object]:
    metrics = dict(measurement.metrics)
    metrics.update(
        {
            "artifact_bytes": measurement.artifact_bytes,
            "build_ns": measurement.build_ns,
            "open_ns": measurement.open_ns,
            "verify_ns": measurement.verify_ns,
        }
    )
    return metrics


def _measurement_json(measurement: Measurement) -> dict[str, object]:
    value = measurement.json()
    value["metrics"] = _available_metrics(measurement)
    # The raw per-operation rows live in observations.jsonl.  Keeping a small
    # count here makes accidental omission of raw evidence visible.
    value["raw_observation_count"] = len(measurement.observations)
    return value


def validate(measurements: Iterable[Measurement]) -> None:
    values = list(measurements)
    by_fixture: dict[str, list[Measurement]] = {}
    for measurement in values:
        if not measurement.available:
            continue
        metadata = measurement.adapter
        if metadata.native != (metadata.adapter_kind == "native_implementation"):
            raise ValueError(
                f"native flag/kind disagreement for {measurement.fixture}/{metadata.label}"
            )
        if metadata.label == "lex4-reference-mock" and metadata.native:
            raise ValueError(f"reference projection cannot be reported as native: {metadata.label}")
        by_fixture.setdefault(measurement.fixture, []).append(measurement)
        if measurement.artifact_bytes <= 0:
            raise ValueError(f"missing/invalid artifact bytes for {measurement.fixture}/{measurement.adapter.label}")
        if not measurement.observations:
            raise ValueError(f"no raw observations for {measurement.fixture}/{measurement.adapter.label}")
        for row in measurement.observations:
            if row.get("expected_cardinality") != row.get("observed_cardinality"):
                raise ValueError(f"cardinality mismatch leaked into report for {measurement.fixture}/{measurement.adapter.label}")
            reader_value = row.get("reader_elapsed_ns")
            outer_value = row.get("outer_call_ns")
            transport_value = row.get("transport_elapsed_ns")
            if type(reader_value) is not int or reader_value < 0:
                raise ValueError(f"invalid reader_elapsed_ns for {measurement.fixture}/{measurement.adapter.label}")
            if type(outer_value) is not int or outer_value < 0 or reader_value > outer_value:
                raise ValueError(f"invalid outer_call_ns for {measurement.fixture}/{measurement.adapter.label}")
            if transport_value is not None and (type(transport_value) is not int or transport_value < 0):
                raise ValueError(f"invalid transport_elapsed_ns for {measurement.fixture}/{measurement.adapter.label}")
        if measurement.adapter.timing_mode == "native_self_timed":
            if any(row.get("transport_elapsed_ns") is None for row in measurement.observations):
                raise ValueError(f"native profile is missing transport timings for {measurement.fixture}/{measurement.adapter.label}")
        elif any(row.get("transport_elapsed_ns") is not None for row in measurement.observations):
            raise ValueError(f"host profile is mislabeled with transport timings for {measurement.fixture}/{measurement.adapter.label}")
        counts = measurement.metrics.get("sample_counts")
        if not isinstance(counts, dict):
            raise ValueError(f"missing explicit sample counts for {measurement.fixture}/{metadata.label}")
        unique_samples = measurement.metrics.get("unique_sample_nonce_count")
        if type(unique_samples) is not int or unique_samples != measurement.metrics.get("operation_count"):
            raise ValueError(f"sample nonces are not unique for {measurement.fixture}/{metadata.label}")
        missing = sorted(operation for operation in _required_operations(measurement.fixture) if int(counts.get(operation, 0)) <= 0)
        if missing:
            raise ValueError(
                f"operation classes omitted from {measurement.fixture}/{metadata.label}: {missing}"
            )
    for fixture, fixture_measurements in by_fixture.items():
        semantic = {str(item.metrics.get("semantic_digest")) for item in fixture_measurements}
        structure = {str(item.metrics.get("structure_checksum")) for item in fixture_measurements}
        query = {str(item.metrics.get("query_checksum")) for item in fixture_measurements}
        if len(semantic) != 1 or len(structure) != 1 or len(query) != 1:
            raise ValueError(
                f"semantic mismatch for {fixture}: semantic={semantic} structure={structure} query={query}"
            )


def _comparison(measurements: list[Measurement], fixture: str, left_label: str, right_label: str, metric: str) -> dict[str, object]:
    left = next(
        (
            item
            for item in measurements
            if item.fixture == fixture
            and item.adapter.label == left_label
            and item.adapter.native
            and item.adapter.adapter_kind == "native_implementation"
            and item.available
        ),
        None,
    )
    right = next((item for item in measurements if item.fixture == fixture and item.adapter.label == right_label and item.available), None)
    if left is None or right is None:
        return {"status": "unavailable", "fixture": fixture, "left": left_label, "right": right_label, "metric": metric, "reason": "one or both profiles are unavailable"}
    # Native rows report a reader-only clock from inside the executable,
    # while external Python adapters report one host-operation call.  The
    # numbers are both useful, but their timing boundaries are not an
    # apples-to-apples ratio. Keep byte-size comparisons (which have no clock
    # boundary) valid and make latency mismatches explicit instead of
    # silently presenting a misleading speedup.
    if metric != "artifact_bytes" and left.adapter.timing_mode != right.adapter.timing_mode:
        return {
            "status": "unavailable",
            "fixture": fixture,
            "left": left_label,
            "right": right_label,
            "metric": metric,
            "reason": f"timing boundary mismatch: {left.adapter.timing_mode} vs {right.adapter.timing_mode}",
        }
    left_value = _available_metrics(left).get(metric)
    right_value = _available_metrics(right).get(metric)
    if not isinstance(left_value, (int, float)) or not isinstance(right_value, (int, float)) or right_value == 0:
        return {"status": "unavailable", "fixture": fixture, "left": left_label, "right": right_label, "metric": metric, "reason": "metric missing or denominator is zero"}
    return {
        "status": "measured",
        "fixture": fixture,
        "left": left_label,
        "right": right_label,
        "metric": metric,
        "left_value": left_value,
        "right_value": right_value,
        "ratio_left_over_right": left_value / right_value,
    }


def _native_profile(measurements: Iterable[Measurement], fixture: str, label: str) -> Measurement | None:
    """Return a completed native profile, never a reference projection."""

    return next(
        (
            item
            for item in measurements
            if item.fixture == fixture
            and item.adapter.label == label
            and item.adapter.native
            and item.adapter.adapter_kind == "native_implementation"
            and item.available
        ),
        None,
    )


def _profile_evidence(measurement: Measurement) -> dict[str, object]:
    metrics = _available_metrics(measurement)
    return {
        "label": measurement.adapter.label,
        "artifact": measurement.artifact,
        "artifact_bytes": measurement.artifact_bytes,
        "artifact_sha256": metrics.get("artifact_sha256"),
        "artifact_bundle_sha256": metrics.get("artifact_bundle_sha256"),
        "build_ns": measurement.build_ns,
        "open_ns": measurement.open_ns,
        "verify_ns": measurement.verify_ns,
        "exact_reader_p50_ns": metrics.get("exact.reader_p50_ns"),
        "prefix_interval_reader_p50_ns": metrics.get("prefix_interval.reader_p50_ns"),
        "prefix_enumerate_reader_p50_ns": metrics.get("prefix_enumerate.reader_p50_ns"),
        "render_reader_p50_ns": metrics.get("render.reader_p50_ns"),
        "semantic_digest": metrics.get("semantic_digest"),
        "structure_checksum": metrics.get("structure_checksum"),
        "query_checksum": metrics.get("query_checksum"),
        "timing_mode": measurement.adapter.timing_mode,
        "timing_work_definition": metrics.get("timing_work_definition"),
        "operation_count": metrics.get("operation_count"),
        "raw_observation_count": len(measurement.observations),
        # The per-operation rows are centralized so that both profiles point
        # at the exact raw evidence used by the report.
        "raw_observations": "raw/observations.jsonl",
    }


def _cross_generation_observations(measurements: list[Measurement]) -> list[dict[str, object]]:
    """Retain matched native src4/src2 observations without calling them ablations.

    Both profiles are built/reopened/verified by the harness and share the
    same oracle.  They still bundle many implementation changes, so this
    deliberately reports evidence and ratios only under a cross-generation
    heading.
    """

    fixtures = sorted({item.fixture for item in measurements})
    rows: list[dict[str, object]] = []
    for fixture in fixtures:
        lex4 = _native_profile(measurements, fixture, "lex4-native")
        src2 = _native_profile(measurements, fixture, "lex2-current-native")
        if lex4 is None or src2 is None:
            rows.append(
                {
                    "fixture": fixture,
                    "status": "unavailable",
                    "reason": "both completed native profiles are required; missing lex4-native or lex2-current-native",
                    "variants": {"automaton_grammar": "lex4-native", "front_code_blocks": "lex2-current-native"},
                }
            )
            continue
        left = _profile_evidence(lex4)
        right = _profile_evidence(src2)
        semantic_equal = left["semantic_digest"] == right["semantic_digest"]
        structure_equal = left["structure_checksum"] == right["structure_checksum"]
        query_equal = left["query_checksum"] == right["query_checksum"]
        timing_equal = left["timing_mode"] == right["timing_mode"] and left["timing_mode"] == "native_self_timed"
        if not (semantic_equal and structure_equal and query_equal and timing_equal):
            reason_parts = []
            if not semantic_equal:
                reason_parts.append("semantic digest mismatch")
            if not structure_equal:
                reason_parts.append("structure checksum mismatch")
            if not query_equal:
                reason_parts.append("query checksum mismatch")
            if not timing_equal:
                reason_parts.append("native reader timing boundary mismatch")
            rows.append(
                {
                    "fixture": fixture,
                    "status": "unavailable",
                    "reason": "; ".join(reason_parts),
                    "variants": {"automaton_grammar": left, "front_code_blocks": right},
                    "oracle_equal": False,
                    "raw_observations": "raw/observations.jsonl",
                }
            )
            continue

        def ratio(metric: str) -> float | None:
            a = left.get(metric)
            b = right.get(metric)
            if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or b == 0:
                return None
            return a / b

        rows.append(
            {
                "fixture": fixture,
                "status": "measured_cross_generation",
                "control": "same fixture/oracle and matched native_self_timed reader boundary; not same compiler",
                "oracle_equal": True,
                "semantic_digest": left["semantic_digest"],
                "structure_checksum": left["structure_checksum"],
                "query_checksum": left["query_checksum"],
                "variants": {"automaton_grammar": left, "front_code_blocks": right},
                "ratios": {
                    "artifact_bytes": ratio("artifact_bytes"),
                    "build_ns": ratio("build_ns"),
                    "open_ns": ratio("open_ns"),
                    "verify_ns": ratio("verify_ns"),
                    "exact_reader_p50_ns": ratio("exact_reader_p50_ns"),
                    "prefix_interval_reader_p50_ns": ratio("prefix_interval_reader_p50_ns"),
                    "prefix_enumerate_reader_p50_ns": ratio("prefix_enumerate_reader_p50_ns"),
                    "render_reader_p50_ns": ratio("render_reader_p50_ns"),
                },
                "raw_observations": "raw/observations.jsonl",
            }
        )
    return rows


def _component_variant(value: object) -> dict[str, object] | None:
    if not isinstance(value, dict):
        return None
    metrics = value.get("metrics")
    if isinstance(metrics, dict):
        merged = dict(value)
        merged.update(metrics)
        return merged
    return dict(value)


def _measured_entropy_ablation(evidence: object) -> dict[str, object] | None:
    """Validate the component probe before allowing a measured row.

    A JSON claim is insufficient by itself: both variants need complete bytes,
    independent verification, an equal oracle digest, and non-empty raw
    observations at exactly one shared reader timing boundary.
    """

    if not isinstance(evidence, dict):
        return None
    candidate = evidence.get("entropy_vs_packed")
    if candidate is None and evidence.get("name") == "entropy_vs_packed":
        candidate = evidence
    if not isinstance(candidate, dict) or candidate.get("status") not in {"measured", "pass"}:
        return None
    evidence_paths = candidate.get("evidence_paths")
    if not isinstance(evidence_paths, dict) or not evidence_paths:
        # The measured row must point to the retained ledger/provenance; an
        # empty object would make the claim impossible to audit after staging.
        return None
    if any(not isinstance(path, str) or not path or path.startswith("memory://") for path in evidence_paths.values()):
        return None

    def validate_pair(pair: object) -> dict[str, object] | None:
        if not isinstance(pair, dict) or pair.get("status") not in {"measured", "pass"}:
            return None
        variants = pair.get("variants")
        if not isinstance(variants, dict):
            return None
        entropy = _component_variant(variants.get("entropy"))
        packed = _component_variant(variants.get("packed"))
        if entropy is None or packed is None:
            return None
        required = ("artifact_bytes", "artifact", "artifact_sha256", "build_ns", "open_ns", "verify_ns")
        for variant in (entropy, packed):
            if any(not isinstance(variant.get(key), (str, int)) for key in required):
                return None
            artifact = variant.get("artifact")
            if not isinstance(artifact, str) or not artifact or artifact.startswith("memory://"):
                # A digest or an in-memory label is not a retained complete wire.
                # The artifact manifest must be able to hash the actual bytes.
                return None
            artifact_sha256 = variant.get("artifact_sha256")
            if (
                not isinstance(artifact_sha256, str)
                or len(artifact_sha256) != 64
                or any(character not in "0123456789abcdefABCDEF" for character in artifact_sha256)
            ):
                return None
            if not isinstance(variant.get("artifact_bytes"), int) or variant["artifact_bytes"] <= 0:
                return None
            if any(not isinstance(variant.get(key), int) or variant[key] < 0 for key in ("build_ns", "open_ns", "verify_ns")):
                return None
            if variant.get("verified") is not True or ("semantic_equal" in variant and variant.get("semantic_equal") is not True):
                return None
            if not isinstance(variant.get("raw_observation_count"), int) or variant["raw_observation_count"] <= 0:
                return None
            raw_observations = variant.get("raw_observations")
            if not isinstance(raw_observations, str) or not raw_observations or raw_observations.startswith("memory://"):
                return None
        oracle = pair.get("oracle_digest", pair.get("semantic_digest"))
        if not isinstance(oracle, str) or not oracle:
            return None
        if entropy.get("oracle_digest", oracle) != oracle or packed.get("oracle_digest", oracle) != oracle:
            return None
        entropy_boundary = entropy.get("timing_boundary")
        packed_boundary = packed.get("timing_boundary")
        if not isinstance(entropy_boundary, str) or entropy_boundary == "" or entropy_boundary != packed_boundary:
            return None
        reader_entropy = entropy.get("reader_p50_ns")
        reader_packed = packed.get("reader_p50_ns")
        if not isinstance(reader_entropy, (int, float)) or not isinstance(reader_packed, (int, float)) or reader_packed == 0:
            return None
        return {
            "lane": pair.get("lane"),
            "oracle_digest": oracle,
            "timing_boundary": entropy_boundary,
            "measurements": {
                "entropy": entropy,
                "packed": packed,
            },
            "ratios": {
                "artifact_bytes": entropy["artifact_bytes"] / packed["artifact_bytes"],
                "build_ns": entropy["build_ns"] / packed["build_ns"] if packed["build_ns"] else None,
                "open_ns": entropy["open_ns"] / packed["open_ns"] if packed["open_ns"] else None,
                "verify_ns": entropy["verify_ns"] / packed["verify_ns"] if packed["verify_ns"] else None,
                "reader_p50_ns": reader_entropy / reader_packed,
            },
        }

    lane_candidates = candidate.get("lanes")
    if isinstance(lane_candidates, list):
        if not lane_candidates:
            return None
        lanes = [validate_pair(pair) for pair in lane_candidates]
        if any(lane is None for lane in lanes):
            return None
        return {
            "name": "entropy_vs_packed",
            "variants": ["entropy", "packed"],
            "status": "measured",
            "control": "same canonical src4/entropy.zig values/options; forced strategies",
            "oracle_equal": True,
            "lanes": lanes,
            "evidence_paths": evidence_paths,
        }

    pair = validate_pair(candidate)
    if pair is None:
        return None
    return {
        "name": "entropy_vs_packed",
        "variants": ["entropy", "packed"],
        "status": "measured",
        "control": "same canonical src4/entropy.zig values/options; forced strategies",
        "oracle_equal": True,
        "oracle_digest": pair["oracle_digest"],
        "timing_boundary": pair["timing_boundary"],
        "measurements": pair["measurements"],
        "ratios": pair["ratios"],
        "evidence_paths": evidence_paths,
    }


def _build_ablations(*, measurements: list[Measurement], component_evidence: object | None) -> list[dict[str, object]]:
    rows = [dict(item) for item in ABLATIONS]
    entropy = _measured_entropy_ablation(component_evidence)
    for row in rows:
        if row["name"] == "entropy_vs_packed" and entropy is not None:
            row.clear()
            row.update(entropy)
    return rows


def build_document(*, run_id: str, config: dict[str, object], measurements: list[Measurement], unavailable: list[dict[str, object]], process: dict[str, object], provenance: dict[str, object], artifact_manifest: list[dict[str, object]], historical_bench2: dict[str, object] | None = None, component_evidence: object | None = None) -> dict[str, object]:
    validate(measurements)
    fixtures = sorted({measurement.fixture for measurement in measurements} | {str(item.get("fixture")) for item in unavailable})
    comparisons: list[dict[str, object]] = []
    for fixture in fixtures:
        # A native LEX4 profile is the only one allowed to support a native
        # claim. The independent mock remains projection data; actual LEX2 is
        # a separately identified native implementation and valid baseline.
        # every valid external baseline gets its own explicit row so an
        # available SQLite/StarDict/SLOB/dict-index adapter cannot disappear
        # from the comparison merely because the first campaign lacked one.
        for baseline in COMPARISON_BASELINES:
            comparisons.append(_comparison(measurements, fixture, "lex4-native", baseline, "artifact_bytes"))
            comparisons.append(_comparison(measurements, fixture, "lex4-native", baseline, "exact.reader_p50_ns"))
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "run_id": run_id,
        "config": config,
        "measurements": [_measurement_json(item) for item in measurements],
        "unavailable": unavailable,
        "comparisons": comparisons,
        "historical_bench2": historical_bench2 or {"status": "unavailable", "reason": "not supplied", "profiles": []},
        "ablations": _build_ablations(measurements=measurements, component_evidence=component_evidence),
        "cross_generation_observations": _cross_generation_observations(measurements),
        "process": process,
        "provenance": provenance,
        # The complete byte-level list is retained in hashes.tsv.  Embedding
        # the list here would make the report self-referential (its own digest
        # would change every time the list changed), so the report stores the
        # count and explicit manifest path while hashes.tsv stores every row.
        "artifact_manifest": {"file_count": len(artifact_manifest), "file_count_before_report": len(artifact_manifest), "path": "hashes.tsv", "manifest_self_excluded": True},
        "claims": {
            "projection": "All external/reference rows use the same entry/key/definition projection; rich graph checks apply only to graph-capable profiles.",
            "measurement": "No native LEX4 claim is emitted unless a profile has adapter_kind=native_implementation and completed all semantic checks.",
            "rss": "Process RSS is aggregate to this driver process and is not attributable to an individual format or adapter.",
            "timing": "Reader latency is measured around one in-process operation or self-reported around one native reader operation; only native profiles expose JSONL transport, which is retained separately and never used as native reader latency. Cross-profile latency ratios require matching timing boundaries; host-operation external timings remain raw evidence rather than native speedup claims.",
            "size": "Per-profile artifact_bytes includes every regular file in that adapter bundle; hashes.tsv retains every completed run byte except its own self-hash.",
            "historical_bench2": "Existing bench2 native timings are retained as a separately hashed historical reference; they are not current measurements or ratios unless semantic identity is proven.",
        },
    }


def write_json(document: dict[str, object], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _fmt(value: object, *, scale: float = 1.0, digits: int = 3) -> str:
    if value is None:
        return "—"
    if isinstance(value, (int, float)):
        return f"{value / scale:,.{digits}f}" if scale != 1 else f"{value:,}"
    return str(value)


def render_markdown(document: dict[str, object]) -> str:
    measurements = document.get("measurements", [])
    lines = [
        "# LEX4 benchmark report",
        "",
        "This report is generated from `benchmark.json`; `raw/observations.jsonl` retains every warmup and measured operation.",
        "",
        "## Reproduction and boundaries",
        "",
        f"- Run: `{document.get('run_id', 'unknown')}`.",
        f"- Configuration: `{json.dumps(document.get('config', {}), sort_keys=True)}`.",
        "- Build, open, and verify are separate phases. Semantic checking occurs outside timed adapter calls.",
        "- Prefix interval and prefix enumeration are distinct operation classes; interval metadata for enumeration is fetched after its timer stops.",
        "- Select, render, and bounded snippet operations are part of the same workload and remain in JSON/raw observations.",
        "- Missing metrics are shown as `—` and remain unavailable in JSON; no zero is substituted.",
        "",
        "## Profiles",
        "",
        "| Fixture | Adapter | Kind | Native | Timing source | Bytes | Build ms | Open us | Verify us | Reader exact p50 us | Transport exact p50 us | Reader prefix interval p50 us | Reader prefix enumeration p50 us | Reader render p50 us |",
        "|---|---|---|:---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for measurement in measurements:
        adapter = measurement.get("adapter", {})
        metrics = measurement.get("metrics", {})
        lines.append(
            f"| {measurement.get('fixture')} | `{adapter.get('label', 'unknown')}` | `{adapter.get('adapter_kind', 'unknown')}` | "
            f"{'yes' if adapter.get('native') else 'no'} | `{adapter.get('timing_mode', 'unknown')}` | "
            f"{_fmt(metrics.get('artifact_bytes'))} | {_fmt(metrics.get('build_ns'), scale=1_000_000)} | "
            f"{_fmt(metrics.get('open_ns'), scale=1_000)} | {_fmt(metrics.get('verify_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('exact.reader_p50_ns'), scale=1_000)} | {_fmt(metrics.get('exact.transport_p50_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('prefix_interval.reader_p50_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('prefix_enumerate.reader_p50_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('render.reader_p50_ns'), scale=1_000)} |"
        )
    lines += [
        "",
        "## Explicit measured sample counts",
        "",
        "Counts are recorded independently of repetition scheduling; a missing class is unavailable/error, never a zero-valued timing.",
        "",
        "| Fixture | Adapter | Operation sample counts |",
        "|---|---|---|",
    ]
    for measurement in measurements:
        adapter = measurement.get("adapter", {})
        metrics = measurement.get("metrics", {})
        lines.append(
            f"| {measurement.get('fixture')} | `{adapter.get('label', 'unknown')}` | "
            f"`{json.dumps(metrics.get('sample_counts', {}), sort_keys=True)}` |"
        )
    lines += [
        "",
        "## Cardinality-class timings",
        "",
        "Exact hit/miss and prefix zero/one/many/pathological classes are retained independently; `—` means the fixture does not define that class.",
        "",
        "| Fixture | Adapter | Reader exact hit p50 us | Reader exact miss p50 us | Reader prefix zero p50 us | Reader prefix one p50 us | Reader prefix many p50 us | Reader prefix pathological p50 us |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for measurement in measurements:
        adapter = measurement.get("adapter", {})
        metrics = measurement.get("metrics", {})
        lines.append(
            f"| {measurement.get('fixture')} | `{adapter.get('label', 'unknown')}` | "
            f"{_fmt(metrics.get('exact.hit_duplicate.reader_p50_ns'), scale=1_000)} | {_fmt(metrics.get('exact.miss.reader_p50_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('prefix_interval.zero.reader_p50_ns'), scale=1_000)} | {_fmt(metrics.get('prefix_interval.one.reader_p50_ns'), scale=1_000)} | "
            f"{_fmt(metrics.get('prefix_interval.many.reader_p50_ns'), scale=1_000)} | {_fmt(metrics.get('prefix_interval.pathological.reader_p50_ns'), scale=1_000)} |"
        )
    lines += ["", "## Comparisons", "", "Only a completed `native_implementation` row with a matching timing boundary can produce a latency ratio; missing or mismatched baselines remain `unavailable`.", "", "| Fixture | Metric | Baseline | Status | Ratio (LEX4 / baseline) | Reason |", "|---|---|---|---|---:|---|"]
    for item in document.get("comparisons", []):
        ratio = item.get("ratio_left_over_right")
        lines.append(
            f"| {item.get('fixture')} | {item.get('metric')} | `{item.get('right')}` | {item.get('status')} | {_fmt(ratio)} | {item.get('reason', '')} |"
        )
    historical = document.get("historical_bench2", {})
    lines += ["", "## Historical bench2 native reference", "", "These rows are retained from bench2's direct native timing boundary and are never merged with current JSONL measurements or ratios.", "", "| Fixture | Format | Variant | Exact p50 ns | Render p50 ns | Comparable to current |", "|---|---|---|---:|---:|:---:|"]
    profiles = historical.get("profiles", []) if isinstance(historical, dict) else []
    if profiles:
        for profile in profiles:
            metrics = profile.get("metrics", {})
            lines.append(
                f"| {profile.get('fixture')} | `{profile.get('format')}` | `{profile.get('variant')}` | "
                f"{_fmt(metrics.get('exact.p50_ns'))} | {_fmt(metrics.get('render.p50_ns'))} | "
                f"{'yes' if profile.get('comparable_to_current') else 'no'} |"
            )
    else:
        lines.append("| — | — | — | — | — | no |")
    lines += ["", "## Availability", ""]
    unavailable = document.get("unavailable", [])
    if unavailable:
        for item in unavailable:
            lines.append(f"- `{item.get('fixture')}/{item.get('adapter')}`: {item.get('reason', 'unavailable')}")
    else:
        lines.append("- No unavailable profiles were emitted.")
    lines += ["", "## Cross-generation observations", "", "The following rows compare the retained native LEX4 artifact (automaton + grammar) with the retained current src2 artifact (front-coded keys + block prose). Both are independently built, reopened, verified, and oracle-checked on the same fixture, and both use the native reader-self timing boundary. They are not controlled ablations because compiler, snapshot, forest, graph, and metadata implementations change together.", "", "| Fixture | Status | Bytes (LEX4/src2) | Exact reader p50 (LEX4/src2) | Render reader p50 (LEX4/src2) | Oracle equal |", "|---|---|---:|---:|---:|:---:|"]
    for item in document.get("cross_generation_observations", []):
        variants = item.get("variants", {})
        left_value = variants.get("automaton_grammar", {}) if isinstance(variants, dict) else {}
        right_value = variants.get("front_code_blocks", {}) if isinstance(variants, dict) else {}
        left = left_value if isinstance(left_value, dict) else {}
        right = right_value if isinstance(right_value, dict) else {}
        lines.append(
            f"| {item.get('fixture')} | {item.get('status')} | "
            f"{_fmt(left.get('artifact_bytes'))} / {_fmt(right.get('artifact_bytes'))} | "
            f"{_fmt(left.get('exact_reader_p50_ns'), scale=1_000)} / {_fmt(right.get('exact_reader_p50_ns'), scale=1_000)} | "
            f"{_fmt(left.get('render_reader_p50_ns'), scale=1_000)} / {_fmt(right.get('render_reader_p50_ns'), scale=1_000)} | "
            f"{'yes' if item.get('oracle_equal') else 'no'} |"
        )
    lines += ["", "## Ablations", "", "A row is measured only when both variants are real encodings/readers (or canonical forced component builders) and the retained evidence proves complete bytes, independent open/verify, equal oracle output, matched timing boundaries, raw observations, and provenance. Rows marked unavailable include the exact missing production switch/API; no zero or projected value is substituted.", ""]
    for item in document.get("ablations", []):
        reason = item.get("reason", "")
        control = item.get("control")
        suffix = f" (control: {control})" if control else ""
        lines.append(f"- `{item['name']}` ({', '.join(item['variants'])}): **{item['status']}**{suffix} — {reason}")
        if item.get("status") == "measured":
            lane_rows = item.get("lanes")
            if isinstance(lane_rows, list):
                for lane_row in lane_rows:
                    lane_measurements = lane_row.get("measurements", {}) if isinstance(lane_row, dict) else {}
                    entropy = lane_measurements.get("entropy", {}) if isinstance(lane_measurements, dict) else {}
                    packed = lane_measurements.get("packed", {}) if isinstance(lane_measurements, dict) else {}
                    lines.append(
                        f"  - lane `{lane_row.get('lane') if isinstance(lane_row, dict) else 'unknown'}` bytes: {_fmt(entropy.get('artifact_bytes'))} / {_fmt(packed.get('artifact_bytes'))}; "
                        f"reader p50: {_fmt(entropy.get('reader_p50_ns'), scale=1_000)} / {_fmt(packed.get('reader_p50_ns'), scale=1_000)} us; "
                        f"oracle: `{lane_row.get('oracle_digest', 'missing') if isinstance(lane_row, dict) else 'missing'}`; raw: `{entropy.get('raw_observations', 'missing')}`"
                    )
            else:
                measurements = item.get("measurements", {})
                entropy = measurements.get("entropy", {}) if isinstance(measurements, dict) else {}
                packed = measurements.get("packed", {}) if isinstance(measurements, dict) else {}
                lines.append(
                    f"  - bytes: {_fmt(entropy.get('artifact_bytes'))} / {_fmt(packed.get('artifact_bytes'))}; "
                    f"reader p50: {_fmt(entropy.get('reader_p50_ns'), scale=1_000)} / {_fmt(packed.get('reader_p50_ns'), scale=1_000)} us; "
                    f"oracle: `{item.get('oracle_digest', 'missing')}`; raw: `{entropy.get('raw_observations', 'missing')}`"
                )
        evidence = item.get("source_evidence")
        if evidence:
            lines.append(f"  - source evidence: {', '.join(str(value) for value in evidence)}")
    lines += ["", "## Claims and caveats", "", f"- Projection: {document.get('claims', {}).get('projection')}", f"- Measurement: {document.get('claims', {}).get('measurement')}", f"- Timing: {document.get('claims', {}).get('timing')}", f"- Size: {document.get('claims', {}).get('size')}", f"- Historical bench2: {document.get('claims', {}).get('historical_bench2')}", f"- RSS: {document.get('claims', {}).get('rss')}", "", "`lex2-current-native` is emitted only by the current compiled src2 reader. Historical/projection data remains separately labelled and never substitutes for it.", ""]
    return "\n".join(lines)


def write_markdown(document: dict[str, object], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_markdown(document), encoding="utf-8")


__all__ = [
    "ABLATIONS",
    "COMPARISON_BASELINES",
    "REPORT_SCHEMA_VERSION",
    "build_document",
    "render_markdown",
    "validate",
    "write_json",
    "write_markdown",
]
