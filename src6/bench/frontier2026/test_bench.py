import unittest
import struct
import zlib
from unittest.mock import patch

from bench import (BenchError, HEADER, MAGIC, VERSION, bz4_max_atom_bytes, decode_frame,
                   encode_frame, intrinsic_ns, verify_extraction)
from sbwt_adapter import inspect as inspect_sbwt


class FrameProtocolTests(unittest.TestCase):
    def test_complete_roundtrip_and_accounted_metadata(self):
        raw = b"fish\0fish\n" * 1800
        identity = {"encode": ["cat"], "decode": ["cat"], "model_dictionary_bytes": 17}
        frame, stats = encode_frame(raw, 1024, identity)
        checked = decode_frame(frame, raw, identity, 1024, measure=True)
        self.assertTrue(checked["verified"])
        self.assertEqual(stats["blocks"], 18)
        self.assertEqual(stats["frame_header_bytes"], HEADER.size)
        self.assertEqual(stats["frame_bytes"], len(frame))
        self.assertEqual(stats["model_dictionary_bytes"], 17)

    def test_rejects_bad_header(self):
        raw = b"a"
        identity = {"encode": ["cat"], "decode": ["cat"]}
        frame, _ = encode_frame(raw, 64, identity)
        self.assertEqual(frame[:8], MAGIC)
        broken = bytes([frame[0] ^ 1]) + frame[1:]
        with self.assertRaises(BenchError):
            decode_frame(broken, raw, identity, 64, measure=False)

    def test_rejects_nonidentical_decoded_content(self):
        identity = {"encode": ["cat"], "decode": ["cat"]}
        frame, _ = encode_frame(b"abc", 64, identity)
        with self.assertRaises(BenchError):
            decode_frame(frame, b"abd", identity, 64, measure=False)


class SbwtFrameAccountingTests(unittest.TestCase):
    @staticmethod
    def raw_fallback_frame(flags=0, *, roots=1, primary=0xFFFFFFFF, events=1, encoded=1):
        header = struct.pack("<4sIIIQIIII", b"WSB2", 2, 1, 1, 1, 0, 0, 0, flags)
        record = struct.pack("<Q6I", 0, encoded, 1, roots, primary, events, zlib.crc32(b"x"))
        metadata = bytearray(header + record)
        metadata[32:36] = struct.pack("<I", zlib.crc32(metadata))
        return bytes(metadata) + b"x" * encoded

    def test_accounts_complete_wsb2_raw_fallback_frame(self):
        stats = inspect_sbwt(self.raw_fallback_frame())
        self.assertEqual(stats["frame_bytes"], 73)
        self.assertEqual(stats["model_dictionary_bytes"], 0)
        self.assertEqual(stats["payload_bytes"], 1)
        self.assertEqual(stats["block_raw_lengths"], [1])
        self.assertEqual(inspect_sbwt(self.raw_fallback_frame(flags=17))["flags"], 17)

    def test_rejects_reserved_wsb2_flags_and_bad_raw_fallback(self):
        with self.assertRaises(ValueError):
            inspect_sbwt(self.raw_fallback_frame(flags=12))
        with self.assertRaises(ValueError):
            inspect_sbwt(self.raw_fallback_frame(flags=32))
        for frame in (
            self.raw_fallback_frame(encoded=2),  # raw-fallback length mismatch
            self.raw_fallback_frame(roots=2),  # roots cannot exceed raw bytes
            self.raw_fallback_frame(events=3),  # events are bounded by root count
            self.raw_fallback_frame(primary=1),  # primary index must be inside roots
        ):
            with self.subTest(frame=frame):
                with self.assertRaises(ValueError):
                    inspect_sbwt(frame)


class Bz4RestartSlackTests(unittest.TestCase):
    def test_longest_atom_matches_bz4_v3_byte_rules(self):
        self.assertEqual(bz4_max_atom_bytes(b"abc123\xc3\xa9!XYZ\n"), 3)
        self.assertEqual(bz4_max_atom_bytes(b"word-1234567-xy"), 7)
        self.assertEqual(bz4_max_atom_bytes(b""), 0)

    def test_legacy_replay_extraction_samples_uniformly_and_includes_edges(self):
        raw = bytes(range(80))
        lengths = [4] * 20
        calls = []

        def fake_extract(command, frame, block_bytes, extra, events=None):
            index = int(extra["block_index"])
            calls.append(index)
            return raw[index * 4:(index + 1) * 4]

        with patch("bench.run_bytes", side_effect=fake_extract):
            stats = verify_extraction(b"frame", raw,
                                      {"extract": ["fake"], "extraction_policy": "legacy_sampled_replay16"},
                                      4, raw_lengths=lengths, measure=True)
        self.assertEqual(len(calls), 16)
        self.assertEqual(calls, stats["extraction_verified_block_indices"])
        self.assertEqual(calls[0], 0)
        self.assertEqual(calls[-1], 19)
        self.assertEqual(stats["extraction_verified_raw_bytes"], 64)
        self.assertEqual([sample["block_index"] for sample in stats["extraction_cold_samples"]], [0, 10, 19])


class NativeTimingAttributionTests(unittest.TestCase):
    def test_encoder_and_full_decoder_metrics_are_not_conflated(self):
        events = [
            {"command": ["sbwt", "encode", "in", "out"], "stdout": '{"codec_ns":101}'},
            {"command": ["sbwt", "decode", "in", "out"], "stdout": '{"codec_ns":202}'},
            {"command": ["sbwt", "decode", "in", "out", "--index", "0"],
             "stdout": '{"codec_ns":303}'},
        ]
        self.assertEqual(intrinsic_ns(events, "encode"), 101)
        self.assertEqual(intrinsic_ns(events, "decode"), 202)


if __name__ == "__main__":
    unittest.main()
