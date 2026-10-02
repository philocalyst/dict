import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location("paq_capture", Path(__file__).with_name("capture.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class CaptureTests(unittest.TestCase):
    def test_pinned_checkout_is_clean_and_fully_fingerprinted(self):
        evidence = CAPTURE.tree_fingerprint(Path("/tmp/paq8px-v217"))
        self.assertEqual(evidence["commit"], CAPTURE.EXPECTED_COMMIT)
        self.assertEqual(evidence["git_status_porcelain"], "")
        self.assertGreater(len(evidence["files"]), 100)
        self.assertEqual(len(evidence["tree_sha256"]), 64)

    def test_frozen_six_prefixes_match_controls(self):
        books = CAPTURE.selected_books(
            Path("/workspace/scratch/books2026-dev/manifest.json"),
            Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json"))
        self.assertEqual(len(books), 6)
        self.assertTrue(all(row["source_bytes"] <= 1048576 for row in books))
        self.assertTrue(all(row["source_sha256"] and row["bzip3_frame_sha256"] for row in books))
        self.assertTrue(all(row["bzip3_bytes"] > 0 for row in books))

    def test_mutated_control_manifest_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "controls.json"
            bad.write_text('{"complete": false}')
            with self.assertRaises(RuntimeError):
                CAPTURE.selected_books(Path("/workspace/scratch/books2026-dev/manifest.json"), bad)

    def test_reported_native_memory_is_parsed_in_bytes(self):
        self.assertEqual(CAPTURE._reported_rss(b"Time 1 sec, used 20 MB (22882747 bytes) of memory"),
                         22882747 // 1024)
        self.assertIsNone(CAPTURE._reported_rss(b"out of memory"))


if __name__ == "__main__":
    unittest.main()
