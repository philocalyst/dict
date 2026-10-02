"""Exact context programs, page resets, and sealed envelope admission."""
import random
import struct
import unittest
import zlib

import context_tree
import geometry
import pages


class TreeTests(unittest.TestCase):
    def test_exact_surface_and_page_reset(self):
        rng = random.Random(10012026)
        fixtures = [b"", b"a b\nc", bytes(range(256)), b"\0a\xff b\n\xfe c\0",
                    "日本語 Arabic العربية Straße\n".encode()*40,
                    b"word word\nword word\n"*4096,
                    b"x"*65535+b"\na b\nc"]
        fixtures += [bytes(rng.choice(b" abcd\n\r\t\0\xff") for _ in range(5000)) for _ in range(12)]
        for raw in fixtures:
            with self.subTest(size=len(raw)):
                normalized, counts, checksums, model, flags, _, _ = pages.fit_residual(raw)
                frame = pages.container(raw,normalized,counts,checksums,model,flags,b"native-frame")
                info = pages.parse(frame)
                self.assertEqual(pages.restore(normalized,info),raw)
                for i,(count,size,checksum) in enumerate(info["index"]):
                    part = context_tree.realize(normalized[i*pages.PAGE:(i+1)*pages.PAGE],flags[i],model,count)
                    self.assertEqual(part,raw[i*pages.PAGE:(i+1)*pages.PAGE])
                    self.assertEqual(zlib.crc32(part),checksum)

    def test_model_limits_and_canonical_residual(self):
        tree = (1,0,(0,4096),(0,4096))
        self.assertEqual(context_tree.parse(context_tree.serialize(tree)),tree)
        for model in (b"",b"\0",b"\0\x01\x10",b"\6\0\0",context_tree.serialize(tree)+b"\0"):
            with self.assertRaises(ValueError):
                context_tree.parse(model)
        deep = (0,4096)
        for _ in range(17):
            deep = (1,0,deep,(0,4096))
        with self.assertRaises(ValueError):
            context_tree.parse(context_tree.serialize(deep))
        raw = b"word word\nword word\nword"
        normal, events = geometry.propose(raw,9)
        columns,labels = context_tree.observations(raw,9)
        flags = context_tree.pack(tree,columns,labels)
        self.assertEqual(context_tree.realize(normal,flags,context_tree.serialize(tree),len(events),9),raw)
        for damaged in (flags[:3],flags+b"\0",b"\xff"*4):
            with self.assertRaises(ValueError):
                context_tree.realize(normal,damaged,context_tree.serialize(tree),len(events),9)

    def test_resealed_index_and_header_reject(self):
        raw = b"word word\nword word\n"*50
        normal,counts,checksums,model,flags,_,_ = pages.fit_residual(raw)
        original = pages.container(raw,normal,counts,checksums,model,flags,b"native-frame")
        for at,value in ((24,2**31),(28,2**31),(32,1534),(48,len(raw)+1),(52,3)):
            frame = bytearray(original)
            struct.pack_into("<I",frame,at,value)
            # Reseal any currently available index/model span so header CRC alone
            # cannot be the reason an impossible declared length is rejected.
            fields = list(pages.HEADER.unpack_from(frame)); fields[-1]=0
            model_end = min(len(frame),48+12*fields[4]+fields[7])
            struct.pack_into("<I",frame,44,zlib.crc32(pages.HEADER.pack(*fields)+frame[48:model_end]))
            with self.assertRaises(ValueError):
                pages.parse(frame)


if __name__=="__main__":
    unittest.main()
