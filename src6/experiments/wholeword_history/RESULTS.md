# Fixed whole-block Lane M development result

The preregistered comparison in [PROTOCOL.md](PROTOCOL.md) completed on the
six frozen at-most-1 MiB development book sources. All 12 candidate frames
passed an independent fresh-process native v4 full decode and exact
byte-for-byte oracle comparison. Each candidate is a complete, standalone
frame. Bzip3 controls are actual complete native 32 MiB-block archives of
the same input bytes, also exact-decoded by the frozen controls harness.

| Development book | Input B | Whole bzip3 B | Lane M 64 KiB B | Lane M one payload B | One-payload change B | One-payload vs bzip3 |
|---|---:|---:|---:|---:|---:|---:|
| Pride and Prejudice (en) | 705,012 | 161,119 | 168,943 | 168,822 | −121 | +4.78% |
| War and Peace prefix (en) | 1,048,576 | 247,364 | 259,815 | 259,704 | −111 | +4.99% |
| Don Quijote prefix (es) | 1,048,576 | 252,940 | 272,932 | 272,699 | −233 | +7.81% |
| Madame Bovary (fr) | 716,472 | 179,597 | 194,483 | 194,598 | +115 | +8.35% |
| Die Verwandlung (de) | 126,200 | 35,251 | 38,405 | 38,317 | −88 | +8.70% |
| Kokoro (ja) | 486,098 | 97,505 | 101,841 | 101,445 | −396 | +4.04% |
| **Sum** | **4,130,934** | **973,776** | **1,036,419** | **1,035,585** | **−834** | **+6.35%** |

The 64 KiB runs produced 11, 16, 16, 11, 2 and 8 payload blocks;
the one-block runs produced exactly one each. The fitted class search was
unchanged, although its selected class can change with the learned parse.
All native model, definition, payload and framing bytes are included in the
frame sizes. The private fork's real Austen 64 KiB frame was byte-identical
to a fresh frozen `m_reference` run with the same complete policy and input.
The highest observed encoder live requested allocation was
579,054,582 bytes; the highest private reader live requested allocation was
7,546,866 bytes, both below their 4 GiB caps. These are allocator accounting
figures, not process RSS. Concurrent development clocks are diagnostic only.

The result rejects block-boundary removal as a material route to beating
whole-file bzip3 on these books. It does not test a longer native token ring,
conditional phrase history, or an adaptive word model. The present native
ring still reaches only about 1,023 recent tokens; the grammar and fitted
automaton were already shared across 64 KiB blocks. We stopped before
full-book scaling because the best saving here is under 0.4% on any book
while every candidate remains at least 4.0% larger than whole-file bzip3.

## Reproduction and provenance

```
cd src6/experiments/wholeword_history
make ZIG=/home/agent/.local/bin/zig
python3 test_whole.py
python3 screen.py --output /workspace/scratch/wholeword-history-dev6-r0
```

The small tests include zero and invalid UTF-8 bytes, all three reader
modes (`inspect`, `verify`, `decode`), overdeclared raw length, trailing
frame bytes, wrong oracle, and a full-policy 64 KiB byte-identical comparison
against the frozen `m_reference` executable.

The source and binary hashes are in
[source-manifest.json](evidence/source-manifest.json); exact rows and frame
SHA256s are in [results.jsonl](evidence/results.jsonl), the run's encoder
pins in [pins.json](evidence/pins.json), full-policy frozen-reference parity
in [fidelity.json](evidence/fidelity.json), and the small test result in
[native-tests.json](evidence/native-tests.json). The complete frame and
private graph artifacts are under
`/workspace/scratch/wholeword-history-dev6-r0/`. The graph is diagnostic,
not a decoder dependency or part of the delivered compressed frame.
