# Prepared WSB2 parameter allocation bound

The reusable reader now bounds decoded COPY parameter **bytes** by the root
count before allocating its rANS output. A COPY root emits two canonical
varints: a length of at most 4,096 bytes (two varint bytes) and a distance no
greater than the raw block length. The bound is therefore
`roots * (2 + varint_bytes(raw_block_bytes))`, including four-byte distances
at the admitted 4 MiB block limit. It preserves valid long-distance copies.

The previous `raw_block_bytes * 8` limit was unnecessarily loose for blocks
with very few roots. A payload mutation now exercises the new guard directly,
before entropy decoding. The four frozen encoder/decoder sources and their
frame bytes are unchanged; this change is confined to `sbwt_session.cpp`.

All seven prepared-reader tests pass in the optimized reader and under
AddressSanitizer plus UndefinedBehaviorSanitizer. The suite includes full and
every-restart parity, raw bytes and multilingual/invalid UTF-8 inputs, forced
COPY, unrelated-payload isolation, copied/moved model lifetime and owning
outputs, 512 mutations, truncations, resealed metadata errors, file limits,
quiet-clock gating, and the decoded-parameter allocation guard.

```sh
make -C src6/experiments/wordzip test-session
g++ -O1 -g -std=c++17 -fsanitize=address,undefined -fno-omit-frame-pointer -ffunction-sections -fdata-sections -Wl,--gc-sections src6/experiments/wordzip/sbwt_session.cpp -o /workspace/scratch/sbwt-session-asan
WORDZIP_SESSION_EXE=/workspace/scratch/sbwt-session-asan ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 python3 src6/experiments/wordzip/test_session.py
```

Validated SHA-256 identities on this workspace:

| Artifact | SHA-256 |
| --- | --- |
| Session source | `f330c68055784baaa6a080e78d83536d2de3ae5ba12c020c16ba79b9bb1583fb` |
| Focused test source | `2e4399069fb3d15b8e09e7910fc0ff59991a752bc1680885ea3a1b44de18ddf3` |
| Optimized session binary | `e5e2b1bdbb5fa5c3250441aa01a7753d74ed2245a472ae2636285f557ec8a9fc` |
| Sanitized binary | `1c026797aa9125a8a08697c0a7fea215ba90546ea3c7829f4def4ad99ff02ff6` |

The source file must remain immutable for the lifetime of the mapped reader.
Logical model and container capacities are separate from OS resident memory;
an inherited process RSS high-water floor is not a memory comparison.
