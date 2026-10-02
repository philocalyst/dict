#!/usr/bin/env python3
"""Small exact-byte and malformed-frame tests for the transform-only LXB1."""
import os
import pathlib
import random
import subprocess
import tempfile

EXE = pathlib.Path(__file__).with_name("lexical_bwt")


def run(*args, success=True):
    result = subprocess.run([str(EXE), *map(str, args)], capture_output=True)
    assert (result.returncode == 0) == success, (args, result.stderr)
    return result


def test():
    rng = random.Random(9147)
    cases = [
        b"", b"a", b"banana banana banana", bytes(range(256)),
        b"\x00\xff\xc0\xaf\xf0\x80\x80\x80\r\n" * 5,
        "كَتَبَ كَتَبْتُ; evlerimizden\n東京の辞書。中文詞語\n".encode() * 4,
        b"one two\nthree four\n" * 20,
        bytes(rng.randrange(256) for _ in range(512)),
        b"a" * 300 + b"\n" + b"abababab" * 80,
    ]
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        source, frame, restored = (root / name for name in ("input", "frame", "restored"))
        count = 0
        for data in cases:
            source.write_bytes(data)
            for kind in ("byte", "word", "subword", "word-all", "word-sep"):
                for order in ("lex", "frequency", "first"):
                    for direction in ("forward", "reverse", "lines"):
                        for pipe in ("direct", "bwt"):
                            for backend in ("zstd", "bzip3"):
                                run("encode", source, frame, "--kind", kind, "--order", order,
                                    "--direction", direction, "--pipe", pipe,
                                    "--backend", backend, "--cap", 8, "--level", 1)
                                run("decode", frame, restored)
                                assert restored.read_bytes() == data, (kind, order, direction, pipe, backend)
                                count += 1
        source.write_bytes(b"abc abc abc\n" * 20)
        run("encode", source, frame, "--kind", "word", "--cap", 8, "--level", 1)
        good = frame.read_bytes()
        for bad in (good[:-1], good + b"x", good[:4] + b"\x00" + good[5:], good[:-1] + bytes([good[-1] ^ 1])):
            frame.write_bytes(bad)
            run("decode", frame, restored, success=False)
        frame.write_bytes(good)
        run("decode", frame, restored)
        assert restored.read_bytes() == source.read_bytes()
    print(f"{count} exact roundtrips and four malformed frames passed")


if __name__ == "__main__":
    test()
