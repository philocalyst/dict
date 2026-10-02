"""Prepared-frame parity, restart isolation, ownership and malformed input."""
from pathlib import Path
import json
import os
import random
import struct
import subprocess
import tempfile
import unittest
import zlib

HERE = Path(__file__).resolve().parent
ENCODER = HERE / "sbwt"
BINDING_ENCODER = HERE / "sbwt-select"
READER = Path(os.environ.get("WORDZIP_SESSION_EXE", str(HERE / "sbwt-session")))


class PreparedReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.raw = self.root / "raw"
        self.frame = self.root / "frame"
        self.output = self.root / "output"

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, executable, operation, source, target, *options):
        target.unlink(missing_ok=True)
        return subprocess.run([str(executable), operation, str(source), str(target),
                               *map(str, options)], capture_output=True, text=True, timeout=30)

    def encoded(self, raw, bindings=False):
        self.raw.write_bytes(raw)
        encoder = BINDING_ENCODER if bindings else ENCODER
        options = ["--block", 4096, "--cap", 2048]
        if bindings:
            options += ["--copy", 12]
        result = self.cli(encoder, "encode", self.raw, self.frame, *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.frame.read_bytes()

    def test_whole_and_every_restart_parity(self):
        rng = random.Random(1102026)
        inputs = [b"", b"x", b"banana banana " * 1300, bytes(range(256)) * 23,
                  ("中国 العربية 한국어 Ελληνικά 日本語 käsi \n".encode()) * 250,
                  bytes(rng.randrange(256) for _ in range(12301))]
        for raw in inputs:
            for bindings in [False, True]:
                with self.subTest(raw_bytes=len(raw), bindings=bindings):
                    self.encoded(raw, bindings)
                    self.raw.unlink()
                    result = self.cli(READER, "decode", self.frame, self.output)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.output.read_bytes(), raw)
                    for index, offset in enumerate(range(0, len(raw), 4096)):
                        result = self.cli(READER, "decode", self.frame, self.output,
                                          "--index", index)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(self.output.read_bytes(), raw[offset:offset + 4096])
                    result = self.cli(READER, "decode", self.frame, self.output,
                                      "--index", (len(raw) + 4095) // 4096)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(self.output.exists())

    def test_unselected_payload_is_not_decoded(self):
        raw = b"first useful lexical page\n" * 700
        frame = bytearray(self.encoded(raw))
        count, = struct.unpack_from("<I", frame, 12)
        grammar, entropy = struct.unpack_from("<II", frame, 24)
        directory = 40 + grammar + entropy
        metadata = directory + count * 32
        last = directory + (count - 1) * 32
        relative, encoded = struct.unpack_from("<QI", frame, last)
        frame[metadata + relative + encoded - 1] ^= 0x80
        self.frame.write_bytes(frame)
        result = self.cli(READER, "decode", self.frame, self.output, "--index", 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), raw[:4096])
        result = self.cli(READER, "decode", self.frame, self.output)
        self.assertNotEqual(result.returncode, 0)

    def test_shared_model_and_output_lifetimes(self):
        raw = ("独立所有の結果 العربية owned output \n".encode()) * 500
        self.encoded(raw, True)
        result = self.cli(READER, "lifetime-check", self.frame, self.output, "--index", 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), raw[4096:8192])
        self.assertTrue(json.loads(result.stdout)["lifetime_verified"])

    def test_fixed_consumed_batch_with_timings_disabled(self):
        self.encoded(b"repeated definitions and lexical data.\n" * 500)
        result = self.cli(READER, "bench-reader", self.frame, self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads(self.output.read_text())
        self.assertEqual(metrics["access_count"], 256)
        self.assertFalse(metrics["timing_enabled"])
        self.assertEqual(metrics["prepare_ns"], 0)
        self.assertEqual(metrics["decode_256_ns"], 0)
        self.assertGreater(metrics["decoded_bytes"], 0)
        self.assertLessEqual(metrics["distinct_logical_input_bytes"], metrics["frame_bytes"])
        result = self.cli(READER, "bench-reader", self.frame, self.output, "--measure", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timing requires quiet gate", result.stderr)

    def test_truncations_and_fixed_mutations(self):
        frame = self.encoded((bytes(range(256)) + b"prefix suffix stem\n") * 45, True)
        rng = random.Random(9912026)
        for _ in range(512):
            mutated = bytearray(frame)
            offset = rng.randrange(len(mutated))
            mutated[offset] ^= 1 << rng.randrange(8)
            self.frame.write_bytes(mutated)
            result = self.cli(READER, "decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, offset)
        for length in range(0, len(frame), max(1, len(frame) // 128)):
            self.frame.write_bytes(frame[:length])
            result = self.cli(READER, "decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, length)

    def test_resealed_directory_checks_and_file_bound(self):
        frame = bytearray(self.encoded(b"surface grammar frame\n" * 700))
        count, = struct.unpack_from("<I", frame, 12)
        grammar, entropy = struct.unpack_from("<II", frame, 24)
        directory = 40 + grammar + entropy
        metadata = directory + count * 32
        for offset, value in [(directory, 1), (directory + 8, 0),
                              (directory + 12, 0), (directory + 16, 0),
                              (directory + 20, 0xfffffff0), (directory + 24, 0),
                              (36, 99)]:
            mutated = bytearray(frame)
            struct.pack_into("<I", mutated, offset, value)
            mutated[32:36] = b"\0" * 4
            struct.pack_into("<I", mutated, 32, zlib.crc32(mutated[:metadata]))
            self.frame.write_bytes(mutated)
            result = self.cli(READER, "decode", self.frame, self.output)
            self.assertNotEqual(result.returncode, 0, offset)
        with self.frame.open("wb") as stream:
            stream.truncate((512 + 64) * 1024 * 1024 + 1)
        result = self.cli(READER, "decode", self.frame, self.output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mapped frame resource limit", result.stderr)

    def test_parameter_byte_allocation_is_bounded_by_roots(self):
        frame = bytearray(self.encoded(b"surface grammar phrase " * 700, True))
        flags, = struct.unpack_from("<I", frame, 36)
        self.assertTrue(flags & 16, "fixture must transmit the COPY parameter alphabet")
        count, = struct.unpack_from("<I", frame, 12)
        grammar, entropy = struct.unpack_from("<II", frame, 24)
        directory = 40 + grammar + entropy
        metadata = directory + count * 32
        for index in range(count):
            offset = directory + index * 32
            relative, encoded, raw, roots, primary = struct.unpack_from("<QIIII", frame, offset)
            if primary == 0xffffffff:
                continue
            distance_bytes = max(1, (raw.bit_length() + 6) // 7)
            malformed = bytearray(frame)
            struct.pack_into("<I", malformed, metadata + relative + 4,
                             roots * (2 + distance_bytes) + 1)
            self.frame.write_bytes(malformed)
            result = self.cli(READER, "decode", self.frame, self.output, "--index", index)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("prepared parameter count", result.stderr)
            self.assertFalse(self.output.exists())
            return
        self.fail("fixture must contain a compressed surface-binding block")


if __name__ == "__main__":
    unittest.main()
