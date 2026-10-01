"""Reject successful-looking timing logs with missing or wrong observations."""
import json
import unittest

from compare_rich import ACCESS, COMMON, REPEATED_SINGLE, parse


def sample():
    rows = [{"protocol": "LEX6-RICH-FRONTIER/1", "entries": 4, "mode": "raw"}]
    for name in sorted(COMMON | ACCESS | REPEATED_SINGLE):
        checksum = 81 if name in ACCESS else 99 if name in REPEATED_SINGLE else 4
        rows.append({"phase": name, "ns": 10, "alloc_calls": 0, "allocated_bytes": 0,
                     "peak_delta_bytes": 0, "checksum": checksum, "page_loads": 0})
    return rows


def wire(rows):
    return "\n".join(json.dumps(row) for row in rows)


class ProtocolTest(unittest.TestCase):
    def test_consistent_consumed_observations(self):
        result = parse(wire(sample()), 4, "raw")
        self.assertEqual(result["phases"]["cold_admitted_load"]["checksum"], 81)

    def test_wrong_projection_is_rejected(self):
        rows = sample()
        next(row for row in rows[1:] if row["phase"] == "prepared_cached_wire_projection")["checksum"] += 1
        with self.assertRaises(ValueError):
            parse(wire(rows), 4, "raw")

    def test_missing_duplicate_negative_or_wrong_workload(self):
        rows = sample()
        cases = [rows[:-1], rows + [rows[1]], [{**rows[0], "entries": 5}] + rows[1:],
                 [rows[0], {**rows[1], "ns": -1}] + rows[2:]]
        # Explicitly remove a required phase regardless of sorted names.
        cases[0] = [row for row in rows if row.get("phase") != "full_semantic_verification"]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                parse(wire(case), 4, "raw")


if __name__ == "__main__":
    unittest.main()
