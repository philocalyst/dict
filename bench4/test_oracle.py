#!/usr/bin/env python3
"""Semantic oracle regression tests (independent of any reader adapter)."""

from __future__ import annotations

import unittest
from pathlib import Path
import tempfile

from oracle import Oracle, expected, make_fixture, workload, write_fixture_json


class OracleEdgeTests(unittest.TestCase):
    def test_duplicate_unicode_and_empty_exact(self):
        fixture = make_fixture("flat", 32)
        oracle = Oracle(fixture)
        duplicate = next(entry.key for entry in fixture.entries if len(oracle.exact_ids(entry.key)) > 1)
        self.assertGreaterEqual(len(oracle.exact_ids(duplicate)), 2)
        self.assertEqual([], oracle.exact_ids(""))
        self.assertEqual([], oracle.exact_ids("absent-ß-東京"))
        self.assertTrue(any("é-東京" in entry.key for entry in fixture.entries))

    def test_prefix_interval_is_explicitly_distinct_from_enumeration(self):
        fixture = make_fixture("pathological_prefix", 48)
        oracle = Oracle(fixture)
        for prefix in ("zzzz-no-such-prefix", "entry-00000047", "entry-", "pathological-prefix-", ""):
            lo, hi = oracle.prefix_interval(prefix)
            values = oracle.prefix_ids(prefix)
            self.assertEqual(hi - lo, len(values))
            self.assertEqual(values, [entry.ident for entry in oracle.ranked_entries[lo:hi]])
        zero_lo, zero_hi = oracle.prefix_interval("zzzz-no-such-prefix")
        self.assertEqual(zero_lo, zero_hi)
        self.assertEqual(oracle.cardinality, len(oracle.prefix_ids("")))

    def test_workload_has_zero_one_many_and_pathological_classes(self):
        fixture = make_fixture("pathological_prefix", 64)
        categories = {operation.category for operation in workload(fixture, 80)}
        self.assertTrue({"zero", "one", "many", "pathological"}.issubset(categories))
        non_path = {operation.category for operation in workload(make_fixture("flat", 64), 80)}
        self.assertTrue({"zero", "one", "many"}.issubset(non_path))
        self.assertNotIn("pathological", non_path)

    def test_low_repetition_workload_includes_graph_and_unique_sample_nonces(self):
        fixture = make_fixture("rich", 16)
        operations = workload(fixture, 1)
        self.assertTrue({"select", "render", "snippet", "concept_members", "translations", "relations"}.issubset({item.op for item in operations}))
        self.assertEqual(len(operations), len({item.sample for item in operations}))

    def test_native_semantic_input_is_fixture_data_not_expected_answers(self):
        fixture = make_fixture("rich", 16)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            write_fixture_json(fixture, path)
            self.assertEqual(path.read_bytes(), fixture.canonical_bytes())
            self.assertNotIn(b"expected", path.read_bytes())

    def test_select_render_and_snippet_are_ranked_and_bounded(self):
        fixture = make_fixture("rich", 24)
        oracle = Oracle(fixture)
        selected = oracle.select(0)
        self.assertEqual(selected.ident, oracle.ranked_entries[0].ident)
        self.assertEqual(selected.definition, oracle.render(selected.ident))
        self.assertEqual(selected.definition[:7], oracle.snippet(selected.ident, 7))
        with self.assertRaises(IndexError):
            oracle.select(oracle.cardinality)

    def test_rich_graph_concepts_translations_relations_and_checksums(self):
        fixture = make_fixture("rich", 24)
        oracle = Oracle(fixture)
        first = fixture.senses[0]
        self.assertIn(first.ident, oracle.concept_members(first.concept_id or 0))
        self.assertIsInstance(oracle.translations(first.ident, "fr"), tuple)
        self.assertIsInstance(oracle.relations(first.ident), tuple)
        operations = workload(fixture, 40)
        self.assertEqual(64, len(oracle.structure_checksum()))
        self.assertEqual(64, len(oracle.query_checksum(operations)))
        self.assertEqual(expected(oracle, operations[0])["ids"], oracle.exact_ids(operations[0].key))


if __name__ == "__main__":
    unittest.main()
