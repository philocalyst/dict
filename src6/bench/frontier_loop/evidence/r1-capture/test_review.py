#!/usr/bin/env python3
"""Independent adversarial loop probes; synthetic data only, no reserved books."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loop


CODEC = r'''
from pathlib import Path
import os, sys, zlib
verb, mode, source, destination = sys.argv[1:]
source, destination = Path(source), Path(destination)
if verb == 'encode':
    raw = source.read_bytes()
    if mode == 'validation-failure' and b'sealed validation' in raw:
        raise ValueError('deliberate validation-only failure')
    if mode in ('sidecar', 'sibling'):
        (destination.parent / 'unpaid.bin').write_bytes(raw)
        destination.write_bytes(b'x')
    elif mode == 'raw' or (mode == 'env' and os.environ.get('REVIEW_CODEC_RAW')):
        destination.write_bytes(b'B' + raw)
    else:
        pad = int(mode.split(':')[1]) if mode.startswith('pad:') else 0
        destination.write_bytes(b'Z' + zlib.compress(raw) + b'!' * pad)
else:
    if mode == 'sidecar':
        raw = (source.parent / 'unpaid.bin').read_bytes()
    elif mode == 'sibling':
        raw = (source.parent.parent / 'encode_job' / 'input.bin').read_bytes()
    else:
        frame = source.read_bytes()
        if frame[:1] == b'Z': raw = zlib.decompress(frame[1:])
        elif frame[:1] == b'B': raw = frame[1:]
        else: raise ValueError('invalid frame')
    destination.write_bytes(raw)
'''


class IndependentReview(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="frontier-independent-review-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.python = Path(sys.executable).resolve()
        self.codec = self.root / "codec.py"
        self.codec.write_text(CODEC)
        self.spec = self.root / "candidate.json"
        self.baseline = self.root / "baseline.json"
        self.registry = self.root / "registry.json"
        self.work = self.root / "coordinator-work"
        self.report = self.root / "report.json"
        self.source = self.root / "a-distinct-development-work.raw"
        self.source.write_bytes(("alpha beta γάμμα.\r\n" * 160).encode())
        self.cases = [self.case("development", "development-work", "development-author", self.source)]
        self.write_registry()
        self.write_spec(self.spec, "candidate", "zlib")
        self.write_spec(self.baseline, "baseline", "raw", backend="control")

    def case(self, split, work_id, author, source):
        return dict(id=work_id, split=split, kind="book", language="en", work_id=work_id,
                    author=author, lineage_id=work_id,
                    source=dict(path=str(source), bytes=source.stat().st_size, sha256=loop.digest(source)))

    def write_registry(self):
        self.registry.write_text(json.dumps(dict(cases=self.cases)))

    def write_spec(self, path, ident, mode, backend="self_contained"):
        spec = dict(id=ident, parent="independent-probe", mechanism="synthetic reversible codec",
                    hypothesis="Adversarial plumbing must not fabricate a compression result.",
                    decisive_test="Exact synthetic source and independent fresh decoder.",
                    backend_class=backend,
                    encode_argv=[str(self.python), str(self.codec), "encode", mode, "{input}", "{frame}"],
                    decode_argv=[str(self.python), str(self.codec), "decode", mode, "{frame}", "{output}"],
                    dependencies={str(self.python): loop.digest(self.python), str(self.codec): loop.digest(self.codec)},
                    model_accounting=dict(kind="universal_code", embedded_learned_bytes=0, data_dependencies=[]),
                    limits=dict(timeout_seconds=2, max_raw_bytes=1 << 20, max_frame_bytes=1 << 20))
        path.write_text(json.dumps(spec))
        return spec

    def run_round(self, *, work=None, env=None, incumbent=None, stage="development", freeze=None, qualification=None):
        argv = [str(self.python), str(Path(loop.__file__)), "run", "--spec", str(self.spec),
                "--baseline", str(self.baseline), "--cases", str(self.registry),
                "--stage", stage, "--work", str(work or self.work), "--report", str(self.report)]
        if incumbent:
            argv += ["--incumbent-report", str(incumbent)]
        if freeze:
            argv += ["--freeze", str(freeze), "--token", "review-coordinator"]
        if qualification:
            argv += ["--qualification-report", str(qualification)]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30, env=env)
        return result.returncode, json.loads(self.report.read_text())

    def freeze(self, target, qualification, stage="validation"):
        argv = [str(self.python), str(Path(loop.__file__)), "freeze", "--spec", str(self.spec),
                "--baseline", str(self.baseline), "--cases", str(self.registry),
                "--token", "review-coordinator", "--stage", stage,
                "--qualification-report", str(qualification), "--out", str(target)]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        return result

    def add_validation(self):
        source = self.root / "a-distinct-sealed-work.raw"
        source.write_bytes(b"sealed validation work, different author.\r\n" * 80)
        self.cases.append(self.case("validation", "validation-work", "validation-author", source))
        self.write_registry()

    def test_unpaid_encoder_sidecar_cannot_supply_decode(self):
        self.write_spec(self.spec, "candidate", "sidecar")
        code, report = self.run_round()
        self.assertEqual(code, 2)
        self.assertFalse(report["scores"]["all_cases_passed"])

    def test_predictable_sibling_encoder_input_is_not_a_decoder_oracle(self):
        self.write_spec(self.spec, "candidate", "sibling")
        code, report = self.run_round()
        self.assertEqual(code, 2, "decoder read adjacent encode_job/input.bin from a1-byte frame")
        self.assertFalse(report["scores"]["all_cases_passed"])

    def test_forged_cache_meta_does_not_certify_undecodable_frame(self):
        code, first = self.run_round()
        self.assertEqual(code, 0)
        trial = first["trials"][self.cases[0]["id"]]["candidate"]
        cached = self.work / "cache" / trial["cache_key"]
        (cached / "frame.bin").write_bytes(b"x")
        meta = json.loads((cached / "meta.json").read_text())
        meta.update(frame_bytes=1, frame_sha256=hashlib.sha256(b"x").hexdigest())
        (cached / "meta.json").write_text(json.dumps(meta))
        code, report = self.run_round()
        self.assertEqual(code, 2)
        self.assertFalse(report["scores"]["all_cases_passed"])

    def test_ambient_env_cannot_change_policy_behind_cache_fingerprint(self):
        self.write_spec(self.spec, "candidate", "env")
        clean = os.environ.copy()
        clean.pop("REVIEW_CODEC_RAW", None)
        code, _ = self.run_round(env=clean)
        self.assertEqual(code, 0)
        changed = dict(clean, REVIEW_CODEC_RAW="1", WGR_COPY="1", WSB_POLICY="hidden")
        code, reused = self.run_round(env=changed)
        self.assertEqual(code, 0)
        code, fresh = self.run_round(work=self.root / "fresh-work", env=changed)
        self.assertEqual(code, 0)
        ident = self.cases[0]["id"]
        self.assertEqual(reused["trials"][ident]["candidate"]["frame_sha256"],
                         fresh["trials"][ident]["candidate"]["frame_sha256"])

    def test_absolute_script_must_be_a_hashed_dependency(self):
        spec = json.loads(self.spec.read_text())
        spec["dependencies"].pop(str(self.codec))
        with self.assertRaises(loop.Invalid):
            loop.validate_spec(spec, "candidate")

    def test_nonfinite_or_fractional_resource_limits_fail_before_process(self):
        spec = json.loads(self.spec.read_text())
        for name, value in (("timeout_seconds", float("nan")), ("timeout_seconds", float("inf")),
                            ("max_raw_bytes", 1.5), ("max_frame_bytes", float("inf"))):
            modified = copy.deepcopy(spec)
            modified["limits"][name] = value
            with self.assertRaises(loop.Invalid):
                loop.validate_spec(modified, "candidate")

    def test_same_work_or_bytes_cannot_cross_development_validation(self):
        validation = self.root / "validation-copy.raw"
        validation.write_bytes(self.source.read_bytes())
        cases = [self.cases[0], self.case("validation", self.cases[0]["work_id"],
                                       self.cases[0]["author"], validation)]
        cases[1]["id"] = "distinct-case-label"
        with self.assertRaises(loop.Invalid):
            loop.validate_registry(dict(cases=cases))

    def test_work_author_byte_and_translation_lineage_split_guards_are_independent(self):
        other = self.root / "other-work.raw"
        other.write_bytes(b"a different complete validation work" * 35)
        base = self.cases[0]
        independent = self.case("validation", "validation-work", "validation-author", other)
        for key in ("work_id", "author", "lineage_id", "source"):
            with self.subTest(shared=key):
                validation = copy.deepcopy(independent)
                validation[key] = copy.deepcopy(base[key])
                if key == "lineage_id":
                    validation["language"] = "fr"
                with self.assertRaises(loop.Invalid):
                    loop.validate_registry(dict(cases=[base, validation]))

    def test_all_case_failure_stays_in_primary_scorecard(self):
        code, report = self.run_round()
        self.assertEqual(code, 0)
        second = self.root / "second.raw"
        second.write_bytes(b"An entirely different work.\n" * 50)
        case = self.case("development", "another-work", "another-author", second)
        case["source"]["sha256"] = "0" * 64
        self.cases.append(case)
        self.write_registry()
        code, report = self.run_round()
        self.assertEqual(code, 2)
        self.assertEqual(report["expected_case_ids"], [case["id"] for case in self.cases])
        self.assertFalse(report["primary"]["eligible"])
        self.assertFalse(report["accepted"])

    def test_local_keeper_is_distinct_from_35_percent_goal(self):
        self.write_spec(self.spec, "incumbent", "pad:2900")
        code, first = self.run_round()
        self.assertEqual(code, 0)
        saved = self.root / "incumbent-report.json"
        saved.write_text(json.dumps(first))
        self.write_spec(self.spec, "candidate", "pad:2800")
        code, report = self.run_round(incumbent=saved)
        self.assertEqual(code, 0)
        self.assertFalse(report["goal_met"])
        self.assertTrue(report["hillclimb_promoted"])

    def test_failed_validation_consumes_cohort_even_with_new_work_directory(self):
        self.add_validation()
        self.write_spec(self.spec, "candidate", "validation-failure")
        code, report = self.run_round()
        self.assertEqual(code, 0)
        self.assertTrue(report["goal_met"])
        qualification = self.root / "qualified-development.json"
        qualification.write_text(json.dumps(report))
        frozen = self.root / "freeze.json"
        result = self.freeze(frozen, qualification)
        self.assertEqual(result.returncode, 0, result.stderr)
        code, first = self.run_round(stage="validation", freeze=frozen, qualification=qualification)
        self.assertEqual(code, 2)
        self.assertFalse(first["scores"]["all_cases_passed"])
        code, retried = self.run_round(stage="validation", freeze=frozen, qualification=qualification,
                                      work=self.root / "new-coordinator-work")
        self.assertEqual(code, 2)
        self.assertEqual(retried["event"], "fatal")
        self.assertIn("consumed", retried["error"])

    def test_nonselected_registry_metadata_cannot_reopen_consumed_validation(self):
        self.add_validation()
        code, report = self.run_round()
        self.assertEqual(code, 0)
        qualification = self.root / "qualified-development.json"
        qualification.write_text(json.dumps(report))
        frozen = self.root / "freeze.json"
        result = self.freeze(frozen, qualification)
        self.assertEqual(result.returncode, 0, result.stderr)
        code, _ = self.run_round(stage="validation", freeze=frozen, qualification=qualification)
        self.assertEqual(code, 0)
        registry = json.loads(self.registry.read_text())
        registry["development_round_note"] = "Changed metadata; sealed validation cases are identical."
        self.registry.write_text(json.dumps(registry))
        code, report = self.run_round(work=self.root / "new-development-work")
        self.assertEqual(code, 0)
        qualification2 = self.root / "qualified-development2.json"
        qualification2.write_text(json.dumps(report))
        result = self.freeze(self.root / "freeze2.json", qualification2)
        self.assertEqual(result.returncode, 2, "registry metadata change reopened an already consumed validation source cohort")

    def test_validation_cannot_qualify_directly_from_unproven_or_wrong_stage_report(self):
        self.add_validation()
        fake = self.root / "fake-qualification.json"
        fake.write_text(json.dumps(dict(stage="validation", goal_met=True, primary=dict(target_35_percent=True))))
        result = self.freeze(self.root / "freeze.json", fake)
        self.assertEqual(result.returncode, 2)

    def test_repriced_report_cannot_certify_undecodable_prior_frame(self):
        self.add_validation()
        code, report = self.run_round()
        self.assertEqual(code, 0)
        row = report["trials"][self.cases[0]["id"]]["candidate"]
        artifact = Path(row["artifact_dir"]) / "decode_job" / "frame.bin"
        artifact.write_bytes(b"x")
        row.update(frame_bytes=1, frame_sha256=hashlib.sha256(b"x").hexdigest(), complete_bytes=1)
        report["scores"] = loop.score([self.cases[0]], report["trials"])
        report["primary"] = loop.book_goal(report["scores"])
        report["goal_met"] = True
        qualification = self.root / "forged-qualification.json"
        qualification.write_text(json.dumps(report))
        result = self.freeze(self.root / "freeze.json", qualification)
        self.assertEqual(result.returncode, 2, "rehashing metadata certified a retained frame that cannot decode")

    def test_successful_parent_cannot_leave_unpaid_background_child(self):
        marker = self.root / "orphan-child-survived"
        script = self.root / "background.py"
        script.write_text("import os,sys,time\nfrom pathlib import Path\n"
                          "if os.fork() == 0:\n"
                          " time.sleep(0.15)\n Path(sys.argv[1]).write_text('alive')\n os._exit(0)\n")
        result = loop.run_process([str(self.python), str(script), str(marker)], self.root,
                                  2, 1 << 20, self.root / "background",
                                  loop.child_environment(json.loads(self.spec.read_text()), self.root))
        self.assertEqual(result["exit_code"], 0)
        time.sleep(0.25)
        self.assertFalse(marker.exists(), "successful parent left an unbounded background process after its clock stopped")

    def test_standard_adapters_emit_the_exact_ordinary_native_frames(self):
        adapter = Path(loop.__file__).resolve().parent / "codec_adapter.py"
        flags = dict(bzip3=["-b", "32", "-c"], bzip2=["-9", "-c"],
                     zstd=["-19", "--single-thread", "-q", "-c"],
                     xz=["-9", "--threads=1", "--check=crc64", "-c"])
        for codec, options in flags.items():
            with self.subTest(codec=codec):
                found = "/workspace/scratch/bzip3" if codec == "bzip3" else shutil.which(codec)
                if not found or not Path(found).is_file():
                    self.skipTest(f"optional standard executable absent: {codec}")
                binary = Path(found).resolve()
                frame = self.root / (codec + ".frame")
                output = self.root / (codec + ".output")
                subprocess.run([str(self.python), str(adapter), "encode", codec, str(binary),
                                str(self.source), str(frame)], check=True, capture_output=True, timeout=30)
                native = subprocess.run([str(binary)] + options + [str(self.source)],
                                        check=True, capture_output=True, timeout=30).stdout
                self.assertEqual(frame.read_bytes(), native)
                subprocess.run([str(self.python), str(adapter), "decode", codec, str(binary),
                                str(frame), str(output)], check=True, capture_output=True, timeout=30)
                self.assertEqual(output.read_bytes(), self.source.read_bytes())


if __name__ == "__main__":
    unittest.main()
