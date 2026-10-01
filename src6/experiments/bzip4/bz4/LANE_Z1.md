# Lane Z1 — v2 integration ("words + syntax"), lab notebook

Owner: `pkg/` (a standalone Zig 0.16 package; never imports lab files —
copies + reshapes what it needs), `LANE_Z1.md` (this file), `results_v2.tsv`
in this directory. See `pkg/README.md` for the file-by-file layout.

## The question

Lane M (`LANE_M.md`) built a compositional MDL lexicon: n-ary, word-like
entries, 3x fewer than Re-Pair, real total bytes that beat Re-Pair-static on
7/12 combos. Lane K (`LANE_K.md`) built an induced class-transition model
over root tokens with free DAG inheritance: 5-7% on phrase tokens, more on
coarser tokens, "the data's own part-of-speech tags." Nobody had put M's
tokens under K's model, or asked whether some of M's phrases stop paying
once the class model already predicts their second half. That is this lane:
a real, from-scratch Zig package implementing the full round-3 pipeline
(bytes -> M lexicon -> K classes -> joint refinement -> a real frame),
measured end to end, never against an estimate.

## What was built

A new package, `pkg/`, not a patch on any lane's files. Every module is
ported and reshaped from the lab's own `m_lexicon.zig`/`m_codec.zig`
(Lane M) and `k_common.zig`/`k_classes.zig` (Lane K), generalised from
"read a B4SD dump" to "operate on this package's own in-memory
`Lexicon`/`Corpus`" — see `pkg/README.md` for the one-line-per-file layout.
Three design decisions shaped everything downstream:

1. **Byte-seeded only.** PLAN's own pipeline is "bytes -> lexicon learning,"
   not "seed from another lane's grammar dump," so `pkg` never reads a
   B4SD file at all (no dependency on Lane A's dumps, no `dumps/` reuse).
2. **Two populations, not one.** Lane M's original codec used ONE shared
   unigram population for corpus tokens *and* lexicon spellings ("the
   lexicon is just more text"). Once corpus tokens move to the
   class-conditional block coder, that population has to split: the
   lexicon's own order-0 reference code (`model_codec.zig`) is now scoped
   to spelling-internal usage only (`lexicon.recountSpellingOnly`), and
   root/corpus occurrence counts `g[]` (`lexicon.recountRootsOnly`) travel
   as a second, independently-coded array purely for the block coder's
   `g[x]/G[class]` term. Both are real, measured, charged bytes.
3. **One map, inherit always on.** Lane K's own notebook found inheritance
   "is not a minor optimisation, it is the entire reason this is
   affordable" and one learned class per symbol (vs. two, one per role)
   "wins 5/8 head-to-head and never loses badly." `classes.zig` ships only
   that safe default — the two-map and no-inherit ablations are Lane K's
   results, not re-run here (a scope cut, stated plainly, not hidden).

**Joint refinement** (`joint.zig`) is the actually-new piece: for every
lexicon entry, its benefit of deletion is recomputed as two additive parts
— a class-conditional part (`uses-as-corpus-token * [cost of its spelling's
internal class transitions and within-class picks - cost of its own
single within-class pick]`, using `classes.transitionCostBits`/
`withinClassCostBits`, Laplace-smoothed exactly like `classes.zig`'s own
learning heuristic) and an order-0 part (Lane M's original
`delete.order0Benefit` formula, applied to the *spelling-only* population,
since spelling-internal references are still coded order-0). Boundary
transitions into/out of the entry cancel between "one token" and "spliced"
whenever the entry has no class override (true almost always), which is
what makes the class-domain term a clean per-entry, context-independent
quantity rather than needing a full occurrence-by-occurrence walk. Ranked
candidates are deleted in one batch, the corpus is re-parsed with Lane M's
ordinary order-0 DP (classes affect *coding*, never *parsing* — literally
PLAN's pipeline order), classes are re-fit from scratch, and the *real*
encoded frame is measured; a round is kept only if that real total actually
shrank, else the round is reverted and refinement stops. Up to 3 rounds.
`joint.run` also computes order-0-M and classes-with-no-refinement as two
independent candidate frames up front, so the final answer is a genuine
3-way real-byte tournament — "never regress versus order-0 M or versus
no-refinement" is enforced by construction, not by hoping the loop behaves.

**Degenerate cases fall out of the general code.** `classes.Params{.C=1}`
*is* order-0 (verified by test: every symbol resolves to class 0, zero
overrides) — the "order-0 M" ablation stage is the *same* class-model code
path at C=1, not a separate codec. An empty lexicon is a `Lexicon` with
zero entries; a single block is a `Corpus` with one `block_end` entry. No
`if (corpus looks like X)` anywhere.

**A latent bounding gap fixed while porting.** Lane M's/Lane K's original
adaptive gamma/var-length decoders (`coding.decodeVar`/`coding.gammaDecode`)
searched an unbounded bit-length prefix; a sufficiently adversarial
(not just randomly bit-flipped) stream could walk `decodeVar` past its
33-slot context array (an out-of-bounds index — a safety-checked panic in
Debug/ReleaseSafe, undefined behaviour without it) or hand `gammaDecode` a
final value that overflows its `u32` narrowing cast. Neither the 2000-trial
random-corruption fuzz test here nor (as far as this notebook can tell) the
lab's own earlier fuzzing ever hit this — the legitimate-data adaptive
contexts are trained hard enough against it that random bit flips almost
never reach it — but "almost never" isn't the bar PLAN sets. Both decoders
are now bounded explicitly (matching their encoders' real maximum lengths)
and return an error instead of ever indexing or casting out of range.

## Results (`results_v2.tsv`, C=128 general setting, 3 joint-refinement
## rounds, real encode -> real decode -> byte-compare every cell)

Machine shared with other lab agents throughout (`uptime` load average
6.0-7.0 during the run, same order as `LANE_V.md` flagged for its own
sweep — timings are indicative, sizes are exact). `pct_vs_bzip3`/
`pct_vs_v1` = `100*(v2_total - baseline)/baseline`; **negative = v2
smaller/better** (same sign convention `results_v1.tsv` already uses).

| file | block | total B | %vs v1 | %vs bzip3 | decode MB/s | vs bzip3 MB/s |
|---|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 16384 | 647,834 | **-4.97%** | **-45.51%** | 125.6 | 3.05x |
| freedict.eval8 | 65536 | 638,216 | **-5.56%** | **-29.04%** | 124.2 | 2.47x |
| freedict.eval8 | 262144 | 634,539 | **-5.93%** | **-14.67%** | 128.4 | 2.38x |
| gcide.eval8 | 16384 | 1,465,897 | **-6.41%** | **-37.95%** | 66.2 | 2.71x |
| gcide.eval8 | 65536 | 1,459,330 | **-6.53%** | **-23.42%** | 64.9 | 2.37x |
| gcide.eval8 | 262144 | 1,461,353 | **-6.33%** | **-9.57%** | 63.6 | 2.21x |
| omw.eval8 | 16384 | 472,401 | +15.98% | **-57.98%** | 186.2 | 5.36x |
| omw.eval8 | 65536 | 459,913 | +15.89% | **-31.80%** | 184.5 | 3.98x |
| omw.eval8 | 262144 | 455,168 | +14.69% | **-8.24%** | 196.7 | 3.43x |
| json.eval8 | 16384 | 1,035,678 | **-7.49%** | **-21.21%** | 83.2 | 2.47x |
| json.eval8 | 65536 | 1,032,423 | **-7.34%** | +0.33% | 82.6 | 2.18x |
| json.eval8 | 262144 | 1,047,668 | **-5.79%** | +12.47% | 78.0 | 2.00x |
| macho.eval8 | 16384 | 3,005,041 | +2.21% | **-22.10%** | 30.6 | 1.84x |
| macho.eval8 | 65536 | 2,995,697 | +2.10% | **-8.09%** | 32.4 | 1.73x |
| macho.eval8 | 262144 | 2,994,048 | +2.10% | +2.77% | 32.0 | 1.55x |
| zigsrc.eval8 | 16384 | 1,397,504 | +5.65% | **-23.94%** | 73.9 | 2.92x |
| zigsrc.eval8 | 65536 | 1,380,887 | +4.91% | **-5.09%** | 75.6 | 2.51x |
| zigsrc.eval8 | 262144 | 1,383,240 | +5.00% | +12.83% | 75.3 | 2.26x |
| freedict.untouched | 16384 | 94,138 | **-6.00%** | **-37.43%** | 112.2 | 2.81x |
| freedict.untouched | 65536 | 93,014 | **-6.47%** | **-19.23%** | 114.5 | 2.36x |
| gcide.untouched | 16384 | 199,731 | **-9.50%** | **-31.75%** | 60.6 | 2.48x |
| gcide.untouched | 65536 | 201,159 | **-8.62%** | **-14.44%** | 61.0 | 2.24x |
| omw.untouched | 16384 | 75,682 | +5.14% | **-51.21%** | 166.2 | 5.37x |
| omw.untouched | 65536 | 75,270 | +6.50% | **-21.00%** | 160.1 | 3.68x |

**Beats bzip3 on size on 20/24 cells** (5.1-58.0%), loses on 4 (json.eval8
+0.33%/+12.47% at 65536/262144, macho.eval8 +2.77% and zigsrc.eval8 +12.83%
at 262144 only) — exactly v1's own known weak spot (bzip3's BWT window
grows with block size on the "generality" files with the least byte-level
redundancy; v2's shared static model is nearly block-size-independent, so
bzip3 closes the gap and eventually passes at 256K, same diagnosis
`LANE_V.md` already made). **Decodes faster than bzip3 on every single
cell** (1.55x-5.37x) though consistently slower than v1's own decode
(v1 hit 200-300+ MB/s on freedict; v2 tops out at ~128 MB/s there) — the
class-conditional coder's extra row-lookup + Fenwick descent per token
costs real time, matching Lane K's own measured 1.3-2.5x-over-X0 decode
overhead. **Startup is faster than v1 almost everywhere** (e.g.
freedict.eval8@65536: 8.3ms vs. v1's 30.1ms) — the range-coded model +
one-pass arena build apparently beats v1's Huffman-table construction.

**Beats v1 on 13/24 cells, loses on 11** — and the split is *exactly*
along the fault line `LANE_M.md` already drew: freedict/gcide/json (the
corpora where Lane M's own model-codec overhead is amortised by ~10-100
uses/entry) win on every block size; omw/macho/zigsrc/omw.untouched (the
long-reuse-tail corpora `LANE_M.md` flagged as the case where "Lane M's
model codec... costs 1.5-3.5x more bits/entry than Lane B's tuned codec")
lose on every block size, by almost the same *unsigned* margin Lane M lost
to Re-Pair-static by on its own (omw: Lane M alone was -7.9% to -11.4% vs.
Re-Pair-static; v2 here is +14.7% to +16.0% vs. v1, which itself already
*beats* Re-Pair-static — so classes + joint refinement did help omw's raw
number, just not enough to climb back over a v1 that starts from a
stronger base codec). This is the single clearest, most mechanistic result
in this notebook: **the class model and joint refinement are real wins on
top of whatever lexicon they're given; they do not fix a weak lexicon
codec**, confirming `LANE_M.md`'s own diagnosis rather than contradicting
it.

## Ablation (freedict.eval8, gcide.eval8, json.eval8 @ 65536)

Real total bytes at each stage, same real encode -> decode -> compare
discipline; `%gain` = `100*(1 - stage/previous_stage)`:

| file | (a) order-0 M | (b) + classes | (c) + joint refinement | b vs a | c vs b | c vs a |
|---|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 678,966 | 638,216 | 638,216 | **5.99%** | 0.00% (round 0 rejected) | **5.99%** |
| gcide.eval8 | 1,551,832 | 1,463,713 | 1,459,330 | **5.68%** | **0.30%** | **5.96%** |
| json.eval8 | 1,107,783 | 1,038,112 | 1,032,423 | **6.29%** | **0.55%** | **6.81%** |

Classes alone are the whole game here (5.7-6.3%, matching Lane K's own
per-file numbers closely) — joint refinement adds a further real 0.3-0.55%
on top on 2 of 3 files and, on the third (freedict.eval8), correctly finds
nothing left to profitably delete and reports that honestly (round 0's real
frame came back 515 bytes *larger*, was rejected, and the loop stopped —
the "never regress" gate firing exactly as designed, not a failure). Full
per-round log: `dumps` were not kept for this lane (no B4SD dependency), but
the raw ablation run is reproducible with `zig build bench -- ablation FILE
65536` from `pkg/`.

**Why the gain is real but small**: PLAN's hypothesis was that "the class
model already predicts many second words, so some phrases stop paying."
That is directly what happened on gcide/json (a handful of entries' benefit
flipped negative once corpus coding moved to classes), but the lexicons
Lane M's engine converges to here are already fairly lean (20-38K entries
for 8 MiB), so there were not many marginal entries sitting exactly on that
boundary — 2-3 rounds found what there was to find and then genuinely ran
out, which is the expected shape of a real MDL search, not a sign the
mechanism is weak.

## C sweep (freedict.eval8, gcide.eval8, json.eval8 @ 65536, classes-only
## stage, no joint refinement)

| file | C=32 | C=64 | C=128 | C=256 |
|---|---:|---:|---:|---:|
| freedict.eval8 | 644,588 | 640,632 | 638,216 | **637,053** |
| gcide.eval8 | 1,479,512 | 1,468,409 | 1,463,713 | **1,448,409** |
| json.eval8 | 1,049,049 | **1,034,295** | 1,038,112 | 1,038,354 |

freedict/gcide keep improving monotonically all the way to C=256 (matching
`LANE_K.md`'s own finding that the C curve hadn't topped out at 128 either)
— C=256 was not carried into the main sweep only because PLAN's Round-3
default fixes C=128 as the "one setting for all files" choice, and
per-file tuning was out of scope for this lane. json peaks at C=64 and is
*non-monotonic* past that (1,034,295 -> 1,038,112 -> 1,038,354) — a small,
real regression at higher C, consistent with `LANE_K.md`'s own "noisy...
not strictly better" warning about its exchange-learning heuristic; not
investigated further here.

## Tests

`zig build test`, Debug and ReleaseSafe, from `pkg/`: **29/29 pass** in
both modes. Coverage: roundtrip for empty input, 1 byte, all-equal bytes,
random bytes (raw-block fallback, verified byte-exact), text at `C=1`
(the order-0 degenerate case) and `C=32`; every block independently
decodable (checked inline, not just full-file); a 2,000-trial corruption
test (random bit flips + random truncation) asserting the decoder only
ever errors or produces exact bytes with a matching CRC32, catch rate
comfortably above the 85% bar (no panics, hangs, or OOB observed across
either build mode); an exhaustive byte-for-byte truncation sweep over
every prefix length of a real frame; a hand-built cyclic model that
`model_codec.decode` correctly rejects with `error.Cycle`; the
range-coder's own mixed binary/frequency stress test. Every module also
carries small unit tests next to its code (the trie, the Fenwick tree, the
gamma/var codes at their boundary values including `u32::max`, topology
ordering + cycle rejection, etc.) — 29 total `test` blocks across 16 files.

## Honest weak spots

- **Joint refinement's inner search is a real simplification, stated
  plainly in `joint.zig`'s own doc comment**: Lane M's `deletePass` gates
  its batch size with a cheap *exact* order-0 recount per halving trial;
  doing the equivalent under the class model would need a full re-fit per
  trial, so this lane instead ranks candidates by an independent-estimate
  heuristic (Laplace-smoothed, boundary-transition-cancellation-assumed)
  and gates the *whole batch* with one real re-encode per round, reverting
  the round outright if it doesn't help rather than retrying smaller
  batches. This is honest and never regresses the final answer (the round
  is thrown away wholesale on failure), but it likely leaves some
  profitable partial-batch deletions on the table on files where the
  full-batch estimate slightly overshoots.
- **Two-map classes, the no-inherit ablation, and order-2 context are Lane
  K's results, not re-run here** — a deliberate scope cut (see "What was
  built" above), not a finding of this lane's own.
- **`model_codec.zig` is still Lane M's own untuned codec**, exactly as
  PLAN's brief anticipated ("start with Lane M's codec... another lane, B2,
  is building a much smaller n-ary lexicon codec"); the omw/macho/zigsrc
  losses against v1 in the main table are that codec's cost showing through
  classes and joint refinement, not a defect in either of those.
- **The C sweep and ablation were only run on 3 files at one block size**,
  per the brief's own scope — the C=256/no-regression pattern on
  freedict/gcide is suggestive but not confirmed on the generality files.
- **`joint.zig` re-fits classes twice per round** (once to rank deletion
  candidates, once again inside the real re-encode that gates acceptance)
  — correctness is unaffected (both fits are genuine, from-scratch fits of
  the same real data) but it is not the most compute-efficient shape;
  simplicity was chosen over shaving that cost, and it was not the
  bottleneck at this corpus scale (whole-matrix + ablation + C-sweep run,
  24+21 real end-to-end combos, completed in a few minutes on a shared,
  loaded machine).

## What would be next

Per `LANE_M.md`'s own diagnosis, the highest-leverage next step is not more
class-model tuning but a better lexicon reference code (Lane B's
DEF-tree/MRU-cache idea, generalised to n-ary entries) sitting behind the
`model_codec.zig` interface this lane deliberately kept narrow for exactly
that swap — it should recover most or all of the omw/macho/zigsrc losses
against v1 without touching `classes.zig`, `block_coder.zig`, or
`joint.zig` at all.
