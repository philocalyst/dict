"""Bounded adversarial checks for the isolated symbol-BWT candidate.

The review deliberately constructs validly resealed frames for malformed
grammar/event/directory fields.  A failure therefore identifies the parser or
entropy boundary rather than an ordinary outer-checksum mutation.
"""

from __future__ import annotations

import itertools
import random
import struct
import sys
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
FRONTIER = HERE.parent
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from grammar import grammar as grammar_codec  # noqa: E402
from symbol_bwt import codec  # noqa: E402


def _naive_bwt(values: tuple[int, ...]) -> tuple[tuple[int, ...], int]:
    order = sorted(
        range(len(values)),
        key=lambda index: (values[index:] + values[:index], index),
    )
    return tuple(values[(index - 1) % len(values)] for index in order), order.index(0)


def _model(*, rules: tuple[tuple[int, ...], ...] = (), block_bytes: int = 257) -> codec.Model:
    grammar_model = grammar_codec.Model(rules=rules, coder="fixed")
    event_lengths = codec._huffman_lengths([1] * (grammar_model.symbol_count + 1))
    return codec.Model(grammar_model, event_lengths, block_bytes=block_bytes)


def _empty_frame(
    grammar_blob: bytes,
    event_blob: bytes,
    symbol_count: int,
    *,
    block_bytes: int = 257,
    block_count: int = 0,
    raw_length: int = 0,
    directory: bytes = b"",
    payload: bytes = b"",
) -> bytes:
    fields = [
        codec.MAGIC,
        codec.VERSION,
        0,
        codec.HEADER_BYTES,
        block_bytes,
        block_count,
        raw_length,
        len(grammar_blob),
        len(event_blob),
        len(directory),
        len(payload),
        symbol_count,
        0,
        0,
    ]
    header_zero = codec.HEADER.pack(*fields)
    fields[12] = codec._metadata_crc(header_zero, grammar_blob, event_blob, directory)
    return codec.HEADER.pack(*fields) + grammar_blob + event_blob + directory + payload


def _reseal_directory(frame: bytes, index: int, field: int, value: int) -> bytes:
    fields = list(codec.HEADER.unpack_from(frame))
    grammar_at = codec.HEADER_BYTES
    event_at = grammar_at + fields[7]
    directory_at = event_at + fields[8]
    payload_at = directory_at + fields[9]
    grammar_blob = frame[grammar_at:event_at]
    event_blob = frame[event_at:directory_at]
    directory = bytearray(frame[directory_at:payload_at])
    record = list(codec.DIRECTORY.unpack_from(directory, index * codec.DIRECTORY_BYTES))
    record[field] = value
    codec.DIRECTORY.pack_into(directory, index * codec.DIRECTORY_BYTES, *record)
    fields[12] = 0
    header_zero = codec.HEADER.pack(*fields)
    fields[12] = codec._metadata_crc(header_zero, grammar_blob, event_blob, bytes(directory))
    return codec.HEADER.pack(*fields) + grammar_blob + event_blob + bytes(directory) + frame[payload_at:]


class SymbolBwtReviewTests(unittest.TestCase):
    def test_integer_bwt_matches_independent_rotation_oracle(self) -> None:
        for length in range(1, 8):
            for values in itertools.product(range(3), repeat=length):
                expected = _naive_bwt(tuple(values))
                actual = codec._bwt_transform(values)
                self.assertEqual(actual, expected)
                self.assertEqual(codec._inverse_bwt(*actual), tuple(values))

        rng = random.Random(0x51B07)
        alphabet = (-9, 0, 1, 256, 257, 999, 65535)
        for length in range(1, 80):
            values = tuple(rng.choice(alphabet) for _ in range(length))
            actual = codec._bwt_transform(values)
            self.assertEqual(actual, _naive_bwt(values))
            self.assertEqual(codec._inverse_bwt(*actual), values)

    def test_model_contains_complete_grammar_and_event_state(self) -> None:
        model = _model(rules=((ord("a"), ord("b")),), block_bytes=64)
        self.assertEqual(model.symbol_count, 257)
        self.assertEqual(model.event_count, 258)
        self.assertTrue(all(length > 0 for length in model.event_lengths))
        self.assertEqual(len(model.serialize_events()), codec.EVENT_HEAD.size + model.event_count)

        raw = (b"ab" * 1200) + bytes(range(256))
        frame = codec.encode(raw, model, block_bytes=64)
        metrics = codec.frame_metrics(frame)
        prepared = codec.prepare(frame)
        self.assertEqual(codec.decode(frame), raw)
        self.assertEqual(metrics["grammar_model_bytes"], len(model.serialize_grammar()))
        self.assertEqual(metrics["event_model_bytes"], len(model.serialize_events()))
        self.assertEqual(
            metrics["complete_bytes"],
            metrics["header_bytes"]
            + metrics["grammar_model_bytes"]
            + metrics["event_model_bytes"]
            + metrics["directory_bytes"]
            + metrics["payload_bytes"],
        )
        self.assertEqual(prepared.model.symbol_count, model.symbol_count)
        self.assertEqual(prepared.model.event_lengths, model.event_lengths)

        with self.assertRaises(codec.ModelError):
            codec.Model(model.grammar_model, (0,) + model.event_lengths[1:])
        with self.assertRaises(codec.ModelError):
            codec.Model(model.grammar_model, (33,) + model.event_lengths[1:])
        with self.assertRaises(codec.ModelError):
            codec.Model(model.grammar_model, model.event_lengths[:-1])

    def test_resealed_grammar_forward_reference_and_dag_capacity_bombs_reject(self) -> None:
        def grammar_blob(rules: tuple[tuple[int, ...], ...], *, training_bytes: int = 0) -> bytes:
            head = grammar_codec.MODEL_HEAD.pack(
                grammar_codec.MODEL_MAGIC,
                grammar_codec.MODEL_VERSION,
                grammar_codec.CODER_FIXED,
                grammar_codec.ALGORITHM_ID,
                grammar_codec.SCOPE_INPUT,
                len(rules),
                training_bytes,
                256 + len(rules),
            )
            body = bytearray(head)
            for rule in rules:
                body.extend(grammar_codec._put_uleb(len(rule)))
                for ref in rule:
                    body.extend(grammar_codec._put_uleb(ref))
            return bytes(body)

        def event_blob(symbol_count: int) -> bytes:
            lengths = codec._huffman_lengths([1] * (symbol_count + 1))
            return codec.EVENT_HEAD.pack(codec.EVENT_MAGIC, codec.VERSION, len(lengths)) + bytes(lengths)

        # Rule zero cannot name rule 257.  Both grammar and event blobs are
        # complete and the outer metadata CRC is valid.
        forward = grammar_blob(((0, 257),))
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(forward, event_blob(257), 257))

        # A 513-child rule is rejected by the model reader before it can
        # allocate/expand the references.
        arity_head = grammar_codec.MODEL_HEAD.pack(
            grammar_codec.MODEL_MAGIC,
            grammar_codec.MODEL_VERSION,
            grammar_codec.CODER_FIXED,
            grammar_codec.ALGORITHM_ID,
            grammar_codec.SCOPE_INPUT,
            1,
            0,
            257,
        )
        oversized_arity = arity_head + grammar_codec._put_uleb(grammar_codec.MAX_RULE_ARITY + 1)
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(oversized_arity, event_blob(257), 257))

        # A valid 512-byte rule followed by a parent that expands it twice is
        # a bounded grammar DAG bomb, not a stale outer checksum.
        expansion = grammar_blob((tuple(0 for _ in range(512)), (256, 256)))
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(expansion, event_blob(258), 258))

        training_overflow = grammar_blob((), training_bytes=grammar_codec.MAX_RAW_BYTES + 1)
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(training_overflow, event_blob(256), 256))

        too_many_head = grammar_codec.MODEL_HEAD.pack(
            grammar_codec.MODEL_MAGIC,
            grammar_codec.MODEL_VERSION,
            grammar_codec.CODER_FIXED,
            grammar_codec.ALGORITHM_ID,
            grammar_codec.SCOPE_INPUT,
            grammar_codec.MAX_RULES + 1,
            0,
            256 + grammar_codec.MAX_RULES + 1,
        )
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(too_many_head, event_blob(256 + grammar_codec.MAX_RULES + 1), 256 + grammar_codec.MAX_RULES + 1))

    def test_resealed_event_model_and_root_directory_ids_reject(self) -> None:
        model = _model(block_bytes=128)
        raw = (b"symbol BWT exact events " * 500) + bytes(range(256))
        frame = codec.encode(raw, model, block_bytes=128)
        prepared = codec.prepare(frame)
        coded_index = next(
            index
            for index, record in enumerate(prepared.parsed.records)
            if frame[prepared.parsed.payload_offset + record.offset] == codec.MODE_CODED
        )
        record = prepared.parsed.records[coded_index]

        # Header symbol_count is metadata state, not an uncharged hint.
        fields = list(codec.HEADER.unpack_from(frame))
        fields[11] += 1
        grammar_at = codec.HEADER_BYTES
        event_at = grammar_at + fields[7]
        directory_at = event_at + fields[8]
        payload_at = directory_at + fields[9]
        grammar_blob = frame[grammar_at:event_at]
        event_blob = frame[event_at:directory_at]
        directory = frame[directory_at:payload_at]
        fields[12] = 0
        fields[12] = codec._metadata_crc(codec.HEADER.pack(*fields), grammar_blob, event_blob, directory)
        bad_header = codec.HEADER.pack(*fields) + frame[codec.HEADER_BYTES:]
        with self.assertRaises(codec.FrameError):
            codec.prepare(bad_header)

        # Root-token overflow and BWT primary overflow are rejected before
        # attempting to expand or checksum the block.
        with self.assertRaises(codec.FrameError):
            codec.prepare(_reseal_directory(frame, coded_index, 3, record.raw_bytes + 1))
        with self.assertRaises(codec.FrameError):
            codec.prepare(_reseal_directory(frame, coded_index, 5, record.token_count))

        # Event count remains a charged directory field; it cannot be changed
        # to ask the Huffman decoder for an extra symbol.
        with self.assertRaises(codec.FrameError):
            codec.decode(_reseal_directory(frame, coded_index, 4, record.token_count * 2 + 17))

        # Event code lengths are complete charged state.  A resealed zero
        # literal length and an oversubscribed all-one table must not be
        # accepted as an alternate event model.
        grammar_blob = model.serialize_grammar()
        event_blob = bytearray(model.serialize_events())
        event_blob[codec.EVENT_HEAD.size] = 0
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(grammar_blob, bytes(event_blob), model.symbol_count))
        oversubscribed = bytearray(model.serialize_events())
        oversubscribed[codec.EVENT_HEAD.size :] = bytes([1]) * model.event_count
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(grammar_blob, bytes(oversubscribed), model.symbol_count))

    def test_exact_huffman_tail_and_resealed_bit_counts(self) -> None:
        model = codec.train(
            b"repeatable language event stream " * 1000,
            block_bytes=257,
            max_rules=0,
            max_passes=1,
            input_fit=True,
        )
        raw = b"repeatable language event stream " * 200
        frame = codec.encode(raw, model, block_bytes=257)
        prepared = codec.prepare(frame)
        coded_index = next(
            index
            for index, record in enumerate(prepared.parsed.records)
            if frame[prepared.parsed.payload_offset + record.offset] == codec.MODE_CODED
        )
        record = prepared.parsed.records[coded_index]
        self.assertGreater(record.valid_bits, 0)
        start = prepared.parsed.payload_offset + record.offset
        body_end = start + record.encoded_bytes

        # Resealing a different valid-bit count cannot alter the exact body
        # length charged by the directory.
        with self.assertRaises(codec.FrameError):
            codec.prepare(_reseal_directory(frame, coded_index, 7, record.valid_bits + 8))

        # If the final byte has padding, a nonzero padding bit is rejected by
        # the entropy parser itself; it is outside the metadata CRC.
        padding = (-record.valid_bits) & 7
        if padding:
            malformed = bytearray(frame)
            malformed[body_end - 1] |= 1
            with self.assertRaises(codec.FrameError):
                codec.decode(bytes(malformed))

        # A directly truncated body is also rejected before root expansion.
        malformed = bytearray(frame)
        malformed[body_end - 1] ^= 0x80
        with self.assertRaises(codec.FrameError):
            codec.decode(bytes(malformed))

    def test_empty_and_raw_fallback_roundtrip_and_access_bounds(self) -> None:
        model = _model(block_bytes=1)
        empty = codec.encode(b"", model, block_bytes=1)
        self.assertEqual(codec.decode(empty), b"")
        prepared_empty = codec.prepare(empty)
        with self.assertRaises(codec.FrameError):
            prepared_empty.decode_block(0)

        rng = random.Random(0xB07)
        raw = bytes(rng.randrange(256) for _ in range(900))
        frame = codec.encode(raw, model, block_bytes=257)
        prepared = codec.prepare(frame)
        self.assertGreater(len(prepared.parsed.records), 0)
        self.assertTrue(any(frame[prepared.parsed.payload_offset + record.offset] == codec.MODE_RAW for record in prepared.parsed.records))
        self.assertEqual(codec.decode(frame), raw)
        with self.assertRaises(codec.FrameError):
            prepared.decode_block(-1)
        with self.assertRaises(codec.FrameError):
            prepared.decode_block(len(prepared.parsed.records))

    def test_encoder_rejects_block_count_before_record_work(self) -> None:
        # Scale the constant down to make the guard cheap to exercise.  The
        # encoder must reject two one-byte records when MAX_BLOCKS is one with
        # FrameError, before it enters per-block BWT/entropy work.  At
        # production values the same path is reachable with >1,000,000
        # one-byte blocks.
        model = _model(block_bytes=1)
        original_limit = codec.MAX_BLOCKS
        original_encoder = codec._encoded_block

        def unexpected_record_work(*args: object, **kwargs: object) -> object:
            raise AssertionError("block-count guard ran after record work")

        codec.MAX_BLOCKS = 1
        codec._encoded_block = unexpected_record_work  # type: ignore[assignment]
        try:
            with self.assertRaises(codec.FrameError):
                codec.encode(b"ab", model, block_bytes=1)
        finally:
            codec.MAX_BLOCKS = original_limit
            codec._encoded_block = original_encoder


if __name__ == "__main__":
    unittest.main()
