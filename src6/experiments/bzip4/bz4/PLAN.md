# bz4 lab — a real bzip4, pure Zig, no dependencies

Lead: Claude (Fable). Workers: Sonnet agents, one lane each. This file is the
shared contract. Read it fully before touching anything.

## Goal

A general-purpose block compressor that **beats bzip3 on size and on decode
speed on every cell**, with a small portable decoder, and that is *more*
composable than bzip3: any block size, independently decodable blocks, an
optional shared model, parallel decode. No per-corpus switches, no text-only
tricks, no external code. Everything is Zig 0.16, std only.

## The thesis (why the previous program stalled, and the way out)

The frozen Python frontier (`../frontier_python/RESULTS.md`) capped the phrase
grammar at 8,192 rules and then spent its effort on BWT+MTF+Huffman over the
roots. The lead's probe (`gprobe.zig`) shows the cap was the limiter. With
independent small blocks, *in-block adaptive statistics are nearly worthless*
(a 16 KiB block holds ~1,000 roots, ~580 of them distinct); redundancy across
blocks can only be captured by the shared model. So take the general idea to
its extreme: **grow the grammar until no pair repeats**, and make the *stored
grammar* — now the dominant cost — extremely cheap to code.

Idealised numbers from `gprobe` (static order-0 root cost, 16 KiB blocks,
min pair frequency 2), versus complete bzip3 frames:

| 8 MiB lane | rules | roots | bytes/root | roots H0 (B) | bzip3 16K (B) | bzip3 64K (B) |
|---|---:|---:|---:|---:|---:|---:|
| FreeDict | 70,003 | 281,885 | 29.8 | 518,566 | 1,189,002 | 899,408 |
| GCIDE | 125,124 | 656,587 | 12.8 | 1,273,931 | 2,362,319 | 1,905,560 |
| OMW | 107,117 | 111,407 | 75.3 | 196,708 | 1,124,142 | 674,384 |

| 1 MiB untouched lane (64K) | rules | roots | roots H0 (B) | bzip3 64K (B) |
|---|---:|---:|---:|---:|
| FreeDict | 12,546 | 46,544 | 72,881 | 115,160 |
| GCIDE | 23,802 | 98,270 | 165,123 | 235,103 |
| OMW | 18,021 | 23,212 | 35,274 | 95,276 |

Whatever the grammar costs on top of "roots H0" decides the game. A naive
2-ids-per-rule code costs 20–30 bits/rule and throws most of the win away.
At ~12–14 bits/rule every lane above beats bzip3 by 12–45 %, the result is
almost independent of block size, and decoding is one table-driven symbol
decode plus one short memcpy per ~10–75 output bytes (no inverse BWT, no
MTF, no per-byte modelling) — potentially 10–50x faster than bzip3.

After a full grammar every adjacent root pair is unique by construction, so
exact-context modelling of roots (BWT, order-k) has nothing left to find.
What is left is *soft* structure (byte-level junction statistics, symbol
classes) and, for data where the grammar is weak (binaries), the partial-
grammar + block-sort/CM regime. Those are lanes too.

## Candidate architecture "GX" (to be confirmed or refuted by measurement)

```
frame  := header, MODEL segment, block directory, BLOCK payloads
MODEL  := the pair grammar as a DEF-tree stream + per-symbol global root
          counts, all coded with the shared adaptive range coder (rc.zig)
BLOCK  := independently decodable root-symbol stream, coded with a static
          code derived from the model's global counts (+ optional context)
decode := symbol -> (ptr,len) expansion table -> memcpy into final output
```

DEF-tree stream (first-occurrence coding): walk rules in an encoder-chosen
order; `emit(s)`: terminal or already-defined symbol -> REF(s); otherwise
`DEF emit(left) emit(right)` and the rule gets the next id (post-order).
A child that is defined in place costs a flag, not an id, so only ~R+T of
the 2R child slots need an id (T = rules that are nobody's child). The
order of top-level emission is free: sort it so REFs cluster (recency).

Standalone "big block" compression is the same format with one block (or a
few), so there is a single codec, not a bag of modes.

## Lanes (each agent owns only its files; never edit another lane's files)

| Lane | Owner files | Question |
|---|---|---|
| D baselines | `bz3base.zig`, `BASELINES.md`, `baselines.tsv` | bzip3 size + decode ms for every file x block size |
| B model | `modelcodec.zig`, `modellab.zig`, `LANE_B.md` | How few bits/rule can a real, decodable grammar code reach? |
| S static roots | `rootstatic.zig`, `rootlab_static.zig`, `LANE_S.md` | Static root codes from counts; real decode speed incl. expansion |
| X context roots | `rootctx.zig`, `rootlab_ctx.zig`, `LANE_X.md` | Soft-context gains over static H0 (first-byte factorisation etc.) |
| W block-sort | `symbwt.zig`, `symcm.zig`, `bwtlab.zig`, `LANE_W.md` | Partial grammar + symbol BWT + adaptive CM; big blocks; binaries |
| A grammar | `grammar2.zig`, `gramlab.zig`, `LANE_A.md` | MDL stopping/pruning, parse quality, builder speed |

Shared, read-only for workers: `PLAN.md`, `rc.zig`, `gprobe.zig`, `data/`.
If you need a change in a shared file, copy the code into your own file and
say so in your report.

## Data (`data/`, see `data/MANIFEST.tsv`; never modify)

`{freedict,gcide,omw}.eval8.bin` (8 MiB, the frozen `[1,9) MiB` lane),
`{freedict,gcide,omw}.untouched.bin` (1 MiB, the frozen `[9,10) MiB` lane),
`{freedict,gcide,omw}.train.bin`, and generality samples
`json.eval8.bin`, `macho.eval8.bin` (arm64 machine code), `zigsrc.eval8.bin`.
The three dictionary corpora are the acceptance gate; the generality files
keep us honest about "general-purpose".

## Tools

```sh
cd src6/experiments/bzip4/bz4
zig build-exe -O ReleaseFast gprobe.zig -femit-bin=bin/gprobe   # already built
# gprobe FILE BLOCK_BYTES MAX_RULES MIN_FREQ ALPHA_PERCENT [DUMP_PATH]
bin/gprobe data/gcide.eval8.bin 16384 1000000 2 50 dumps/gcide.eval8.16k.full.b4sd
zig test -O ReleaseSafe rc.zig
```

`gprobe` dump format (little-endian u32 words): `"B4SD"`, version=1,
rule_count, block_count, block_bytes, raw_len; then rule_count x (left,
right) with ids 0..255 = bytes and 256+i = rule i (children always have
smaller ids); then per block: root_count, root_count x symbol. Pairs never
span a block barrier. Put dumps under `dumps/` (create it; it is scratch).
`MAX_RULES=1000000 MIN_FREQ=2 ALPHA=50` is the "full" grammar; smaller
MAX_RULES gives the nested partial grammars.

Zig 0.16 idioms that compile here (copy them): `pub fn main(init:
std.process.Init) !void`, `init.gpa`, `init.io`,
`std.process.Args.Iterator.init(init.minimal.args)`,
`std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 30))`,
`std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = p, .data = bytes })`,
`std.Io.Clock.awake.now(init.io).nanoseconds` (i96), `std.ArrayList(T) =
.empty` with the allocator passed to every call, `std.debug.print`. See
`gprobe.zig` and `../runner.zig` for working examples. Build single files
with `zig build-exe -O ReleaseFast x.zig -femit-bin=bin/x`; keep every
source file in this flat directory (imports are same-directory only).

## Rules of evidence

- Every size you report must come from a real encoder whose output a real
  decoder turned back into the exact input (or exact dump) in the same run.
  Idealised entropy estimates are allowed only when labelled `est`.
- Charge everything: headers, counts, tables, per-block lengths.
- No per-corpus parameters. One setting for all files, or a rule the
  encoder derives from the input itself and the decoder never needs.
- Several agents share this machine, so timings are indicative; report
  ns/root or MB/s with the caveat. The lead runs the final serial timings.
- Keep a terse lab notebook in your `LANE_*.md`: what you tried, the table
  of results, what failed and why. Negative results are valuable.
- Do not touch git, do not edit files outside this directory, do not add
  dependencies or call other compressors (Lane D alone links the vendored
  bzip3 as the control).

---

# Round 3 — structural rethink: words, classes, one tower (lead, 2026-09-20)

Rounds 1–2 settled the facts (notebooks `LANE_*.md`): with small independent
blocks only *shared static knowledge* matters and a full grammar + static
code beats bzip3 by 16–60 %; with big blocks *statistical* modelling wins and
a lex-ordered symbol BWT + tree CM reaches parity with 3–20x fewer decisions;
the stored grammar costs 16–20 bits/rule (20–50 % of a small-block archive);
soft junction bytes buy only ~3 %; rules used twice do not pay.

The weakness underneath all of it: Re-Pair merges *frequent byte pairs*, so
the alphabet is full of fragments that straddle natural units ("e th"),
57 % of OMW's rules are structural filler, random hex digits get thousands
of junk rules, and the root stream has no learnable syntax. The rethink:

1. **Tokens are units of uncertainty ("words"), not frequent pairs.** A
   junction is glued only where the data itself makes it predictable; a
   token ends where the block sorter / predictor would be uncertain. Same
   operator at every level (bytes -> words -> phrases): a *tower of
   lexicons*, no text-specific rule anywhere. (Lane W3a tests the gated
   accretion form for the BWT regime; Lane M the compositional MDL form.)
2. **The lexicon is just more text.** Entries are n-ary, spelled in other
   entries, parsed by the same optimal parser and coded by the same static
   code as the corpus (de Marcken-style compositional MDL). Growth,
   re-parse and deletion iterate to convergence; filler never exists.
3. **The data's own part-of-speech tags.** Induce C classes over tokens and
   code `P(x | prev) = T[ctx(prev)][tgt(x)] * g[x]/G[tgt(x)]` with static
   shared tables: a learned finite-state syntax of the data format that
   costs a few KB, needs no in-block learning (so it works at 16 KiB), and
   decodes with two table lookups per token. Classes are *inherited* down
   the lexicon DAG (target class from the leftmost constituent, context
   class from the rightmost) and stored only as overrides where that pays,
   which generalises Lane X's junction-byte model from bytes to learned
   categories. Expected to fix JSON (hex/number/key "modes") for free.
4. **Sorted lexicon = alphabet order = coding tree.** Lex order of
   expansions is the BWT alphabet (zero bytes), reverse-lex order is the
   statistics-sharing tree of the adaptive coder.

## B4SD version 2 (n-ary rules)

Header word 2 (`version`) = 2. Rule section: per rule `arity` (u32, >= 2)
followed by `arity` child ids. Ids 0..255 are bytes, 256+i is rule i;
children may now reference ANY other rule (forward references allowed) but
the reference graph must be acyclic. Everything else as version 1. Readers
written in round 3 must accept both versions.

## Round 3 lanes

| Lane | Owner files | Question |
|---|---|---|
| K classes | `k_*.zig`, `LANE_K.md` | What does an induced class-transition static model buy, all tables charged? |
| M lexicon | `m_*.zig`, `LANE_M.md` | Does an iterated compositional MDL lexicon (n-ary, word-like) beat Re-Pair+MDL in real total bytes? |
| W3a / W3b | `w3a_*`, `w3b_*` | adaptive path: gated grammar + F contexts (size); fast TreeCM (speed) |
| V | `bz4*.zig` | v1 integration of the round-1 static path (the baseline to beat) |
