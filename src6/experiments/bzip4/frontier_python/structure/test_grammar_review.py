"""Adversarial wire and capacity checks for the isolated grammar codec.

The normal grammar tests cover roundtrips.  These checks deliberately rebuild
the metadata CRC after malformed header/model/directory edits so a rejection
cannot be attributed only to a stale checksum.  They also exercise the model
parser directly with forward references, oversized arity/expansion, and the
in-memory trie rule that prevents an uncoded internal DAG node from becoming a
frozen-model terminal.
"""

from __future__ import annotations

import sys
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
FRONTIER = HERE.parent
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from grammar import grammar as codec  # noqa: E402


def _reseal(frame: bytes, *, fields: list[object] | None = None, directory: bytes | None = None) -> bytes:
    parsed = list(codec.HEADER.unpack_from(frame)) if fields is None else list(fields)
    model_at = codec.HEADER_BYTES
    model_length = int(parsed[7])
    directory_at = model_at + model_length
    directory_length = int(parsed[8])
    model_blob = frame[model_at:directory_at]
    directory_blob = frame[directory_at : directory_at + directory_length] if directory is None else directory
    parsed[10] = 0
    header_zero = codec.HEADER.pack(*parsed)
    parsed[10] = codec._metadata_crc(header_zero, model_blob, directory_blob)
    result = bytearray(frame)
    result[: codec.HEADER_BYTES] = codec.HEADER.pack(*parsed)
    if directory is not None:
        result[directory_at : directory_at + directory_length] = directory_blob
    return bytes(result)


def _empty_frame(model_blob: bytes) -> bytes:
    fields: list[object] = [
        codec.MAGIC,
        codec.VERSION,
        0,
        codec.HEADER_BYTES,
        1,
        0,
        0,
        len(model_blob),
        0,
        0,
        0,
        0,
    ]
    header = codec.HEADER.pack(*fields)
    return _reseal(header + model_blob, fields=fields)


def _fixed_model_blob(rules: tuple[tuple[int, ...], ...], *, training_bytes: int = 0) -> bytes:
    result = bytearray(
        codec.MODEL_HEAD.pack(
            codec.MODEL_MAGIC,
            codec.MODEL_VERSION,
            codec.CODER_FIXED,
            codec.ALGORITHM_ID,
            codec.SCOPE_INPUT,
            len(rules),
            training_bytes,
            256 + len(rules),
        )
    )
    for rule in rules:
        result.extend(codec._put_uleb(len(rule)))
        for ref in rule:
            result.extend(codec._put_uleb(ref))
    return bytes(result)


class GrammarReviewTests(unittest.TestCase):
    def test_resealed_header_and_directory_bounds(self) -> None:
        raw = b"repeat me " * 500
        frame = codec.encode(raw, 256, max_rules=128)
        base = list(codec.HEADER.unpack_from(frame))
        model_at = codec.HEADER_BYTES
        directory_at = model_at + base[7]
        directory = bytearray(frame[directory_at : directory_at + base[8]])

        probes: list[tuple[str, bytes]] = []
        for name, index, value in (
            ("reserved", 11, 1),
            ("block-bytes-zero", 4, 0),
            ("raw-length", 6, base[6] + 1),
            ("block-count", 5, base[5] + 1),
            ("directory-length", 8, base[8] + codec.DIR_BYTES),
            ("model-length-zero", 7, 0),
        ):
            fields = list(base)
            fields[index] = value
            probes.append((name, _reseal(frame, fields=fields)))

        first = list(codec.DIR.unpack_from(directory))
        first[0] = 1
        bad_offset = bytearray(directory)
        codec.DIR.pack_into(bad_offset, 0, *first)
        probes.append(("directory-offset", _reseal(frame, directory=bytes(bad_offset))))

        first = list(codec.DIR.unpack_from(directory))
        first[4] += 8
        bad_bits = bytearray(directory)
        codec.DIR.pack_into(bad_bits, 0, *first)
        probes.append(("valid-bit-count", _reseal(frame, directory=bytes(bad_bits))))

        for name, probe in probes:
            with self.subTest(name=name), self.assertRaises((codec.FrameError, codec.ModelError)):
                codec.prepare(probe)

        # Payload is intentionally outside the metadata CRC.  Appending one
        # byte and resealing the length fields must still fail at the directory
        # total check rather than silently becoming an uncharged trailer.
        fields = list(base)
        fields[9] += 1
        trailer = _reseal(frame + b"x", fields=fields)
        with self.assertRaises(codec.FrameError):
            codec.prepare(trailer)

    def test_resealed_forward_reference_and_capacity_limits(self) -> None:
        forward = _empty_frame(_fixed_model_blob(((256, 0),)))
        with self.assertRaises(codec.FrameError):
            codec.prepare(forward)

        oversized_arity = _empty_frame(_fixed_model_blob((tuple(0 for _ in range(codec.MAX_RULE_ARITY + 1)),)))
        with self.assertRaises(codec.FrameError):
            codec.prepare(oversized_arity)

        too_many_rules = codec.MODEL_HEAD.pack(
            codec.MODEL_MAGIC,
            codec.MODEL_VERSION,
            codec.CODER_FIXED,
            codec.ALGORITHM_ID,
            codec.SCOPE_INPUT,
            codec.MAX_RULES + 1,
            0,
            256 + codec.MAX_RULES + 1,
        )
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(too_many_rules))

        # The wire ordering is topological, so the following is not a cycle
        # that can sneak past the forward-reference check: it is a valid
        # backward-reference chain whose final expansion exceeds 512 bytes.
        expansion_overflow = _fixed_model_blob(
            (
                tuple(0 for _ in range(256)),
                (256, 256),
                (257, 257),
            )
        )
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(expansion_overflow))

        # Model metadata with an impossible training byte count reaches the
        # Model invariant after the metadata CRC has already been resealed.
        invalid_training = _fixed_model_blob((), training_bytes=codec.MAX_RAW_BYTES + 1)
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(invalid_training))

    def test_uncoded_internal_rule_is_not_a_frozen_trie_terminal(self) -> None:
        rules = ((ord("a"), ord("b")), (256, 256))
        symbol_count = 256 + len(rules)
        frequencies = (1,) * symbol_count
        lengths = list(codec._huffman_lengths(frequencies))
        lengths[256] = 0  # internal child deliberately lacks an event code
        model = codec.Model(
            rules=rules,
            coder="huff",
            frequencies=frequencies,
            code_lengths=tuple(lengths),
        )
        self.assertEqual(codec._tokenize_with_model(b"ab", model), [ord("a"), ord("b")])
        self.assertEqual(codec._tokenize_with_model(b"abab", model), [257])

    def test_noncanonical_uleb_references_are_rejected_after_reseal(self) -> None:
        # The grammar model is self-delimiting; alternate zero encodings must
        # not change where the rule or its children end.  Both probes carry a
        # valid frame metadata CRC, so rejection comes from _read_uleb().
        head = codec.MODEL_HEAD.pack(
            codec.MODEL_MAGIC,
            codec.MODEL_VERSION,
            codec.CODER_FIXED,
            codec.ALGORITHM_ID,
            codec.SCOPE_INPUT,
            1,
            0,
            257,
        )
        noncanonical_arity = head + b"\x82\x00" + codec._put_uleb(0) + codec._put_uleb(1)
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(noncanonical_arity))

        noncanonical_reference = head + b"\x02" + b"\x80\x00" + codec._put_uleb(1)
        with self.assertRaises(codec.FrameError):
            codec.prepare(_empty_frame(noncanonical_reference))

    def test_decoder_accepts_a_non_longest_but_expansion_equivalent_token_stream(self) -> None:
        # This is a format-policy observation, not a corruption primitive:
        # [child, child] and [parent] expand to the same bytes.  The encoder's
        # trie chooses the longest match, but the decoder validates expansion
        # and CRC rather than re-tokenizing the result, so both streams are
        # semantically valid wire representations.
        model = codec.Model(
            rules=((ord("a"), ord("b")), (256, 256)),
            coder="huff",
            frequencies=(1,) * 258,
        )
        raw = b"abab"
        original = codec.encode(raw, 4, model=model)
        body, valid_bits = codec._encode_huffman([256, 256], model.code_lengths)
        alternate_block = b"\x01" + body
        directory = codec.DIR.pack(0, len(alternate_block), len(raw), codec._crc(raw), valid_bits)
        model_blob = model.serialize()
        alternate = codec._frame_with_directory(
            len(raw),
            [raw],
            [alternate_block],
            model_blob,
            directory,
            alternate_block,
            4,
        )
        self.assertNotEqual(alternate, original)
        self.assertEqual(codec.decode(alternate), raw)

    def test_zero_literal_huffman_state_is_rejected_at_model_boundary(self) -> None:
        # The repaired public constructor rejects a zero literal frequency;
        # the corresponding serialized length-table mutation must also fail
        # after a valid metadata reseal.  Internal zero code lengths remain
        # legal only for uncoded DAG nodes.
        with self.assertRaises(codec.FrameError):
            model = codec.Model(rules=(), frequencies=(1,) * 256)
            frame = codec.encode(b"a", 1, model=model)
            model_at = codec.HEADER_BYTES
            length_at = model_at + codec.MODEL_HEAD_BYTES
            mutated = bytearray(frame)
            mutated[length_at] = 0
            codec.prepare(_reseal(bytes(mutated)))

        with self.assertRaises(codec.ModelError):
            codec.Model(rules=(), frequencies=(0,) + (1,) * 255)


if __name__ == "__main__":
    unittest.main()
