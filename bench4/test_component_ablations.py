#!/usr/bin/env python3
"""Tests for the retained canonical entropy component evidence gate."""

from __future__ import annotations

import unittest

from report import _measured_entropy_ablation


def _variant(name: str, *, digest: str, bytes_count: int, reader_ns: int) -> dict[str, object]:
    return {
        "artifact": f"artifacts/component-ablations/{name}.ens4",
        "artifact_sha256": "a" * 64,
        "artifact_bytes": bytes_count,
        "build_ns": 10,
        "open_ns": 11,
        "verify_ns": 12,
        "verified": True,
        "semantic_equal": True,
        "oracle_digest": digest,
        "timing_boundary": "canonical entropy.View reader operation",
        "reader_p50_ns": reader_ns,
        "raw_observation_count": 4,
        "raw_observations": "raw/component-ablations.jsonl",
    }


class ComponentAblationReportTests(unittest.TestCase):
    def test_all_lanes_are_retained_as_measured_rows(self) -> None:
        lanes = []
        for lane, digest, entropy_bytes, packed_bytes in (
            ("low", "digest-low", 120, 84),
            ("medium", "digest-medium", 392, 116),
            ("high", "digest-high", 656, 172),
        ):
            lanes.append(
                {
                    "status": "measured",
                    "lane": lane,
                    "oracle_digest": digest,
                    "variants": {
                        "entropy": _variant(f"{lane}-entropy", digest=digest, bytes_count=entropy_bytes, reader_ns=100),
                        "packed": _variant(f"{lane}-packed", digest=digest, bytes_count=packed_bytes, reader_ns=50),
                    },
                }
            )
        evidence = {
            "entropy_vs_packed": {
                "status": "measured",
                "evidence_paths": {
                    "ledger": "raw/component-ablations.jsonl",
                    "provenance": "provenance.json",
                },
                "lanes": lanes,
            }
        }
        result = _measured_entropy_ablation(evidence)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual("measured", result["status"])
        self.assertEqual(["low", "medium", "high"], [lane["lane"] for lane in result["lanes"]])
        self.assertEqual(3, len(result["lanes"]))

    def test_pseudo_artifact_and_empty_paths_stay_unavailable(self) -> None:
        candidate = {
            "status": "measured",
            "oracle_digest": "digest",
            "evidence_paths": {},
            "variants": {
                "entropy": _variant("entropy", digest="digest", bytes_count=120, reader_ns=100),
                "packed": _variant("packed", digest="digest", bytes_count=84, reader_ns=50),
            },
        }
        self.assertIsNone(_measured_entropy_ablation({"entropy_vs_packed": candidate}))

        candidate["evidence_paths"] = {"ledger": "raw/component-ablations.jsonl"}
        candidate["variants"]["entropy"]["artifact"] = "memory://not-retained"
        self.assertIsNone(_measured_entropy_ablation({"entropy_vs_packed": candidate}))


if __name__ == "__main__":
    unittest.main()
