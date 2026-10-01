import unittest
import adapter

class GrammarTests(unittest.TestCase):
    def test_exact_graphs(self):
        for raw in (b'',bytes(range(256)),b'\xff\xfe bad\x00 bytes repeated repeated',
                    '猫と猫\nkäyttö käyttö\nİstanbul\ne\u0301\n'.encode()):
            for config in adapter.CONFIGS:
                bodies,blocks=adapter.grammar(raw,17,config)
                values=[]
                for body in bodies:
                    self.assertGreaterEqual(len(body),2)
                    self.assertTrue(all(t<256+len(values) for t in body))
                    values.append(b''.join(bytes((t,)) if t<256 else values[t-256] for t in body))
                rebuilt=b''.join(bytes((t,)) if t<256 else values[t-256] for block in blocks for t in block)
                self.assertEqual(rebuilt,raw)
    def test_public_native_roundtrip(self):
        raw=bytes(range(256))*2+'日本語\nTürkçe\nsuomi\n'.encode()
        frame=adapter.encode(raw,block_bytes=128,config=0,native_control=False)
        self.assertEqual(adapter.decode(frame),raw)
    def test_options(self):
        for options in ({'config':-1},{'config':24},{'misspelled':True},{'native_control':1}):
            with self.assertRaises(ValueError): adapter.encode(b'x',block_bytes=16,**options)

if __name__=='__main__': unittest.main()
