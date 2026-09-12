#!/usr/bin/env python3
"""Provenance and complete artifact-manifest tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

try:
    from .provenance import artifact_manifest, capture, verify, verify_artifact_manifest, write_artifact_manifest
except ImportError:  # direct unittest discovery
    from provenance import artifact_manifest, capture, verify, verify_artifact_manifest, write_artifact_manifest


class ProvenanceTests(unittest.TestCase):
    def _repo(self, root: Path) -> None:
        (root / "src2").mkdir()
        (root / "src4").mkdir()
        (root / "bench4").mkdir()
        (root / "src2" / "root.zig").write_text("pub const legacy: u8 = 2;\n", encoding="utf-8")
        (root / "src4" / "root.zig").write_text("pub const answer: u8 = 1;\n", encoding="utf-8")
        (root / "bench4" / "driver.py").write_text("print('bench')\n", encoding="utf-8")
        (root / "bench4.zig").write_text("pub fn main() void {}\n", encoding="utf-8")
        (root / "build4.zig").write_text("pub fn build() void {}\n", encoding="utf-8")
        (root / "flake.nix").write_text("{ description = \"test\"; }\n", encoding="utf-8")
        (root / "flake.lock").write_text('{"nodes":{"root":{"locked":{"type":"path"}}},"root":"root"}\n', encoding="utf-8")

    def test_source_drift_is_fatal_and_current_src4_is_manifested(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._repo(root)
            manifest = root / "run" / "provenance.json"
            first = capture(root=root, output=manifest, executable=None, cli=("bench4/run.py", "--records", "8"))
            paths = {row["path"] for row in first["sources"]["files"]}
            self.assertIn("src4/root.zig", paths)
            self.assertIn("src2/root.zig", paths)
            self.assertIn("bench4/driver.py", paths)
            ok, reasons, _ = verify(root=root, manifest=manifest)
            self.assertTrue(ok, reasons)
            (root / "src4" / "root.zig").write_text("pub const answer: u8 = 2;\n", encoding="utf-8")
            ok, reasons, _ = verify(root=root, manifest=manifest)
            self.assertFalse(ok)
            self.assertTrue(any("source" in reason for reason in reasons))
            (root / "src4" / "root.zig").write_text("pub const answer: u8 = 1;\n", encoding="utf-8")
            (root / "flake.lock").write_text('{"nodes":{},"root":"root"}\n', encoding="utf-8")
            ok, reasons, _ = verify(root=root, manifest=manifest)
            self.assertFalse(ok)
            self.assertTrue(any("flake" in reason for reason in reasons))

    def test_artifact_manifest_covers_every_byte_except_itself(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "raw").mkdir()
            (root / "raw" / "observation.jsonl").write_text('{"elapsed_ns": 7}\n', encoding="utf-8")
            (root / "artifact.bin").write_bytes(b"LEX4")
            output = root / "hashes.tsv"
            records = write_artifact_manifest(root, output)
            paths = {row["path"] for row in records}
            self.assertIn("raw/observation.jsonl", paths)
            self.assertIn("artifact.bin", paths)
            self.assertNotIn("hashes.tsv", paths)
            expected = {row["path"] for row in artifact_manifest(root, output)}
            self.assertEqual(paths, expected)
            self.assertTrue(output.read_text(encoding="utf-8").startswith("sha256\t"))
            ok, reasons = verify_artifact_manifest(root, output)
            self.assertTrue(ok, reasons)
            (root / "artifact.bin").write_bytes(b"LEX4-tampered")
            ok, reasons = verify_artifact_manifest(root, output)
            self.assertFalse(ok)
            self.assertTrue(any("changed" in reason for reason in reasons))

    def test_output_root_is_excluded_from_source_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._repo(root)
            output_root = root / "bench4" / "custom-results"
            output_root.mkdir(parents=True)
            (output_root / "generated.py").write_text("not a source\n", encoding="utf-8")
            manifest = output_root / "run" / "provenance.json"
            first = capture(
                root=root,
                output=manifest,
                executable=None,
                cli=("bench4/run.py",),
                excluded_roots=(output_root,),
            )
            self.assertIn("bench4/custom-results", first["sources"]["excluded_roots"])
            (output_root / "later.json").write_text("retained output\n", encoding="utf-8")
            ok, reasons, _ = verify(root=root, manifest=manifest)
            self.assertTrue(ok, reasons)

    def test_path_executable_is_hashed_even_when_supplied_by_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._repo(root)
            manifest = root / "run" / "provenance.json"
            value = capture(root=root, output=manifest, executable="python3", cli=("bench4/run.py",))
            self.assertFalse(value["executable"].get("missing", False))
            self.assertEqual(64, len(value["executable"]["sha256"]))
            ok, reasons, _ = verify(root=root, manifest=manifest, executable="python3")
            self.assertTrue(ok, reasons)

    def test_every_native_executable_is_hashed_and_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._repo(root)
            first = root / "lex4-native"
            second = root / "lex2-native"
            first.write_bytes(b"lex4")
            second.write_bytes(b"lex2")
            manifest = root / "run" / "provenance.json"
            value = capture(
                root=root,
                output=manifest,
                executable=first,
                extra_executables={"lex2-current-native": second},
                cli=("bench4/run.py",),
            )
            self.assertEqual(64, len(value["extra_executables"]["lex2-current-native"]["sha256"]))
            ok, reasons, _ = verify(
                root=root,
                manifest=manifest,
                executable=first,
                extra_executables={"lex2-current-native": second},
            )
            self.assertTrue(ok, reasons)
            second.write_bytes(b"changed")
            ok, reasons, _ = verify(
                root=root,
                manifest=manifest,
                executable=first,
                extra_executables={"lex2-current-native": second},
            )
            self.assertFalse(ok)
            self.assertTrue(any("lex2-current-native" in reason for reason in reasons))

    def test_secret_environment_values_are_redacted_from_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._repo(root)
            manifest = root / "run" / "provenance.json"
            with mock.patch.dict(
                os.environ,
                {
                    "SECRET_TOKEN": "sentinel-do-not-persist",
                    "LEX4_SAFE": "unlisted-must-not-persist",
                    "PYTHONHASHSEED": "17",
                },
                clear=False,
            ):
                capture(root=root, output=manifest, executable=None, cli=("bench4/run.py", "--api-token", "sentinel-cli-do-not-persist", "--env", "SECRET_TOKEN=sentinel-cli-env-do-not-persist"))
            encoded = manifest.read_text(encoding="utf-8")
            self.assertNotIn("sentinel-do-not-persist", encoded)
            self.assertNotIn("sentinel-cli-do-not-persist", encoded)
            self.assertNotIn("sentinel-cli-env-do-not-persist", encoded)
            self.assertNotIn("SECRET_TOKEN", encoded)
            self.assertNotIn("LEX4_SAFE", encoded)
            self.assertIn("PYTHONHASHSEED", encoded)


if __name__ == "__main__":
    unittest.main()
