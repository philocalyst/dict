from __future__ import annotations

import unittest

from .codec import FrameError, decode, encode, train


class BindingCodecTests(unittest.TestCase):
    def test_varied_arguments_and_repeated_bindings_roundtrip(self) -> None:
        training = b"".join(
            b"<entry><head>" + word + b"</head><tail>same</tail></entry>\n"
            for word in (b"cat", b"dog", b"pig", b"cow") * 32
        )
        model = train(training)
        self.assertTrue(model.templates)
        evaluation = b"".join(
            b"<entry><head>" + word + b"</head><tail>same</tail></entry>\n"
            for word in (b"rat", b"cat", b"dog") * 16
        )
        frame = encode(model, evaluation, block_bytes=128)
        self.assertEqual(decode(frame), evaluation)

    def test_repeated_variable_identity_is_preserved(self) -> None:
        training = b"".join(
            b"<left>" + word + b"</left> / <right>" + word + b"</right>\n"
            for word in (b"cat", b"dog", b"pig", b"cow") * 16
        )
        model = train(training)
        self.assertTrue(any(len(set(template.variables)) < len(template.variables) for template in model.templates))
        evaluation = b"<left>rat</left> / <right>rat</right>\n"
        self.assertEqual(decode(encode(model, evaluation)), evaluation)

    def test_arbitrary_bytes_roundtrip_without_utf8_assumptions(self) -> None:
        data = bytes(range(256)) + b"\x00\xff\xc3\x28\n" + "e\u0301 日本 العربية".encode("utf-8")
        model = train(data)
        self.assertEqual(decode(encode(model, data, block_bytes=64)), data)

    def test_empty_input_roundtrip(self) -> None:
        model = train(b"")
        self.assertEqual(decode(encode(model, b"", block_bytes=64)), b"")

    def test_corrupt_metadata_and_payload_are_rejected(self) -> None:
        data = b"<x>one</x>\n<x>two</x>\n" * 8
        frame = bytearray(encode(train(data), data, block_bytes=64))
        frame[-1] ^= 0x40
        with self.assertRaises(FrameError):
            decode(bytes(frame))

    def test_random_no_repeat_does_not_invent_templates(self) -> None:
        data = bytes(((index * 73 + 19) & 0xFF) for index in range(1200))
        model = train(data)
        self.assertEqual(model.templates, ())
        self.assertEqual(decode(encode(model, data, block_bytes=128)), data)


if __name__ == "__main__":
    unittest.main()
