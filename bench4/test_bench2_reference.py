#!/usr/bin/env python3
"""Tests for the separate historical bench2 timing projection."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

try:
    from .bench2_reference import load, verify
except ImportError:  # direct unittest discovery
    from bench2_reference import load, verify


class Bench2ReferenceTests(unittest.TestCase):
    def test_historical_native_rows_are_hashed_and_not_current_measurements(self):
        rows = [
            {"kind": "meta", "scope": "global", "name": "seed", "value": 1},
            {"kind": "meta", "scope": "global", "name": "records", "value": 8},
            {"kind": "result", "fixture": "flat", "format": "v2", "variant": "raw.latency", "metric": "exact.p50_ns", "value": 417},
            {"kind": "result", "fixture": "flat", "format": "v2", "variant": "raw.latency", "metric": "render.p50_ns", "value": 42},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "benchmark.json"
            path.write_text(json.dumps({"rows": rows}) + "\n", encoding="utf-8")
            value = load(path, current_seed="0x4c45583400040001", current_records=8)
            self.assertEqual("available", value["status"])
            self.assertEqual("bench2_authoritative_native", value["profiles"][0]["source_kind"])
            self.assertFalse(value["profiles"][0]["comparable_to_current"])
            self.assertTrue(verify(value)[0])
            path.write_text(json.dumps({"rows": rows + [{"kind": "meta", "scope": "global", "name": "changed", "value": True}]}) + "\n", encoding="utf-8")
            self.assertFalse(verify(value)[0])

    def test_missing_historical_source_is_explicitly_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            value = load(Path(directory) / "missing.json")
            self.assertEqual("unavailable", value["status"])
            self.assertEqual([], value["profiles"])
            self.assertTrue(verify(value)[0])


if __name__ == "__main__":
    unittest.main()
