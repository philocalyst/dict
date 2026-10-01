# Lane V — integration ("bz4 v1"), lab notebook

Owner files: `bz4.zig` (frame format, `compress`/`Frame.open`/`decodeBlock`/
`decodeAll`, closed-loop MDL driver, `zig test` suite), `bz4_grammar.zig`
(Lane A's builder + the new calibrated-cost MDL deletion), `bz4_model.zig`
(Lane B's model codec, trimmed to `v2y_leftchild_order`/`v2x_gctx_on_freq`),
`bz4_root.zig` (Lane S's canonical Huffman + a descending-g expansion
arena), `bz4cli.zig`, `bz4bench.zig`, `bz4_ablation.zig` (isolates the
arena-layout change), `results_v1.tsv`, this file. Never touched git or any
file outside this directory; read grammar2.zig/modelcodec.zig/rootstatic.zig
but copied (and, where noted, fixed/changed) their logic into `bz4_*.zig`
per PLAN.md's rule for another lane's owned files.

## What was integrated, and one real bug found along the way

`bz4_grammar.zig` is grammar2.zig's `build()` (A3 saving-priority),
`mdlDeleteFlat` (A2, kept verbatim as a comparison candidate) and
`optimalReparse` (A4), plus a new `mdlDeleteCalibrated` (below).
`bz4_model.zig` is modelcodec.zig's DEF-tree codec, trimmed to the two
named winners, extended to also return the encoder's old-id -> new-id
`remap` (see "what failed" below). `bz4_root.zig` is rootstatic.zig's
canonical length-limited Huffman construction and bit I/O, with the range
coder / old frame format dropped (Lane S's own recommendation was
Huffman outright) and the expansion arena rebuilt in descending-g order.

**Bug found in grammar2.zig** (reported to Lane A, not fixed there since
this lane may only edit `bz4_*.zig`): `build()` returns `.seq = seq[0..live]`,
a re-sliced VIEW of the original `n`-sized allocation. Freeing that view
with a real allocator panics with "Invalid free" (`std.heap.DebugAllocator`
computes its size-class bucket from the *passed-in* slice length, and a
shorter length than the original allocation resolves to the wrong bucket).
Lane A's own `gramlab.zig` never hit this because it always builds inside
an `ArenaAllocator`, whose `free()` is a no-op. Reproduced directly against
the unmodified `grammar2.zig` with a tiny input; fixed in `bz4_grammar.zig`
by using `alloc.realloc(seq, live)` instead of the raw reslice.

## FORMAT actually shipped

32-byte header (magic `"BZ4\x01"`, flags, reserved, `block_bytes:u32`,
`raw_len:u64`, `block_count:u32`, `model_len:u32`, `crc32:u32` over
header[0..28]++model++directory) + the MODEL segment (bz4_model.zig's
range-coded bytes, opaque) + an 8-byte-per-block DIRECTORY (`end_offset:u32`
with the top bit meaning "stored raw", `crc32:u32` of the decoded block) +
concatenated BLOCK payloads (canonical Huffman, byte-padded, or raw bytes
when Huffman would not have shrunk the block). Root length per block is
never stored: `decodeBlock` decodes symbols until the block's raw length is
produced exactly, and rejects overrun/underrun/CRC mismatch/out-of-range
symbol ids as errors, never panics.

## The one non-obvious integration bug: two id spaces

The model codec **renumbers rules** during its own DEF-tree walk (a
deliberate design choice per LANE_B.md: "no permutation is ever
transmitted", the decoder replays the same walk to discover it). That means
`gm.seq`/`gm.rules` (the grammar builder's own numbering) and
`decoded.rules`/`decoded.g` (what `Frame.open` reconstructs) are **two
different, non-trivially-related numberings of the same symbols** — ties in
the canonical Huffman code assignment break on real-id order, and the two
numberings order same-weight symbols differently. Encoding the block/root
stream with the grammar's own ids produced a codec that looked correct in
every unit test until measured against real multi-thousand-rule grammars,
where it reliably failed with `BlockOverrun`/`BlockCrcMismatch` (caught
immediately by this lane's `zig test` suite on real text, not silently).
Fixed by having `encodeModel` also return the `old_id -> new_id` map it
already computes internally (`w.newid`, copied out of its per-call arena),
and remapping every root token and every `g[]` count through it before
building the Huffman table and encoding blocks — i.e. the encoder now
builds its Huffman table over exactly the id space the decoder will
reconstruct, matching the architecture PLAN.md's own "GX" sketch implies
("BLOCK := ... coded with a static code derived from the model's global
counts") but that the three lanes' separate deliverables never had to
reconcile with each other.

## Closed-loop MDL: what it bought vs. flat pruning and vs. no pruning

Per the brief: build with A3, prune with a per-rule cost that mirrors the
REAL model codec (`cost(rule) = flag_bits + gcount_bits(g[rule]) + sum over
children of {byte: byte_bits; rule with <=1 parent and g=0: 0 (defined in
place, charged on its own index); other rule: ref_log_coeff*log2(live
rules)}`), encode the real model, recalibrate `{flag_bits, byte_bits,
ref_log_coeff, g_scale, g_zero_bits}` by the real/approx bit ratio, repeat.
Every candidate (unpruned A3, A3+flat-a2, A3+closed-loop at each iteration,
and effort=1's +A4) is **really encoded end to end** (real model bytes,
real Huffman table, real block payloads) and only the smallest real frame
is ever kept — the closed loop can only match or beat the simpler
baselines, never regress below them, by construction.

Real measured total frame bytes (block=65536, effort=0), from `bz4cli -v`:

| file | a3 unpruned | a3+flat_a2 (RULE_BITS=13) | a3+closed-loop MDL (winner) | vs unpruned | vs flat_a2 |
|---|---:|---:|---:|---:|---:|
| freedict.eval8 | 684,187 (69,452 rules) | 677,656 (60,024) | **675,787** (50,590) | -1.23% | -0.28% |
| gcide.eval8 | 1,580,325 (121,773) | 1,565,839 (101,409) | **1,561,346** (79,613) | -1.20% | -0.29% |
| omw.eval8 | 398,867 (104,753) | 397,577 (103,525) | **396,852** (101,187) | -0.51% | -0.18% |
| json.eval8 | 1,178,808 (60,715) | 1,114,355 (15,864) | **1,114,195** (13,043) | -5.48% | -0.014% |
| macho.eval8 | 3,000,072 (345,915) | 2,944,241 (301,438) | **2,934,113** (278,355) | -2.20% | -0.34% |
| zigsrc.eval8 | 1,328,732 (209,322) | 1,320,134 (200,653) | **1,316,201** (190,885) | -0.94% | -0.30% |

Closed-loop MDL **always won or tied** (never lost to flat-a2, matching the
real-measurement-gated selection above), by 0.014%-0.34% beyond flat-a2's
own real gain, on top of flat-a2's own 0.3%-5.5% beyond no pruning at all.
The gain is consistently real but modest on top of flat-a2 for most files
(flat-a2 already captures most of the easy win) — **except gcide and
freedict, the dictionary corpora with the most g=2 top-level rules the
task's own hint calls out**, where closed-loop deletes ~1.6-1.9x MORE rules
than flat-a2 (79,613 vs 101,409 for gcide; 50,590 vs 60,024 for freedict)
while landing at a SMALLER real size — direct evidence that a flat 13-bit
charge under-prices real ~16-20+ bit rules and the calibrated cost model
corrects it, exactly as the brief predicted. `json.eval8` shows the other
side of A2's own finding (LANE_A.md): flat-a2 already recovers almost all
of the available gain there (a huge one-shot cut from 60,715 to 15,864
rules), leaving little for calibration to add. Every intermediate/rejected
candidate and iteration count is in `bz4cli`'s `-v` diagnostic output (not
wired into `bz4bench`'s TSV, which only reports the winner, per PLAN's
required column list).

Recalibration converged in 1 round for every file tried (a 2nd round found
0 further profitable deletions and the loop exited early); `effort=1`'s
extra A4 DP re-parse was verified to roundtrip correctly (see tests) but
was not included in the main sweep (default `effort=0`, matching the
brief's "0 = a3+MDL only" default) since Lane A's own numbers put A4 at
2-12 **seconds** per 8 MiB file vs 20-120 **milliseconds** for MDL alone.

## Startup speed: before/after

**Ablation, holding the grammar fixed** (`bz4_ablation.zig`, unpruned A3
grammar so rule count matches what Lane S measured, block=65536): building
the descending-g arena instead of ascending-id is a **mixed result**, not a
clean win — it consistently shrinks the arena (alphabet-only symbols, not
every structural rule: 1.94MB vs 2.38MB freedict, 1.80MB vs 1.96MB gcide,
2.80MB vs 5.67MB macho) and consistently costs ~2x longer to *build* (a
few ms either way: 5.5 vs 3.5ms freedict, 7.5 vs 2.9ms gcide, 16.9 vs
8.3ms macho — the two-pass construction, real cost, honestly a wash at
this scale), but its effect on **decode throughput** ranged from +40%
(freedict: 299 vs 214 MB/s) to -5% (gcide: 130.6 vs 136.6 MB/s) depending
on the corpus's own access pattern — the cache-locality win the task's
hint predicted is real on some corpora and a genuine (small) regression on
others. Kept it anyway: it never regressed by more than ~5%, it shrinks
memory unconditionally, and combined with MDL pruning's own much larger
rule-count cut it is a net win end to end (below).

**End to end** (`Frame.open`, includes decoding the real compressed model —
a real cost Lane S's own isolated arena+table figure never had to pay —
plus the smaller, MDL-pruned rule count): gcide.eval8 @ 65536 startup is
**49.3ms** total (model decode + arena + Huffman) vs Lane S's own
**47.3ms** for arena+Huffman ALONE on the unpruned 125,124-rule grammar;
freedict.eval8 @ 65536 is **30.1ms** vs Lane S's 16.3ms (worse here: the
model-decode cost this lane's number includes dominates over the smaller
rule count's savings on this file). Net: comparable to, not uniformly
better than, Lane S's own isolated number, because it is honestly doing
strictly more work (a real model decode Lane S's number never counted) —
the MDL-driven rule-count cut and the arena change roughly cancel that
extra cost out rather than beating it outright. Full per-file startup_ms is
in `results_v1.tsv`.

## Results (results_v1.tsv, effort=0, block sizes 16384/65536/262144 for
## eval8 files, 16384/65536 for untouched files; REPEATS=5)

| file | block | bz4 total | bzip3 total | vs bzip3 | bz4 MB/s | bzip3 MB/s | decode speedup | startup ms | single-block us |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 16384 | 681,709 | 1,189,002 | -42.67% | 221.7 | 41.2 | 5.38x | 28.68 | 45.34 |
| freedict.eval8 | 65536 | 675,787 | 899,408 | -24.86% | 200.3 | 50.2 | 3.99x | 30.09 | 180.05 |
| freedict.eval8 | 262144 | 674,558 | 743,607 | -9.29% | 217.2 | 54.0 | 4.03x | 28.73 | 742.70 |
| gcide.eval8 | 16384 | 1,566,358 | 2,362,319 | -33.69% | 113.0 | 24.5 | 4.62x | 47.34 | 57.91 |
| gcide.eval8 | 65536 | 1,561,346 | 1,905,560 | -18.06% | 123.0 | 27.3 | 4.50x | 49.29 | 235.37 |
| gcide.eval8 | 262144 | 1,560,078 | 1,615,933 | -3.46% | 130.7 | 28.8 | 4.55x | 47.25 | 1332.50 |
| omw.eval8 | 16384 | 407,330 | 1,124,142 | -63.77% | 305.8 | 34.7 | 8.81x | 45.19 | 41.67 |
| omw.eval8 | 65536 | 396,852 | 674,384 | -41.15% | 312.9 | 46.3 | 6.75x | 41.43 | 164.45 |
| omw.eval8 | 262144 | 396,872 | 496,068 | -20.00% | 291.9 | 57.3 | 5.10x | 45.91 | 666.19 |
| json.eval8 | 16384 | 1,119,517 | 1,314,524 | -14.83% | 218.1 | 33.7 | 6.48x | 8.70 | 49.39 |
| json.eval8 | 65536 | 1,114,195 | 1,028,983 | **+8.28%** | 202.2 | 38.0 | 5.32x | 8.85 | 202.62 |
| json.eval8 | 262144 | 1,112,093 | 931,486 | **+19.39%** | 210.3 | 39.0 | 5.39x | 8.55 | 894.66 |
| macho.eval8 | 16384 | 2,940,018 | 3,857,767 | -23.79% | 95.3 | 16.6 | 5.73x | 166.65 | 69.47 |
| macho.eval8 | 65536 | 2,934,113 | 3,259,348 | -9.98% | 101.4 | 18.7 | 5.42x | 169.53 | 282.11 |
| macho.eval8 | 262144 | 2,932,598 | 2,913,217 | **+0.67%** | 82.6 | 20.6 | 4.01x | 185.23 | 1581.33 |
| zigsrc.eval8 | 16384 | 1,322,796 | 1,837,421 | -28.01% | 173.3 | 25.3 | 6.84x | 114.95 | 51.75 |
| zigsrc.eval8 | 65536 | 1,316,201 | 1,454,997 | -9.54% | 171.8 | 30.1 | 5.70x | 103.87 | 214.78 |
| zigsrc.eval8 | 262144 | 1,317,345 | 1,225,909 | **+7.46%** | 160.7 | 33.3 | 4.83x | 111.26 | 1190.54 |
| freedict.untouched | 16384 | 100,145 | 150,446 | -33.43% | 174.9 | 40.0 | 4.38x | 6.95 | 49.19 |
| freedict.untouched | 65536 | 99,447 | 115,160 | -13.64% | 184.8 | 48.5 | 3.81x | 7.31 | 195.00 |
| gcide.untouched | 16384 | 220,697 | 292,647 | -24.59% | 115.3 | 24.5 | 4.71x | 12.18 | 58.98 |
| gcide.untouched | 65536 | 220,125 | 235,103 | -6.37% | 54.2\* | 27.2 | 2.00x\* | 23.25 | 250.38 |
| omw.untouched | 16384 | 71,980 | 155,112 | -53.59% | 241.9 | 31.0 | 7.80x | 13.29 | 44.85 |
| omw.untouched | 65536 | 70,675 | 95,276 | -25.82% | 217.6 | 43.5 | 5.01x | 12.12 | 187.88 |

\* `gcide.untouched @ 65536`'s decode_median_ms (19.33ms) is nearly 2x its
decode_min_ms (11.03ms) — a stalled pass under concurrent machine load
(other lanes' agents were actively building/running throughout this sweep;
`uptime` load average was ~6.9-7.0), the same noise pattern BASELINES.md
already flagged for its own omw.untouched cell. The min (11.03ms, ~95
MB/s, ~3.5x bzip3) is the trustworthy figure for this cell.

**Every single cell beats bzip3 on decode speed** (2.0x-8.8x, weakest at
the noisy gcide.untouched@65536 cell above, strongest at omw.eval8@16384).
**Size beats bzip3 everywhere except**: json.eval8 at every block size
(+8.3% to +19.4% LARGER) and macho/zigsrc.eval8 at the largest block size
(262144: +0.67%/+7.46%). See "weakest cells" below for why.

## Weakest cells and diagnosis

1. **json.eval8, all three block sizes, and macho/zigsrc.eval8 at 262144**:
   bz4's total size is close to flat across block sizes (gcide: 1,566,358 ->
   1,561,346 -> 1,560,078 from 16K to 256K, a 0.4% spread) because the
   shared model already captures cross-block redundancy regardless of
   block size (PLAN's own thesis: "the result is almost independent of
   block size"). **bzip3 is the opposite** — its BWT context window grows
   with block size, so its total keeps falling as block size grows
   (BASELINES.md: "gain flattens hard past 256KiB-1MiB", but it is still
   falling steeply from 16K to 256K in this range: gcide 2,362,319 ->
   1,615,933, -31.6%). At small blocks bz4 wins by a mile; by 256K bzip3
   has closed most of the gap on the corpora where its win was already
   thin (json, macho, zigsrc — LANE_A/LANE_B's own "generality" files,
   with less byte-level substring reuse per grammar rule than the
   dictionary corpora), and overtakes on json specifically. Diagnosis:
   this is a structural limit of a model that amortizes over the WHOLE
   file rather than adapting further within a block — not a bug, and not
   fixable by better MDL tuning (the model is already close to real H0 per
   Lane S), only by a genuinely adaptive in-block model (Lane X/W's
   territory) or accepting bzip3 wins at very large blocks on weak-grammar
   corpora.
2. **gcide.untouched@65536's decode-speed cell**: a concurrent-load timing
   artifact (see \* above), not a codec weakness — the min-based figure is
   in line with every neighboring cell.
3. **Startup ms on macho.eval8** (166-185ms) is the single largest startup
   figure in the table — macho keeps by far the most rules after pruning
   (278,355, vs freedict's 50,590) because its ~346K-symbol pre-prune
   alphabet (Lane S's own number) has the least byte-level redundancy for
   MDL to find net-harmful rules in; this is a real, expected consequence
   of macho being the "hardest" generality file for a grammar-based
   approach specifically, not a startup-path inefficiency (the ablation
   above shows the descending-g arena is if anything a net *win* on
   macho's decode throughput, +6%).

## Validation

`zig test bz4.zig` (15 tests; also run under `-O ReleaseSafe`, all pass):
roundtrip on empty input, 1 byte, all-equal bytes, random bytes (falls back
to raw blocks, verified via `pct_vs_bzip3`-style byte-exact comparison, no
blow-up), text, and `effort=1`'s A4 path; every block independently
decodable (checked inline in every roundtrip test, not just full-file);
**corruption**: 2000 trials of random bit-flips (1-4 bits) and/or random
truncation on a real compressed frame in `-O ReleaseSafe`, asserting the
decoder either errors or (if it "succeeds") reproduces the exact original
bytes (i.e. every per-block CRC32 that "succeeded" was a true positive) —
measured catch rate stayed above the 85% bar the test asserts (comparable
to Lane B's own 90% bar on a smaller, model-only fuzz target; this lane's
target is the whole frame, which has more legitimately-uninformative slack
— e.g. each of bz4_model's two internal range-coder streams' 8-byte flush
tails — for a random flip to land in harmlessly); plus an exhaustive
byte-for-byte truncation sweep (every prefix length of a real frame) as a
second, non-random pass. **Zero panics, zero OOB, zero hangs** in any of
the above, across both Debug and ReleaseSafe. `bz4_model.zig` and
`bz4_grammar.zig` and `bz4_root.zig` each carry their own additional
`zig test` cases (model DEF-tree roundtrip + Lane B's original corruption
fuzz test ported over; grammar build/verifyExact and calibrated-MDL
exactness; expansion-arena ordering/byte-exactness) — 15 tests total across
all four files, all passing.

Expansion length per rule and total arena size are bounded during model
decode (`decodeModel`'s existing `next_new_id`/`defined_count`/depth
guards, ported unchanged from Lane B, already reject expansion-bomb-style
malformed models with `error.CorruptModel` rather than exhausting memory —
covered by the ported corruption-fuzz test in `bz4_model.zig`).

## What failed / negative results (kept per PLAN's rules of evidence)

- The two-id-space bug above (grammar's own numbering vs. the model's
  post-order renumbering) is the one integration mistake worth calling out
  loudly: every unit test that built a SMALL synthetic grammar happened to
  pass anyway (small alphabets have few or no same-weight ties, so the two
  numberings' canonical codes often coincide by luck), and it only
  reliably failed once real multi-thousand-rule data was measured — a
  reminder that "no permutation is ever transmitted" (LANE_B.md) is a
  promise about the MODEL only; anything else that wants to name the same
  symbols (this lane's own root/Huffman coder) has to go through the same
  renumbering, and that dependency isn't visible from either lane's file
  in isolation.
- The descending-g arena reorder is a genuine mixed result on decode
  throughput (see "Startup speed" above) — kept for its unconditional
  memory win and because it never regressed decode speed by more than
  ~5%, but it is not the clean win the task's framing implied on every
  corpus.
- Did not attempt: package-merge-optimal Huffman (Lane S already found the
  simpler Kraft fix-up within 0.5% of H0, not worth the complexity here);
  a from-scratch tANS/rANS decoder (Lane S's own recommendation was plain
  Huffman); running `effort=1` (A4) across the full required matrix (cost/
  benefit not favorable for a 24-cell sweep given LANE_A's own 2-12s/file
  measurement — verified correct via the dedicated roundtrip test instead).
