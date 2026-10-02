"""Correctness-only coverage for the persistent native-control reader."""
import json
import random
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parent
CONTROLS = ROOT / "native-controls"
READER = ROOT / "native-controls-reader"


class PersistentReaderTests(unittest.TestCase):
    def run_cli(self, exe, *args, okay=True):
        result = subprocess.run([str(exe), *map(str, args)], capture_output=True)
        if okay:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            return result
        self.assertNotEqual(result.returncode, 0)
        return result

    def test_all_codecs_verify_every_block_and_same_256_query_batch(self):
        rng = random.Random(20261001)
        # Three pages ensure first, middle, and last are distinct; tail is short.
        source_bytes = (
            ("كتاب talossa evlerimizden 中文词语 日本語 e\u0301\n" * 8000).encode()
            + rng.randbytes(17000)
        )[: 2 * 65536 + 317]
        self.assertEqual(len(source_bytes) % 65536, 317)
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp)
            raw, frame, output, report, wrong = [d / n for n in
                ("raw", "frame", "output", "report.json", "wrong")]
            raw.write_bytes(source_bytes)
            for codec in ("bzip2", "bzip3", "zstd", "xz"):
                with self.subTest(codec=codec):
                    self.run_cli(CONTROLS, "encode", codec, raw, frame, "--block", 65536)
                    verified = self.run_cli(READER, codec, frame, raw, report,
                                            "--mode", "verify")
                    verification = json.loads(verified.stdout)
                    self.assertTrue(verification["all_blocks_oracle_verified"])
                    completed = self.run_cli(READER, codec, frame, raw, report,
                                             "--mode", "query")
                    stats = json.loads(completed.stdout)
                    self.assertEqual(stats["query_count"], 256)
                    self.assertEqual(stats["query_indices"], [0, 1, 2])
                    self.assertFalse(stats["all_blocks_oracle_verified"])
                    self.assertTrue(stats["query_oracle_verified"])
                    self.assertFalse(stats["measure_enabled"])
                    expected_checksum = 1469598103934665603
                    for index in ([0, 1, 2] * (256 // 3)) + [0]:
                        chunk = source_bytes[index * 65536:min((index + 1) * 65536,
                                                                len(source_bytes))]
                        expected_checksum = ((expected_checksum ^ zlib.crc32(chunk))
                                             * 1099511628211) & ((1 << 64) - 1)
                    self.assertEqual(stats["query_checksum"], expected_checksum)
                    self.assertEqual(stats["blocks"], 3)
                    self.assertEqual(stats["raw_bytes"], len(source_bytes))
                    self.assertGreaterEqual(stats["prepare_ns"], 0)
                    self.assertGreaterEqual(stats["query_256_ns"], 0)

                    full = json.loads(self.run_cli(READER, codec, frame, raw, report,
                                                   "--mode", "full").stdout)
                    self.assertTrue(full["all_blocks_oracle_verified"])
                    self.assertEqual(full["query_count"], 0)

                    wrong.write_bytes(source_bytes[:-1] + bytes([source_bytes[-1] ^ 1]))
                    self.run_cli(READER, codec, frame, wrong, report, okay=False)

    def test_clock_requires_explicit_environment_gate(self):
        raw_bytes = b"one access test page " * 4000
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp)
            raw, frame, report = d / "raw", d / "frame", d / "report"
            raw.write_bytes(raw_bytes)
            self.run_cli(CONTROLS, "encode", "zstd", raw, frame, "--block", 65536)
            command = ["zstd", frame, raw, report, "--mode", "query", "--measure", "1", "--quiet-gate",
                       "FRONTIER2026-ACCESS-QUIET"]
            result = subprocess.run([str(READER), *command], capture_output=True,
                                    env={k: v for k, v in __import__("os").environ.items()
                                         if k != "FRONTIER2026_ACCESS_QUIET"})
            self.assertNotEqual(result.returncode, 0)

    def test_rejects_bad_frames_before_querying(self):
        source_bytes = b"frame validation and restart checks\n" * 5000
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp)
            raw, frame, bad, report = [d / n for n in ("raw", "frame", "bad", "report")]
            raw.write_bytes(source_bytes)
            self.run_cli(CONTROLS, "encode", "zstd", raw, frame, "--block", 65536)
            original = frame.read_bytes()
            for changed in (original[:31], original[:-1], original + b"x"):
                bad.write_bytes(changed)
                self.run_cli(READER, "zstd", bad, raw, report, okay=False)
            altered = bytearray(original)
            altered[28] ^= 1  # metadata checksum
            bad.write_bytes(altered)
            self.run_cli(READER, "zstd", bad, raw, report, okay=False)


if __name__ == "__main__":
    unittest.main()
