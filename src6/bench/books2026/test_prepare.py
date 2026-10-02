#!/usr/bin/env python3
"""Projection oracles and rejection boundaries; no codec benchmarks."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import controls
import prepare


class ProjectionTests(unittest.TestCase):
    def pg(self, encoding="utf-8-sig"):
        book = dict(title="A Test", author="A Writer", declared_language="English",
                    source_encoding=encoding,
                    rights=dict(source_license_marker="*** START: FULL LICENSE ***"))
        declared = "ISO-8859-1" if encoding == "iso-8859-1" else "UTF-8"
        body = "\r\nRésumé: keep punctuation!\r\n\r\n"
        text = (f"Title: A Test\r\nAuthor: A Writer\r\nLanguage: English\r\n"
                f"Character set encoding: {declared}\r\n"
                "*** START OF THIS PROJECT GUTENBERG EBOOK A TEST ***\r\n" + body +
                "*** END OF THIS PROJECT GUTENBERG EBOOK A TEST ***\r\n"
                "*** START: FULL LICENSE ***\r\nterms\r\n")
        return text.encode(encoding), book, body.encode("utf-8")

    def test_utf8_and_latin1_exact_body_and_full_source_inverse(self):
        for encoding in ("utf-8-sig", "utf-8", "iso-8859-1"):
            raw, book, expected = self.pg(encoding)
            body, oracle = prepare.pg_projection(raw, book)
            self.assertEqual(body, expected)
            self.assertEqual(oracle["full_original_source_reconstruction_sha256"], prepare.digest(raw))
            self.assertEqual(body.count(b"\r\n"), 3)

    def test_reject_wrong_metadata_ambiguous_marker_and_missing_license(self):
        raw, book, _ = self.pg()
        changes = [
            (b"Title: A Test", b"Title: A Different Test"),
            (b"Language: English", b"Language: French"),
            (b"Character set encoding: UTF-8", b"Character set encoding: ASCII"),
            (b"*** START: FULL LICENSE ***", b"license missing"),
        ]
        for before, after in changes:
            with self.assertRaises(ValueError):
                prepare.pg_projection(raw.replace(before, after), book)
        duplicate = raw.replace(b"*** END OF THIS PROJECT", b"*** START OF THIS PROJECT GUTENBERG EBOOK A TEST ***\r\n*** END OF THIS PROJECT")
        with self.assertRaises(ValueError):
            prepare.pg_projection(duplicate, book)
        with self.assertRaises(ValueError):
            prepare.pg_projection(raw.replace(b"END OF THIS PROJECT GUTENBERG EBOOK A TEST", b"END OF THIS PROJECT GUTENBERG EBOOK WRONG"), book)

    def test_legacy_ascii_exact_marker_and_translator_metadata(self):
        raw, book, expected = self.pg("iso-8859-1")
        book["source_encoding"] = "ascii"
        book["declared_source_encoding"] = "ISO-646-US (US-ASCII)"
        book["translator"] = "A Translator and Another"
        raw = raw.replace(b"R\xe9sum\xe9", b"Resume").replace(
            b"Character set encoding: ISO-8859-1", b"Character set encoding: ISO-646-US (US-ASCII)").replace(
            b"Language: English", b"Translators: A Translator and Another\r\nLanguage: English").replace(
            b"*** START OF THIS", b"***START OF THE").replace(
            b"*** END OF THIS", b"***END OF THE").replace(b"A TEST ***", b"A TEST***")
        book["exact_start_marker"] = "***START OF THE PROJECT GUTENBERG EBOOK A TEST***"
        book["exact_end_marker"] = "***END OF THE PROJECT GUTENBERG EBOOK A TEST***"
        body, oracle = prepare.pg_projection(raw, book)
        self.assertEqual(body, expected.decode().replace("Résumé", "Resume").encode())
        self.assertEqual(oracle["full_original_source_reconstruction_sha256"], prepare.digest(raw))
        with self.assertRaises(ValueError):
            prepare.pg_projection(raw.replace(b"Translators: A Translator and Another", b"Translators: Someone Else"), book)
        book["exact_start_marker"] += " different"
        with self.assertRaises(ValueError):
            prepare.pg_projection(raw, book)

    def test_utf8_prefix_uses_bytes_and_never_splits_scalar(self):
        raw = "a夏😀éz".encode()
        for limit in range(len(raw) + 4):
            out = prepare.utf8_prefix(raw, limit)
            out.decode("utf-8", errors="strict")
            self.assertLessEqual(len(out), limit)
            self.assertTrue(raw.startswith(out))
            if len(out) != len(raw):
                next_character = raw[len(out):].decode()[0].encode()
                self.assertGreater(len(out) + len(next_character), limit)

    def aozora(self):
        book = dict(title="こころ", author="夏目漱石", source_encoding="shift_jis",
                    required_part_headings=["上　先生と私", "中　両親と私", "下　先生と遺書"])
        sep = "-" * 55 + "\r\n"
        body = ("\r\n［＃２字下げ］上　先生と私\r\n｜夏目《なつめ》を読む。\r\n"
                "中　両親と私\r\n※［＃外字］を保つ。\r\n下　先生と遺書\r\n")
        raw = ("こころ\r\n夏目漱石\r\n" + sep + "記号の説明\r\n" + sep + body + "底本：原典\r\n").encode("shift_jis")
        return raw, book, body

    def test_aozora_base_text_gaiji_and_reversible_annotation_deletions(self):
        raw, book, original_body = self.aozora()
        body, oracle, deletions = prepare.aozora_projection(raw, book)
        text = body.decode()
        self.assertIn("夏目を読む。", text)
        self.assertIn("※［＃外字］を保つ。", text)
        self.assertEqual(prepare.undo_deletions(text, deletions), original_body)
        self.assertEqual(oracle["full_original_source_reconstruction_sha256"], prepare.digest(raw))
        self.assertEqual(oracle["opaque_gaiji_annotations_retained"], 1)
        self.assertEqual(oracle["ruby_annotations_removed"], 1)
        self.assertEqual(text.count("\r\n"), original_body.count("\r\n"))

    def test_aozora_malformed_markup_and_incomplete_parts_rejected(self):
        raw, book, _ = self.aozora()
        for source in (raw.decode("shift_jis").replace("》", ""),
                       raw.decode("shift_jis").replace("下　先生と遺書", "欠落")):
            with self.assertRaises(ValueError):
                prepare.aozora_projection(source.encode("shift_jis"), book)

    def test_source_hash_limit_and_reserved_no_diagnostic_prefixes(self):
        raw, book, _ = self.pg()
        book.update(id="synthetic", raw_filename="source.raw", projection="pg-marked-body-v1",
                    language="en", source_bytes=len(raw), source_sha256=prepare.digest(raw))
        lock = dict(role="reserved-validation", source_limit_bytes=4096, books=[book])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "raw").mkdir()
            (root / "raw/source.raw").write_bytes(raw)
            result = prepare.prepare(lock, root)
            self.assertEqual(result["books"][0]["prefixes"], [])
            mismatch = copy.deepcopy(lock)
            mismatch["books"][0]["source_sha256"] = "0" * 64
            with self.assertRaises(ValueError):
                prepare.prepare(mismatch, root)
            oversized = copy.deepcopy(lock)
            oversized["source_limit_bytes"] = 4
            with self.assertRaises(ValueError):
                prepare.prepare(oversized, root)

    def test_control_driver_refuses_reserved_before_running_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "reserved.json"
            manifest.write_text('{"role":"reserved-validation"}')
            out = Path(directory) / "must-not-exist"
            with mock.patch("sys.argv", ["controls.py", "--manifest", str(manifest), "--out", str(out)]):
                with mock.patch.object(controls.subprocess, "run") as run:
                    with self.assertRaisesRegex(ValueError, "reserved books"):
                        controls.main()
                    run.assert_not_called()
            self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
