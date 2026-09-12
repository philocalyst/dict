"""Focused semantic and artifact-boundary tests for external baselines."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

try:
    from .external import OffsetIndexAdapter, SlobAdapter, StarDictAdapter
    from .harness import measure_adapter
    from .oracle import Fixture, make_fixture
except ImportError:  # pragma: no cover - direct unittest discovery
    from external import OffsetIndexAdapter, SlobAdapter, StarDictAdapter
    from harness import measure_adapter
    from oracle import Fixture, make_fixture


class ExternalAdapterTests(unittest.TestCase):
    def test_stardict_and_offset_index_are_complete_flat_readers(self):
        fixture = make_fixture("flat", 20)
        for adapter in (StarDictAdapter(fixture), OffsetIndexAdapter(fixture)):
            with self.subTest(adapter=adapter.metadata.label), tempfile.TemporaryDirectory() as directory:
                measurement = measure_adapter(fixture, adapter, Path(directory) / "payload.bin", repetitions=1, warmup=1)
                self.assertGreater(measurement.artifact_bytes, 0)
                self.assertGreaterEqual(measurement.metrics["artifact_file_count"], 2)
                self.assertEqual("external_format_adapter", measurement.adapter.adapter_kind)
                self.assertEqual("host_operation", measurement.metrics["timing_mode"])

    def test_duplicate_and_unicode_records_survive_star_dict(self):
        fixture = make_fixture("repeated", 24)
        adapter = StarDictAdapter(fixture)
        with tempfile.TemporaryDirectory() as directory:
            measurement = measure_adapter(fixture, adapter, Path(directory) / "payload.bin", repetitions=2, warmup=0)
        self.assertTrue(measurement.metrics["query_checksum"])

    def test_slob_reports_unavailable_without_dependency(self):
        available, reason = SlobAdapter.available()
        if available:
            self.assertEqual("", reason)
        else:
            self.assertIn("SLOB", reason)

    def test_graph_fixture_is_rejected_by_flat_adapters(self):
        fixture = make_fixture("rich", 16)
        with self.assertRaises(ValueError):
            StarDictAdapter(fixture)

    def test_open_uses_the_counted_id_sidecar_not_fixture_semantics(self):
        fixture = make_fixture("flat", 16)
        expected = sorted(fixture.entries, key=lambda entry: (entry.key.encode(), entry.ident))
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "payload.bin"
            builder = StarDictAdapter(fixture)
            builder.build(artifact)
            # A new reader with no Fixture object must serve the durable
            # payload/index/ID-sidecar bundle.  This catches the old shortcut
            # where sparse source IDs or content were reconstructed from the
            # input model during open/query.
            adapter = StarDictAdapter(None)
            adapter.open(artifact)
            adapter.verify()
            self.assertEqual([entry.ident for entry in expected if entry.key == expected[0].key], adapter.exact(expected[0].key))
            self.assertEqual(expected[0].definition, adapter.render(expected[0].ident))
            adapter.close()

    def test_every_flat_reader_reopens_without_fixture_authority(self):
        fixture = make_fixture("repeated", 18)
        expected = sorted(fixture.entries, key=lambda entry: (entry.key.encode(), entry.ident))
        factories = [
            ("stardict", lambda: StarDictAdapter(None), StarDictAdapter(fixture)),
            ("dict-index", lambda: OffsetIndexAdapter(None), OffsetIndexAdapter(fixture)),
        ]
        available, _ = SlobAdapter.available()
        if available:
            factories.extend(
                (
                    ("slob/raw", lambda: SlobAdapter(None, compression=None, label="slob/adapter"), SlobAdapter(fixture, compression=None, label="slob/adapter")),
                    ("slob/lzma2", lambda: SlobAdapter(None, compression="lzma2", label="slob/adapter-lzma2"), SlobAdapter(fixture, compression="lzma2", label="slob/adapter-lzma2")),
                )
            )
        for name, reader_factory, builder in factories:
            with self.subTest(adapter=name), tempfile.TemporaryDirectory() as directory:
                artifact = Path(directory) / "payload.bin"
                builder.build(artifact)
                reader = reader_factory()
                reader.open(artifact)
                reader.verify()
                self.assertEqual(expected[0].ident, reader.select(0)["id"])
                self.assertEqual(expected[0].definition, reader.render(expected[0].ident))
                self.assertEqual(reader.prefix_enumerate(expected[0].key), reader.exact(expected[0].key))
                self.assertEqual((0, len(expected)), reader.prefix_interval(""))
                reader.close()


if __name__ == "__main__":
    unittest.main()
