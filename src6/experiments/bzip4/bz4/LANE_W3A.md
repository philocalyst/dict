# Lane W3a — determinism-gated grammar + symbol-level BWT contexts

Owner files: `w3a_gprobe.zig`, `w3a_symcm.zig`, `w3a_bwtlab.zig`,
`w3a_sweep.zig`, this notebook. Builds on Lane W's round 2 result (lex-sort
symbol BWT + weight-balanced alphabetic TreeCM beats bzip3 at 1 MiB blocks
on 4/6 files) by (1) testing the lead's determinism-gate hypothesis for the
grammar builder in place of gprobe's frequency/alpha-percent threshold, (2)
adding BWT-native contexts (the F column, an exact "urn" order-0 input) to
TreeCM, and (3) charging the grammar for real via Lane B's `modelcodec.zig`
instead of an `est` bits/rule constant. Question: can we WIN ON SIZE against
bzip3 on every cell while keeping decisions/byte low?

## What was built

- **`w3a_gprobe.zig`** — a copy of `gprobe.zig`'s round structure (role-
  consistent pair families, block barriers, priority-by-count within a
  round) with the eligibility test replaced: pair `(a,b)` merges only if
  `count(ab) >= C_MIN` **and** `count(ab) / min(count(a), count(b)) >=
  THETA` (both this round's counts; `THETA` passed as an integer percent to
  avoid float bias). `THETA=0` degenerates to `C_MIN`-only frequency
  selection (the "grammar = determinism compression" idea's null setting).
  Rounds iterate until nothing is eligible, capped by a new `max_passes`
  safety valve (see "Grammar-build wall-clock pathology" below — a real,
  disclosed lab finding, not silently swept under the rug). 3 unit tests
  (theta=0 sanity, theta=100 exactness, multi-gate roundtrip-via-expansion).

- **`w3a_symcm.zig`** — a copy of `symcm.zig` with `ByteCM`/`GenericCM`/
  `AlphaTree`/`buildAlphaTree` unchanged, and `TreeCM` extended with idea
  2's four togglable inputs (all default off, all no-ops when the caller
  passes empty context arrays):
  - **idea 2a-i**: hashed `(node, F[i])`, `F[i]` = the symbol that follows
    `L[i]` in the text (the BWT's F column).
  - **idea 2a-ii**: hashed `(node, first two expansion bytes of F[i])` — a
    "junction-byte" model shared across different phrases that start alike.
  - **idea 2a-iii**: `F[i] != F[i-1]` (a known context boundary) folded
    into the mixer-weight-set/SSE selector (doubles that dimension).
  - **idea 2b**: an exact "urn" order-0 input — `remaining_right /
    remaining_total` from a Fenwick tree seeded with the block's real
    histogram (in leaf-rank order) and decremented by 1 on *every* symbol
    consumed (both the run-shortcut and tree-walk paths, so encoder/decoder
    never diverge on "remaining counts"). Zero learning cost: the value
    needs no adaptation, only the mixer's weight on it does.
  All four are additional inputs to the existing 3-input (order-0 primed +
  2 hashed order-1/2) logistic mixer, fed a neutral stretch of 0 when
  disabled/unavailable so a disabled feature costs nothing and cannot alter
  the baseline's output. 10 unit tests (was 7; added disabled-feature
  no-op checks and a combined-all-four config), all roundtrip AND
  decision-count-exact.

- **`w3a_bwtlab.zig`** — driver: builds the determinism-gated grammar,
  lex-sorts for BWT (Lane W's own fix, reused verbatim since it's
  orthogonal to this lane's changes), BWTs each block, derives the F
  column via `deriveFctx` (pure function of the block's exact histogram +
  `primary` — no SA materialization needed, see below), codes with
  `TreeCM`, decodes, inverse-BWTs, expands through the grammar, and
  byte-exact-checks against the input. Idea 2 contexts are computed **only
  for single-block (whole-file) frames** — see "Idea 2 and multi-block
  frames" below for why, and how that's disclosed per-row
  (`idea2_available`). Idea 3: the grammar (rules + `g[]`) is charged via
  `modelcodec.encodeModel`/`decodeModel`/`verifyModel` with Lane B's best
  real variant (`v2y_leftchild_order`) — a real, decodable, verified model
  byte count, not an `est` constant. 2 tests (a from-scratch brute-force
  cross-check of `deriveFctx` against a naive rotation sort, and a full
  pipeline roundtrip across every idea-1 gate x idea-2 combo).

- **`w3a_sweep.zig`** — the experiment orchestrator: runs the THETA x
  C_MIN grid per (file, block size), auto-selects the smallest real total
  per cell, looks up bzip3 totals from `baselines.tsv`, compares 64K-block
  cells against the lead's given main-line static-full-grammar totals, and
  runs the idea-2 ablation (freedict/json/macho, whole-file, at that cell's
  auto-selected gate).

## Deriving the BWT's F column without materializing it (idea 2a)

`F(i)` (row `i`'s first-column symbol, 0-indexed among the block's `m=n+1`
sorted suffixes) is **just the sorted array of the block's own symbol
multiset** — a classic BWT fact (the first column of the sorted rotation
matrix is sorted by construction) that needs no suffix array at all once
the exact histogram is known: `F(i)` = the value at cumulative-count rank
`i`. `symbwt.bwt`'s compacted output `l[]` (what the CM actually codes)
drops exactly the SA-row whose `L` is the sentinel (`primary`); `l[]`-index
`j` maps to SA-row `i` via `i=j` for `j<primary`, `i=j+1` for `j>=primary`.
Separately, row `i=0` *always* has `F=sentinel` (the sentinel is the
unique global minimum, so its own suffix sorts first) — and since `primary`
is never 0 for a non-empty block (the row whose `L` is the sentinel is the
suffix starting at position 0, a different suffix than the sentinel's own
one-character suffix), `j=0` always maps to `i=0`. So **`fctx_sym[0]` is
always the block-end marker**, matching the intuition "the BWT's first
output byte is the text's last byte, which is followed by nothing." Every
other position is a real symbol, computed via a two-pointer scan over a
static cumulative-count array (O(k+n) per block, no adaptive structure
needed since the histogram never changes). Verified against a from-scratch
brute-force rotation sort (30 random trials, `w3a_bwtlab.zig`'s
`deriveFctx` test) before ever touching real data — this was the highest
bug-risk piece of the lane and it roundtrips exactly.

## Idea 2 and multi-block frames

Idea 2a/2b both need the block's *exact* symbol histogram, which only
single-block (whole-file) frames get for free from the model's global
`g[]`. For 1 MiB and 64K shared-grammar frames (many blocks under one
grammar), `g[]` is the SUM over all blocks, not any one block's true count
— using it as if it were per-block would silently lie about what the
decoder actually knows. Per the assignment's own instruction ("either skip
idea 2a or charge a per-block histogram honestly"), **this lane skips idea
2a/2b entirely for multi-block frames** rather than pay a per-block
histogram side-channel (untested, and likely to cost more than it buys at
these already-small per-block root counts). `w3a_bwtlab.Report.
idea2_available` is `false` on every non-whole-file row, so this is
visible in the data, not just asserted here.

## Grammar-build wall-clock pathology (idea 1, negative-but-informative result)

At **loose gates** (mid THETA, low C_MIN) on **high-entropy/binary-ish
data**, a large number of pairs can satisfy `count(ab)>=C_MIN` and the
ratio test in a single round, but role-consistency (no symbol is both a
left- and right-member in one round) means only a small independent subset
can actually be selected — so convergence can take hundreds to thousands
of rounds, each costing O(live sequence length) regardless of how few
rules it yields. Measured: `macho.eval8.bin`, THETA=0.40/C_MIN=4, needed
**1,887 rounds** and **~150 seconds** of wall time for only 9,944 rules
(confirmed both at whole-file and at 65536-byte blocks — the effect is
about total eligible-pair volume, not block count). `zigsrc` and `omw` hit
similar (if less extreme) walls at THETA in [0.20, 0.40]; `freedict`,
`gcide`, and `json` converge in under 100 rounds across the whole THETA
range tested (these are the dictionary/text corpora with less pair-level
"noise" — many candidate pairs simply don't exist in the first place).
`w3a_gprobe.buildBounded` adds a `max_passes` safety valve (300 for every
run in this lab, chosen so the worst observed per-pass cost, ~80 ms,
bounds a single grammar build to ~24 s); a run that hits the cap reports
`grammar_capped=true` and `grammar_passes` in every table below — every
number from a capped run is still a REAL grammar (just not the fully
mutually-exclusive-pair-exhausted one for that gate), never silently
substituted or hidden. This is itself a finding about idea 1: the
determinism gate's *middle* THETA range is the expensive one to compute on
noisy data, which independently explains why THETA=0 (frequency-only) and
THETA>=0.8 (strict) are both the fast, well-behaved ends of the sweep.

## THETA x C_MIN sweep (json, macho, freedict, whole-file)

All real encode+decode, `model_B` from `modelcodec` (idea 3), 12 bits/rule
nowhere in this table. `roots` = symbol count after the grammar; `passes`
= grammar rounds actually run (see the wall-clock finding above).

### freedict.eval8.bin, whole-file

| THETA | C_MIN | rules | roots | payload_B | model_B | total_B | pct_vs_bzip3 | passes |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.95 | 4 | 160 | 4,324,189 | 549,102 | 649 | 549,799 | -0.76% | 105 |
| 0.95 | 16 | 159 | 4,324,196 | 549,108 | 645 | 549,801 | -0.76% | 105 |
| 0.80 | 4 | 457 | 1,915,023 | 545,075 | 1,113 | 546,236 | -1.40% | 74 |
| 0.80 | 16 | 395 | 1,915,224 | 545,024 | 1,017 | **546,089** | **-1.43%** | 74 |
| 0.60 | 4 | 847 | 1,781,175 | 544,597 | 2,016 | 546,661 | -1.33% | 52 |
| 0.60 | 16 | 537 | 1,782,955 | 544,798 | 1,531 | 546,377 | -1.38% | 48 |
| 0.40 | 4 | 6,489 | 1,416,205 | 547,630 | 12,269 | 559,947 | +1.07% | 76 |
| 0.40 | 16 | 2,487 | 1,441,900 | 548,773 | 5,429 | 554,250 | +0.04% | 45 |
| 0.20 | 4 | 19,460 | 830,013 | 542,188 | 42,446 | 584,682 | +5.54% | 45 |
| 0.20 | 16 | 5,464 | 915,474 | 547,637 | 13,442 | 561,127 | +1.29% | 34 |
| 0.00 | 4 | 48,118 | 392,499 | 529,310 | 110,112 | 639,470 | +15.43% | 12 |
| 0.00 | 16 | 12,754 | 531,200 | 550,950 | 31,416 | 582,414 | +5.13% | 11 |

Auto-selected (bold) = THETA=0.80/C_MIN=16, -1.43% vs bzip3 (554,003 B).
Shape: a broad plateau at THETA in [0.6, 0.95] all within 1% of each other
and all beating bzip3; below THETA=0.6 the model cost (more, less-certain
rules) outgrows the payload savings and it crosses into a loss.

### json.eval8.bin, whole-file

| THETA | C_MIN | rules | roots | payload_B | model_B | total_B | pct_vs_bzip3 | passes |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.95 | 4/16 | 219 | 3,085,007 | 913,607 | 540 | 914,195 | +3.31% | 38 |
| 0.80 | 4/16 | 243/236 | 2,168,4xx | 905,84x | 62x | 906,5xx | +2.44% | 27 |
| 0.60 | 4/16 | 392/348 | 2,005,0xx | 901,12x | 8xx | 902,0xx | +1.94%/+1.93% | 22 |
| 0.40 | 4 | 558 | 1,954,206 | 891,258 | 1,397 | 892,703 | +0.88% | 15 |
| 0.40 | 16 | 400 | 1,955,152 | 891,046 | 1,091 | **892,185** | **+0.82%** | 15 |
| 0.20 | 4 | 3,225 | 1,827,007 | 901,961 | 7,282 | 909,291 | +2.75% | 18 |
| 0.20 | 16 | 1,155 | 1,840,186 | 900,415 | 2,950 | 903,413 | +2.09% | 14 |
| 0.00 | 4 | 44,255 | 682,864 | 995,224 | 86,158 | 1,081,430 | +22.21% | 16 |
| 0.00 | 16 | 12,479 | 806,681 | 980,322 | 25,838 | 1,006,208 | +13.71% | 13 |

Auto-selected = THETA=0.40/C_MIN=16, +0.82% vs bzip3 (884,918 B) — the
closest this lane gets to bzip3 at whole-file on json without beating it.
Non-monotonic in THETA (a shallow minimum near 0.4-0.6, worse on both
sides) — unlike freedict, json's grammar-eligible pairs are a mix of long
fixed key strings (genuinely near-deterministic, reward loosening THETA a
little) and random hash/counter bytes (never deterministic at any C_MIN,
so loosening further just adds model cost for nothing).

### macho.eval8.bin, whole-file

| THETA | C_MIN | rules | roots | payload_B | model_B | total_B | pct_vs_bzip3 | passes | capped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 0.95 | 4/16 | 0 | 8,388,608 | 2,590,926 | 596 | 2,591,570 | +3.95% | 0 | no |
| 0.80 | 4/16 | 6 | 8,005,921 | 2,587,913 | 625 | 2,588,586 | +3.83% | 2 | no |
| 0.60 | 4/16 | 40 | 7,396,596 | 2,579,304 | 752 | 2,580,104 | +3.49% | 16 | no |
| 0.40 | 4 | 8,229 | 6,394,963 | 2,571,685 | 11,073 | 2,582,806 | +3.60% | 300 | **yes** |
| 0.40 | 16 | 1,389 | 6,439,425 | 2,573,655 | 2,926 | **2,576,629** | **+3.35%** | 112 | no |
| 0.20 | 4 | 130,025 | 3,981,325 | 2,471,906 | 194,634 | 2,666,588 | +6.96% | 300 | **yes** |
| 0.20 | 16 | 16,901 | 4,577,207 | 2,556,124 | 33,084 | 2,589,256 | +3.85% | 112 | no |
| 0.00 | 4 | 189,522 | 1,484,310 | 2,360,367 | 455,251 | 2,815,666 | +12.94% | 15 | no |
| 0.00 | 16 | 41,949 | 2,220,763 | 2,548,441 | 107,525 | 2,656,014 | +6.53% | 12 | no |

Auto-selected = THETA=0.40/C_MIN=16, +3.35% vs bzip3 (2,493,160 B) — macho
never beats bzip3 at whole-file at any THETA/C_MIN tried; THETA=0.95 (i.e.
**no grammar at all**, k=0) is only 0.6 points worse than the auto-selected
best, meaning the whole determinism-gated grammar buys almost nothing
here at this block size — macho's near-random byte pairs mostly fail the
determinism test regardless of C_MIN, exactly the failure mode idea 1
predicts for non-redundant binaries. The two THETA=0.20/0.40, C_MIN=4 rows
hit the 300-pass cap (see wall-clock finding); both are worse than their
C_MIN=16 counterparts anyway, so capping did not cost this cell a win.

## Idea 2 ablation (freedict, json, macho, whole-file, at each file's auto-selected gate)

Real payload bytes; `delta` = bytes saved vs the idea-2-off baseline at the
*same* grammar (so this isolates idea 2's contribution from idea 1's).

| file | gate | none (baseline payload_B) | +fctx | +fctx_bytes | +boundary | +urn | +all four |
|---|---|---:|---:|---:|---:|---:|---:|
| freedict | θ0.80/c16 | 545,024 | -189 | -171 | -4 | -234 | **-281 (-0.052%)** |
| json | θ0.40/c16 | 891,046 | -487 | -475 | +10 | -401 | **-765 (-0.086%)** |
| macho | θ0.40/c16 | 2,573,655 | -2,343 | -2,339 | -17 | -1,113 | **-2,804 (-0.109%)** |

Consistent story on all three files: **idea 2a-i (hashed node+F) is the
single strongest input**, 2a-ii (junction bytes) is a near-duplicate of it
(makes sense — F's identity already implies its first bytes, so the two
inputs are highly correlated and mostly redundant with each other, not
additive) and idea 2b (exact urn) is the second-most-useful, distinct
input. Idea 2a-iii (the boundary flag folded into the mixer/SSE selector)
is a wash to very slightly negative everywhere — doubling that context
dimension costs a small amount of adaptation speed that the boundary
signal itself doesn't repay at these rule counts. All four together give
the best result on every file, but the **effect size is small**: 0.05-0.11%
of payload, two to three orders of magnitude smaller than idea 1's own
swings (1-20%+) or idea 3's real-vs-est model-cost correction. Idea 2 is a
real, positive, reproducible effect — not large enough to change any
cell's win/loss verdict against bzip3 by itself.

## Main results: auto-selected setting per (file, block size) — 18 cells

Auto-selection = smallest real `total_B` (payload + real modelcodec bytes
+ 16B/block + 32B header) across the settings tried per cell (full
6-THETA x 2-C_MIN grid at whole-file for freedict/json/macho per the
lead's request; a 3-THETA{0.80,0.40,0.00} x 2-C_MIN handful everywhere
else — "a handful," explicitly allowed). `main_line_64k` is the lead's
given static-full-grammar reference (not derived here), 64K-block only.

| file | block | setting | rules | roots | model_B | payload_B | total_B | bzip3_B | **pct_vs_bzip3** | **dec/byte** | main_line_64k | vs main_line |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict | whole | θ0.80/c16 | 395 | 1,915,224 | 1,017 | 545,024 | 546,089 | 554,003 | **-1.43%** | 0.857 | — | — |
| freedict | 1M | θ0.80/c16 | 393 | 1,914,247 | 1,030 | 617,737 | 618,927 | 641,321 | **-3.49%** | 0.898 | — | — |
| freedict | 64K | θ0.00/c4 | 48,233 | 393,431 | 110,093 | 589,178 | 701,351 | 899,408 | **-22.02%** | 0.673 | 692,000 | +1.35% |
| gcide | whole | θ0.80/c16 | 297 | 6,463,844 | 817 | 1,275,769 | 1,276,634 | 1,243,221 | +2.69% | 2.313 | — | — |
| gcide | 1M | θ0.40/c16 | 4,217 | 3,585,634 | 9,713 | 1,430,267 | 1,440,140 | 1,421,958 | +1.28% | 2.104 | — | — |
| gcide | 64K | θ0.00/c4 | 75,620 | 867,215 | 185,093 | 1,395,664 | 1,582,837 | 1,905,560 | **-16.94%** | 1.603 | 1,603,000 | **-1.26%** |
| omw | whole | θ0.40/c16† | 9,314 | 2,724,549 | 10,250 | 385,208 | 395,506 | 332,331 | +19.01% | 0.715 | — | — |
| omw | 1M | θ0.00/c4 | 87,431 | 232,981 | 180,387 | 274,687 | 455,234 | 417,761 | +8.97% | 0.348 | — | — |
| omw | 64K | θ0.00/c4 | 81,484 | 217,376 | 164,831 | 272,582 | 439,493 | 674,384 | **-34.83%** | 0.329 | 424,000 | +3.65% |
| json | whole | θ0.40/c16 | 400 | 1,955,152 | 1,091 | 891,046 | 892,185 | 884,918 | +0.82% | 1.440 | — | — |
| json | 1M | θ0.40/c16 | 400 | 1,955,178 | 1,098 | 918,931 | 920,189 | 898,936 | +2.36% | 1.436 | — | — |
| json | 64K | θ0.40/c4 | 545 | 1,926,063 | 1,452 | 960,147 | 963,679 | 1,028,983 | **-6.35%** | 1.401 | 1,183,000 | **-18.55%** |
| macho | whole | θ0.40/c16 | 1,389 | 6,439,425 | 2,926 | 2,573,655 | 2,576,629 | 2,493,160 | +3.35% | 3.752 | — | — |
| macho | 1M | θ0.00/c16 | 41,949 | 2,220,764 | 107,528 | 2,649,950 | 2,757,638 | 2,687,953 | +2.59% | 3.076 | — | — |
| macho | 64K | θ0.00/c4 | 189,501 | 1,484,510 | 455,266 | 2,393,421 | 2,850,767 | 3,259,348 | **-12.54%** | 2.713 | 3,008,000 | **-5.23%** |
| zigsrc | whole | θ0.40/c16 | 4,671 | 5,400,217 | 7,092 | 1,102,176 | 1,109,316 | 1,037,980 | +6.87% | 1.853 | — | — |
| zigsrc | 1M | θ0.40/c16 | 4,702 | 5,400,517 | 7,133 | 1,178,665 | 1,185,958 | 1,121,996 | +5.70% | 1.898 | — | — |
| zigsrc | 64K | θ0.00/c16 | 31,910 | 1,201,382 | 83,720 | 1,276,921 | 1,362,721 | 1,454,997 | **-6.34%** | 1.568 | 1,336,000 | +2.00% |

† omw/whole hit the 300-pass grammar-build cap (`grammar_capped=true`) —
a real, disclosed partial grammar; every other row's grammar converged
naturally (`passes` well under 300, not tabulated above for space, see
`dumps/w3a_sweep/full_run.log`).

**decisions/byte flag** (plan: "don't make this worse than ~2 without
saying so"): gcide whole (2.313) and 1M (2.104), and all three macho cells
(3.752, 3.076, 2.713) exceed 2. Every other cell is at or under 1.9. The
pattern tracks root count directly — these are the cells where the
determinism gate found few/weak rules (gcide's real-word structure and
macho's near-random bytes both resist the gate), leaving a root stream
close to raw bytes, which is exactly where TreeCM's tree depth (and hence
decisions/byte) approaches ByteCM's fixed 8 (well, in these cases 2-4,
since some grammar is still found).

## Assessment

**Clean win at 64K blocks, on every single file (6/6):** -22.0% (freedict),
-16.9% (gcide), -34.8% (omw), -6.3% (json), -12.5% (macho), -6.3% (zigsrc)
vs bzip3, and beats the given main-line static-full-grammar reference on
3/6 (gcide, json, macho — json by a huge -18.6% margin) while losing to it
by 1.3-3.7% on the other 3 (freedict, omw, zigsrc). This is the strongest,
cleanest result in this lane: a determinism-gated shared grammar, lex-sort
BWT, and TreeCM together beat bzip3's own adaptive model at 64K blocks
regardless of file type, at decisions/byte mostly well under 2.

**Mixed/losing at whole-file and 1 MiB (10/12 cells still lose to bzip3):**
only freedict wins cleanly at all three block sizes. gcide and json are
close (within 1-2.5 points) at whole-file/1M but still lose. omw, macho,
and zigsrc lose more clearly at whole-file/1M (omw worst, +19% and +9%) —
omw's redundancy is long-range exact duplication that this lane's capped,
role-consistency-throttled grammar search doesn't fully capture at whole-
file (see the wall-clock finding), macho's byte pairs are mostly not
deterministic enough for the gate to find much (idea 1's own predicted
failure mode for non-redundant binaries), and zigsrc sits in between. This
matches, and does not overturn, Lane W round 2's own finding that pure
block-sort (no grammar) or a small rule-CAPPED grammar (not this lane's
determinism GATE) is the better whole-file/1M lever on those files —
**idea 1 is a different knob from round 2's rule cap, not a strict
upgrade of it**, and the two should probably be tried together (e.g.
determinism-gate first, then still cap the result) rather than in place
of each other; not attempted here given lane scope/time.

**Idea 1 in one sentence**: it works, and works very well, exactly at the
block size (64K, many small blocks sharing one grammar) where a stored
model's fixed cost is amortized the most and a decoder needs to walk the
fewest binary decisions per byte — matching the plan's own stated goal
"win on size while keeping decisions/byte low" precisely there, and not
(yet, with this lane's search strategy) at the larger block sizes where
bzip3's own single-block adaptive model has more room to work.

**Idea 2 in one sentence**: real, positive, cheap to add, and correctly
scoped to single-block frames only — but a rounding error next to idea 1
and idea 3's effect sizes; keep it, don't expect it to flip a verdict.

**Idea 3 in one sentence**: charging the grammar for real (Lane B's
`v2y_leftchild_order`, 15.8-20.35 bits/rule per LANE_B.md, well above the
12-bit `est` round 2 used) matters a lot precisely where rule counts get
large (freedict/gcide/macho/omw/zigsrc 64K cells all have 30K-190K rules
— `model_B` there is 15-30% of `total_B`, not a rounding error), and is
part of why this lane's THETA sweep has a real minimum in the middle of
the range rather than monotonically favoring more rules.

## What failed / didn't pan out

- **Grammar-build wall-clock pathology** at loose-to-mid THETA on
  high-entropy/binary data (see above) — a real, disclosed limitation of
  the determinism-gate design (not a bug): role-consistency throttles
  selection-per-round independently of how many pairs qualify, so a data
  distribution with many marginally-qualifying pairs and few truly
  deterministic ones pays for every one of them across hundreds of nearly-
  empty rounds. A smarter builder would batch-select more per round when
  many candidates are mutually compatible by chance, or bound rounds by
  a shrinking-gain heuristic instead of a fixed pass cap — not attempted,
  lane time budget went to breadth (18 cells + sweep + ablation) over
  fixing this one mechanism.
- **Idea 2a-ii (junction bytes) adds ~nothing over idea 2a-i (F symbol
  itself)** — expected in hindsight (a symbol's identity already implies
  its own first bytes) but worth stating since the plan proposed them as
  two separate inputs; a from-scratch design would likely fold them into
  one.
- **Idea 2a-iii (boundary flag) is not worth its own mixer/SSE dimension**
  at the rule counts this lane's grammars produce — it's a wash to
  slightly negative on all three ablation files.
- Did not verify whether idea 1's determinism gate composes with round 2's
  rule cap (gate-then-cap) — flagged above as the obvious next experiment,
  not run.
