#!/usr/bin/env python3
"""Byte-exact property probes including malformed markup and arbitrary bytes."""
import random
import subprocess
import tempfile
import unittest
from pathlib import Path

import attribute_register as local
import scope_register as scope


def roundtrip(data):
    a, _ = local.forward(data)
    b, _ = scope.forward(a)
    if local.inverse(scope.inverse(b)) != data:
        raise AssertionError(repr(data))


class RegisterProperties(unittest.TestCase):
    def test_nested_registers_and_literal_markers(self):
        data = (b'\x00\x01\x00\x02\xff<LexicalEntry id="omw-ja-\xe6\xbc\xa2-v">'
                b'<Lemma writtenForm="\xe6\xbc\xa2" />'
                b'<Sense id="omw-ja-\xe6\xbc\xa2-123-v" synset="omw-ja-123-v" />'
                b'</LexicalEntry><Synset id="omw-ja-123-v" '
                b'members="omw-ja-\xe6\xbc\xa2-123-v omw-ja-\xe5\xad\x97-123-v">'
                b'<Definition>\xff\x00a</Definition></Synset>')
        a, local_stats = local.forward(data)
        b, scope_stats = scope.forward(a)
        self.assertGreater(local_stats["records"], 0)
        self.assertGreater(scope_stats["slices"]+scope_stats["edges"], 0)
        self.assertEqual(local.inverse(scope.inverse(b)), data)

    def test_arbitrary_and_truncated_bytes(self):
        rng = random.Random(19027)
        seed = (b'<x id="abXYcd" values="ab1cd ab2cd" />'
                b'<parent id="pqHELLOxy"><child value="HELLO" /></parent>')
        for _ in range(1000):
            raw = rng.randbytes(rng.randrange(0,512))
            at = rng.randrange(len(raw)+1)
            candidate = raw[:at]+seed[:rng.randrange(len(seed)+1)]+raw[at:]
            roundtrip(candidate)
        for end in range(len(seed)+1):
            roundtrip(seed[:end])

    def test_native_decoder_matches_arbitrary_bytes(self):
        decoder = Path(__file__).resolve().parent / "register_decode"
        if not decoder.exists():
            self.skipTest("build register_decode.cpp first")
        rng = random.Random(25031)
        fixture = (b'<LexicalEntry id="prefix-WORD-tail"><Lemma value="WORD" />'
                   b'<Sense id="prefix-WORD-123-tail" /></LexicalEntry>'
                   b'<Synset id="prefix-123-tail" members="prefix-A-123-tail '
                   b'prefix-B-123-tail" />')
        with tempfile.TemporaryDirectory(prefix="wreg-test-") as temp:
            src, out = Path(temp)/"source", Path(temp)/"output"
            for _ in range(100):
                raw = rng.randbytes(rng.randrange(0,256)) + fixture + rng.randbytes(rng.randrange(0,256))
                local_source, _ = local.forward(raw)
                transformed, _ = scope.forward(local_source)
                src.write_bytes(transformed)
                subprocess.run([decoder,"3",src,out],check=True,capture_output=True)
                self.assertEqual(out.read_bytes(),raw)

    def test_one_byte_donor_index_boundary(self):
        for prefix_fields in (255,256,257):
            raw = (b'<x '+b' '.join([b'a=""']*prefix_fields+
                    [b'a="prefix-aaaa-suffix"',
                     b'b="prefix-X-suffix prefix-Y-suffix prefix-Z-suffix"'])+b' />')
            transformed, _ = local.forward(raw)
            self.assertEqual(local.inverse(transformed),raw)
            if prefix_fields == 255:
                self.assertIn(local.MARK,transformed)
            else:
                self.assertNotIn(local.MARK,transformed)


if __name__ == "__main__":
    unittest.main()
