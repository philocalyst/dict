"""Fast integrity tests for the durable access capture framework."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import access_capture as capture


class AccessCaptureTests(unittest.TestCase):
    def test_registry_matches_exact_final_and_core_lane_matrix(self):
        registry = json.loads(capture.CAPTURE_REGISTRY.read_text())
        lanes = capture.load_corpora(capture.DEFAULT_MANIFEST)
        candidates = capture.candidates()
        self.assertEqual(len(lanes), 22)
        self.assertEqual(sum(capture.core_lane(row) for row in lanes), 17)
        self.assertEqual([row["name"] for row in candidates], registry["size_candidates"])
        self.assertEqual([row["name"] for row in lanes if capture.core_lane(row)],
                         sorted(registry["timing_lanes"]))

    def test_completed_rows_resume_only_with_same_frame_and_fingerprint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = capture.Store(root)
            frame = root / "frame"
            frame.write_bytes(b"exact frame bytes")
            row = {"cell_key": "cell-a", "status": "complete",
                   "frame_sha256": capture.file_sha(frame),
                   "frozen_fingerprint_sha256": "guard-a"}
            store.commit(row)
            resumed = capture.Store(root)
            self.assertTrue(resumed.done("cell-a", frame, "guard-a"))
            self.assertFalse(resumed.done("cell-a", frame, "guard-b"))
            frame.write_bytes(b"changed frame bytes")
            self.assertFalse(resumed.done("cell-a", frame, "guard-a"))

    def test_native_control_ledger_is_complete_and_rejects_bad_total(self):
        # WCTR26 header + two exact directory records + payload.
        raw = 65536 + 17
        count = 2
        frame_bytes = 32 + count * 16 + 1234
        header = bytearray(32)
        header[:8] = b"WCTR26\0\0"
        header[8] = 1
        header[9] = 3
        header[12:16] = (65536).to_bytes(4, "little")
        header[16:24] = raw.to_bytes(8, "little")
        header[24:28] = count.to_bytes(4, "little")
        frame = bytes(header) + bytes(count * 16 + 1234)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "frame"
            path.write_bytes(frame)
            event = {"frame_bytes": frame_bytes, "raw_bytes": raw}
            ledger = capture.exact_ledger("native-control", path, event, raw)
            self.assertEqual(ledger["sum_bytes"], frame_bytes)
            with self.assertRaises(capture.CaptureError):
                capture.exact_ledger("native-control", path, event, raw + 1)

    def test_cell_log_keeps_raw_process_output_and_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "calls.jsonl"
            result, _ = capture.run_process(
                ["python3", "-c", "import sys; print('{\\\"ok\\\":true}'); print('detail', file=sys.stderr)"],
                {}, log, stage="mock")
            self.assertEqual(result.returncode, 0)
            event = json.loads(log.read_text().splitlines()[0])
            self.assertEqual(event["stage"], "mock")
            self.assertEqual(event["returncode"], 0)
            self.assertIn('"ok":true', event["stdout"])
            self.assertIn("detail", event["stderr"])

    def test_access_commands_pin_native_page_geometry_and_keep_operations_separate(self):
        candidate_map = {row["name"]: row for row in capture.candidates()}
        raw, frame, graph = Path("/raw"), Path("/frame"), Path("/graph")
        for name in ("bzip2-9", "sbwt-word-grammar",
                     "wordfrontier-quality", "laneA-plus-M-quality-raw"):
            candidate = candidate_map[name]
            command = capture.direct_command(candidate, raw, frame, graph)
            self.assertTrue(command)
            self.assertNotIn("{input}", " ".join(command))
        control = candidate_map["bzip2-9"]
        full = capture.timing_command(control, frame, raw, Path("/report"), Path("/output"), "full", 1)
        query = capture.timing_command(control, frame, raw, Path("/report"), Path("/output"), "query", 1)
        self.assertIn("decode", full)
        self.assertIn("--mode", query)
        self.assertIn("query", query)
        self.assertIn("FRONTIER2026-ACCESS-QUIET", query)

    def test_query_checksum_matches_fixed_source_page_schedule(self):
        import zlib
        data = (bytes(range(251)) * 600)[: 2 * 65536 + 13]
        indices = (0, 1, 2)
        expected = 1469598103934665603
        for access in range(256):
            index = indices[access % 3]
            page = data[index * 65536:min((index + 1) * 65536, len(data))]
            expected = ((expected ^ zlib.crc32(page)) * 1099511628211) & ((1 << 64) - 1)
        self.assertEqual(capture.expected_query_checksum(data), expected)


if __name__ == "__main__":
    unittest.main()
