"""Independent native-control framing/roundtrip/extraction checks."""
import json
from pathlib import Path
import random
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
BIN = ROOT / "native-controls"


class NativeControls(unittest.TestCase):
    def run_command(self, *args, okay=True):
        result = subprocess.run([str(BIN), *map(str, args)], capture_output=True)
        if okay:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_roundtrip_and_every_independent_block(self):
        rng = random.Random(701)
        cases = [b"", b"x", bytes(range(256)), rng.randbytes(32781),
                 ("كتاب كتب العربية talossa taloista evlerimizden 中文词语 日本語 e\u0301\n" * 800).encode()]
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            source, frame, restored = [directory / item for item in ("input", "frame", "output")]
            for codec in ("bzip2", "bzip3", "zstd", "xz"):
                for case in cases:
                    with self.subTest(codec=codec, bytes=len(case)):
                        source.write_bytes(case)
                        stats = self.run_command("encode", codec, source, frame, "--block", 16384)
                        self.assertEqual(stats["output_bytes"], frame.stat().st_size)
                        self.run_command("decode", codec, frame, restored)
                        self.assertEqual(restored.read_bytes(), case)
                        for index, off in enumerate(range(0, len(case), 16384)):
                            self.run_command("decode-block", codec, frame, restored, "--index", index)
                            self.assertEqual(restored.read_bytes(), case[off:off+16384])

    def test_rejects_corrupt_metadata_and_extent(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            source, frame, bad, output = [directory / item for item in ("source", "frame", "bad", "output")]
            source.write_bytes(b"alphabet dictionary morphological segments " * 1000)
            for codec in ("bzip2", "bzip3", "zstd", "xz"):
                self.run_command("encode", codec, source, frame, "--block", 16384)
                raw = frame.read_bytes()
                for position in (0, 8, 10, 12, 16, 24, 28, 32, 40, 44):
                    modified = bytearray(raw)
                    modified[position] ^= 1
                    bad.write_bytes(modified)
                    self.run_command("decode", codec, bad, output, okay=False)
                for modified in (raw[:-1], raw + b"\0", raw[:31]):
                    bad.write_bytes(modified)
                    self.run_command("decode", codec, bad, output, okay=False)
                self.run_command("decode-block", codec, frame, output, "--index", 1000000, okay=False)


if __name__ == "__main__":
    unittest.main()
