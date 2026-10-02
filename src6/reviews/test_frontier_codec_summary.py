import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("summary", Path(__file__).with_name("summarize_frontier_codec.py"))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class EvidenceTests(unittest.TestCase):
    def row(self):
        return {"frame_sha256": "frame", "block_mode": "64k", "corpus": {"bytes": 131073, "sha256": "source"},
                "verification": {"frame_sha256": "frame", "fresh_full_exact": True,
                                 "fresh_restart_oracle_exact": 3}}

    def test_missing_last_restart_rejected(self):
        row = self.row()
        summary.verification(row)
        row["verification"]["fresh_restart_oracle_exact"] = 2
        with self.assertRaises(ValueError):
            summary.verification(row)

    def test_reuse_bound_to_both_source_and_frame(self):
        row = self.row()
        original = row["verification"]
        row["verification"] = {"reused_verified_frame_sha256": "frame", "source_sha256": "source",
                               "prior_verification": original}
        summary.verification(row)
        for field in ("source_sha256", "reused_verified_frame_sha256"):
            bad = copy.deepcopy(row)
            bad["verification"][field] = "other"
            with self.assertRaises(ValueError):
                summary.verification(bad)

    def test_full_oracle_required(self):
        row = self.row()
        row["verification"]["fresh_full_exact"] = False
        with self.assertRaises(ValueError):
            summary.verification(row)

    def test_whole_frame_requires_one_complete_decode(self):
        row = self.row()
        row["block_mode"] = "whole"
        row["verification"]["fresh_restart_oracle_exact"] = 1
        summary.verification(row)

    def test_incomplete_final_matrix_rejected(self):
        registry = {"size_candidates": ["a", "b"], "whole_control_candidates": [], "final_lane_count": 2}
        with self.assertRaises(ValueError):
            summary.summarize_sizes([], registry, "env", {})

    def test_failed_or_duplicate_size_rows_cannot_be_hidden(self):
        registry = {"size_candidates": ["a"], "whole_control_candidates": [], "final_lane_count": 1}
        failed = {"phase": "size", "status": "failed"}
        with self.assertRaisesRegex(ValueError, "failed or incomplete"):
            summary.summarize_sizes([failed], registry, "env", {})
        complete = {"phase": "size", "status": "complete", "capture_scope": "final-storage",
                    "corpus": {"name": "lane"}, "candidate": "a"}
        with self.assertRaisesRegex(ValueError, "duplicate"):
            summary.summarize_sizes([complete, complete], registry, "env", {})

    def test_snapshot_equality_does_not_replace_live_dependency_hash(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "decoder"
            path.write_bytes(b"old")
            environment = {"files": {str(path): {"bytes": 3, "sha256": summary.digest(path)}}}
            summary.verify_environment_files(environment)
            path.write_bytes(b"new")
            with self.assertRaisesRegex(ValueError, "frozen dependency changed"):
                summary.verify_environment_files(environment)
            path.unlink()
            with self.assertRaises(ValueError):
                summary.verify_environment_files(environment)

    def test_incomplete_timing_cannot_be_promoted(self):
        registry = {"timing_lanes": ["a"], "size_candidates": ["b"], "paired_fresh_process_samples": 5}
        with self.assertRaises(ValueError):
            summary.summarize_timing([], registry, {}, "env")

    def test_failed_or_duplicate_timing_rows_cannot_be_hidden(self):
        registry = {"timing_lanes": ["a"], "size_candidates": ["b"], "paired_fresh_process_samples": 5}
        with self.assertRaisesRegex(ValueError, "failed or incomplete"):
            summary.summarize_timing([{"phase": "timing", "status": "failed"}], registry, {}, "env")
        complete = {"phase": "timing", "status": "complete", "corpus": "a", "candidate": "b",
                    "operation": "full", "sample_index": 0}
        with self.assertRaisesRegex(ValueError, "duplicate"):
            summary.summarize_timing([complete, complete], registry, {}, "env")

    def test_missing_clock_not_zero_filled(self):
        for values in ([], [None], [0], [-1]):
            with self.assertRaises(ValueError):
                summary.distribution(values)
        self.assertEqual(summary.distribution([3, 1, 2])["median"], 2)

    def test_full_clock_scopes_are_distinct(self):
        self.assertNotEqual(summary.full_clock_scope("wordfrontier"), summary.full_clock_scope("native-control"))

    def test_query_scopes_distinguish_external_crc_work(self):
        self.assertIn("outside", summary.query_clock_scope("wsb2"))
        self.assertIn("outside", summary.query_clock_scope("native-control"))
        self.assertIn("plus source-page CRC fold", summary.query_clock_scope("wordfrontier"))

    def test_oracle_uses_exact_final_short_page(self):
        import zlib
        raw = b'a' * 65536 + b'b'
        expected = 1469598103934665603
        crcs = [zlib.crc32(b'a' * 65536), zlib.crc32(b'b'), zlib.crc32(b'b')]
        for access in range(256):
            expected = ((expected ^ crcs[access % 3]) * 1099511628211) & ((1 << 64) - 1)
        self.assertEqual(summary.query_oracle(raw), expected)

    def automatic(self):
        row = self.row()
        row.update({"candidate": "wordfrontier-quality", "frame_bytes": 123,
                    "accounting": {"sum_bytes": 123}})
        row["native_encoder_event"] = {
            "frame_sha256": "frame", "frame_bytes": 123, "source_sha256": "source",
            "source_bytes": 131073, "accounting": {"sum_bytes": 123}, "format": "WPG2",
            "policy": "wordfrontier-global/1", "runtime_sha256": {"reader": "reader-sha"},
            "policy_parameters": {"profile": "quality", "tie_order": ["WPG2", "GWT1"]},
            "tie_order": ["WPG2", "GWT1"], "fresh_native_full_decode_exact": True,
            "fresh_native_all_original_pages_exact": 3,
            "candidates": [{"format": "WPG2", "frame_bytes": 123, "encoder": {"archive_sha256": "frame"}},
                           {"format": "GWT1", "frame_bytes": 124, "encoder": {"frame_sha256": "other"}}]}
        import hashlib, json
        event = row["native_encoder_event"]
        event["policy_fingerprint"] = hashlib.sha256(json.dumps(
            {"parameters": event["policy_parameters"], "runtime_sha256": event["runtime_sha256"]},
            sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return row

    def test_automatic_identity_and_profile_gates(self):
        row = self.automatic()
        summary.check_automatic_choice(row)
        for field in ("frame_sha256", "source_sha256"):
            bad = copy.deepcopy(row)
            bad["native_encoder_event"][field] = "wrong"
            with self.assertRaises(ValueError):
                summary.check_automatic_choice(bad)
        row["native_encoder_event"]["policy_parameters"]["profile"] = "access"
        with self.assertRaises(ValueError):
            summary.check_automatic_choice(row)

    def test_automatic_loser_and_missing_family_rejected(self):
        row = self.automatic()
        row["native_encoder_event"]["candidates"][1]["frame_bytes"] = 122
        with self.assertRaises(ValueError):
            summary.check_automatic_choice(row)
        row = self.automatic()
        row["native_encoder_event"]["candidates"].pop()
        with self.assertRaises(ValueError):
            summary.check_automatic_choice(row)

    def test_exact_tie_keeps_declared_first_family(self):
        row = self.automatic()
        row["native_encoder_event"]["candidates"][1]["frame_bytes"] = 123
        summary.check_automatic_choice(row)
        row["native_encoder_event"]["format"] = "GWT1"
        with self.assertRaises(ValueError):
            summary.check_automatic_choice(row)

    def test_runtime1_parity_requires_complete_frame_and_source_identity(self):
        old = {"corpus": {"sha256": "source"}, "frame_sha256": "frame", "frame_bytes": 123}
        row = copy.deepcopy(old)
        row["runtime1_frame_parity"] = {"status": "byte-identical", "runtime1_frame_sha256": "frame",
                                        "runtime1_frame_bytes": 123}
        summary.check_runtime1_counterpart(row, old)
        for field, value in (("frame_sha256", "other"), ("frame_bytes", 124)):
            bad = copy.deepcopy(row)
            bad[field] = value
            with self.assertRaises(ValueError):
                summary.check_runtime1_counterpart(bad, old)
        row["corpus"]["sha256"] = "other-source"
        with self.assertRaises(ValueError):
            summary.check_runtime1_counterpart(row, old)

    def test_runtime1_parity_cannot_be_missing_or_invented(self):
        old = {"corpus": {"sha256": "source"}, "frame_sha256": "frame", "frame_bytes": 123}
        row = copy.deepcopy(old)
        with self.assertRaises(ValueError):
            summary.check_runtime1_counterpart(row, old)
        with self.assertRaises(ValueError):
            summary.check_runtime1_counterpart(row, None)
        row["runtime1_frame_parity"] = {"status": "no-complete-runtime1-counterpart"}
        summary.check_runtime1_counterpart(row, None)
        with self.assertRaises(ValueError):
            summary.check_runtime1_counterpart(row, old)


if __name__ == "__main__":
    unittest.main()
