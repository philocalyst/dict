"""LEX5 benchmark protocol and coverage contract.

This module describes the host boundary and its admitted archive-only native
bridge.  It does not answer queries or retain expected-answer schedules.
"""

from __future__ import annotations

from pathlib import Path
from typing import Sequence


PROTOCOL = "LEX5-BENCH/1"
FIXTURES = ("flat", "repeated", "prose_heavy", "pathological_prefix", "rich")
RECORDS = 2048
REPETITIONS = 4000
WARMUP = 600


def releasefast_module_command(
    *,
    root_source: str | Path,
    library_source: str | Path,
    output: str | Path,
    root_module: str = "root",
    library_module: str = "src5",
) -> list[str]:
    """Return the required two-module Zig 0.16 ReleaseFast command shape.

    Zig resets optimization settings at every ``-M``.  Keeping ``-O
    ReleaseFast`` immediately before each module is therefore part of this
    host contract, not an implementation detail that can be inferred later.
    The command is recorded by the host harness and executed by
    ``bench5.native`` when correctness is explicitly run.
    """

    return [
        "zig",
        "build-exe",
        "--dep",
        library_module,
        "-O",
        "ReleaseFast",
        f"-M{root_module}={Path(root_source)}",
        "-O",
        "ReleaseFast",
        f"-M{library_module}={Path(library_source)}",
        f"-femit-bin={Path(output)}",
    ]


def has_releasefast_before_each_module(command: Sequence[str]) -> bool:
    """Check the exact per-module optimization rule for a command list."""

    module_positions = [index for index, value in enumerate(command) if value.startswith("-M")]
    return bool(module_positions) and all(
        index >= 2 and list(command[index - 2 : index]) == ["-O", "ReleaseFast"]
        for index in module_positions
    )


def protocol_contract() -> dict[str, object]:
    """Return the proposed LEX5 JSONL contract for root review."""

    return {
        "status": "candidate_archive_bridge_root_review_pending",
        "protocol": PROTOCOL,
        "identity": {
            "candidate_label": "LEX5",
            "control_label": "immutable accepted LEX4",
            "control_path": "experiments/frontier/unification-20260908/paired-release/artifacts/<fixture>/0/candidate/dictionary.lex4",
            "native_adapter": "bench5.native.NativeBridge; archive-only verify/audit/server against frozen foundation-13; root review pending; timing not run",
        },
        "phases": {
            "build": {
                "entrypoint": "--bench5-build",
                "argv": [
                    "--bench5-build",
                    "--fixture",
                    "NAME",
                    "--records",
                    "N",
                    "--corpus",
                    "INPUT.tsv",
                    "--semantic-input",
                    "FIXTURE.json",
                    "--output",
                    "ARTIFACT",
                ],
                "boundary": "host wall time from child launch through non-empty primary artifact and retained sidecar discovery",
                "includes": ["process launch", "compiler/encoder work", "artifact and sidecar writes"],
                "excludes": ["open", "verify", "queries", "oracle comparison"],
            },
            "open": {
                "entrypoint": "--bench5-server --artifact ARTIFACT",
                "boundary": "host wall time from server launch through one validated ready event",
                "includes": ["process launch", "mapping/loading", "artifact opening", "validate/verify work performed before readiness", "format readiness"],
                "excludes": ["query requests", "oracle work", "response comparison"],
                "note": "If the server validates before emitting ready, that verification is part of open_ns even when a separate --bench5-verify phase is also timed.",
            },
            "verify": {
                "entrypoint": "--bench5-verify --artifact ARTIFACT",
                "boundary": "separate --bench5-verify subprocess wall time from child launch through completion",
                "includes": ["process launch", "artifact opening/loading", "full structural and semantic artifact verification"],
                "excludes": ["build", "server startup", "query timing"],
            },
            "query": {
                "boundary": "native reader_self time around exactly one operation; outer request/response transport retained separately",
                "includes": ["one requested reader operation"],
                "excludes": ["JSON parsing", "JSON serialization", "pipe I/O", "oracle answers", "checksums", "prefix interval metadata added after enumeration"],
            },
            "render": {
                "boundary": "reader_self time around one byte-emitting render or snippet operation",
                "includes": ["grammar expansion or borrowed byte emission for one requested result"],
                "excludes": ["response serialization", "transport", "oracle comparison"],
            },
        },
        "build_contract": {
            "native_cli_status": "implemented build/verify/audit/server; candidate correctness sweep passed locally; root review and timing pending",
            "primary_artifact": "non-empty regular file at --output",
            "sidecars": "regular files beneath the primary artifact parent; no symlinks; counted and hashed",
            "source_inputs": "canonical fixture data only; expected answers and query schedules are forbidden",
            "optimization": "-O ReleaseFast must appear immediately before every -M module declaration",
        },
        "server_contract": {
            "ready_event": {
                "protocol": PROTOCOL,
                "event": "ready",
                "artifact_bytes": "actual primary file length",
                "book_bytes": "actual @sizeOf(Book) for the opened native reader state, distinct from artifact_bytes",
                "scratch_ids": "archive-derived retained integer-result capacity",
                "scratch_relations": "archive-derived retained relation-result capacity",
                "scratch_bytes": "archive-derived maximum scalar render capacity",
                "scratch_key": "archive-derived maximum native key output capacity",
                "scratch_relation_text": "archive-derived sum of materialized relation text bytes",
            },
            "request_required": ["protocol", "request_id", "op", "sample"],
            "request_optional": ["key", "id", "limit", "language", "predicate", "timing_mode"],
            "request_forbidden": [
                "expected",
                "oracle",
                "answers",
                "oracle_digest",
                "query_checksum",
                "schedule",
                "query_schedule",
                "workload",
                "category",
            ],
            "timed_mode": "optional timing_mode=reader_self; native clock covers one dispatched reader operation and emits reader_elapsed_ns; campaign remains disabled",
            "response_envelope": {"protocol": PROTOCOL, "request_id": "echo", "sample": "echo", "ok": True, "result": "operation-specific object"},
            "stdout": "one readiness line followed by one flushed response per request; no diagnostics",
            "stderr": "diagnostics permitted outside the JSONL protocol and timing boundaries",
        },
        "operations": {
            "exact": {"request": ["key"], "result": {"ids": "ordered integer array"}},
            "prefix_interval": {"request": ["key"], "result": {"lo": "integer", "hi": "integer"}},
            "prefix_enumerate": {
                "request": ["key"],
                "result": {"ids": "ordered integer array", "lo": "integer", "hi": "integer"},
                "interval_metadata": "native response; host comparison does not fill or derive bounds",
            },
            "select": {"request": ["id"], "result": {"id": "integer", "key": "UTF-8 string", "rank": "integer"}},
            "render": {"request": ["id"], "result": {"bytes_hex": "hex string"}, "timing_note": "raw bytes are produced into retained scratch; hex serialization is after the reader clock"},
            "snippet": {"request": ["id", "limit"], "result": {"bytes_hex": "hex string"}, "timing_note": "raw bytes are produced into retained scratch; hex serialization is after the reader clock"},
            "concept_members": {"request": ["id"], "result": {"members": "ordered integer array"}},
            "translations": {"request": ["id", "language"], "result": {"members": "ordered integer array"}},
            "relations": {"request": ["id", "predicate"], "result": {"relations": "ordered relation records"}},
            "structure_checksum": {"request": [], "result": {"sha256": "64-character hex string"}, "phase": "preflight only; not a timed query"},
        },
    }


def coverage_contract() -> dict[str, object]:
    """Return the semantic coverage required before LEX5 admission."""

    return {
        "status": "oracle_and_candidate_archive_bridge_root_review_pending",
        "fixture_matrix": list(FIXTURES),
        "flat_oracle_operations": {
            "exact": ["duplicate-key hit", "ordinary miss", "empty-key miss", "UTF-8 miss"],
            "prefix_interval": ["empty many", "zero", "one", "many", "pathological-prefix many"],
            "prefix_enumerate": ["same cardinality classes as prefix_interval; separately timed"],
            "select": ["first ranked entries", "sparse/non-contiguous source IDs in rich only"],
            "render": ["full definition bytes", "UTF-8 prose"],
            "snippet": ["bounded prefixes of rendered bytes"],
        },
        "rich_oracle_operations": ["concept_members", "translations", "relations", "structure_checksum"],
        "src5_public_surface_pending": {
            "coherent_input": ["DocumentInput", "OccurrenceInput", "EventInput", "KeyInput", "Input"],
            "dependent_query": ["lookup(prefix)", "lookup(...).sources(.realization).descendants(.{kind=...})", "descendants(.sense)", "descendants(.definition)", "texts().next", "text.render"],
            "binding_projection": {
                "attached": "source.bindings(kind, attached)",
                "within": "source.bindings(kind, within)",
                "row": "{ binding_id, record, anchor }",
                "deduplication": "uniqueRecords is an explicit terminal; the physical binding projection does not deduplicate",
            },
            "source_scope_rules": ["source scopes remain distinct from record references", "empty handles are retained"],
            "occurrence_queries": ["descendants", "attributeByName", "lookupXmlId", "effectiveLanguage", "events", "plainText"],
            "proof_rules": ["child events are sole containment authority", "typed references retain domains", "disjoint descendant scopes never widen", "text/comment/PI share one content stream"],
            "adapter_status": "candidate archive-only native bridge implemented against frozen foundation-13; reader_self boundary prepared, root review and timing remain pending",
        },
        "answer_rule": "every scheduled operation is answered independently by bench4.oracle; only digests/counts may be retained in readiness artifacts, never the full schedule or expected-answer table",
    }


def comparison_entrypoints(repo: str | Path) -> dict[str, object]:
    """Return Nix-wrapped source2/external comparison entry points.

    These commands are documentation and future entry points only.  The
    preparation scaffold does not invoke them and emits no comparison result.
    """

    root = Path(repo)
    common = [
        "python3",
        "bench4/run.py",
        "--repo",
        ".",
        "--records",
        str(RECORDS),
        "--repetitions",
        str(REPETITIONS),
        "--warmup",
        str(WARMUP),
        "--fixtures",
        *FIXTURES,
    ]
    nix_prefix = ["nix", "develop", ".#", "--command"]
    accepted_control = "experiments/frontier/unification-20260908/final/bin/lex4-final-release"
    source2 = "bench4/zig-out/bin/src2-bench"
    benchmark_root = "experiments/frontier/lex5-20260909/benchmark/comparisons"
    return {
        "status": "entrypoints_documented_not_run",
        "nix_shell": "nix develop .# --command",
        "accepted_lex4_control": {
            "label": "immutable accepted LEX4",
            "protocol": "LEX4-BENCH/1 via unchanged bench4/run.py; comparison-only, not a LEX5 adapter",
            "executable": accepted_control,
            "command": [*nix_prefix, *common, "--native-executable", accepted_control, "--out-root", f"{benchmark_root}/lex4-control"],
        },
        "source2": {
            "label": "current src2 comparison entry point",
            "protocol": "LEX4-BENCH/1 via unchanged bench4/run.py; comparison-only, not a LEX5 adapter",
            "executable": source2,
            "command": [*nix_prefix, *common, "--native-executable", accepted_control, "--src2-executable", source2, "--out-root", f"{benchmark_root}/src2"],
            "status": "not run by host scaffold; must remain separately labelled from LEX5",
        },
        "external": {
            "label": "bench4 external-format profiles",
            "protocol": "host bench4 adapters; comparison-only, not a LEX5 adapter",
            "profiles": ["sqlite/adapter", "stardict/adapter", "dict-index/adapter", "slob/adapter", "slob/adapter-lzma2"],
            "command": [*nix_prefix, *common, "--out-root", f"{benchmark_root}/external"],
            "status": "not run by host scaffold; rich graph semantics remain unavailable for flat external formats",
        },
        "lex5_native": {
            "label": "LEX5 candidate",
            "command_shape": ["<LEX5_EXECUTABLE>", "--bench5-build/--bench5-verify/--bench5-server", "..."],
            "status": "candidate correctness bridge; root review pending; timing not run",
        },
        "repo_path_note": f"commands execute from {root.resolve()} with immutable control paths recorded above",
    }


def timing_contract() -> dict[str, object]:
    """Return the host-side timing labels used by the future harness."""

    return {
        "status": "definitions_only_no_measurements",
        "build_ns": "child launch through completed artifact write and sidecar discovery",
        "open_ns": "server launch through validated ready event after opening/loading artifact, including any validate/verify work completed before ready",
        "verify_ns": "separate --bench5-verify subprocess wall time from child launch through completion; includes artifact open/load and verification, not pure verifier cost, and is not folded into open or query",
        "verify_reader_ns": "reserved for a future native inner verify-reader measurement; not emitted by this scaffold",
        "open_envelope_reader_ns": "reserved for a future native inner open-envelope measurement; not emitted by this scaffold",
        "reader_elapsed_ns": "native self-reported time around one reader operation only",
        "transport_elapsed_ns": "outer request/response wall time for native JSONL only",
        "outer_call_ns": "host perf_counter wall time around the complete adapter call",
        "render_reader_ns": "reader-only byte expansion/emission; serialization and transport excluded",
        "oracle_and_comparison": "always outside all adapter timing boundaries",
        "raw_observations": "future run must retain chronological warmup and measured rows; no in-place percentile mutation",
        "reader_boundary": "request JSON decode/field validation ends before the clock; native lookup/expansion, relation text materialization into retained scratch, and result writes are inside; JSON response construction/escaping, raw-byte hex encoding, transport, oracle comparison, and checksums are outside",
        "scratch_policy": "IDs, relation rows, relation text, and render/snippet bytes use caller-owned retained scratch sized from opened archive counts/values/text lengths; capacities and retained state are reported outside query timing",
        "pairing_policy": "future campaign uses one unique attempt with five chronological all-fixture batches; pair order alternates within each batch and the first lane flips by batch; no best-of-runs selection",
        "rank_select": "native Book.keys.select(rank) is used; no adapter-side index is introduced",
        "prefix_miss_behavior": "canonical bridge exposes native foundation-13 prefix ranges, including checked insertion boundaries for absent paths; no adapter repair is applied",
        "paired_driver": {
            "entrypoint": "bench5.timing.run_paired(authorize_timing=True)",
            "gate": "authorize_timing must be explicitly true; false remains inert",
            "pins": "machine-generated foundation13-correctness.json artifacts/executable plus immutable paired-release LEX4 controls",
            "batches": "five chronological fixture batches using the canonical 2048-record, 4000-repetition, 600-warmup plan",
            "preflight": "candidate full archive audit, then separate control/candidate verify subprocess walls, then server ready/open walls",
            "build": "not run in the pinned timing attempt; build_ns is explicitly unavailable rather than a rebuild of frozen bytes",
            "provenance": "new unique attempt directory, full before/after source/executable/artifact hashes, phase stdout/stderr/exit records, and raw host failure records",
            "native_cryptintegrity": "not exposed by this driver",
        },
    }


__all__ = [
    "FIXTURES",
    "PROTOCOL",
    "RECORDS",
    "REPETITIONS",
    "WARMUP",
    "comparison_entrypoints",
    "coverage_contract",
    "has_releasefast_before_each_module",
    "protocol_contract",
    "releasefast_module_command",
    "timing_contract",
]
