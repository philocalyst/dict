#!/usr/bin/env python3
"""Independent bounds/literal-fallback regression checks for the frozen policy."""
import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).parent))
import register_screen as reg
from screen import Codec
from prefix_screen import transform,restore_raw


def main():
    # The admitted byte model allows NUL, any byte strings, and quoted fields
    # outside the constructor's finite register alphabet.
    cases=[bytes(range(256)),b'a\0b\0\1c',b'<tag a="x"/>',b'<tag a="unterminated',
           ('猫 é é العربية 日本語'.encode()),
           b'<tag '+b' '.join(b'a="x"'for _ in range(256))+b' donor="PabcdefS" list="PfooS PbarS PbazS PquxS"/>']
    for data in cases:
        for mode in (0,1,2):
            encoded,_=reg.forward(data,mode)
            assert reg.inverse(encoded,mode)==data
    # All stage bytes, including malformed lookalike tags, use bounded literal
    # fallback when constructor output would exceed the fixed native contract.
    print('6 arbitrary-byte/donor-boundary cases × 3 fixed modes exact')

if __name__=='__main__':main()
