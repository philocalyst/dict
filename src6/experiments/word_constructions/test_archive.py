#!/usr/bin/env python3
"""Complete native WPG2 decode and page integrity across arbitrary boundaries."""
import subprocess
import tempfile
import unittest
from pathlib import Path

import compose_page
from template_split import getvar, varint

HERE = Path(__file__).resolve().parent


class ArchiveProperties(unittest.TestCase):
    def test_native_prepared_pages_and_header_guard(self):
        if not (HERE / "prepared_wpg").exists():
            self.skipTest("build prepared_wpg first")
        record = (b'<LexicalEntry id="prefix-\xe6\xbc\xa2-tail">'
                  b'<Lemma writtenForm="\xe6\xbc\xa2" />'
                  b'<Sense id="prefix-\xe6\xbc\xa2-123-tail" />'
                  b'</LexicalEntry><Synset id="prefix-123-tail" '
                  b'members="prefix-\xe6\xbc\xa2-123-tail prefix-\xe5\xad\x97-123-tail" />')
        raw = b'\xff\x00\x01' + record * 900 + b'\x80\x00tail'
        archive, _ = compose_page.encode(raw, modes=(3,), seed="bytes", hoist=True)
        self.assertEqual(compose_page.decode(archive,native_register=True),raw)
        with tempfile.TemporaryDirectory(prefix="wpg-test-") as temp:
            frame, output = Path(temp)/"frame",Path(temp)/"output"
            frame.write_bytes(archive)
            subprocess.run([HERE/"prepared_wpg","decode",frame,output],check=True,capture_output=True)
            self.assertEqual(output.read_bytes(),raw)
            for i in range((len(raw)+compose_page.PAGE-1)//compose_page.PAGE):
                subprocess.run([HERE/"prepared_wpg","query",frame,output,"--index",str(i)],
                               check=True,capture_output=True)
                self.assertEqual(output.read_bytes(),raw[i*compose_page.PAGE:(i+1)*compose_page.PAGE])
            corrupt = bytearray(archive)
            at = 5
            for _ in range(3):
                _, at = getvar(corrupt, at)
            _, at = getvar(corrupt, at)
            corrupt[at] ^= 1  # first source-page CRC, covered by header CRC
            frame.write_bytes(corrupt)
            result = subprocess.run([HERE/"prepared_wpg","query",frame,output,"--index","0"],
                                    capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("header CRC",result.stderr)

            final_crc_bad = bytearray(archive)
            final_crc_bad[-1] ^= 1
            frame.write_bytes(final_crc_bad)
            output.write_bytes(b"existing valid output")
            result = subprocess.run([HERE/"prepared_wpg","decode",frame,output],
                                    capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("global CRC",result.stderr)
            self.assertEqual(output.read_bytes(),b"existing valid output")
            self.assertEqual(list(Path(temp).glob("output.tmp.*")),[])

            # The legacy v4 decoder allocates from this claimed delta-output
            # length before it validates decoded bytes. Reseal a valid WPG2
            # envelope around an excessive claim: our private preflight must
            # reject it before the model is prepared.
            at = 5
            for _ in range(3):
                _, at = getvar(archive, at)
            count = (len(raw)+compose_page.PAGE-1)//compose_page.PAGE
            for _ in range(count):
                _, at = getvar(archive, at)
                at += 4
            at += 4  # header CRC
            frame_len, payload_at = getvar(archive, at)
            payload = archive[payload_at:payload_at+frame_len]
            self.assertEqual(payload[:4],b"bz4\x03")
            model_len, block_at = getvar(payload,4)
            block_at += model_len
            self.assertEqual(payload[block_at] & 1,1)
            _, delta_at = getvar(payload,block_at+1)  # defs
            _, delta_end = getvar(payload,delta_at)
            changed = payload[:delta_at] + varint(64*1024*1024+1) + payload[delta_end:]
            resealed = archive[:at] + varint(len(changed)) + changed + archive[payload_at+frame_len:]
            frame.write_bytes(resealed)
            result = subprocess.run([HERE/"prepared_wpg","query",frame,output,"--index","0"],
                                    capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("native v4 model preparation failed",result.stderr)


if __name__ == "__main__":
    unittest.main()
