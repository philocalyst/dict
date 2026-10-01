from __future__ import annotations

import random
import unittest

try:
    from . import structure
except ImportError:  # Preserve direct execution from this directory.
    import structure


class StructureCodecTests(unittest.TestCase):
    def test_exact_roundtrip_all_variants_and_boundaries(self) -> None:
        rng = random.Random(0xB45A)
        data = (
            b"<entry xml:lang=\"en\">Alpha beta 123 -- </entry>\n"
            + bytes(range(256))
            + "é日本語\x00".encode("utf-8")
            + bytes(rng.randrange(256) for _ in range(2_000))
        )
        for variant in ("raw", "shape", "byteclass", "templates"):
            model = structure.train(data[:1_048_576], variant=variant)
            for block_bytes in (17, 16_384, 65_536):
                frame = structure.encode(model, data, block_bytes=block_bytes)
                self.assertEqual(structure.decode(frame), data)
                blocks = (len(data) + block_bytes - 1) // block_bytes
                for index in range(blocks):
                    start = index * block_bytes
                    self.assertEqual(
                        structure.decode_block(frame, index), data[start : start + block_bytes]
                    )
            one_byte = data[:73]
            frame = structure.encode(model, one_byte, block_bytes=1)
            self.assertEqual(structure.decode(frame), one_byte)
            for index in range(len(one_byte)):
                self.assertEqual(structure.decode_block(frame, index), one_byte[index : index + 1])

    def test_empty_input(self) -> None:
        for variant in ("raw", "shape", "byteclass", "templates"):
            frame = structure.encode(structure.train(b"", variant=variant), b"")
            self.assertEqual(structure.decode(frame), b"")
            self.assertEqual(structure.frame_info(frame)["block_count"], 0)
            with self.assertRaises(IndexError):
                structure.decode_block(frame, 0)

    def test_unknown_and_invalid_bytes_are_preserved(self) -> None:
        data = bytes([0, 1, 2, 9, 10, 13, 32, 127, 128, 129, 191, 192, 223, 240, 255]) * 100
        for variant in ("shape", "byteclass", "templates"):
            frame = structure.encode(structure.train(data, variant=variant), data, block_bytes=31)
            self.assertEqual(structure.decode(frame), data)

    def test_corruption_and_truncation_rejected(self) -> None:
        data = b"markup " * 1_000
        frame = bytearray(structure.encode(structure.train(data, variant="templates"), data, block_bytes=257))
        for cut in (0, 1, 51, len(frame) - 1):
            with self.assertRaises(structure.FrameError):
                structure.decode(bytes(frame[:cut]))
        # Header, model/directory, and payload mutations are all checked by a
        # different checksum or by the strict transformed decoder.
        for offset in (0, structure.HEADER_SIZE, len(frame) - 1):
            mutated = bytearray(frame)
            mutated[offset] ^= 0x01
            with self.assertRaises(structure.FrameError):
                structure.decode(bytes(mutated))

    def test_unknown_variant_and_bounds_rejected(self) -> None:
        data = b"abc" * 500
        frame = bytearray(structure.encode(structure.train(data, variant="shape"), data, block_bytes=64))
        # Variant byte is the sixth byte of the fixed header.
        frame[5] = 99
        with self.assertRaises(structure.FrameError):
            structure.decode(bytes(frame))
        valid = structure.encode(structure.train(data, variant="shape"), data, block_bytes=64)
        with self.assertRaises(structure.FrameError):
            structure.decode(valid, max_frame_bytes=len(valid) - 1)
        with self.assertRaises(ValueError):
            structure.encode(structure.train(data), data, block_bytes=structure.MAX_BLOCK_BYTES + 1)

    def test_model_is_training_only_and_templates_are_bounded(self) -> None:
        train = b"<a>same</a>" * 10_000
        model = structure.train(train, variant="templates", max_templates=7)
        self.assertLessEqual(len(model.templates), 7)
        self.assertEqual(structure.Model.from_bytes("templates", model.to_bytes()), model)


if __name__ == "__main__":
    unittest.main()
