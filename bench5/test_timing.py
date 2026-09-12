"""No-clock tests for the prepared LEX5 timing boundary."""

from __future__ import annotations

import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

from bench4.oracle import Operation, Oracle, make_fixture
from bench5.timing import (
    CONTROL_PROTOCOL,
    CONTROL_SHA256,
    JsonlTimedClient,
    MeasurementNotAuthorized,
    PROTOCOL,
    TimingError,
    build_plan,
    control_provenance,
    normalize_result,
    run_paired,
    timed_request,
    validate_timed_response,
)


class TimingPreparationTests(unittest.TestCase):
    def test_plan_is_five_fixture_count_only_and_alternates_order(self):
        plan = build_plan(records=16, repetitions=4, warmup=2)
        self.assertEqual(30, plan.pair_count())
        self.assertEqual(("lex4-control", "lex5-candidate"), plan.lane_order(0))
        self.assertEqual(("lex5-candidate", "lex4-control"), plan.lane_order(1))
        value = plan.as_dict()
        self.assertNotIn("operations", value)
        self.assertEqual("not retained in plan or artifacts", value["query_schedule"])
        five = build_plan(records=16, repetitions=4, warmup=2, batch_count=5)
        self.assertEqual(150, five.pair_count())
        self.assertEqual(("lex4-control", "lex5-candidate"), five.lane_order(30))

    def test_timed_request_is_strict_and_answer_free(self):
        operation = Operation("exact", key="alpha", category="many", sample=7)
        candidate = timed_request(operation, 3)
        control = timed_request(operation, 3, protocol=CONTROL_PROTOCOL)
        self.assertEqual(PROTOCOL, candidate["protocol"])
        self.assertEqual(CONTROL_PROTOCOL, control["protocol"])
        self.assertEqual("reader_self", candidate["timing_mode"])
        self.assertNotIn("category", candidate)
        self.assertFalse(set(candidate) & {"expected", "oracle", "answers", "query_checksum", "schedule", "workload"})

    def test_timed_response_requires_exact_reader_self_envelope(self):
        response = {
            "protocol": PROTOCOL,
            "request_id": 2,
            "sample": 9,
            "ok": True,
            "timing_mode": "reader_self",
            "reader_elapsed_ns": 17,
            "result": {"ids": [], "cardinality": 0},
        }
        self.assertEqual(response, validate_timed_response(response, request_id=2, sample=9))
        bad = dict(response)
        bad["unexpected"] = 1
        with self.assertRaises(TimingError):
            validate_timed_response(bad, request_id=2, sample=9)

    def test_candidate_prefix_bounds_are_normalized_from_wire(self):
        fixture = make_fixture("flat", 16)
        oracle = Oracle(fixture)
        operation = Operation("prefix_enumerate", key="", sample=0)
        value = {
            "ids": oracle.prefix_ids(""),
            "lo": 0,
            "hi": len(oracle.prefix_ids("")),
            "cardinality": len(oracle.prefix_ids("")),
        }
        normalized = normalize_result(operation, value, lane="lex5-candidate")
        self.assertEqual(value["lo"], normalized["lo"])
        self.assertEqual(value["hi"], normalized["hi"])

    def test_control_identity_is_pinned_without_running_a_campaign(self):
        value = control_provenance()
        self.assertEqual(CONTROL_SHA256, value["sha256"])
        self.assertEqual("immutable accepted LEX4", value["label"])

    def test_campaign_entrypoint_is_held_without_authorization(self):
        with self.assertRaises(MeasurementNotAuthorized):
            run_paired()

    def test_authorized_driver_rejects_noncanonical_plan_before_staging(self):
        with self.assertRaises(TimingError):
            run_paired(authorize_timing=True, plan=build_plan(records=16, repetitions=4, warmup=2))

    def test_candidate_prefix_bounds_reject_invalid_native_range(self):
        fixture = make_fixture("flat", 16)
        operation = Operation("prefix_enumerate", key="", sample=0)
        bad = {
            "ids": [],
            "lo": 1,
            "hi": 0,
            "cardinality": 0,
        }
        with self.assertRaises(TimingError):
            normalize_result(operation, bad, lane="lex5-candidate")

    def test_partial_response_timeout_persists_raw_failure_and_reaps_child(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "artifact.lex4"
            artifact.write_bytes(b"fixture")
            ready = json.dumps(
                {"protocol": CONTROL_PROTOCOL, "event": "ready", "artifact_bytes": artifact.stat().st_size}
            )
            script = (
                "import sys,time; "
                f"print({ready!r}, flush=True); "
                "sys.stdin.readline(); "
                "sys.stdout.write('{\\\"bad\\\":'); sys.stdout.flush(); time.sleep(1)"
            )
            client = JsonlTimedClient(
                label="lex4-control",
                command=[sys.executable, "-c", script],
                artifact=artifact,
            )
            client.RESPONSE_TIMEOUT_SECONDS = 0.05
            client.open()
            operation = Operation("exact", key="alpha", category="many", sample=7)
            with self.assertRaises(TimingError):
                client.timed_request(operation)
            self.assertIsNone(client.process)
            self.assertIsNotNone(client.last_request_record)
            record = client.last_request_record
            assert record is not None
            self.assertIsInstance(record["outer_elapsed_ns"], int)
            self.assertIsNone(record["reader_elapsed_ns"])
            self.assertEqual('{"bad":', record["raw_response"]["text"])


if __name__ == "__main__":
    unittest.main()
