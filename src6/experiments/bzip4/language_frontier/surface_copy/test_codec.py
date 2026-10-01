import hashlib
import random
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).parent))
from codec import Source, encode, decode, HEAD
import codec


class CausalTests(unittest.TestCase):
    def test_roundtrip(self):
        rng = random.Random(97)
        for raw in (b'',b'x',bytes(range(256)),bytes(rng.randrange(256) for _ in range(1024)),b'abc\xff\xfe'*200,b'a'*1000):
            for policy in (0,1):
                f = encode(raw,block_bytes=333,policy=policy)
                self.assertEqual(decode(f),raw)
                self.assertEqual(encode(raw,block_bytes=333,policy=policy),f)

    def test_prefix_and_support(self):
        a,b = Source(),Source()
        raw = b'abracadabra\xff\xfe'*30
        for byte in raw:
            self.assertEqual(a.prediction(),b.prediction())
            self.assertTrue(all(x > 0 for x in a.prediction()))
            self.assertLessEqual(sum(a.prediction()),65536)
            self.assertLessEqual(len(a.active),a.k)
            self.assertEqual(a.escape+sum(w for w,age in a.active.values()),65536)
            self.assertTrue(all(j < len(a.history) for j in a.pending[0]))
            a.observe(byte)
            b.observe(byte)
        # Source is fed only prefix; two complete inputs with this prefix
        # cannot enter its state, even if their future continuations differ.
        self.assertEqual(bytes(a.history),raw)

    def test_encoder_future_invariance(self):
        traces = []
        class Recorded(Source):
            def prediction(self):
                counts = super().prediction()
                traces.append(tuple(counts))
                return counts
        original = codec.Source
        codec.Source = Recorded
        try:
            prefix = b'abcd\xfeabcd\xff' * 20
            encode(prefix+b'future one')
            first = traces[:len(prefix)]
            traces.clear()
            encode(prefix+b'a wholly different future')
            self.assertEqual(first,traces[:len(prefix)])
        finally:
            codec.Source = original

    def test_malformed(self):
        f = encode(b'banana\xff'*100)
        for n in range(len(f)):
            with self.assertRaises(ValueError): decode(f[:n])
        with self.assertRaises(ValueError): decode(f+b'x')
        with self.assertRaises(ValueError): decode(f,output_budget=1)
        with self.assertRaises(ValueError): decode(b'SCM2'+f[4:])
        for at in range(HEAD.size+12,len(f)):
            g = bytearray(f); g[at] ^= 1
            with self.assertRaises(ValueError): decode(g)
        for at in (0,4,5,6,7,HEAD.size,HEAD.size+4):
            g = bytearray(f); g[at] ^= 255
            with self.assertRaises(ValueError): decode(g)

    def test_fresh_process(self):
        raw = b'continuation \xff abcd '*50
        f = encode(raw)
        script = 'import sys; from codec import decode; sys.stdout.buffer.write(decode(sys.stdin.buffer.read()))'
        p = subprocess.run([sys.executable,'-c',script],input=f,capture_output=True,cwd=Path(__file__).parent,check=True)
        self.assertEqual(p.stdout,raw)


if __name__ == '__main__': unittest.main()
