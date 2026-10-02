#!/usr/bin/env python3
"""Fresh-process integration and failed-publication checks for the paid driver."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
CLI = HERE / "wordfrontier.py"
BACKEND = HERE.parent / "wordgrammar" / "wgp6"
GWT = HERE.parent / "wordgrammar" / "geometry"
PAGE = 65536


class AutomaticWordCodec(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wordfrontier-test-")
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def call(self, *args, ok=True, env=None):
        result = subprocess.run([sys.executable, str(CLI), *map(str, args)],
                                capture_output=True, text=True, env=env)
        if not ok:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def input(self, name, data):
        source = self.directory / name
        source.write_bytes(data)
        return source

    def verify(self, archive, raw):
        decoded = self.directory / "decoded"
        event = self.call("decode", archive, decoded)
        self.assertEqual(decoded.read_bytes(), raw)
        self.assertFalse(event["timing_enabled"])
        ledger = self.call("inspect", archive, self.directory / "ledger.json")
        self.assertEqual(ledger["source_bytes"], len(raw))
        self.assertEqual(ledger["accounting"]["sum_bytes"], archive.stat().st_size)
        for page in range((len(raw) + PAGE - 1) // PAGE):
            event = self.call("extract", archive, decoded, "--index", page)
            self.assertEqual(decoded.read_bytes(), raw[page * PAGE:(page + 1) * PAGE])
            self.assertFalse(event["timing_enabled"])
        return ledger

    def test_paid_choice_profiles_and_determinism(self):
        record = b'<r id="alphabet-123"><child ref="alphabet-123"/><x id="alphabet-456" members="alphabet-456-0 alphabet-456-1"/></r>\n'
        raw = record * 700 + 'élève العربية 漢字 ёжик\n'.encode() + bytes(range(256)) + b'\x00\xff'
        source = self.input("input-a", raw)
        copy = self.input("different-name-ja.xml", raw)
        for profile in ("quality", "access"):
            a, b = self.directory / (profile + "-a"), self.directory / (profile + "-b")
            first = self.call("encode", source, a, "--profile", profile)
            second = self.call("encode", copy, b, "--profile", profile)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            self.assertEqual(first["frame_sha256"], second["frame_sha256"])
            self.assertEqual(first["frame_bytes"], min(r["frame_bytes"] for r in first["candidates"]))
            self.assertEqual([r["format"] for r in first["candidates"]], ["WPG2", "GWT1"])
            self.assertEqual(first["fresh_native_all_original_pages_exact"], 2)
            expected_ns = first["candidates"][0]["encoder"]["paid_native_codec_ns"]
            expected_ns += sum(r.get("codec_ns", 0) for r in first["candidates"][1]["encoder"]["native_events"])
            self.assertEqual(first["all_search_native_codec_ns"], expected_ns)
            self.verify(a, raw)

    def test_geometry_dispatch_partial_page_and_empty(self):
        raw = (b'words of variable length occupy columns\n' * 1800) + bytes(range(256))
        source = self.input("raw", raw)
        archive = self.directory / "geometry"
        result = subprocess.run([sys.executable, str(GWT / "pages.py"), "encode", str(source), str(archive),
                                 "--reference", str(BACKEND / "m_reference"), "--native", str(BACKEND / "native")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.verify(archive, raw)["format"], "GWT1")
        empty = self.input("empty", b'')
        empty_frame = self.directory / "empty-frame"
        result = self.call("encode", empty, empty_frame)
        self.assertEqual(result["fresh_native_all_original_pages_exact"], 0)
        self.verify(empty_frame, b'')
        previous = self.input("previous", b'keep')
        self.call("extract", empty_frame, previous, "--index", 0, ok=False)
        self.assertEqual(previous.read_bytes(), b'keep')

    def test_failed_outputs_are_not_published(self):
        raw = self.input("raw", b'word\n' * 20)
        archive = self.directory / "valid"
        self.call("encode", raw, archive)
        data = archive.read_bytes()
        destination = self.input("destination", b'preserve existing output')
        for damaged in (b'xxxx', data[:4], data[:-1], data + b'\x00'):
            bad = self.input("bad", damaged)
            for operation in ("decode", "inspect"):
                self.call(operation, bad, destination, ok=False)
                self.assertEqual(destination.read_bytes(), b'preserve existing output')
        self.call("extract", archive, destination, "--index", 10000000000, ok=False)
        self.call("extract", archive, destination, "--index", -1, ok=False)
        self.call("decode", archive, destination, "--measure", 1, ok=False)
        self.assertEqual(destination.read_bytes(), b'preserve existing output')

    def test_pre_read_limits_and_environment_override(self):
        large = self.directory / "large"
        with large.open("wb") as stream:
            stream.truncate(32 * 1024 * 1024 + 1)
        destination = self.input("destination", b'keep')
        self.call("encode", large, destination, ok=False)
        self.assertEqual(destination.read_bytes(), b'keep')
        raw = self.input("raw", b'bounded resources exact bytes\n' * 5)
        self.call("encode", raw, destination, "--block", 1, ok=False)
        self.assertEqual(destination.read_bytes(), b'keep')
        env = os.environ.copy()
        env["WPG6_BIN_DIR"] = str(self.directory / "missing-env-backend")
        result = self.call("encode", raw, destination, "--backend-dir", BACKEND, env=env)
        self.assertTrue(result["fresh_native_full_decode_exact"])
        self.assertEqual(result["candidates"][0]["encoder"]["backend_directory"], str(BACKEND.resolve()))


if __name__ == "__main__":
    unittest.main()
