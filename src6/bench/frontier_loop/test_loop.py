#!/usr/bin/env python3
"""Adversarial exact-frame tests for the standalone frontier loop."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import loop as frontier


CODEC = r'''
import os
from pathlib import Path
import sys
import time
import zlib

verb, mode, source, target = sys.argv[1:]
source = Path(source)
target = Path(target)
if verb == "encode":
    data = source.read_bytes()
    if mode == "sleep":
        time.sleep(3)
    elif mode == "symlink":
        os.symlink(source, target)
    elif mode == "mutate":
        source.write_bytes(b"changed")
        target.write_bytes(b"B" + data)
    elif mode == "sidecar":
        (target.parent / "side.raw").write_bytes(data)
        target.write_bytes(b"S")
    elif mode == "zlib":
        target.write_bytes(b"Z" + zlib.compress(data))
    else:
        target.write_bytes(b"B" + data)
else:
    data = source.read_bytes()
    decoded = ((source.parent / "side.raw").read_bytes() if data[:1] == b"S" else
               zlib.decompress(data[1:]) if data[:1] == b"Z" else data[1:])
    target.write_bytes(decoded[:-1] if mode == "lossy" else decoded)
'''


def hash_bytes(data):
    return hashlib.sha256(data).hexdigest()


class FrontierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="frontier-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.python = Path(sys.executable).resolve()
        self.codec = self.root / "codec.py"
        self.codec.write_text(CODEC)
        self.spec_file = self.root / "candidate.json"
        self.base_file = self.root / "baseline.json"
        self.registry_file = self.root / "cases.json"
        self.work = self.root / "work"
        self.report = self.root / "report.json"
        self.cases = [
            self.case("english", "book", "en", "one", b"alpha beta " * 200, "development"),
            self.case("french", "book", "fr", "two", b"bonjour jour " * 180, "development"),
            self.case("lexicon", "dictionary", "en", "three", bytes(range(256)) * 4, "development"),
        ]
        self.registry()
        self.spec("candidate", "zlib")
        self.spec("baseline", "raw", target=self.base_file, backend="control")

    def case(self, name, kind, language, work_id, data, split):
        path = self.root / (name + ".raw")
        prefix_path = self.root / (name + ".prefix")
        path.write_bytes(data)
        prefix_path.write_bytes(data[:128])
        return {"id": name, "split": split, "kind": kind, "language": language,
                "work_id": work_id,
                "source": {"path": str(path), "bytes": len(data), "sha256": hash_bytes(data)},
                "prefix": {"path": str(prefix_path), "bytes": min(len(data), 128),
                           "sha256": hash_bytes(data[:128])}}

    def registry(self):
        self.registry_file.write_text(json.dumps({"cases": self.cases}))

    def spec(self, ident, mode, *, target=None, backend="self_contained", timeout=2,
             side_information=None):
        target = target or self.spec_file
        dependencies = {str(self.python): frontier.digest(self.python),
                        str(self.codec): frontier.digest(self.codec)}
        for side in side_information or []:
            dependencies[side["path"]] = side["sha256"]
        config = {
            "id": ident, "parent": "root", "mechanism": "pinned toy codec",
            "hypothesis": "exact files and paid bytes", "decisive_test": "all registered cases",
            "backend_class": backend,
            "model_accounting": {"kind": "universal_code" if backend == "control" else "frame_learned_only",
                                 "data_dependencies": [], "embedded_learned_bytes": 0},
            "encode_argv": [str(self.python), str(self.codec), "encode", mode, "{input}", "{frame}"],
            "decode_argv": [str(self.python), str(self.codec), "decode", mode, "{frame}", "{output}"],
            "dependencies": dependencies,
            "limits": {"timeout_seconds": timeout, "max_raw_bytes": 1 << 20,
                       "max_frame_bytes": 1 << 20},
        }
        if side_information is not None:
            config["side_information"] = side_information
        target.write_text(json.dumps(config))
        return config

    def call(self, *args, code=0):
        result = subprocess.run([str(self.python), str(Path(frontier.__file__)), *args],
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        return result

    def run_round(self, stage="development", code=0, token=None, freeze=None, qualification=None,
                  incumbent=None):
        argv = ["run", "--spec", str(self.spec_file), "--baseline", str(self.base_file),
                "--cases", str(self.registry_file), "--stage", stage,
                "--work", str(self.work), "--report", str(self.report)]
        if token is not None:
            argv += ["--token", token]
        if freeze is not None:
            argv += ["--freeze", str(freeze)]
        if qualification is not None:
            argv += ["--qualification-report", str(qualification)]
        if incumbent is not None:
            argv += ["--incumbent-report", str(incumbent)]
        self.call(*argv, code=code)
        return json.loads(self.report.read_text())

    def test_exact_full_round_cache_rehash_and_screen_is_only_rejection(self):
        first = self.run_round()
        self.assertTrue(first["scores"]["all_cases_passed"])
        self.assertEqual(len(first["scores"]["kinds"]["book"]["cases"]), 2)
        self.assertTrue(all(row["candidate"]["fresh_decode"] for row in first["trials"].values()))
        self.assertLess(first["primary"]["language_balanced_work_geo"], 0.65)
        cached = self.run_round()
        self.assertTrue(all(row["candidate"]["status"] == "cached_verified"
                            for row in cached["trials"].values()))
        self.assertEqual(cached["size_proof"], "fresh exact decode of every current frame")
        self.assertTrue(all(row["candidate"]["fresh_decode"] for row in cached["trials"].values()))
        self.assertFalse(any(row["candidate"]["fresh_encode"] for row in cached["trials"].values()))
        screened = self.run_round("screen")
        self.assertFalse(screened["accepted"])
        self.assertEqual(screened["stage"], "screen")
        cache = Path(cached["trials"]["english"]["candidate"]["cached_frame_dir"])
        (cache / "frame.bin").write_bytes(b"tampered")
        failed = self.run_round(code=2)
        self.assertFalse(failed["scores"]["all_cases_passed"])
        self.assertIn("english", failed["scores"]["missing_or_failed"])
        self.assertEqual(failed["trials"]["english"]["candidate"]["status"], "fail")

    def test_cache_frame_meta_forgery_cannot_reuse_prior_output(self):
        first = self.run_round()
        cache = Path(first["trials"]["english"]["candidate"]["artifact_dir"])
        key = first["trials"]["english"]["candidate"]["cache_key"]
        cached = self.work / "cache" / key
        (cached / "frame.bin").write_bytes(b"B")
        meta = json.loads((cached / "meta.json").read_text())
        meta["frame_sha256"] = hash_bytes(b"B")
        meta["frame_bytes"] = 1
        (cached / "meta.json").write_text(json.dumps(meta))
        result = self.run_round(code=2)
        self.assertFalse(result["scores"]["all_cases_passed"])
        self.assertIn("cached frame is lossy", result["trials"]["english"]["candidate"]["error"])

    def test_lossy_case_cannot_disappear_or_be_offset_by_dictionary(self):
        self.spec("candidate", "lossy")
        result = self.run_round(code=2)
        self.assertEqual(result["expected_case_ids"], ["english", "french", "lexicon"])
        self.assertEqual(len(result["scores"]["missing_or_failed"]), 3)
        self.assertFalse(result["accepted"])
        self.assertFalse(result["scores"]["kinds"]["book"]["eligible"])
        self.assertTrue(Path(result["trials"]["english"]["candidate"]["artifact_dir"]).exists())
        ledger = [json.loads(line) for line in (self.work / "ledger.jsonl").read_text().splitlines()]
        self.assertEqual(len([x for x in ledger if x.get("event") == "trial"]), 6)
        self.assertEqual(ledger[-1]["event"], "round")

    def test_source_and_dependency_changes_fail_closed(self):
        self.run_round()
        self.codec.write_text(CODEC + "\n# changed dependency\n")
        fatal = self.run_round(code=2)
        self.assertEqual(fatal["event"], "fatal")
        self.assertIn("SHA-256 mismatch", fatal["error"])
        self.codec.write_text(CODEC)
        self.cases[0]["source"]["path"] = str(self.root / "english.raw")
        (self.root / "english.raw").write_bytes(b"modified source")
        result = self.run_round(code=2)
        self.assertEqual(result["trials"]["english"]["candidate"]["status"], "fail")
        self.assertFalse(result["scores"]["all_cases_passed"])

    def test_freeze_validation_token_and_external_model_are_separate(self):
        self.cases += [
            self.case("english-val", "book", "en", "four", b"alpha beta " * 170, "validation"),
            self.case("french-val", "book", "fr", "five", b"bonjour jour " * 165, "validation"),
        ]
        self.registry()
        development = self.run_round()
        self.assertTrue(development["goal_met"])
        qualification = self.root / "development-qualified.json"
        shutil.copyfile(self.report, qualification)
        frozen = self.root / "freeze.json"
        self.call("freeze", "--spec", str(self.spec_file), "--baseline", str(self.base_file),
                  "--cases", str(self.registry_file), "--stage", "validation",
                  "--qualification-report", str(qualification), "--token", "coordinator-secret",
                  "--out", str(frozen))
        denied = self.run_round("validation", code=2, token="wrong", freeze=frozen,
                                qualification=qualification)
        self.assertEqual(denied["event"], "fatal")
        valid = self.run_round("validation", token="coordinator-secret", freeze=frozen,
                               qualification=qualification)
        self.assertTrue(valid["scores"]["all_cases_passed"])
        self.assertTrue(valid["accepted"])
        self.work = self.root / "different-work"
        reused = self.run_round("validation", code=2, token="coordinator-secret", freeze=frozen,
                                qualification=qualification)
        self.assertIn("already consumed", reused["error"])
        self.spec("candidate", "zlib", backend="external_model")
        external = self.run_round()
        self.assertTrue(external["primary"]["target_35_percent"])
        self.assertFalse(external["goal_met"])
        self.assertFalse(external["accepted"])

    def test_symlink_artifact_timeout_and_decoder_input_guard(self):
        self.spec("candidate", "symlink")
        unsafe = self.run_round(code=2)
        self.assertIn("escaping artifact", unsafe["trials"]["english"]["candidate"]["error"])
        self.spec("candidate", "sleep", timeout=.05)
        timed = self.run_round(code=2)
        self.assertTrue(timed["trials"]["english"]["candidate"]["encode"]["timed_out"])
        spec = self.spec("candidate", "raw")
        spec["decode_argv"].append("{input}")
        self.spec_file.write_text(json.dumps(spec))
        fatal = self.run_round(code=2)
        self.assertIn("decoder must not receive", fatal["error"])

    def test_encoder_work_sidecar_is_not_available_to_decoder(self):
        self.spec("candidate", "sidecar")
        result = self.run_round(code=2)
        self.assertEqual(result["trials"]["english"]["candidate"]["status"], "fail")
        self.assertIn("decode failed", result["trials"]["english"]["candidate"]["error"])
        self.assertFalse((Path(result["trials"]["english"]["candidate"]["artifact_dir"])
                          / "encode_job" / "side.raw").exists())

    def test_declared_side_bytes_and_kind_isolation(self):
        side = self.root / "model.bin"
        side.write_bytes(b"M" * 500)
        self.spec("candidate", "zlib", side_information=[{"path": str(side), "sha256": frontier.digest(side)}])
        result = self.run_round()
        row = result["trials"]["english"]["candidate"]
        self.assertEqual(row["complete_bytes"], row["frame_bytes"] + 500)
        artificial = {
            "book-en": {"baseline": {"status": "pass", "complete_bytes": 100},
                        "candidate": {"status": "pass", "complete_bytes": 120}},
            "book-fr": {"baseline": {"status": "pass", "complete_bytes": 100},
                        "candidate": {"status": "pass", "complete_bytes": 110}},
            "dict": {"baseline": {"status": "pass", "complete_bytes": 100000},
                     "candidate": {"status": "pass", "complete_bytes": 1}},
        }
        cases = [
            {"id": "book-en", "kind": "book", "language": "en", "work_id": "a"},
            {"id": "book-fr", "kind": "book", "language": "fr", "work_id": "b"},
            {"id": "dict", "kind": "dictionary", "language": "en", "work_id": "c"},
        ]
        scores = frontier.score(cases, artificial)
        self.assertGreater(frontier.book_goal(scores)["language_balanced_work_geo"], 1)
        self.assertLess(scores["kinds"]["dictionary"]["language_balanced_work_geo"], .001)

    def test_screen_prefix_must_equal_registered_source_start(self):
        prefix = self.root / "english.prefix"
        prefix.write_bytes(b"x" * 128)
        self.cases[0]["prefix"]["sha256"] = frontier.digest(prefix)
        self.registry()
        result = self.run_round("screen", code=2)
        self.assertEqual(result["event"], "fatal")
        self.assertIn("prefix differs", result["error"])

    def test_extended_registry_qualifies_from_exact_embedded_dev_subset(self):
        development = self.run_round()
        self.assertTrue(development["goal_met"])
        qualification = self.root / "development.json"
        shutil.copyfile(self.report, qualification)
        self.cases += [self.case("new-validation", "book", "en", "unseen-work",
                                 b"other prose " * 220, "validation")]
        self.registry()
        frozen = self.root / "freeze-extended.json"
        self.call("freeze", "--spec", str(self.spec_file), "--baseline", str(self.base_file),
                  "--cases", str(self.registry_file), "--stage", "validation",
                  "--qualification-report", str(qualification), "--token", "coordinator-secret",
                  "--out", str(frozen))
        result = self.run_round("validation", token="coordinator-secret", freeze=frozen,
                                qualification=qualification)
        self.assertEqual(result["expected_case_ids"], ["new-validation"])
        self.assertTrue(result["goal_met"])

    def test_invalid_incumbent_is_rejected_before_new_trials(self):
        first = self.run_round()
        self.assertTrue(first["scores"]["all_cases_passed"])
        incumbent = self.root / "incumbent.json"
        bad = dict(first)
        bad["primary"] = dict(first["primary"], language_balanced_work_geo=0.0001)
        incumbent.write_text(json.dumps(bad))
        before = (self.work / "ledger.jsonl").read_text().count('"event": "trial"')
        fatal = self.run_round(code=2, incumbent=incumbent)
        after = (self.work / "ledger.jsonl").read_text().count('"event": "trial"')
        self.assertEqual(fatal["event"], "fatal")
        self.assertEqual(after, before)
        self.assertIn("recomputed", fatal["error"])


if __name__ == "__main__":
    unittest.main()
