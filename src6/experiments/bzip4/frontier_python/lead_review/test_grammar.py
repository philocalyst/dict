"""Independent grammar API invariants, separate from worker tests."""

from pathlib import Path
import random
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from grammar import grammar


class GrammarAudit(unittest.TestCase):
    def test_internal_definition_is_not_a_stream_symbol(self):
        # 'ab' is needed only as the definition of codeable 'abc'. A new input
        # containing 'abx' must fall back to literals, never emit uncoded 'ab'.
        model = grammar.Model(
            rules=((ord("a"), ord("b")), (256, ord("c"))),
            scope="training", frequencies=tuple([1] * 256 + [0, 100]),
        )
        self.assertEqual(model.code_lengths[256], 0)
        data = b"abxabc" * 73 + bytes(range(256))
        for restored_model in (model, grammar.Model.from_bytes(model.serialize())):
            wire = grammar.encode(data, 127, model=restored_model)
            self.assertEqual(grammar.decode(wire), data)

    def test_arbitrary_input_and_every_restart(self):
        rng = random.Random(417523)
        samples = (b"", rng.randbytes(3001), b"\xff\xfe\x00" * 913,
                   "été 日本語 العربية\n".encode() * 71,
                   b"abcdefghij" * 377)
        for data in samples:
            for boundary in (1, 79, 65536):
                for variant in ("input_huff", "input_fixed"):
                    with self.subTest(size=len(data), boundary=boundary, variant=variant):
                        frame = grammar.encode(data, boundary, variant=variant)
                        self.assertEqual(grammar.decode(frame), data)
                        view = grammar.prepare(frame)
                        for index, offset in enumerate(range(0, len(data), boundary)):
                            self.assertEqual(view.decode_block(index), data[offset:offset + boundary])

    def test_serialized_model_and_frame_mutations(self):
        data = b"a repeated fragment is a definition, not an event; " * 60
        frame = grammar.encode(data, 511)
        rng = random.Random(7339)
        for _ in range(80):
            mutated = bytearray(frame)
            at = rng.randrange(len(frame))
            mutated[at] ^= 1 << rng.randrange(8)
            try:
                result = grammar.decode(bytes(mutated))
            except (grammar.FrameError, grammar.ModelError):
                continue
            self.assertEqual(result, data)
        for rules in (((256, 97),), ((97, 98), (258, 256))):
            with self.assertRaises(grammar.ModelError):
                grammar.Model(rules=rules)


if __name__ == "__main__":
    unittest.main()
