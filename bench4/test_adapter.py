#!/usr/bin/env python3
"""Adversarial tests for the native subprocess boundary."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

try:
    from .adapter import AdapterError, SubprocessAdapter
    from .oracle import Operation, make_fixture
except ImportError:  # direct unittest discovery
    from adapter import AdapterError, SubprocessAdapter
    from oracle import Operation, make_fixture


SERVER = r'''#!/usr/bin/env python3
import json, pathlib, sys, time
log = pathlib.Path(sys.argv[sys.argv.index("--log") + 1])
artifact = pathlib.Path(sys.argv[sys.argv.index("--artifact") + 1])
bad_id = "--bad-id" in sys.argv
omit_ids = "--omit-ids" in sys.argv
if "--ready-delay" in sys.argv:
    time.sleep(float(sys.argv[sys.argv.index("--ready-delay") + 1]))
ready_bytes = artifact.stat().st_size + (1 if "--bad-ready-size" in sys.argv else 0)
print(json.dumps({"protocol": "LEX4-BENCH/1", "event": "ready", "artifact_bytes": ready_bytes}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    log.write_text(line, encoding="utf-8")
    assert request["protocol"] == "LEX4-BENCH/1"
    assert "expected" not in request
    assert "category" not in request
    response_id = request["request_id"] + (1 if bad_id else 0)
    result = {} if omit_ids else {"ids": []}
    response = {"protocol": "LEX4-BENCH/1", "request_id": response_id, "sample": request["sample"], "ok": True, "result": result}
    if request.get("timing_mode") == "reader_self":
        response.update({"timing_mode": "reader_self", "reader_elapsed_ns": 17})
    print(json.dumps(response), flush=True)
'''


class NativeProtocolTests(unittest.TestCase):
    def test_open_waits_for_verified_server_readiness(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            adapter = SubprocessAdapter(
                fixture,
                [sys.executable, str(script), "--log", str(root / "request.json"), "--ready-delay", "0.08"],
            )
            started = time.perf_counter()
            adapter.open(artifact)
            elapsed = time.perf_counter() - started
            adapter.close()
            self.assertGreaterEqual(elapsed, 0.07)

    def test_open_rejects_artifact_readiness_mismatch_and_reaps_child(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            adapter = SubprocessAdapter(
                fixture,
                [sys.executable, str(script), "--log", str(root / "request.json"), "--bad-ready-size"],
            )
            with self.assertRaises(AdapterError):
                adapter.open(artifact)
            self.assertIsNone(adapter._process)

    def test_native_identity_is_explicit_not_inferred_from_protocol(self):
        fixture = make_fixture("flat", 8)
        adapter = SubprocessAdapter(
            fixture,
            ["/not/run"],
            label="lex2-current-native",
            implementation="actual-src2-zig",
            note="current src2",
        )
        self.assertEqual("lex2-current-native", adapter.metadata.label)
        self.assertEqual("actual-src2-zig", adapter.metadata.implementation)
        self.assertEqual("current src2", adapter.metadata.note)

    def test_requests_contain_no_expected_answers_or_categories(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            log = root / "request.json"
            adapter = SubprocessAdapter(
                fixture,
                [sys.executable, str(script), "--log", str(log)],
            )
            adapter.open(artifact)
            adapter.set_sample(73)
            self.assertEqual([], adapter.exact("not-present"))
            adapter.close()
            request = json.loads(log.read_text(encoding="utf-8"))
            self.assertEqual(73, request["sample"])
            self.assertNotIn("expected", request)
            self.assertNotIn("category", request)

    def test_empty_key_is_explicit_on_wire(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            log = root / "request.json"
            adapter = SubprocessAdapter(fixture, [sys.executable, str(script), "--log", str(log)])
            adapter.open(artifact)
            self.assertEqual([], adapter.exact(""))
            adapter.close()
            request = json.loads(log.read_text(encoding="utf-8"))
            self.assertIn("key", request)
            self.assertEqual("", request["key"])

    def test_response_id_mismatch_is_fatal(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            adapter = SubprocessAdapter(
                fixture,
                [sys.executable, str(script), "--log", str(root / "request.json"), "--bad-id"],
            )
            adapter.open(artifact)
            with self.assertRaises(AdapterError):
                adapter.exact("not-present")
            adapter.close()

    def test_missing_empty_result_field_is_fatal(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            adapter = SubprocessAdapter(
                fixture,
                [sys.executable, str(script), "--log", str(root / "request.json"), "--omit-ids"],
            )
            adapter.open(artifact)
            with self.assertRaises(AdapterError):
                adapter.exact("not-present")
            adapter.close()

    def test_reader_self_timing_is_separate_from_transport(self):
        fixture = make_fixture("flat", 8)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "server.py"
            script.write_text(SERVER, encoding="utf-8")
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"LEX4")
            adapter = SubprocessAdapter(fixture, [sys.executable, str(script), "--log", str(root / "request.json")])
            adapter.open(artifact)
            raw, reader_ns = adapter.reader_timed(Operation("exact", key="not-present", sample=11))
            adapter.close()
            self.assertEqual([], raw)
            self.assertEqual(17, reader_ns)
            request = json.loads((root / "request.json").read_text(encoding="utf-8"))
            self.assertEqual("reader_self", request["timing_mode"])
            self.assertNotIn("expected", request)


if __name__ == "__main__":
    unittest.main()
