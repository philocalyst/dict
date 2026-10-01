"""Correctness and hostile-wire tests for the global grammar reference."""

from __future__ import annotations

import random
import struct
import unittest

try:
    from . import grammar
except ImportError:  # Preserve direct execution from this directory.
    import grammar


class GrammarCodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rng = random.Random(0xB4_2026)
        # Draw once and retain the exact seeded stream.  Re-seeding per case
        # would hide accidental fixture-dependent behavior.
        cls.seeded_random = bytes(cls.rng.randrange(256) for _ in range(65536))
        cls.training = (b"the quick brown fox jumps over the lazy dog; " * 500) + bytes(range(256)) * 16

    def roundtrip(self, raw: bytes, *, coder: str = "huff", block: int = 257) -> bytes:
        frame = grammar.encode(raw, block, variant="input_fixed" if coder == "fixed" else "input_huff", max_rules=256)
        self.assertEqual(grammar.decode(frame), raw)
        prepared = grammar.prepare(frame)
        rebuilt = b"".join(prepared.decode_block(index) for index in range(len(prepared.records)))
        self.assertEqual(rebuilt, raw)
        self.assertEqual(grammar.decode_all(prepared), raw)
        return frame

    def test_empty_full_boundary_unicode_invalid_and_random(self) -> None:
        cases = [
            b"",
            b"x",
            b"\x00\xff\x80",
            bytes(range(256)),
            b"A" * 65536,
            ("English 日本語 العربية हिन्दी — dictionary\n".encode("utf-8") + b"\xff\xfe\x80") * 200,
            self.seeded_random,
        ]
        for raw in cases:
            with self.subTest(size=len(raw)):
                self.roundtrip(raw, block=65536 if len(raw) >= 65536 else 257)
                self.roundtrip(raw, coder="fixed", block=4096)

    def test_long_repeats_create_shared_dag_and_are_deterministic(self) -> None:
        raw = (b"<entry><word>repeatable</word><definition>long shared grammar</definition></entry>\n" * 2000)
        first = self.roundtrip(raw, block=4096)
        second = grammar.encode(raw, 4096, max_rules=256)
        self.assertEqual(first, second)
        info = grammar.frame_metrics(first)
        self.assertGreater(info["rule_count"], 0)
        self.assertGreater(info["rule_expansion_bytes"], 0)
        self.assertEqual(info["raw_bytes"], len(raw))

    def test_pruning_counts_stored_fanin_not_runtime_expansion(self) -> None:
        # This pattern creates deep residual reuse.  Every retained rule must
        # have at least two stored sites (root streams plus one occurrence in
        # each reachable definition); a parent used 100 times must not keep a
        # child that is present only once in that parent's definition.
        raw = (b"prefix-ABCD-suffix\n" * 100) + (b"prefix-ABCE-suffix\n" * 100)
        rules, blocks, _ = grammar._build_grammar(raw, 4096, max_rules=256)
        reachable: set[int] = set()
        pending = [ref - 256 for sequence in blocks for ref in sequence if ref >= 256]
        while pending:
            index = pending.pop()
            if index in reachable:
                continue
            reachable.add(index)
            pending.extend(ref - 256 for ref in rules[index] if ref >= 256)
        stored = [0] * len(rules)
        for sequence in blocks:
            for ref in sequence:
                if ref >= 256:
                    stored[ref - 256] += 1
        for index in reachable:
            for ref in rules[index]:
                if ref >= 256:
                    stored[ref - 256] += 1
        self.assertTrue(all(stored[index] >= 2 for index in reachable))

    def test_frozen_training_grammar_handles_unseen_literals(self) -> None:
        model = grammar.train(self.training, block_bytes=1024, max_rules=512)
        raw = (b"new spelling \xff\xfe\x80 " * 300) + self.seeded_random[:1000]
        frame = grammar.encode(raw, 1024, model=model)
        self.assertEqual(grammar.decode(frame), raw)
        self.assertEqual(grammar.prepare(frame).model.scope, "training")

    def test_internal_zero_huffman_rule_is_wire_legal_but_literals_are_not(self) -> None:
        # Rule 256 is present only inside rule 257.  It therefore has no
        # top-level event and is deliberately uncoded; the trie must skip it
        # while retaining rule 257 as the held-out match.
        frequencies = tuple([1] * 256 + [0, 100])
        model = grammar.Model(
            rules=((97, 98), (256, 99)),
            coder="huff",
            frequencies=frequencies,
        )
        blob = model.serialize()
        rebuilt = grammar.Model.from_bytes(blob)
        self.assertEqual(rebuilt.code_lengths[256], 0)
        self.assertGreater(rebuilt.code_lengths[257], 0)
        frame = grammar.encode(b"abc" * 80, 256, model=rebuilt)
        self.assertEqual(grammar.decode(frame), b"abc" * 80)

        with self.assertRaises(grammar.ModelError):
            grammar.Model(rules=(), coder="huff", frequencies=(0,) + (1,) * 255)
        lengths = list(grammar.Model(rules=(), coder="huff").code_lengths)
        lengths[0] = 0
        with self.assertRaises(grammar.ModelError):
            grammar.Model(rules=(), coder="huff", code_lengths=tuple(lengths))

    def test_consistent_pair_policy_roundtrip(self) -> None:
        raw = (b"abcabca abcabca abcabca -- " * 500) + self.seeded_random[:2048]
        frame = grammar.encode(raw, 1024, max_rules=512, max_passes=24, pair_policy="consistent")
        self.assertEqual(grammar.metrics()["grammar"].get("pair_policy"), "consistent")
        self.assertEqual(grammar.decode(frame), raw)

    def test_independent_block_records(self) -> None:
        raw = (b"block-local restart and shared rules " * 400) + bytes(range(256))
        frame = self.roundtrip(raw, block=113)
        prepared = grammar.prepare(frame)
        at = 0
        for index, record in enumerate(prepared.records):
            piece = prepared.decode_block(index)
            self.assertEqual(piece, raw[at : at + record.raw_bytes])
            at += record.raw_bytes
        self.assertEqual(at, len(raw))

    def test_header_model_directory_tails_and_padding_rejected(self) -> None:
        raw = b"repeat me " * 500
        frame = grammar.encode(raw, 256, max_rules=128)
        probes = {
            "magic": bytes((frame[0] ^ 1,)) + frame[1:],
            "header": frame[:12] + bytes((frame[12] ^ 1,)) + frame[13:],
            "trailing": frame + b"x",
            "truncated": frame[:-1],
        }
        for name, probe in probes.items():
            with self.subTest(name=name), self.assertRaises((grammar.FrameError, ValueError)):
                grammar.decode(probe)

        prepared = grammar.prepare(frame)
        coded = next((record for record in prepared.records if frame[prepared.payload_offset + record.offset] == 1), None)
        if coded is not None and coded.valid_bits & 7:
            at = prepared.payload_offset + coded.offset + coded.encoded_bytes - 1
            bad = bytearray(frame)
            bad[at] |= 1
            with self.assertRaises(grammar.FrameError):
                grammar.decode(bytes(bad))

    def test_forward_reference_cycle_and_expansion_overflow_rejected(self) -> None:
        with self.assertRaises(grammar.ModelError):
            grammar.Model(rules=((256, 257), (256, 256)))
        rules: list[tuple[int, ...]] = [(0, 0)]
        for _ in range(9):
            rules.append((256 + len(rules) - 1, 256 + len(rules) - 1))
        with self.assertRaises(grammar.ModelError):
            grammar.Model(rules=tuple(rules))

        # A hand-built serialized rule with child ID 256 in rule zero is a
        # forward reference.  The frequency table is otherwise complete so
        # this reaches the ordering check rather than an unrelated truncation.
        head = grammar.MODEL_HEAD.pack(grammar.MODEL_MAGIC, 1, 0, 1, 0, 1, 0, 257)
        bad_model = head + b"\x02" + grammar._put_uleb(256) + grammar._put_uleb(0)
        bad_model += grammar._put_uleb(256)
        for symbol in range(256):
            bad_model += grammar._put_uleb(symbol) + grammar._put_uleb(1) + b"\x08"
        with self.assertRaises(grammar.FrameError):
            grammar.Model.from_bytes(bad_model)

    def test_model_and_decode_bomb_limits(self) -> None:
        raw = b"safe frame " * 300
        frame = grammar.encode(raw, 128, max_rules=64)
        fields = list(grammar.HEADER.unpack_from(frame))
        model_at = grammar.HEADER_BYTES
        directory_at = model_at + fields[7]
        directory = bytearray(frame[directory_at : directory_at + fields[8]])
        record = list(grammar.DIR.unpack_from(directory))
        record[2] = fields[4] + 1
        grammar.DIR.pack_into(directory, 0, *record)
        fields[10] = 0
        header_zero = grammar.HEADER.pack(*fields)
        model_blob = frame[model_at:directory_at]
        fields[10] = grammar._metadata_crc(header_zero, model_blob, bytes(directory))
        bad = bytearray(frame)
        bad[: grammar.HEADER_BYTES] = grammar.HEADER.pack(*fields)
        bad[directory_at : directory_at + fields[8]] = directory
        with self.assertRaises(grammar.FrameError):
            grammar.prepare(bytes(bad))


if __name__ == "__main__":
    unittest.main()
