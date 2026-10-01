# Lane W — block-sort in the middle of the grammar continuum

Owner files: `symbwt.zig`, `symcm.zig`, `bwtlab.zig`, this notebook.
Question: for a **partial** grammar of k rules, then a symbol-BWT over the
root stream, then an adaptive context-mixing coder — where is the optimum
k per file/block size, and does any k beat the main line's full-grammar
static code for big blocks? k=0 is a pure byte BWT+CM (bzip3-shaped), so it
also answers "how good is our CM against bzip3's, independent of the
grammar question."

## What was built

- **`symbwt.zig`** — BWT over `u32` symbol sequences, alphabet size K up to
  2^20. Suffix array by prefix doubling with a two-pass stable counting
  sort (O(m log m), m = n+1 for one appended sentinel). The sentinel is
  dropped from the output (`bwt` returns `l` of length n plus a `primary`
  index), recovered on decode by reinserting a `0` at `primary` before
  running the standard `next[]`/`prev[]` LF-mapping inverse. Tested against
  a naive full-sort-of-rotations reference on random/periodic/tiny-alphabet
  inputs, lengths 0/1/2, and separately roundtrip-tested at K up to 2^20
  with sparse symbols. All 6 tests pass (`zig test -O ReleaseSafe
  symbwt.zig`).

- **`symcm.zig`** — two coder families, dispatched on alphabet size:
  - `ByteCM` (K==256, the k=0 byte-BWT case, for a fair bzip3 comparison):
    a direct structural port of bzip3's `encode_bytes`/`decode_bytes`
    (`vendor/bzip3/src/libbz3.c` ~330-494) — 8-bit context tree per byte,
    order-0 C0[ctx] mixed with two order-1 predictions C1[prev][ctx] and
    C1[prev2][ctx] at bzip3's 7:7:2 weights, an SSE/APM stage
    C2[2·ctx+run][17 buckets] blended 3:1 against the raw mix, same
    adaptation rates (2,4,6,6). Reimplemented against `rc.zig`'s
    `encodeBitProb`/`decodeBitProb` rather than bzip3's own coder.
  - `GenericCM` (K>256, partial-grammar roots): recency cache (N=16,
    move-to-front array), hit/miss coded as an adaptive `rc.Bit` under
    context = (last 3 hit/miss outcomes, was-previous-rank-0), rank-on-hit
    coded by a 4-bit tree under context of the previous rank bucket, miss
    symbols coded by a Fenwick-tree adaptive frequency model over all K
    symbols with a **uniform prior of 1** (no per-corpus counts smuggled
    in) and an additive increment of 24 applied on *every* symbol
    (hit or miss) — chosen so the model reflects true global frequency
    even though only misses are actually coded against it; see "decisions"
    below. No exclusion of cache-resident symbols from the miss model
    (plan's "excluding nothing at first").
  - 7 tests pass, including a Zipf-ish K=5000 case, a runs-heavy case, a
    K=2^20 sparse case, and a Fenwick correctness/invertibility check.

- **`bwtlab.zig`** — driver. Imports `gprobe.build` directly (rather than
  shelling to the dump format) to get the grammar + root stream with
  barriers at block boundaries; BWTs each block's roots, encodes/decodes
  with `symcm`, inverse-BWTs, **expands roots back to raw bytes through the
  grammar rules** (iterative stack-based expansion, matching the pattern
  already used in `grammar2.zig`), and asserts byte-exact equality against
  the original file per block. Every number in this notebook comes from a
  run where that assertion held — no silent estimates.

## Bugs found and fixed while building this (worth recording)

1. **SSE interpolation sign bug** (`symcm.zig`): bzip3's `ssep = x1 +
   (((x2-x1)*(p&4095))>>12)` uses signed `int` arithmetic — adjacent SSE
   buckets are not guaranteed monotone, so `x2-x1` can be negative. My
   first port used wrapping *unsigned* subtraction, which turned a
   negative delta into a huge unsigned value and corrupted every
   probability. Symptom: `ByteCM` **expanded** skewed data 3.8x instead of
   compressing it (20,000 symbols -> 76,323 bytes). Fixed by doing the
   interpolation in `i32`. Caught immediately by the `enc.len < n` sanity
   assertion in the roundtrip test — worth keeping that kind of assertion,
   not just byte-equality, in every coder test.
2. **rc.zig `Encoder.finish()` ownership**: `finish()` returns
   `self.out.items`, a slice borrowed from the ArrayList's backing
   allocation (capacity ≥ len). Freeing that slice directly trips the
   debug allocator ("allocation size does not match free size") because
   the real allocation is sized to capacity. Fix: `alloc.dupe` the result
   before `enc.deinit()`. rc.zig's own test sidesteps this by never
   freeing `bytes` separately (it relies on `enc.deinit()` to reclaim
   everything, with the encoder kept alive as long as the bytes are
   needed) — that convention is fine for a short scope but does not
   compose if you want to return owned bytes from a function, so
   `symcm.zig`'s `encodeBytes`/`encodeSymbols` dupe explicitly.
3. **`gprobe.Grammar.seq` is a truncated view**: `build()` allocates
   `seq` of length `n` (input length) internally but returns `seq[0..live]`
   after compaction. `gprobe.zig`'s own `main()` never frees it (fine for
   a one-shot CLI exiting immediately), but a driver that calls `build()`
   repeatedly (my test loop, and in spirit any long-running host) must
   free the *original* extent (`g.seq.ptr[0..n]`), not the returned slice,
   or the debug allocator aborts. Noted here since this is a shared,
   read-only file I can't patch — worth flagging to the grammar lane.

## Decisions worth stating explicitly (rules-of-evidence hygiene)

- **Fenwick prior**: uniform 1 per symbol, not the block's true global
  counts. This costs a little adaptation speed at the very start of each
  block but requires zero side-channel data the decoder wouldn't
  otherwise have, and keeps every block independently decodable (per the
  architecture's own goal), which a shared/global-count prior would
  compromise.
- **Fenwick sizing**: every block allocates a Fenwick tree of size K
  (=256+total rule count so far), not just the symbols actually seen in
  that block, and BWT's suffix array scratch is likewise sized to K where
  counting-sort buckets are needed. This is simple and correct (a rule id
  can appear in any block regardless of which round created it) but is
  the single biggest performance tax in this lab — see below.
- **k=0 grammar cost**: at k=0 there are no rules, so `grammar_est_B=0`
  and the root stream is literally the input bytes; this is intentionally
  the "how good is our CM alone" cell.
- **Block-bytes=0 ("whole file")**: passed to `gprobe.build` as
  `block_bytes=input.len` so it degenerates to one block, matching
  bzip3's own single-block mode at the same size for the comparison.
- **min_freq=2, alpha=50** fixed for every run (no per-corpus knobs),
  matching `PLAN.md`'s own example invocation.
- **Grammar cost**: charged at the fixed 14 bits/rule **est** the plan
  specifies, plus 16 bytes/block + 32 bytes overhead; payload bytes are
  always the real `symcm` output. `total_est_static0` substitutes the
  real payload with the (also real-input, `est`-labelled) global order-0
  entropy of the roots, for the "what does BWT+CM buy" comparison.

## Results

6 files (`{freedict,gcide,omw,json,macho,zigsrc}.eval8.bin`, 8 MiB each) ×
3 block sizes (64K, 1M, whole) × 5 k (0, 1024, 8192, 65536, full) = 90 runs,
all byte-exact round-tripped. bzip3 numbers are real runs of Lane D's
`bin/bz3base` at the matching block size (`baselines.tsv` did not exist
yet when this ran).

### Total-est bytes by (file, block, k) — best k in **bold**

| file | block | k=0 | k=1024 | k=8192 | k=65536 | k=full | bzip3 (same block) |
|---|---|---:|---:|---:|---:|---:|---:|
| freedict | 64K | 871,767 | 843,136 | 737,926 | 668,518 | **664,912** | 899,408 |
| freedict | 1M | **615,897** | 710,943 | 692,064 | 666,888 | 663,207 | 641,321 |
| freedict | whole | **535,510** | 648,076 | 659,642 | 672,731 | 669,237 | 554,003 |
| gcide | 64K | 1,871,624 | 1,991,536 | 1,768,054 | 1,562,446 | **1,541,799** | 1,905,560 |
| gcide | 1M | **1,392,528** | 1,657,947 | 1,634,447 | 1,560,675 | 1,550,726 | 1,421,958 |
| gcide | whole | **1,220,439** | 1,501,836 | 1,540,987 | 1,536,919 | 1,554,331 | 1,243,221 |
| omw | 64K | 785,452 | 728,945 | 605,540 | 432,355 | **390,579** | 674,384 |
| omw | 1M | 527,960 | 543,017 | 509,326 | 414,368 | **382,886** | 417,761 |
| omw | whole | 435,822 | 452,907 | 443,221 | 411,990 | **390,645** | 332,331 |
| json | 64K | **1,063,664** | 1,141,896 | 1,157,070 | 1,223,872 | 1,223,872 | 1,028,983 |
| json | 1M | **952,947** | 1,116,132 | 1,117,342 | 1,203,634 | 1,203,634 | 898,936 |
| json | whole | **940,388** | 1,134,694 | 1,124,941 | 1,201,683 | 1,201,683 | 884,918 |
| macho | 64K | 3,334,530 | 3,439,602 | 3,269,695 | 3,017,146 | **2,849,534** | 3,259,348 |
| macho | 1M | **2,783,093** | 3,041,777 | 2,996,939 | 2,925,858 | 2,835,966 | 2,687,953 |
| macho | whole | **2,589,911** | 2,917,093 | 2,917,335 | 2,902,577 | 2,877,660 | 2,493,160 |
| zigsrc | 64K | 1,510,328 | 1,571,523 | 1,432,855 | 1,307,802 | **1,221,353** | 1,454,997 |
| zigsrc | 1M | **1,206,911** | 1,329,039 | 1,309,858 | 1,272,084 | 1,216,574 | 1,121,996 |
| zigsrc | whole | **1,124,783** | 1,270,709 | 1,294,670 | 1,301,878 | 1,258,802 | 1,037,980 |

Pattern: at **64K** blocks, the near-full grammar (k=full or k=65536 when
the natural grammar exhausts before 65536, as it does on json) wins on
5/6 files — a shared vocabulary amortized over many small blocks beats
per-block BWT context, which barely exists at 64K. At **1M/whole** blocks,
pure byte BWT+CM (**k=0**) wins on 5/6 files — once blocks are big enough
to give the CM real context, grammar-rule overhead (14 bits/rule, real
money at 100K+ rules) stops paying for itself. **OMW is the outlier**:
full grammar wins at every block size, because OMW's redundancy is
long-range *exact* duplication (dictionary cross-references) that a
grammar rule captures in ~14 bits regardless of distance, while BWT+CM's
context window can't reach as far.

### k=0 vs bzip3 (whole-file block — is our from-scratch CM competitive?)

| file | our k=0 total_est | bzip3 | ratio | our decode | bzip3 decode |
|---|---:|---:|---:|---:|---:|
| freedict | 535,510 | 554,003 | 0.967 | 1288 ms | 305 ms |
| gcide | 1,220,439 | 1,243,221 | 0.982 | 1610 ms | 588 ms |
| omw | 435,822 | 332,331 | 1.311 | 1212 ms | 208 ms |
| json | 940,388 | 884,918 | 1.063 | 1299 ms | 505 ms |
| macho | 2,589,911 | 2,493,160 | 1.039 | 1603 ms | 848 ms |
| zigsrc | 1,124,783 | 1,037,980 | 1.084 | 2839 ms | 646 ms |

**Size**: competitive — within ±8% of bzip3 on 5/6 files, actually smaller
on the two dictionary corpora (freedict, gcide), for a same-shape port
that received no tuning of its own. OMW is the one bad outlier (+31%);
OMW's redundancy is long-range exact repetition that bzip3's own
(also byte-level) BWT+CM apparently also captures much better than ours
does at this block size — worth a follow-up (possibly our BWT's tie-breaking
or our CM's context choices interact worse with OMW's specific repeat
structure; not chased further given lane scope).

**Speed**: not competitive. Our decode is **4-9x slower** than bzip3's
native decoder at k=0 across every file. This is a from-scratch,
un-optimized Zig port (64-bit divide-based range coder vs bzip3's
shift-based one, no SIMD, generic loop structure) — the size result says
the *prediction* design is sound, but the *implementation* has real
headroom bzip3's C has already claimed.

### What BWT+CM buys over static order-0 root coding, by k

(payload bytes only, whole-file block; "save%" = (static_h0 − payload) /
static_h0)

| file | k=0 | k=1024 | k=8192 | k=65536 | k=full |
|---|---:|---:|---:|---:|---:|
| freedict | +88.6% | +31.2% | +13.0% | −5.4% | −6.1% |
| gcide | +76.5% | +36.0% | +15.1% | −0.3% | −5.0% |
| omw | +92.8% | +77.0% | +65.2% | +15.5% | −9.5% |
| json | +82.9% | +3.7% | +0.7% | −3.4% | −3.4% |
| macho | +63.2% | +45.5% | +34.0% | +16.7% | −5.5% |
| zigsrc | +78.2% | +59.6% | +41.2% | +16.2% | −7.0% |

This is the cleanest result in the lab and it matches the project thesis
exactly: **BWT+CM's advantage over a static order-0 root code shrinks
monotonically as the grammar grows, and goes slightly *negative* at full
grammar on every single file.** Once the grammar has grown until no pair
repeats, adjacent roots are (by construction) not correlated the way BWT
needs, so sorting them by context finds nothing, and the CM's own
per-symbol overhead (hit/miss bit, tree bits) costs a little more than a
plain static code would. The crossover (where BWT+CM stops paying for
itself) lands around k=65536 for freedict/gcide/json, later (still
positive through k=65536) for the more redundant omw/macho/zigsrc.

### Decode speed (indicative, shared machine)

Pure-byte CM (k=0) is 5-8 MB/s everywhere — the ByteCM's per-bit tree
walk with SSE dominates. Once any grammar is applied, GenericCM decode is
20-700 MB/s depending on how few roots remain and how large K has grown.
Two effects fight each other as k grows: fewer roots to decode (good) vs.
a bigger Fenwick tree that gets rebuilt with a uniform prior *from
scratch for every block* (bad — O(K) per block regardless of how many
roots that block actually has). This second effect is visible directly:
macho/zigsrc at k=full decode *slower* at 64K blocks (523/626 ms) than at
k=65536 (220/315 ms), because 128 blocks each pay a ~350K-entry Fenwick
build, vs. only 8 such builds at 1M blocks (201/206 ms) or 1 at whole
(367/159 ms). **This is a lab shortcut, not a fundamental cost** — a real
implementation would size the Fenwick to the block's actual referenced
alphabet (or reuse/rescale one Fenwick across blocks) and this tax would
mostly disappear; flagging it rather than fixing it since block-count-many
allocations of the true size would have eaten this lane's remaining time
budget for a result that doesn't change the k-selection story.

## What failed / didn't pan out

- Wrapping-unsigned SSE interpolation (see bugs above) — not a design
  failure, a straight porting bug, but worth remembering: signed deltas
  in a "probability" pipeline need signed arithmetic even when every
  individual value is non-negative.
- No attempt was made to tune `fenwick_increment` (fixed at 24), the
  `rc.Bit` adaptation rate (fixed at 5) for `GenericCM`, or the recency
  cache size (fixed at 16). These are plausible knobs for a few more
  percent; not touched, given the lane's job was the k-sweep, not
  micro-tuning one cell of it.
- Did not attempt per-context-split Fenwick models (plan's optional
  "second-level" for the K>256 path) — the single global Fenwick was
  already doing the required job (see savings table); a context split
  would mostly matter for the already-marginal k=65536/k=full cells where
  BWT has little left to find anyway, so was not worth the added
  O(contexts × K) memory for this lab's time budget.

## Does any k beat the full-grammar main line? — two comparisons, not one

First cut, **within this lane only**: comparing each cell's real BWT+CM
`total_est_B` against this lane's own naive-order-0 proxy for the full
grammar (`total_est_static0_B` at k=full) gives:

| file | 64K: real BWT+CM best vs static0-full | 1M | whole |
|---|---:|---:|---:|
| freedict | static0-full wins by 3.7% | BWT+CM (k=0) wins by 3.4% | BWT+CM (k=0) wins by 16.0% |
| gcide | static0-full wins by 3.3% | BWT+CM wins by 6.6% | BWT+CM wins by 18.1% |
| omw | static0-full wins by 2.4% | static0-full wins by 2.6% | static0-full wins by 4.8% |
| json | BWT+CM wins by 9.0% | BWT+CM wins by 18.4% | BWT+CM wins by 19.4% |
| macho | static0-full wins by 3.2% | static0-full wins by 0.8% | BWT+CM wins by 6.2% |
| zigsrc | static0-full wins by 1.4% | static0-full wins by 0.5% | BWT+CM wins by 6.3% |

Read naively, block-sort looks like a big winner at large blocks. **But
`total_est_static0_B` is a naive global order-0 code, not what the real
main line achieves** — Lane B's grammar coder and Lane X's soft-context
root coding both explicitly exist to beat order-0. So this first cut only
answers "does BWT+CM beat doing nothing clever with the roots," not "does
it beat the main line."

Second cut, **against Lane X's real, charged numbers** (`LANE_X.md`,
its own `rootlab_ctx` runs — real encoder/decoder, not an estimate),
which exist only for 64K-block full-grammar dumps. Reconstructing a real
main-line total there (Lane X's best real payload+table + this lane's own
14-bit/rule grammar estimate + the same 16 B/block + 32 overhead, so the
grammar/overhead accounting matches like-for-like):

| file | real main line, 64K full | this lane's best BWT+CM, 64K | winner |
|---|---:|---:|---|
| freedict | 626,607 | 664,912 (k=full) | main line by 5.8% |
| gcide | 1,453,145 | 1,541,799 (k=full) | main line by 5.7% |
| omw | 370,014 | 390,579 (k=full) | main line by 5.3% |
| json | 1,146,484 | **1,063,664 (k=0)** | **BWT+CM by 7.2%** |
| macho | 2,694,579 | 2,849,534 (k=full) | main line by 5.4% |
| zigsrc | 1,138,677 | 1,221,353 (k=full) | main line by 6.8% |

This is the trustworthy comparison at 64K, and it **reverses** most of the
naive-proxy picture: once the main line gets Lane X's real soft-context
gain (2-8% over order-0, per `LANE_X.md`), it retakes the lead on every
acceptance-gate corpus and on the two generality files that aren't JSON.
**JSON is the one file where block-sort's win is real and holds up against
real numbers, at every block size tested.**

**The open question this lane cannot close**: Lane X did not run its
context coder at 1M or whole-file blocks (no dumps existed at those
sizes), so there is no real (non-order-0) main-line number to check this
lane's 16-19% whole-file wins on freedict/gcide against. Lane X's real
gain over order-0 was only 2-8% at 64K; if that held at whole-file size
too, block-sort's whole-file win would survive. But context models
typically get *more* out of bigger blocks (richer statistics), so the
real gain at whole-file could plausibly be larger than 8% and close some
or all of the gap — this lane does not know, and says so rather than
guessing.

## Recommendation

**Do not adopt block-sort as a replacement for the main line's static
full-grammar code at the acceptance-gate corpora's target (small) block
sizes** — real numbers say the main line wins there by a consistent
~5-6%. **Do keep k=0 (pure byte BWT+CM) in reserve for two concrete
cases with evidence behind them**: (1) JSON-shaped data, where it wins at
every block size against both the naive and the real main-line
comparison, and (2) large/whole-file blocks generally, where this lane's
own numbers show a large (16-19%) apparent win on text corpora that no
lane has yet checked against a real (non-order-0) main-line coder at that
block size — worth Lane X or Lane B spending an hour building whole-file
dumps and re-running their real coders before either adopting or
dismissing block-sort there. On weak-grammar data (macho): full grammar
alone is not the best static cell at 64K blocks either (this lane's
k=full BWT+CM beats this lane's own static0-full estimate there, +savings
table above), consistent with the thesis that block-sort matters most
where the grammar is weak — but the *real* main-line comparison at 64K
still edges it out by ~5%, so even for machine code block-sort is a
fallback, not (yet) a win, at the block size actually tested against real
numbers.

---

# Round 2 (lead's follow-up): fixing the sort order and the CM

The lead's diagnosis of round 1's valley at intermediate k: (1) the BWT
sorted suffixes by gprobe's creation-order rule ids, which have nothing to
do with lexicographic content, so related phrases ("the", "the ", "there")
scatter to unrelated rows and can't share predecessor statistics; (2)
`GenericCM` (recency cache + Fenwick) has no hierarchical sharing, no
order-1/2 mixing, no SSE — a much weaker coder than the bzip3-shaped
`ByteCM` used for k=0, so k>0 was handicapped twice over. Round 2 fixes
both, in the same three owned files.

## What was built (W2)

- **Lexicographic `fwd_rank`** (`bwtlab.zig`): every symbol's byte
  expansion is given a capped (64-byte) prefix/suffix key, built
  bottom-up in O(key_cap) per rule (children always have smaller ids, so
  a single pass over the rule list suffices — no full materialisation, no
  risk of an O(n log n) blow-up from a pathological rule chain). `fwd_rank`
  sorts symbols by that prefix key (shorter-but-genuinely-complete prefix
  first, matching real string order; ties beyond the 64-byte cap fall
  back to full length then id — never triggered in practice on these
  corpora). The root sequence is remapped through `fwd_rank` before
  `symbwt.bwt`, and the BWT's output is mapped straight back to original
  symbol ids afterward, so the *sort* uses the lexicographic order but the
  *coder* always sees original ids — `symbwt.zig` itself needed no
  changes. `fwd_rank` is a pure function of the grammar (which the real
  decoder already has from the MODEL segment), so it costs zero bytes.
- **`rev_rank` and a weight-balanced alphabetic tree** (`symcm.zig`,
  `AlphaTree`/`buildAlphaTree`): the same key machinery sorts symbols by
  their *reversed* expansion, then `buildAlphaTree` recursively splits
  that order at the weighted-median position (weights = global root
  count `g[s]+1`, also free — the plan's own MODEL segment already carries
  per-symbol counts), giving a full binary tree with leaves in `rev_rank`
  order. No explicit per-symbol path is stored: encode finds a symbol's
  path by comparing its `rev_rank` position against each node's stored
  absolute split threshold (`mid`); decode walks the same tree structure
  by coded bits. Frequent symbols land near the root.
- **`TreeCM`** (`symcm.zig`): generalises `ByteCM`'s bzip3-shaped
  machinery from the fixed 255-node byte tree to this alphabetic tree —
  order-0 per node (*primed* to the node's own split ratio, not a neutral
  0.5), two hashed order-1 contexts `hash(node, L[i-1])` /
  `hash(node, L[i-2])` (2^20-entry `u16` tables, no check bits), a fixed
  bzip3-style mix or a small per-(depth-bucket, run-flag) logistic mixer,
  and an SSE stage keyed by (depth bucket, run flag) since a real
  node-indexed SSE table would need one entry per of up to ~350k nodes.
  A one-bit run shortcut ("same symbol as last output?", context = run
  length bucket x previous-hit flag) precedes the tree walk and, on a
  hit, skips it entirely. Every sub-piece is a runtime toggle
  (`TreeCMConfig`) for the ablation below. `GenericCM` is untouched and
  still selectable (`cm=generic`) as the round-1 baseline.
- **`bwtlab.zig`** CLI grew `[SORT] [CM] [RUNSC] [MIX] [SSE]` trailing
  args (all default to the round-2 "best" combination: `lex tree 1
  logistic 1`), and now also accepts a `min_freq`-driven "unlimited
  rules" grammar (pass a huge `MAX_RULES` cap with a real `MIN_FREQ`) for
  the frequency-gated grammar experiment. Grammar cost is now charged at
  **12 bits/rule** (down from round 1's 14 — Lane I's real in-band DEF-tree
  coder measured ~9.6 bits/rule; 12 stays a labelled `est` but is closer
  to that real number). `decisions` (a real count of every binary
  range-coder call made) is threaded through every coder (`ByteCM`,
  `GenericCM`, `TreeCM` all gained a `decisions` field and `*Counted`
  wrapper functions) and asserted equal between encode and decode before
  any run is trusted, on top of the existing byte-exact expansion check.

## A real bug, caught by the decision-count assertion

`TreeCM.decodeSymbol` computed its run-shortcut bookkeeping from *whether
the shortcut path was taken* (a local `was_same` flag, only ever set
`true` inside the `if (use_run_shortcut)` branch) instead of from
*whether the actual decoded symbol matches the previous one*. When the
shortcut was disabled (or missed), `run_len`/`prev_hit` silently stayed at
their initial values on the decode side forever, while the encode side —
which always knows the symbol up front — tracked them correctly. Both
sides code identical bits until the run-length bucket first diverges
between the two (e.g. the moment a run gets long enough to flip the
mixer/SSE "run flag" context), at which point the decoder starts reading
a *different* adaptive table than the encoder wrote to, decodes garbage,
and every symbol after that is wrong. Caught by a small crafted repro
(one symbol repeated 6 times) after the full random test failed at
symbol 5 with `enc.decisions=182677` vs `dec.decisions=293456` — a
visible symptom precisely *because* decisions are now counted and
asserted equal. Fixed by recomputing the repeat flag from the actually
decoded symbol (`sym == self.prev1`) for bookkeeping, independent of
which path produced `sym`. All 18 tests (`symbwt.zig` + `symcm.zig` +
`bwtlab.zig`) pass after the fix, including a dedicated "every
config-flag combination roundtrips" test.

## Ablation (freedict + macho, whole-file, k=8192 — payload bytes, real)

| toggle changed from best | freedict payload | Δ vs best | macho payload | Δ vs best |
|---|---:|---:|---:|---:|
| **best: lex, tree, run=1, logistic, sse=1** | 542,436 | — | 2,560,964 | — |
| sort → creation-order | 599,543 | +10.5% | 2,654,193 | +3.6% |
| cm → generic | 618,709 | +14.1% | 2,869,693 | +12.1% |
| run shortcut off | 553,428 | +2.0% | 2,660,183 | +3.9% |
| mix → fixed (bzip3-style, no logistic) | 547,810 | +1.0% | 2,582,815 | +0.9% |
| SSE off | 545,102 | +0.5% | 2,564,006 | +0.1% |

Every toggle moves the same direction on both files: the lead's diagnosis
was right on both counts, and the tree CM (+12-14%) matters more than the
sort order (+3.6-10.5%), which matters more than run-shortcut/logistic/SSE
(each worth low single digits). The lex-sort win is bigger on freedict
(a dictionary, lots of near-duplicate phrase prefixes) than on macho
(binary, less lexical structure) — matches the mechanism claimed. Decode
speed note: `mix=fixed` decodes 2.4x faster than `mix=logistic` on
freedict (157ms vs 378ms) for a 1% size cost — logistic mixing is a real
but expensive lever. `cm=generic` decodes far faster than `cm=tree` (35ms
vs 378ms on freedict) at a 14% size cost, confirming the classic
size/speed trade a simpler coder buys.

## Main results: whole-file and 1 MiB blocks, best setting per cell

k in {0,256,1024,4096,8192,32768} (rule-capped) and MIN_FREQ in
{1000,200,50,16} with unlimited rules (frequency-gated grammar) — 10
grammar settings x 6 files x 2 block sizes = 120 runs, all byte-exact,
all with `enc.decisions == dec.decisions`. `total_est_B` uses 12
bits/rule; bzip3 totals are real `bin/bz3base` runs at the matching block
size.

| file | block | best setting | rules | roots | payload_B | grammar_est_B | total_est_B | bzip3 total_B | % vs bzip3 | decisions/byte | decode ms | decode MB/s |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict | 1M | k=32768 | 32,768 | 360,226 | 534,142 | 49,152 | 583,454 | 641,321 | -9.0% | 0.611 | 406 | 20.7 |
| freedict | whole | k=0 | 0 | 8,388,608 | 535,462 | 0 | 535,510 | 554,003 | -3.3% | 8.000 | 1300 | 6.5 |
| gcide | 1M | k=32768 | 32,768 | 909,698 | 1,320,943 | 49,152 | 1,370,255 | 1,421,958 | -3.6% | 1.543 | 900 | 9.3 |
| gcide | whole | k=0 | 0 | 8,388,608 | 1,220,391 | 0 | 1,220,439 | 1,243,221 | -1.8% | 8.000 | 1510 | 5.6 |
| omw | 1M | k=32768 | 32,768 | 367,876 | 330,560 | 49,152 | 379,872 | 417,761 | -9.1% | 0.392 | 229 | 36.7 |
| omw | whole | k=32768 | 32,768 | 366,909 | 303,975 | 49,152 | 353,175 | 332,331 | +6.3% | 0.364 | 198 | 42.3 |
| json | 1M | k=256 | 256 | 1,667,813 | 941,099 | 384 | 941,643 | 898,936 | +4.8% | 1.325 | 705 | 11.9 |
| json | whole | mf=1000 | 437 | 1,281,591 | 917,556 | 656 | 918,260 | 884,918 | +3.8% | 1.285 | 715 | 11.7 |
| macho | 1M | mf=16 | 33,901 | 2,266,081 | 2,643,353 | 50,852 | 2,694,364 | 2,687,953 | +0.2% | 3.050 | 2014 | 4.2 |
| macho | whole | mf=1000 | 736 | 4,807,279 | 2,558,693 | 1,104 | 2,559,845 | 2,493,160 | +2.7% | 3.470 | 2254 | 3.7 |
| zigsrc | 1M | k=32768 | 32,768 | 996,648 | 1,060,683 | 49,152 | 1,109,995 | 1,121,996 | -1.1% | 1.289 | 864 | 9.7 |
| zigsrc | whole | mf=200 | 3,001 | 2,010,609 | 1,069,564 | 4,502 | 1,074,114 | 1,037,980 | +3.5% | 1.481 | 920 | 9.1 |

(`k=0`'s numbers are byte-for-byte identical to round 1's, as expected —
`fwd_rank` is the identity permutation on a 256-symbol alphabet, so
round 2's changes are inert there; this is a useful internal
cross-check.)

## Answering the lead's question

**At 1 MiB blocks: yes, clearly, on 4 of 6 files.** freedict (-9.0% vs
bzip3, -5.3% vs this lane's own k=0), gcide (-3.6%/-1.6%), omw
(-9.1%/-28.0%!), and zigsrc (-1.1%/-8.0%) all get their *best* cell from
a rule-capped grammar (mostly k=32768) beating **both** k=0 and bzip3,
while cutting binary decisions per byte by roughly 5x to 20x (0.39-1.54
vs k=0's fixed 8). Macho ties bzip3 to within 0.2% (also via a small
grammar, mf=16, beating k=0 by 3.2%). Only json still loses to bzip3
(+4.8%), though it too beats k=0.

**At whole-file blocks: no, mostly.** Pure k=0 (no grammar at all, just
byte BWT+CM) remains the single best cell on freedict and gcide — no
amount of grammar beats *pure BWT+CM itself* there, let alone bzip3.
Small/frequency-gated grammars do beat k=0 on json/macho/zigsrc/omw at
whole-file too, but none of them beat bzip3 there (omw +6.3%, json
+3.8%, macho +2.7%, zigsrc +3.5%) — bzip3's own single-block adaptive
model is simply very strong at 8 MiB, and even a cheap grammar's fixed
12-bits/rule tax stops paying for itself at that scale as fast as it does
at 1 MiB, where the same grammar is shared across 8 blocks.

**Decoder speed, honestly**: decisions/byte drops exactly as predicted —
often by an order of magnitude — but *wall-clock* decode does not drop
by the same factor, because each `TreeCM` decision (hash lookups into two
2^20-entry tables, an optional float stretch/squash/mix, an SSE lookup)
costs more than one of `ByteCM`'s simpler fixed-point bit decisions, and
far more than bzip3's own tight C inner loop. Concretely: freedict 1M's
winning cell needs 13x fewer decisions/byte than k=0 (0.611 vs 8.0) but
decodes only 3.2x faster (406ms vs 1300ms) — real, but a fraction of the
theoretical win — and is still 2.4x *slower* than bzip3's native decoder
(406ms vs 167ms) despite coding a smaller file. The prediction/structure
half of the lead's hypothesis is vindicated by the size numbers; the
"therefore faster" half needs a much more optimized (fixed-point mixer,
no per-decision hashing into 8MB of table, likely SIMD-friendly)
implementation before it shows up in wall-clock terms — this lab's Zig
port simply hasn't earned that yet.

## Recommendation (round 2)

Block-sort with a *small, rule-capped or frequency-gated* grammar and the
fixed sort/CM earns a real place in the design **specifically at
sub-whole-file block sizes (this lab tested 1 MiB)**, where it beats both
the pure-byte fallback and bzip3 on 4-5 of 6 files by meaningful margins
(1-9%) while needing far fewer binary decisions per byte — a genuine
result, not an artifact of the round-1 sort/CM handicaps the lead
diagnosed correctly. At whole-file block size the picture reverts to
round 1's: nothing here beats bzip3, and on the two dictionary corpora
nothing here even beats plain byte-level BWT+CM. Given the main line
already targets small/moderate blocks (not one giant whole-file block),
this makes small-grammar block-sort a credible complement, not just a
fallback — worth Lane B/X checking their own real (non-order-0) coders at
1 MiB block size before ranking it against the true main line, the same
gap round 1 flagged and still open.

