#!/usr/bin/env python3
"""Check exact logical ranges across word-aligned legacy restart boundaries."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

ENCODER = os.environ.get("BZ4_ENCODER", "/tmp/frontier2026-bzip4-v3")
READER = os.environ.get("BZ4_READER", "/tmp/frontier2026-bz4-reader")


class RetainedLegacyJobs(unittest.TestCase):
    def test_ranges_and_consumed_batch_after_all_deltas(self):
        fixtures = [
            (("東京都 словоформа العربية Türkçe deutsch\n" * 1900).encode()
             + b"x" * 2999 + b"\n" + (b"unrepeated changed WORD 123 \xff\xfe\n" * 2300)),
            bytes(range(256)) * 601,
        ]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for number, raw in enumerate(fixtures):
                with self.subTest(fixture=number):
                    source, frame, output = (directory / n for n in ("source", "frame", "output"))
                    source.write_bytes(raw)
                    subprocess.run([ENCODER, "encode", str(source), str(frame), "--block", "65536"],
                                   check=True, capture_output=True)
                    subprocess.run([READER, "decode", str(frame), str(output)],
                                   check=True, capture_output=True)
                    self.assertEqual(output.read_bytes(), raw)
                    count = (len(raw) + 65535) // 65536
                    for index in range(count):
                        subprocess.run([READER, "decode", str(frame), str(output), "--index", str(index)],
                                       check=True, capture_output=True)
                        self.assertEqual(output.read_bytes(), raw[index * 65536:(index + 1) * 65536])
                    subprocess.run([READER, "bench-reader", str(frame), str(output), "--measure", "0"],
                                   check=True, capture_output=True)
                    evidence = json.loads(output.read_text())
                    checksum, consumed = 1469598103934665603, 0
                    for access in range(256):
                        index = (0, count // 2, count - 1)[access % 3]
                        chunk = raw[index * 65536:(index + 1) * 65536]
                        consumed += len(chunk)
                        checksum = ((checksum ^ zlib.crc32(chunk)) * 1099511628211) & ((1 << 64) - 1)
                    self.assertEqual(evidence["checksum"], checksum)
                    self.assertEqual(evidence["decoded_bytes"], consumed)
                    self.assertFalse(evidence["timing_enabled"])
                    self.assertEqual(evidence["prepare_ns"], 0)
                    self.assertEqual(evidence["decode_256_ns"], 0)
                    self.assertGreaterEqual(evidence["decoded_jobs"], 256)
                    self.assertGreater(evidence["decoder_arena_reserved_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
