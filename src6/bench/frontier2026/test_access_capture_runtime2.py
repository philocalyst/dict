"""No-codec tests for the isolated resource-only runtime-2 capture wrapper."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import access_capture_runtime2 as runtime2
import access_capture as capture


class Runtime2CaptureTests(unittest.TestCase):
    def write_runtime2_capture(self, out, count=352):
        out.mkdir(parents=True)
        frame = out / "frame.bin"
        frame.write_bytes(b"frame")
        frozen = out / "frozen-input.bin"
        frozen.write_bytes(b"frozen")
        rows = [{"phase": "size", "status": "complete", "cell_key": f"cell-{i}",
                 "frame_path": str(frame), "frame_bytes": frame.stat().st_size}
                for i in range(count)]
        (out / "results.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        status = {"phase": "size", "error": None, "active_cell": None,
                  "completed_cells": count, "total_cells": 352}
        (out / "status.json").write_text(json.dumps(status))
        fingerprint = {"files": {str(frozen): {"bytes": frozen.stat().st_size}}}
        (out / "environment-start.json").write_text(json.dumps(fingerprint))
        (out / "environment-end.json").write_text(json.dumps(fingerprint))

    def test_new_protocol_preserves_the_full_frozen_matrix(self):
        protocol = json.loads((HERE / "runtime2_capture_protocol.json").read_text())
        registry = json.loads(capture.CAPTURE_REGISTRY.read_text())
        self.assertEqual(protocol["matrix"]["final_lanes"], 22)
        self.assertEqual(protocol["matrix"]["matched_candidates"], len(registry["size_candidates"]))
        self.assertEqual(protocol["matrix"]["whole_frame_native_controls"], 4)
        self.assertEqual(protocol["matrix"]["total_cells"], 352)
        self.assertEqual(protocol["canonical_commit"], registry["canonical_commit"])
        self.assertEqual(protocol["backend_manifest_sha256"], runtime2.RUNTIME2_MANIFEST_SHA256)

    def test_manifest_pin_prevents_pre_freeze_capture(self):
        runtime2.verify_runtime2_manifest()

    def test_raw_m_candidates_fingerprint_reclaim_source(self):
        rows = runtime2.runtime2_candidates()
        raw_m = [row for row in rows if row.get("kind") == "raw-m"]
        self.assertEqual(len(raw_m), 2)
        self.assertTrue(all(row["source_files"] == [
            "/workspace/dict/src6/experiments/wordgrammar/wgp6/m_reference_reclaim.zig"
        ] for row in raw_m))

    def test_zlib_runtime_records_file_origin_and_linked_files(self):
        paths = runtime2.zlib_runtime_paths()
        origin = str(getattr(runtime2.zlib.__spec__, "origin", "built-in"))
        if origin not in ("built-in", "frozen") and Path(origin).is_file():
            self.assertIn(Path(origin).resolve(), paths)
            self.assertTrue(all(path.is_file() for path in paths))
        else:
            self.assertEqual(paths, ())

    def test_runtime2_timing_rejects_partial_size_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "capture"
            self.write_runtime2_capture(out, count=351)
            with self.assertRaises(capture.CaptureError):
                runtime2.validate_runtime2_size_capture(out)

    def test_runtime2_timing_rejects_missing_environment_end(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "capture"
            self.write_runtime2_capture(out)
            (out / "environment-end.json").unlink()
            with self.assertRaises(capture.CaptureError):
                runtime2.validate_runtime2_size_capture(out)

    def test_runtime2_timing_rejects_changed_environment_fingerprint(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "capture"
            self.write_runtime2_capture(out)
            (out / "environment-end.json").write_text(json.dumps({"files": {}}))
            with self.assertRaises(capture.CaptureError):
                runtime2.validate_runtime2_size_capture(out)

    def test_runtime1_completed_frame_parity_is_checked_and_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old_results = runtime2.RUNTIME1_RESULTS
            old_frame = root / "runtime1.bin"
            new_frame = root / "runtime2.bin"
            old_frame.write_bytes(b"same complete frame")
            new_frame.write_bytes(b"same complete frame")
            source_sha = "source-sha"
            baseline = {
                "phase": "size", "status": "complete", "candidate": "codec-a",
                "block_mode": "64k", "frame_path": str(old_frame),
                "frame_bytes": old_frame.stat().st_size,
                "frame_sha256": capture.file_sha(old_frame),
                "corpus": {"name": "lane-a", "sha256": source_sha},
            }
            runtime2.RUNTIME1_RESULTS = root / "runtime1-results.jsonl"
            runtime2.RUNTIME1_RESULTS.write_text(json.dumps(baseline) + "\n")
            original_commit = runtime2.add_runtime1_parity()
            try:
                store = capture.Store(root / "runtime2")
                row = {
                    "phase": "size", "status": "complete", "cell_key": "cell-a",
                    "candidate": "codec-a", "block_mode": "64k",
                    "frame_path": str(new_frame), "frame_bytes": new_frame.stat().st_size,
                    "frame_sha256": capture.file_sha(new_frame),
                    "corpus": {"name": "lane-a", "sha256": source_sha},
                }
                store.commit(row)
                saved = json.loads(store.results.read_text())
                self.assertEqual(saved["runtime1_frame_parity"]["status"], "byte-identical")

                new_frame.write_bytes(b"different complete frame")
                mismatch = {**row, "cell_key": "cell-b",
                            "frame_bytes": new_frame.stat().st_size,
                            "frame_sha256": capture.file_sha(new_frame)}
                with self.assertRaises(capture.CaptureError):
                    store.commit(mismatch)
            finally:
                capture.Store.commit = original_commit
                runtime2.RUNTIME1_RESULTS = old_results


if __name__ == "__main__":
    unittest.main()
