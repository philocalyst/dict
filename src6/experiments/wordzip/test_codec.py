"""Fresh-process roundtrips, independent restart reads, and hostile frames."""
from pathlib import Path
import hashlib
import json
import os
import random
import struct
import subprocess
import tempfile
import unittest
import zlib

HERE = Path(__file__).resolve().parent
EXE = Path(os.environ.get("WORDZIP_EXE", str(HERE / "sbwt")))
EXTRA_OPTIONS = json.loads(os.environ.get("WORDZIP_ENCODER_OPTIONS", "[]"))


class NativeCodecTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.raw = self.root / "raw"
        self.frame = self.root / "frame"
        self.output = self.root / "output"

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, operation, source, target, *options):
        target.unlink(missing_ok=True)
        return subprocess.run([str(EXE), operation, str(source), str(target), *map(str, options)],
                              capture_output=True, text=True, timeout=30)

    def encoded(self, raw):
        self.raw.write_bytes(raw)
        result = self.run_cli("encode", self.raw, self.frame, "--block", 4096, "--cap", 2048,
                              *EXTRA_OPTIONS)
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads(result.stdout)
        self.assertEqual(metrics["input_bytes"], len(raw))
        self.assertGreaterEqual(metrics["codec_ns"], metrics["codec_us"] * 1000)
        return self.frame.read_bytes()

    def test_lossless_and_every_restart(self):
        rng = random.Random(9202601)
        cases = [b"", b"a", b"banana banana " * 1300,
                 bytes(range(256)) * 23,
                 ("中国 العربية 한국어 日本語 Ελληνικά käsi IŞIK ".encode()) * 200,
                 bytes(rng.randrange(256) for _ in range(12297)),
                 b"a" * 4096 + b"b" * 4096 + b"a"]
        for raw in cases:
            with self.subTest(bytes=len(raw)):
                self.encoded(raw)
                result = self.run_cli("decode", self.frame, self.output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.output.read_bytes(), raw)
                for index, offset in enumerate(range(0, len(raw), 4096)):
                    result = self.run_cli("decode", self.frame, self.output, "--index", index)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.output.read_bytes(), raw[offset:offset + 4096])
                result = self.run_cli("decode", self.frame, self.output,
                                      "--index", (len(raw) + 4095) // 4096)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def test_deterministic_frame(self):
        raw = ("walking walked walker walked caminar caminando. ".encode()) * 1000
        first = self.encoded(raw)
        second = self.encoded(raw)
        self.assertEqual(first, second)

    def test_decoder_uses_only_moved_frame(self):
        raw = ("語彙語彙 العربية العربية café café \n".encode()) * 300
        self.encoded(raw)
        self.raw.unlink()
        moved = self.root / "unrelated" / "renamed-frame"
        moved.parent.mkdir()
        self.frame.replace(moved)
        result = self.run_cli("decode", moved, self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), raw)

    def test_preallocation_file_limit(self):
        with self.raw.open("wb") as stream:
            stream.truncate((512 + 64) * 1024 * 1024 + 1)
        for operation in ["encode", "decode"]:
            result = self.run_cli(operation, self.raw, self.output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("input file resource limit", result.stderr)
            self.assertFalse(self.output.exists())

    def test_all_prefix_truncations_and_extra_bytes(self):
        frame = self.encoded(b"a periodic periodic phrase " * 400)
        for length in range(len(frame)):
            self.frame.write_bytes(frame[:length])
            result = self.run_cli("decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, length)
            self.assertFalse(self.output.exists())
        for tail in [b"\0", b"unused trailing bytes", frame]:
            self.frame.write_bytes(frame + tail)
            result = self.run_cli("decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0)

    def test_fixed_mutation_set(self):
        frame = self.encoded((bytes(range(256)) + b"affixes prefixes suffixes\n") * 50)
        rng = random.Random(102026)
        for _ in range(1024):
            mutated = bytearray(frame)
            at = rng.randrange(len(mutated))
            mutated[at] ^= 1 << rng.randrange(8)
            self.frame.write_bytes(mutated)
            result = self.run_cli("decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, at)
            self.assertFalse(self.output.exists())

    def test_resealed_semantic_directory_errors(self):
        frame = bytearray(self.encoded(b"grammar grammar phrase phrase " * 600))
        count, = struct.unpack_from("<I", frame, 12)
        grammar, entropy = struct.unpack_from("<II", frame, 24)
        directory = 40 + grammar + entropy
        metadata_end = directory + 32 * count
        for offset, value in [(directory, 1), (directory + 8, 0),
                              (directory + 12, 0), (directory + 16, 0),
                              (directory + 20, 0xfffffff0),
                              (directory + 24, 0), (36, 99)]:
            mutated = bytearray(frame)
            struct.pack_into("<I", mutated, offset, value)
            mutated[32:36] = b"\0" * 4
            struct.pack_into("<I", mutated, 32, zlib.crc32(mutated[:metadata_end]))
            self.frame.write_bytes(mutated)
            result = self.run_cli("decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, offset)
            self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
