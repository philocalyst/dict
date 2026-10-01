"""Small deterministic permutation tests; no corpus benchmarks."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import bench


class GridTests(unittest.TestCase):
    def test_sorted_product_and_override(self):
        self.assertEqual(bench.policies({"a": 99, "fixed": 2}, {"z": [3, 4], "a": [1, 2]}),
                         [{"a": a, "fixed": 2, "z": z} for a in [1, 2] for z in [3, 4]])
        self.assertEqual(bench.policies({"x": 1}, {}), [{"x": 1}])

    def test_validation(self):
        for defaults, grid in [([], {}), ({"block_bytes": 1}, {}), ({}, []),
                               ({}, {1: [2]}), ({}, {"block_bytes": [2]}),
                               ({}, {"x": []}), ({}, {"x": 1}),
                               ({}, {"x": list(range(257))}),
                               ({}, {"x": list(range(17)), "y": list(range(16))}),
                               ({"x": float("nan")}, {})]:
            with self.subTest(defaults=defaults, grid=grid), self.assertRaises(ValueError):
                bench.policies(defaults, grid)
        self.assertEqual(len(bench.policies({}, {"x": list(range(256))})), 256)

    def test_labels_paths_shared_matrix_and_no_grid(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "adapter.py"
            path.touch()
            grid = {"x": ["../../escape/a", "\\b"]}
            codecs = bench.candidates([str(path), str(path)], 32, {"fixed": True}, [], grid)
            self.assertEqual([c["policy"] for c in codecs], [1, 2, 1, 2])
            self.assertEqual(codecs[0]["options"], codecs[2]["options"])
            self.assertIn('policy-001', codecs[0]["name"])
            self.assertIn('../../escape/a', codecs[0]["name"])
            names = [bench.artifact_name(c) for c in codecs]
            self.assertEqual(len(set(names)), 4)
            self.assertTrue(all(Path(name).name == name and "/" not in name and "\\" not in name for name in names))
            plain = bench.candidates([str(path)], 32, {"x": 1}, [])[0]
            self.assertEqual(plain["name"], "adapter")
            self.assertNotIn("policy", plain)

    def test_wam_rejection(self):
        for name in ["wam-map", "wam-marginal"]:
            with self.assertRaisesRegex(ValueError, "fixed policies"):
                bench.candidates([name], 32, {}, [], {"x": [1]})
            self.assertEqual(len(bench.candidates([name], 32, {}, [])), 1)
            with self.assertRaisesRegex(ValueError, "nonempty --options"):
                bench.candidates([name], 32, {"x": 1}, [])
            with self.assertRaisesRegex(ValueError, "nonempty --options"):
                bench.candidates(["unused.py", name], 32, {"x": 1}, [])

    def test_grid_requires_candidate_and_timeout_is_finite(self):
        for arguments in [["--grid", '{"x":[1]}'], ["--timeout", "nan"],
                          ["--timeout", "inf"], ["--timeout=-inf"], ["--timeout", "0"]]:
            with self.subTest(arguments=arguments), patch.object(sys, "argv", ["bench.py", *arguments]), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    bench.main()
                self.assertEqual(error.exception.code, 2)

    def test_invalid_json_is_cli_error(self):
        for flag in ["--grid", "--options"]:
            with patch.object(sys, "argv", ["bench.py", flag, "{"]), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    bench.main()
                self.assertEqual(error.exception.code, 2)

    def test_run_freezes_matrix_and_controls_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, adapter = root / "input", root / "adapter.py"
            source.write_bytes(b"abc")
            adapter.touch()
            calls = []

            def measure(codec, provenance, source, directory, *args):
                calls.append(codec)
                return {"codec": codec["name"], "frame": {"bytes": 3},
                        "cache_hit": False, "decode_process_median_ns": None}

            argv = ["bench.py", str(source), "--candidate", str(adapter),
                    "--grid", '{"x":[1,2,3]}', "--output", str(root / "runs")]
            with patch.object(sys, "argv", argv), patch.object(bench, "fingerprint", return_value={}), \
                 patch.object(bench, "measure", side_effect=measure), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(bench.main(), 0)
            self.assertEqual(len(calls), 6)
            invocation = json.loads(next((root / "runs").glob("*/invocation.json")).read_text())
            self.assertEqual(invocation["matrix"]["policies"], [{"x": 1}, {"x": 2}, {"x": 3}])
            self.assertEqual(output.getvalue().count("Policy 001:"), 1)


if __name__ == "__main__":
    unittest.main()
