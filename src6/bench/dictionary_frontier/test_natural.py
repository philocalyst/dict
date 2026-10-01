"""Validate natural access evidence without executing benchmark timings."""
from __future__ import annotations

import contextlib
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import compare_natural as natural
from compare import file_record


def sample(artifact, *, wire=False, codec="raw", entries=3, operations=4, lengths=None):
    lengths = lengths or {"all": 30, "samepage": 40, "mixed": 40}
    rows = [{"protocol": natural.PROTOCOL, "archive": artifact["path"],
             "archive_bytes": artifact["bytes"], "entries": entries, "pages": 2,
             "operations": operations,
             "workload": "natural source projection: headword plus complete single-definition Inline.text",
             "shape_gate": "all entries; exactly one definition containing exactly one Inline.text",
             "cold": "fresh application page cache; memory-resident previously touched bytes",
             "allocation_accounting": "none; this client reports time, page loads, consumed bytes, and checksum"}]
    names = ["open", "full_semantic_verification", "native_samepage_reader_init",
             "native_samepage_access", "native_mixed_reader_init", "native_mixed_access"]
    if wire:
        names += ["wire_samepage_reader_init", "wire_samepage_access", "wire_mixed_reader_init", "wire_mixed_access"]
    for name in names:
        if name == "full_semantic_verification":
            checksum, consumed, ops, pages = entries, 0, entries, 2
        elif name == "open":
            checksum, consumed, ops, pages = entries, 0, 0, 0
        elif name.endswith("_access"):
            workload = "samepage" if "samepage" in name else "mixed"
            checksum, consumed, ops = (41 if workload == "samepage" else 82), lengths[workload], operations
            pages = 0 if name.startswith("wire") and codec == "raw" else (1 if workload == "samepage" else 2)
        else:
            checksum, consumed, ops, pages = 0, 0, 0, 0
        rows.append({"phase": name, "ns": 10, "checksum": checksum,
                     "consumed_bytes": consumed, "operations": ops, "page_loads": pages})
        if name == "full_semantic_verification":
            rows.append({"gate": "all_entries_validated", "entries": entries,
                         "checksum": 12345, "consumed_bytes": lengths["all"]})
    return rows


def wire(rows):
    return "\n".join(json.dumps(row) for row in rows)


def row_named(rows, name):
    return next(row for row in rows if row.get("phase") == name)


class ProtocolTest(unittest.TestCase):
    artifact = {"path": "/archive.lex6", "bytes": 123}

    def parse(self, rows, *, prepared=False, codec="raw", oracle=None):
        return natural.parse(wire(rows), self.artifact, 3, 4, wire=prepared, codec=codec, oracle_bytes=oracle)

    def test_valid_native_and_prepared_protocols(self):
        before = self.parse(sample(self.artifact))
        for codec in ("raw", "adaptive"):
            after = self.parse(sample(self.artifact, wire=True, codec=codec), prepared=True, codec=codec)
            natural.compare_observations(before, after)
            self.assertEqual(after["gate"]["entries"], 3)

    def test_incomplete_duplicate_or_extra_phases_and_gates(self):
        rows = sample(self.artifact, wire=True)
        cases = [rows[:-1], rows + [rows[1]], rows + [rows[3]],
                 [row for row in rows if "gate" not in row],
                 rows + [{"gate": "unexpected", "entries": 3, "checksum": 0, "consumed_bytes": 0}],
                 rows + [{**rows[-1], "phase": "unaccounted_access"}]]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.parse(case, prepared=True)
        with self.assertRaises(ValueError):
            self.parse(rows)
        with self.assertRaises(ValueError):
            self.parse(sample(self.artifact), prepared=True)

    def test_wrong_header_or_noninteger_counts_are_rejected(self):
        rows = sample(self.artifact)
        for field, value in (("protocol", "wrong"), ("archive", "/other.lex6"),
                             ("archive_bytes", 124), ("entries", 2), ("operations", 5),
                             ("pages", 0), ("pages", 4), ("pages", True),
                             ("cold", "disk cold"), ("shape_gate", "selected entries only")):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.parse([{**rows[0], field: value}] + rows[1:])
        for field in natural.PHASE_FIELDS:
            for invalid in (-1, True, 1.5, "1", None):
                altered = copy.deepcopy(rows)
                altered[1][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    self.parse(altered)
        altered = copy.deepcopy(rows)
        altered[1]["checksum"] = 1 << 64
        with self.assertRaises(ValueError):
            self.parse(altered)

    def test_setup_and_batch_boundaries_are_checked(self):
        for name, field, value in (("open", "checksum", 4), ("open", "consumed_bytes", 1),
                                   ("full_semantic_verification", "operations", 2),
                                   ("full_semantic_verification", "page_loads", 1),
                                   ("native_samepage_reader_init", "page_loads", 1),
                                   ("native_samepage_access", "operations", 3),
                                   ("native_samepage_access", "page_loads", 0),
                                   ("native_mixed_access", "page_loads", 1),
                                   ("native_mixed_access", "page_loads", 3),
                                   ("wire_samepage_access", "page_loads", 1)):
            rows = sample(self.artifact, wire=True)
            row_named(rows, name)[field] = value
            with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                self.parse(rows, prepared=True)

    def test_full_bytes_and_checksums_must_match_each_path(self):
        for field in ("checksum", "consumed_bytes"):
            rows = sample(self.artifact, wire=True)
            row_named(rows, "wire_mixed_access")[field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.parse(rows, prepared=True)
        before = self.parse(sample(self.artifact))
        after = self.parse(sample(self.artifact, wire=True), prepared=True)
        for field in ("checksum", "consumed_bytes", "entries"):
            changed = copy.deepcopy(after)
            changed["gate"][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                natural.compare_observations(before, changed)
        changed = copy.deepcopy(after)
        changed["phases"]["native_mixed_access"]["consumed_bytes"] += 1
        with self.assertRaises(ValueError):
            natural.compare_observations(before, changed)

    def test_independent_oracle_catches_matching_but_incomplete_results(self):
        oracle = {"all": 30, "samepage": 40, "mixed": 40}
        self.parse(sample(self.artifact, wire=True), prepared=True, oracle=oracle)
        for component in oracle:
            changed = {**oracle, component: oracle[component] + 1}
            with self.subTest(component=component), self.assertRaises(ValueError):
                self.parse(sample(self.artifact, wire=True), prepared=True, oracle=changed)

    def test_summary_retains_all_phases_setup_and_actual_loads(self):
        first = self.parse(sample(self.artifact, wire=True), prepared=True)
        second = copy.deepcopy(first)
        for row in second["phases"].values():
            row["ns"] = 20
        result = natural.summarize([first, second])
        self.assertEqual(set(result["phases"]), natural.COMMON | natural.WIRE)
        self.assertEqual(result["phases"]["wire_mixed_access"]["ns"], {"min": 10, "median": 15, "max": 20})
        self.assertEqual(result["phases"]["wire_mixed_access"]["page_loads"]["median"], 0)
        self.assertEqual(result["prepared_setup"]["mixed"]["open_full_verification_and_reader_init_ns"]["median"], 45)
        second["gate"]["checksum"] += 1
        with self.assertRaises(ValueError):
            natural.summarize([first, second])


class ArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report = {"schema": 1, "status": "complete-verified", "sources": {"before": [], "after": []},
                       "dependencies": {"fixture": True}, "corpora": []}
        records = [("猫", "猫の定義", "別名"), ("كتاب", "описание", "alias"), ("word", "English prose", "other")]
        for index in range(5):
            final = self.root / f"dictionary{index}" / "final"
            final.mkdir(parents=True)
            projection = final / "projection.tsv"
            projection.write_text("".join(
                f"{str(row).encode().hex()}\t{head.encode().hex()},{alias.encode().hex()}\t{content.encode().hex()}\n"
                for row, (head, content, alias) in enumerate(records)), encoding="ascii")
            corpus = {"name": f"dictionary{index}-final", "projection": file_record(projection), "records": 3, "lanes": []}
            self.report["corpora"].append(corpus)
            for codec in ("raw", "adaptive"):
                lane = {"codec": codec, "sizes": []}
                corpus["lanes"].append(lane)
                for version in ("before", "after"):
                    artifact = final / f"{codec}-{version}.lex6"
                    artifact.write_bytes(f"artifact-{index}-{codec}-{version}".encode())
                    lane["sizes"].append({"lane": version, "target_page_bytes": 65536,
                                          "artifact": file_record(artifact), "validated": {
                                              "status": "smoke-ok", "entries": 3, "loaded_entries": 3,
                                              "hits": 6, "key_bytes": 32, "content_bytes": 52,
                                              "query_checks": 4, "all_hit_digest": "a" * 64,
                                              "loaded_content_digest": "b" * 64}})

    def test_unicode_primary_keys_complete_text_and_fixed_ordinals(self):
        lanes = natural.artifact_lanes(self.report, 4)
        self.assertEqual(len(lanes), 10)
        projection = Path(self.report["corpora"][0]["projection"]["path"])
        lengths = [len("猫".encode()) + len("猫の定義".encode()),
                   len("كتاب".encode()) + len("описание".encode()),
                   len(b"word") + len(b"English prose")]
        self.assertEqual(natural.projection_bytes(projection, 3, 4),
                         {"all": sum(lengths), "samepage": 4 * lengths[0],
                          "mixed": lengths[0] * 2 + lengths[1] + lengths[2]})
        self.assertEqual(natural.projection_bytes(projection, 3, 1)["mixed"], lengths[0])

    def test_stale_artifact_and_projection_are_rejected(self):
        for record in (self.report["corpora"][0]["projection"],
                       self.report["corpora"][0]["lanes"][0]["sizes"][0]["artifact"]):
            path = Path(record["path"])
            initial = path.read_bytes()
            path.write_bytes(initial + b"changed")
            with self.subTest(path=path), self.assertRaises(ValueError):
                natural.artifact_lanes(self.report, 4)
            path.write_bytes(initial)

    def test_report_rejects_missing_duplicate_nonfinal_or_unverified_lanes(self):
        cases = []
        for field, value in (("status", "in-progress"), ("schema", 2), ("schema", True)):
            changed = copy.deepcopy(self.report); changed[field] = value; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"].pop(); cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][1]["name"] = changed["corpora"][0]["name"]; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["name"] = ".."; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][1]["projection"] = changed["corpora"][0]["projection"]; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][1]["codec"] = "raw"; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][0]["sizes"].pop(); cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][0]["sizes"][1]["lane"] = "before"; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][0]["sizes"][0]["validated"]["loaded_entries"] = 2; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][0]["sizes"][0]["validated"]["loaded_content_digest"] = "c" * 64; cases.append(changed)
        changed = copy.deepcopy(self.report); changed["corpora"][0]["lanes"][0]["sizes"][1]["artifact"] = changed["corpora"][0]["lanes"][0]["sizes"][0]["artifact"]; cases.append(changed)
        changed = copy.deepcopy(self.report)
        changed["corpora"][0]["projection"]["path"] = str(self.root / "development" / "projection.tsv")
        cases.append(changed)
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                natural.artifact_lanes(case, 4)

    def test_missing_projection_is_explicit_and_not_a_fake_oracle(self):
        Path(self.report["corpora"][0]["projection"]["path"]).unlink()
        first = natural.artifact_lanes(self.report, 4)[0]
        self.assertFalse(first["projection_available"])
        self.assertIsNone(first["oracle_consumed_bytes"])

    def run_driver(self, *, mutate_binary=False):
        before, after = self.root / "before", self.root / "after"
        before.write_bytes(b"before-binary"); after.write_bytes(b"after-binary")
        artifacts = self.root / "artifacts.json"
        artifacts.write_text(json.dumps(self.report))
        output = self.root / "output"
        calls = []
        lanes = natural.artifact_lanes(self.report, 4)
        lookup = {artifact["path"]: lane for lane in lanes for artifact in lane["artifacts"].values()}
        def fake_capture(argv, prefix):
            calls.append(argv)
            prefix.parent.mkdir(parents=True, exist_ok=True)
            lane = lookup[argv[1]]
            candidate = Path(argv[0]).name == "after"
            rows = sample(lane["artifacts"]["after" if candidate else "before"],
                          wire=candidate, codec=lane["codec"], lengths=lane["oracle_consumed_bytes"])
            stdout, stderr = prefix.with_suffix(".stdout"), prefix.with_suffix(".stderr")
            stdout.write_text(wire(rows)); stderr.write_bytes(b"")
            if mutate_binary and len(calls) == 120:
                after.write_bytes(b"changed-binary")
            return {"argv": argv, "exit_code": 0, "stdout": file_record(stdout), "stderr": file_record(stderr)}
        argv = ["compare_natural.py", "--artifacts-report", str(artifacts), "--before", str(before),
                "--after", str(after), "--before-source", str(self.root), "--output", str(output),
                "--pairs", "5", "--operations", "4", "--quiet-gate", natural.GATE]
        with patch("sys.argv", argv), patch.object(natural, "capture", fake_capture), \
             patch.object(natural, "source_record", return_value=[]), \
             patch.object(natural, "dependencies_record", return_value={"fixture": True}), \
             patch.object(natural, "runtime_dependencies", return_value={"files": []}), \
             contextlib.redirect_stdout(io.StringIO()):
            if mutate_binary:
                with self.assertRaisesRegex(ValueError, "binary changed"):
                    natural.main()
            else:
                natural.main()
        return calls, json.loads((output / "results.json").read_text())

    def test_driver_schedule_warmups_and_fresh_observations_without_timing(self):
        calls, report = self.run_driver()
        self.assertEqual(report["status"], "complete-verified")
        self.assertEqual(len(calls), 120)  # ten lanes, two warmups, ten measured calls
        for lane in report["lanes"]:
            self.assertEqual(set(lane["warmups"]), {"before", "after"})
            for version in ("before", "after"):
                self.assertEqual([sample["pair"] for sample in lane["samples"][version]], list(range(5)))
                self.assertEqual([sample["order"] for sample in lane["samples"][version]],
                                 [["before", "after"], ["after", "before"], ["before", "after"],
                                  ["after", "before"], ["before", "after"]])
            self.assertIn("prepared_setup", lane["summary"]["after"])

    def test_driver_marks_changed_binary_run_failed(self):
        _, report = self.run_driver(mutate_binary=True)
        self.assertEqual(report["status"], "failed")
        self.assertIn("binary changed", report["error"])


if __name__ == "__main__":
    unittest.main()
