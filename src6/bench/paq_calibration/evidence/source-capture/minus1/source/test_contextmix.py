import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "paq_contextmix_capture", Path(__file__).with_name("capture_contextmix.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class ContextMixCaptureTests(unittest.TestCase):
    def test_one_pinned_context_profile_and_larger_budget(self):
        self.assertEqual(CAPTURE.PROFILE, "-1")
        self.assertEqual(CAPTURE.MEMORY_LIMIT, 1024 * 1024 * 1024)
        self.assertEqual(CAPTURE.TIMEOUT_SECONDS, 180)

    def test_programchecker_field_does_not_claim_rss(self):
        sample = b"Time 12.34 sec, used 583 MB (611319808 bytes) of memory"
        self.assertEqual(CAPTURE._reported_paq_memory_kib(sample), 611319808 // 1024)
        self.assertIsNone(CAPTURE._reported_paq_memory_kib(b"resource error"))

    def test_fixed_inputs_still_match_frozen_controls(self):
        books = CAPTURE.selected_books(
            Path("/workspace/scratch/books2026-dev/manifest.json"),
            Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json"))
        self.assertEqual(len(books), 6)
        self.assertTrue(all(item["source_sha256"] and item["bzip3_frame_sha256"] for item in books))


if __name__ == "__main__":
    unittest.main()
