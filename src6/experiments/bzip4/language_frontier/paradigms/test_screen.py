#!/usr/bin/env python3
"""Round-trip and corruption tests for the isolated PPL screen."""

from __future__ import annotations

import pathlib
import sys
import unittest


HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import screen  # noqa: E402
import backend_screen  # noqa: E402
import generative_screen  # noqa: E402
import evidence_check  # noqa: E402


class ScreenTests(unittest.TestCase):
    def test_all_modes_preserve_arbitrary_bytes(self) -> None:
        # This deliberately contains invalid UTF-8, NUL, high bytes, ASCII
        # digits, separators, and a mixed-script UTF-8 sequence.  The screen
        # must not normalize, decode, or drop any of it.
        data = b"cats cat\x00CAT\xff\xe3\x81\x82 42\x80,\n"
        words, pieces = screen.scan(data)
        self.assertEqual(screen.decode_payload(screen.encode_payload(pieces, {i: i for i in range(len(words))}), words, len(data)), data)
        for mode in ("independent", "cut", "edit", "program"):
            for order in ("first", "lex"):
                frame, stats = screen.build_frame(data, words, pieces, mode, order, 4, 128, 2_000)
                self.assertEqual(screen.decode_frame(frame), data)
                self.assertEqual(stats.input_hash, screen.hash_hex(data))
                self.assertTrue(stats.roundtrip)

        frame, stats = screen.build_frame(data, words, pieces, "dafsa", "lex", 4, 128, 2_000)
        self.assertEqual(screen.decode_frame(frame), data)
        self.assertEqual(stats.by_family["states"], len(screen.build_dafsa(sorted(words))[0]))

    def test_program_reuses_nonprefix_geometry_and_charges_literals(self) -> None:
        # Two unrelated long stems each have one internal substitution.  The
        # two C-S-C relations share one geometry template; only parent IDs and
        # replacement bytes remain edge-local.
        data = b"abcdefghijabcdefghij klmnopqrstklmnopqrst abcdefghijXbcdefghij klmnopqrstYlmnopqrst"
        words, pieces = screen.scan(data)
        frame, stats = screen.build_frame(data, words, pieces, "program", "first", 4, 128, 2_000)
        self.assertEqual(screen.decode_frame(frame), data)
        self.assertEqual(stats.templates, 1)
        self.assertEqual(stats.relations, 2)
        self.assertEqual(stats.novel_relations, 2)
        self.assertEqual(stats.by_family, {"substitution_nonprefix": 2})
        self.assertEqual(stats.relation_literals, 2)

    def test_edit_and_program_frames_reject_truncation_and_bad_crc(self) -> None:
        data = b"abcdefghijklmnopqrst abcdefghijXbcdefghij"
        words, pieces = screen.scan(data)
        for mode in ("independent", "cut", "edit", "program", "dafsa"):
            frame, _ = screen.build_frame(data, words, pieces, mode, "lex" if mode == "dafsa" else "first", 4, 128, 2_000)
            with self.assertRaises(ValueError):
                screen.decode_frame(frame[:-1])
            damaged = bytearray(frame)
            damaged[-1] ^= 0x01
            with self.assertRaises(ValueError):
                screen.decode_frame(bytes(damaged))

    def test_candidate_policy_is_not_an_oracle(self) -> None:
        words = [b"abcdefghijabcdefghij", b"klmnopqrstklmnopqrst", b"abcdefghijXbcdefghij"]
        candidate = screen.best_relation(words, 2, 4, 128)
        self.assertIsNotNone(candidate)
        assert candidate is not None
        self.assertEqual(candidate.parent, 0)
        self.assertEqual(candidate.family, "substitution_nonprefix")

    def test_common_backends_wrap_complete_frame_and_raw_direct(self) -> None:
        data = b"abcdefghijklmnopqrst abcdefghijXbcdefghij\x00"
        words, pieces = screen.scan(data)
        frame, _ = screen.build_frame(data, words, pieces, "program", "first", 4, 128, 2_000)
        for backend in ("zlib", "bz2"):
            packed_raw = backend_screen.compress(backend, data)
            packed_frame = backend_screen.compress(backend, frame)
            self.assertEqual(backend_screen.decompress(backend, packed_raw), data)
            self.assertEqual(backend_screen.decompress(backend, packed_frame), frame)

    def test_shared_set_frame_charges_first_use_permutation_and_roundtrips(self) -> None:
        data = b"abcdefghijabcdefghij klmnopqrstklmnopqrst abcdefghijXbcdefghij klmnopqrstYlmnopqrst"
        words, pieces = screen.scan(data)
        for order in ("first", "lex"):
            frame, stats = generative_screen.build_frame(data, words, pieces, order)
            self.assertEqual(generative_screen._decode_frame(frame), data)
            self.assertGreaterEqual(stats.groups, 1)
            if order == "first":
                self.assertGreater(stats.permutation_bytes, 0)
            else:
                self.assertEqual(stats.permutation_bytes, 0)

    def test_evidence_comparison_ledger_asserts_measured_signs(self) -> None:
        summary = evidence_check.validate()
        self.assertEqual(summary["pgs_minus_independent"]["OMW/lex"], -668)
        self.assertEqual(summary["common_program_minus_cut_zlib_bz2"]["OMW/first"], (-65, -95))


if __name__ == "__main__":
    unittest.main()
