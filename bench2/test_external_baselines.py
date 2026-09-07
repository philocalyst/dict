"""Semantic regression tests for the independent benchmark readers.

These tests deliberately exercise the adapters without changing benchmark
artifacts.  The optional SLOB case runs in the Nix shell, where ``slob`` is
available, and is skipped in a minimal Python installation.
"""

from __future__ import annotations

import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


BENCH_DIR = Path(__file__).resolve().parent
if str(BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(BENCH_DIR))

import external_baselines as baselines


class ExternalBaselineTests(unittest.TestCase):
    @staticmethod
    def _sqlite(rows):
        temp = tempfile.TemporaryDirectory()
        path = Path(temp.name) / "fixture.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE entries (id INTEGER PRIMARY KEY, key TEXT NOT NULL, definition BLOB NOT NULL)")
            db.executemany("INSERT INTO entries(id,key,definition) VALUES(?,?,?)", rows)
            db.execute("CREATE INDEX entries_key ON entries(key, id)")
        return temp, path

    def test_sqlite_prefix_wildcards_are_literal(self):
        rows = [
            (31, "%alpha", b"percent-alpha"),
            (5, "plain", b"plain"),
            (19, "_under", b"underscore"),
            (2, "%beta", b"percent-beta"),
            (27, "xray", b"xray"),
        ]
        temp, path = self._sqlite(rows)
        self.addCleanup(temp.cleanup)
        reader = baselines.SQLiteReader(path)
        self.addCleanup(reader.close)

        self.assertEqual([2, 31], reader.prefix("%"))
        self.assertEqual([19], reader.prefix("_"))
        self.assertEqual([5], reader.prefix("p"))

    def test_sqlite_duplicate_unicode_exact_and_prefix_sets(self):
        rows = [
            (41, "東京", b"first"),
            (7, "東京", b"second"),
            (13, "東京湾", b"bay"),
            (3, "éclair", b"accent"),
            (17, "\uD7FF-boundary", b"before surrogate range"),
            (23, "\U0010FFFF-boundary", b"maximum Unicode scalar"),
        ]
        temp, path = self._sqlite(rows)
        self.addCleanup(temp.cleanup)
        reader = baselines.SQLiteReader(path)
        self.addCleanup(reader.close)

        self.assertEqual([7, 41], reader.exact("東京"))
        self.assertEqual([7, 13, 41], reader.prefix("東"))
        self.assertEqual([3], reader.exact("éclair"))
        self.assertEqual([3], reader.prefix("é"))
        self.assertEqual([17], reader.prefix("\uD7FF"))
        self.assertEqual([23], reader.prefix("\U0010FFFF"))

    def test_main_propagates_fatal_semantic_builder_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "fixture.tsv"
            corpus.write_text("# fixture=fatal\n7\tkey\tdefinition\n", encoding="utf-8")
            artifact_dir = root / "artifacts"
            output = root / "rows.tsv"
            calls = []

            def fatal(*_args, **_kwargs):
                calls.append("sqlite")
                raise RuntimeError("semantic mismatch")

            def should_not_run(*_args, **_kwargs):
                calls.append("continued")

            argv = [
                "external_baselines.py",
                "--corpus",
                str(corpus),
                "--artifact-dir",
                str(artifact_dir),
                "--out",
                str(output),
                "--repetitions",
                "1",
                "--warmup",
                "0",
            ]
            with mock.patch.object(baselines, "build_sqlite", side_effect=fatal), \
                    mock.patch.object(baselines, "build_stardict", side_effect=should_not_run), \
                    mock.patch.object(baselines, "build_dict_index", side_effect=should_not_run), \
                    mock.patch.object(baselines, "build_slob", side_effect=should_not_run), \
                    mock.patch.object(sys, "argv", argv):
                with self.assertRaisesRegex(RuntimeError, "semantic mismatch"):
                    baselines.main()
            self.assertEqual(["sqlite"], calls)

    @unittest.skipUnless(importlib.util.find_spec("slob"), "optional SLOB dependency is unavailable")
    def test_slob_duplicate_unicode_lookup_uses_stable_ids_without_content_decode(self):
        import slob

        rows = [
            (101, "東京", b"first"),
            (7, "東京", b"second"),
            (42, "東京", b"third"),
            (11, "a%", b"percent"),
            (12, "a_", b"underscore"),
        ]
        corpus = baselines.Corpus("slob-test", rows, 0, sum(len(content) for _, _, content in rows))
        observed = []
        original_find = slob.find

        class NoContentHit:
            def __init__(self, item):
                self.key = item.key
                self.id = item.id
                self.fragment = item.fragment

            @property
            def content(self):
                raise AssertionError("SLOB lookup must not decode content")

        def no_content_find(word, reader, match_prefix=True):
            for source, item in original_find(word, reader, match_prefix=match_prefix):
                yield source, NoContentHit(item)

        def capture_measure(_rows, measured_corpus, fmt, variant, _artifact_bytes, _build_ns,
                            _open_fn, exact_fn, prefix_fn, _render_fn, _repetitions, _warmup):
            self.assertEqual("slob", fmt)
            observed.append(variant)
            self.assertEqual(sorted(measured_corpus.exact_expected("東京")), sorted(exact_fn("東京")))
            self.assertEqual(sorted(measured_corpus.prefix_expected("東")), sorted(prefix_fn("東")))
            self.assertEqual(sorted(measured_corpus.exact_expected("a%")), sorted(exact_fn("a%")))
            self.assertEqual(sorted(measured_corpus.exact_expected("a_")), sorted(exact_fn("a_")))
            self.assertEqual(sorted(measured_corpus.prefix_expected("a")), sorted(prefix_fn("a")))

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(baselines, "measure", side_effect=capture_measure), \
                mock.patch.object(slob, "find", side_effect=no_content_find):
            baselines.build_slob(corpus, Path(directory), [], repetitions=1, warmup=0)

        self.assertEqual(["raw", "lzma2"], observed)


if __name__ == "__main__":
    unittest.main()
