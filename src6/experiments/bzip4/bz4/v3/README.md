# bz4 v3

A word-oriented block compressor in pure Zig 0.16 (std only). The idea and
the measured status are in [DESIGN.md](DESIGN.md); this file is the map.

```sh
zig build test                       # Debug; add -Doptimize=ReleaseSafe
zig build                            # zig-out/bin/lab (always ReleaseFast)
cd .. && v3/zig-out/bin/lab data/gcide.eval8.bin dumps/m_gcide.eval8.65536.b4sd --classes 64 --stats
```

`lab DATA DUMP` takes a parse (a B4SD v1/v2 dump: lexicon entries plus one
token stream per block; in a body the kid `0xffffff00 + n` is `CUT n`), lets
`plan.fit` choose the class count, encodes, decodes on 1 and N threads,
checks the bytes against DATA and prints real sizes, the bit budget by symbol
kind (`--stats`) and timings. Flags: `--classes N` (0: fit), `--direct N`,
`--leader N`, `--ring N`, `--log N`, `--slack F`, `--rawbytes`, `--hoist`,
`--merge N` (join blocks), `--workers N`, `--prune N`, `--bits FILE [--trace N]` (per-byte
real costs, and the costliest tokens).

`lab/w_parse DATA DUMP` makes a word-aligned parse (see its header).

| File | Lines | What |
|---|---:|---|
| `src/bits.zig` | 130 | forward LSB-first bit reader, writer, and the reversing stack tANS needs |
| `src/tans.zig` | 215 | normalisation, decode cells, encoder rows; rows of different sizes share one state |
| `src/binary.zig` | 160 | adaptive binary range coder, used only for the header |
| `src/model.zig` | 325 | buckets + rows (the transducer); one comptime walk reads and writes the header |
| `src/frame.zig` | 75 | block framing |
| `src/decode.zig` | 340 | deltas in order, then payload jobs on any number of threads |
| `src/encode.zig` | 455 | priced walks: places definitions at first use, chooses past or bucket, counts, normalises, writes streams backwards |
| `src/classes.zig` | 265 | exchange clustering of tokens into classes |
| `src/plan.zig` | 300 | baseline planner (byte aliases, buckets, rows), `fit`, `prune` |

The codec proper (`bits` … `encode`) is about 1,700 lines; it knows nothing
about words, classes or text. Everything that does is planner policy.

`lab/` holds the lanes' experiments and notebooks: `c_*.zig` (this round's
measurements: context lists, per-field accounting, a reference CM),
`w_parse.zig` (word-aligned learner), `LANE_O.md`, `LANE_F.md`, `LANE_L.md`
(earlier rounds), `LANE_W2.md` (the word-aligned learner lane).
