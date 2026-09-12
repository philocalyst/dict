#!/usr/bin/env python3
"""Harness failure-mode tests."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from dataclasses import replace

from adapter import AdapterMetadata, ReferenceAdapter, SemanticMismatch, UnavailableAdapter
from harness import HarnessError, _call_adapter, measure_adapter
from oracle import Oracle, make_fixture, workload
from report import build_document


class BadExactAdapter(ReferenceAdapter):
    def query_checksum(self, operations):
        # Let the per-operation semantic gate catch the bad answer, rather
        # than failing earlier on the aggregate checksum.
        return Oracle(self.fixture).query_checksum(operations)

    def exact(self, key):
        values = super().exact(key)
        return values[:-1] if values else [999999]


class SelfTimedAdapter(ReferenceAdapter):
    """Test double for a reader that reports core timing separately."""

    def reader_timed(self, operation):
        return _call_adapter(self, operation), 7

    def __init__(self, fixture):
        super().__init__(fixture)
        self.metadata = replace(self.metadata, timing_mode="native_self_timed")


class HarnessFailureTests(unittest.TestCase):
    def test_semantic_mismatch_is_fatal_and_not_a_partial_measurement(self):
        fixture = make_fixture("flat", 16)
        adapter = BadExactAdapter(fixture, label="bad-reader")
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SemanticMismatch):
                measure_adapter(fixture, adapter, Path(directory) / "bad.bin", repetitions=20, warmup=0)

    def test_reference_measurement_retains_warmups_and_distinct_prefix_modes(self):
        fixture = make_fixture("pathological_prefix", 24)
        adapter = ReferenceAdapter(fixture)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(fixture, adapter, Path(directory) / "ok.bin", repetitions=30, warmup=4)
        self.assertEqual(34, len(measurement.observations))
        self.assertEqual(4, sum(row["phase"] == "warmup" for row in measurement.observations))
        self.assertTrue(any(row["op"] == "prefix_interval" for row in measurement.observations if row["phase"] == "measure"))
        self.assertTrue(any(row["op"] == "prefix_enumerate" for row in measurement.observations if row["phase"] == "measure"))
        self.assertTrue(all(row["expected_cardinality"] == row["observed_cardinality"] for row in measurement.observations))

    def test_reader_and_transport_timings_are_retained_separately(self):
        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(
                fixture, SelfTimedAdapter(fixture), Path(directory) / "timed.bin", repetitions=1, warmup=0
            )
        measured = [row for row in measurement.observations if row["phase"] == "measure"]
        self.assertTrue(measured)
        self.assertTrue(all(row["reader_elapsed_ns"] == 7 for row in measured))
        self.assertTrue(all(row["transport_elapsed_ns"] >= row["reader_elapsed_ns"] for row in measured))
        self.assertEqual(7, measurement.metrics["exact.reader_p50_ns"])
        self.assertGreaterEqual(measurement.metrics["exact.transport_p50_ns"], 7)
        self.assertEqual(len(measured), measurement.metrics["unique_sample_nonce_count"])

    def test_host_profiles_do_not_label_reader_time_as_transport(self):
        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(
                fixture,
                ReferenceAdapter(fixture),
                Path(directory) / "host.bin",
                repetitions=1,
                warmup=0,
            )
        self.assertTrue(all(row["transport_elapsed_ns"] is None for row in measurement.observations))
        self.assertNotIn("exact.transport_p50_ns", measurement.metrics)

    def test_impossible_native_reader_time_is_fatal(self):
        class OverreportingAdapter(ReferenceAdapter):
            def reader_timed(self, operation):
                return _call_adapter(self, operation), 10**18

        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(HarnessError):
                measure_adapter(
                    fixture,
                    OverreportingAdapter(fixture),
                    Path(directory) / "bad-timing.bin",
                    repetitions=1,
                    warmup=0,
                )

    def test_low_repetition_is_stratified_and_keeps_every_timed_class(self):
        fixture = make_fixture("rich", 16)
        operations = workload(fixture, 1)
        names = {operation.op for operation in operations}
        self.assertTrue(
            {
                "exact", "prefix_interval", "prefix_enumerate", "select", "render", "snippet",
                "concept_members", "translations", "relations",
            }.issubset(names)
        )
        self.assertEqual(len(operations), len({operation.sample for operation in operations}))
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(
                fixture, ReferenceAdapter(fixture), Path(directory) / "ok.bin", repetitions=1, warmup=0
            )
        self.assertTrue(all(value > 0 for value in measurement.metrics["sample_counts"].values()))

    def test_interval_only_reader_cannot_pass_enumeration(self):
        class IntervalOnlyAdapter(ReferenceAdapter):
            def prefix_enumerate(self, prefix):
                self.prefix_interval(prefix)
                return []

        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SemanticMismatch):
                measure_adapter(fixture, IntervalOnlyAdapter(fixture), Path(directory) / "bad.bin", repetitions=1, warmup=0)

    def test_harness_does_not_send_a_preflight_query_schedule(self):
        class NoPreflightAdapter(ReferenceAdapter):
            def query_checksum(self, operations):
                raise AssertionError("query schedule was disclosed to adapter")

        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(
                fixture, NoPreflightAdapter(fixture), Path(directory) / "ok.bin", repetitions=1, warmup=0
            )
        self.assertEqual(measurement.metrics["operation_count"], len(workload(fixture, 1)))

    def test_artifact_bytes_include_sidecars_and_drift_is_fatal(self):
        class SidecarAdapter(ReferenceAdapter):
            def __init__(self, fixture, *, mutate=False):
                super().__init__(fixture)
                self.mutate = mutate

            def build(self, artifact):
                super().build(artifact)
                artifact.with_name("sidecar.idx").write_bytes(b"retained-index")

            def open(self, artifact):
                super().open(artifact)
                if self.mutate:
                    artifact.with_name("sidecar.idx").write_bytes(b"changed")

        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "ok.bin"
            measurement = measure_adapter(fixture, SidecarAdapter(fixture), artifact, repetitions=1, warmup=0)
            self.assertEqual(measurement.artifact_bytes, artifact.stat().st_size + len(b"retained-index"))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(HarnessError):
                measure_adapter(fixture, SidecarAdapter(fixture, mutate=True), Path(directory) / "bad.bin", repetitions=1, warmup=0)

    def test_unavailable_profile_is_not_projected_as_zero(self):
        fixture = make_fixture("flat", 16)
        adapter = ReferenceAdapter(fixture)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(fixture, adapter, Path(directory) / "ok.bin", repetitions=18, warmup=2)
        unavailable = {"fixture": "flat", "adapter": "star-dict", "reason": "dependency absent"}
        document = build_document(
            run_id="test", config={}, measurements=[measurement], unavailable=[unavailable], process={}, provenance={}, artifact_manifest=[]
        )
        self.assertEqual("dependency absent", document["unavailable"][0]["reason"])
        self.assertNotIn("artifact_bytes", document["unavailable"][0])
        self.assertTrue(all(value != 0 for value in document["measurements"][0]["metrics"].values() if isinstance(value, int)))

    def test_reference_label_cannot_support_native_comparison(self):
        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(fixture, ReferenceAdapter(fixture), Path(directory) / "ok.bin", repetitions=1, warmup=0)
        # Relabelling a reference projection as lex4-native must not make the
        # report emit a native-vs-reference ratio.
        measurement.adapter = AdapterMetadata(
            "lex4-native", "reference_adapter", "python-reference", False, note="spoof"
        )
        document = build_document(
            run_id="test",
            config={},
            measurements=[measurement],
            unavailable=[],
            process={},
            provenance={},
            artifact_manifest=[],
        )
        self.assertTrue(all(item["status"] == "unavailable" for item in document["comparisons"]))

    def test_report_rejects_cross_boundary_latency_ratio(self):
        fixture = make_fixture("flat", 16)
        with tempfile.TemporaryDirectory() as directory:
            native = measure_adapter(
                fixture,
                SelfTimedAdapter(fixture),
                Path(directory) / "native.bin",
                repetitions=1,
                warmup=0,
            )
            native.adapter = replace(
                native.adapter,
                label="lex4-native",
                adapter_kind="native_implementation",
                native=True,
            )
            host = measure_adapter(
                fixture,
                ReferenceAdapter(fixture),
                Path(directory) / "host.bin",
                repetitions=1,
                warmup=0,
            )
            host.adapter = replace(
                host.adapter,
                label="sqlite/adapter",
                adapter_kind="external_format_adapter",
                native=False,
            )
        document = build_document(
            run_id="test",
            config={},
            measurements=[native, host],
            unavailable=[],
            process={},
            provenance={},
            artifact_manifest=[],
        )
        latency = next(
            item
            for item in document["comparisons"]
            if item["right"] == "sqlite/adapter" and item["metric"] == "exact.reader_p50_ns"
        )
        self.assertEqual("unavailable", latency["status"])
        self.assertIn("timing boundary mismatch", latency["reason"])
        size = next(
            item
            for item in document["comparisons"]
            if item["right"] == "sqlite/adapter" and item["metric"] == "artifact_bytes"
        )
        self.assertEqual("measured", size["status"])


if __name__ == "__main__":
    unittest.main()
