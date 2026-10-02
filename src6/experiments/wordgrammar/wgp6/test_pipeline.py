#!/usr/bin/env python3
"""Meaningful encoder-graph tests; this does not harden the inherited decoder."""

import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def run(*arguments, good=True):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True)
    if good and result.returncode:
        raise AssertionError(f"command failed: {arguments!r}\n{result.stderr}")
    if not good:
        if result.returncode == 0:
            raise AssertionError(f"invalid interchange accepted: {arguments!r}")
        return result
    return json.loads(result.stdout)


def parse_file(bodies, tokens, blocks=None):
    offsets, kids = [0], []
    for body in bodies:
        kids.extend(body)
        offsets.append(len(kids))
    arrays = (offsets, kids, [0, len(tokens)] if blocks is None else blocks, tokens)
    return b"P6P1" + b"".join(struct.pack("<I", len(a)) +
                               struct.pack(f"<{len(a)}I", *a) for a in arrays)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="wgp6-test-")
        self.work = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def encode(self, data, name="input", block=8192):
        raw, frame = self.work / f"{name}.raw", self.work / f"{name}.frame"
        raw.write_bytes(data)
        metrics = run(sys.executable, HERE / "encode.py", "encode", raw, frame, "--block", block)
        sizes = [trial["frame_bytes"] for trial in metrics["trials"]]
        self.assertEqual(metrics["frame_bytes"], min(sizes))
        self.assertLessEqual(metrics["frame_bytes"], sizes[0])
        self.assertEqual(metrics["all_search_encoder_codec_ns"],
                         sum(trial["codec_ns"] for trial in metrics["trials"]))
        self.assertEqual(len(metrics["trials"]), 6)
        self.assertEqual(frame.stat().st_size, metrics["frame_bytes"])
        ledger = metrics["ledger"]
        self.assertEqual(ledger["raw_bytes"], len(data))
        self.assertEqual(ledger["header_bytes"] + ledger["directory_bytes"] +
                         ledger["model_dictionary_bytes"] + ledger["payload_bytes"],
                         metrics["frame_bytes"])
        decoded = self.work / "decoded"
        run(HERE / "native", "decode", frame, decoded)
        self.assertEqual(decoded.read_bytes(), data)
        return frame, metrics

    def test_multilingual_every_restart_and_determinism(self):
        # Exact invalid UTF-8, combining marks, and non-Latin script bytes
        # remain part of the same lossless source. No normalized projection.
        unit = ("antidisestablishment stem stemming stemmed\n"
                "日本語の辞書と中国語的語形、形態素。\n"
                "книга книги کتاب العربية مُدَوَّن ترکی kitaplar\n"
                "é e\u0301 Δελτίο palabras palabra\n").encode() + b"\xff\xc0\x80\x00\n"
        data = unit * 210
        first, first_metrics = self.encode(data, "first")
        second, second_metrics = self.encode(data, "second")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(first_metrics["selected_candidate"], second_metrics["selected_candidate"])
        offset = 0
        lengths = first_metrics["ledger"]["block_raw_lengths"]
        self.assertGreater(len(lengths), 1)
        # Each block has a brand-new decoder process, including model/delta
        # preparation. Extraction reports this preparation scope explicitly.
        for index, length in enumerate(lengths):
            target = self.work / f"block-{index}.raw"
            extracted = run(HERE / "native", "extract", first, target, index)
            self.assertEqual(extracted["raw_bytes"], length)
            self.assertEqual(target.read_bytes(), data[offset:offset + length])
            offset += length
        self.assertEqual(offset, len(data))
        run(HERE / "native", "extract", first, self.work / "bad-index", len(lengths), good=False)

    def test_binary_literal_and_tiny_sources(self):
        rng = random.Random(517)
        for name, data in (("empty", b""), ("one", b"x"),
                           ("alphabet", bytes(range(256)) * 7),
                           ("random", rng.randbytes(1200))):
            with self.subTest(name=name):
                self.encode(data, name)

    def test_private_parse_rejects_cycles_bad_offsets_and_cut(self):
        # These are untrusted PRIVATE encoder artifacts, not archive mutation
        # claims about the old native decoder. Reject before model fitting.
        invalid = [
            parse_file([[256]], [256]),
            parse_file([[257], [ord("a")]], [256]),
            parse_file([[0xFFFFFF01]], [256]),
            parse_file([[ord("a"), 0xFFFFFF00]], [256]),
            parse_file([[ord("a"), 0xFFFFFF02]], [256]),
            parse_file([[ord("a")]], [257]),
            parse_file([[ord("a")]], [256], blocks=[1, 1]),
            parse_file([[ord("a")]], [256]) + b"trailing",
        ]
        for index, content in enumerate(invalid):
            source = self.work / f"invalid-{index}.parse"
            source.write_bytes(content)
            run(HERE / "native", "compile", source, self.work / "invalid.frame", 1, good=False)
        valid = self.work / "valid.parse"
        valid.write_bytes(parse_file([[ord("a"), ord("b")], [256, ord("c")]], [257, 257]))
        frame, decoded = self.work / "valid.frame", self.work / "valid.raw"
        for classes in (3, 129, 65535, 65536):
            run(HERE / "native", "compile", valid, frame, classes, good=False)
        run(HERE / "native", "compile", valid, frame, 1)
        run(HERE / "native", "decode", frame, decoded)
        self.assertEqual(decoded.read_bytes(), b"abcabc")

    def test_restart_policy_rejects_before_search(self):
        raw = self.work / "small.raw"
        raw.write_bytes(b"test")
        for block in (0, 65537, 1 << 22):
            run(sys.executable, HERE / "encode.py", "encode", raw,
                self.work / "rejected.frame", "--block", block, good=False)
        with raw.open("r+b") as stream:
            stream.truncate((64 << 20) + 1)
        run(sys.executable, HERE / "encode.py", "encode", raw,
            self.work / "rejected.frame", good=False)

    def test_price_matrix_budget_before_native_fit(self):
        # A syntactically valid private graph with unused definitions. The
        # 128-class matrix exceeds the explicit cell budget; fitting it is
        # unnecessary and must not occur before rejection.
        count = 20_000_000 // 129 - 256 + 1
        source = self.work / "oversize.parse"
        source.write_bytes(parse_file([[ord("a")]] * count, []))
        rejected = run(HERE / "native", "compile", source,
                       self.work / "oversize.frame", 128,
                       self.work / "oversize.prices", good=False)
        self.assertIn("PriceBudget", rejected.stderr)
        self.assertFalse((self.work / "oversize.prices").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
