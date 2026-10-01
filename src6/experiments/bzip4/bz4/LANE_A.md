# Lane A — grammar builder, lab notebook

Owner files: `grammar2.zig` (builder + A2/A4/A5 library), `gramlab.zig`
(measurement driver), this file. Binaries under `bin/`, dumps under
`dumps/a_*.b4sd`. See `PLAN.md` for the shared contract; this lane never
edits another lane's files. `gprobe.zig` was read-only input (copied, not
edited) per the contract.

## The question

gprobe's builder greedily turns every pair with frequency >= 2 into a rule
(the "full" grammar). Is that the grammar that minimises

```
cost(grammar) = sum over roots of -log2(g[s]/M)      (static order-0 root code)
              + RULE_BITS * num_rules                 (RULE_BITS = 13 default, also 10/16)
              + 2.5 bits * |{s : g[s]>0 or s is a rule}|   (root-count side info)
```

**No.** The full grammar (min_freq=2) is usually a good *local* choice but
never the global optimum, and which direction to fix it in is corpus
dependent (see A1). An MDL deletion pass that finds and removes net-harmful
rules recovers most of the available gain **without any per-corpus
parameter** and is nearly free to run (tens of ms on an 8 MiB file). An
optimal DP re-parse adds a further, smaller, but much more expensive gain
on some files and correctly no-ops on others. Full results below.

## What was built

- **`grammar2.zig`**: `build()` is gprobe's algorithm (rounds of
  role-consistent pair families, block barriers respected) generalised
  with `BuildOpts{ min_freq, alpha_percent, priority, fast_count }`.
  - `Priority.freq` = gprobe's original rule (A1).
  - `Priority.saving` = rank candidates by estimated bit savings, not raw
    frequency (A3).
  - `fast_count` = A6 speed-up: flat 65536-entry array for the round-0
    byte-pair count (no hashing at all while every symbol is still a raw
    byte), and hash tables in later rounds sized to the *previous* round's
    distinct-pair count instead of `2 * live_len`.
  - `mdlDelete()`: A2, the deletion pass.
  - `optimalReparse()`: A4, the DP re-parse.
  - `objective()` / `costOf()`: the exact cost formula above, plus an
    `est-deftree` variant for A5.
  - `verifyExact()`: expands every block's roots and compares to the raw
    file, byte for byte, block by block (no rule may span a barrier). Run
    after every mutation, every time, no exceptions — see "rules of
    evidence" in `PLAN.md`.
- **`gramlab.zig`**: for each (file, block) builds A1 (sweep min_freq in
  {2,3,4,6}), A3, A2 on top of both A1(mf=2) and A3, A4 on top of whichever
  is best so far, verifies exactness at every step, prints one TSV row per
  variant, and writes the best grammar found to
  `dumps/a_<file>.<block>.best.b4sd` (same B4SD format gprobe uses).

Both compile clean under `zig build-exe -O ReleaseFast` (Zig 0.16, std
only, no warnings).

## Full results

All 12 required (file, block) combinations ran; every grammar in every row
below passed `verifyExact`. Total wall time for the entire suite (12
combos x 9 variants each) was **2:08** on the shared machine — indicative
only, per PLAN's rules of evidence.

### A1: does growing until no pair repeats (min_freq=2) minimise the objective?

`est_rb13` (bytes) as min_freq varies, alpha=50 fixed, block=65536:

| file | mf=2 | mf=3 | mf=4 | mf=6 | best of sweep |
|---|---:|---:|---:|---:|---|
| freedict.eval8 | 652,035 | 671,546 | 685,423 | 705,403 | **mf2** |
| gcide.eval8 | 1,513,669 | 1,538,270 | 1,561,099 | 1,599,342 | **mf2** |
| omw.eval8 | 399,638 | 441,748 | 485,717 | 571,949 | **mf2** |
| macho.eval8 | 2,824,077 | 2,995,721 | 3,077,989 | 3,338,387 | **mf2** |
| zigsrc.eval8 | 1,241,599 | 1,380,468 | 1,453,171 | 1,572,990 | **mf2** |
| json.eval8 | 1,178,976 | 1,157,190 | 1,150,544 | **1,143,660** | **mf6** |

For every dictionary/text/code file, min_freq=2 (the full grammar) *is*
better than any coarser threshold in the sweep — raising min_freq only
throws away rules that were, on net, worth their overhead. But for
`json.eval8` the trend **reverses**: mf6 beats mf2 by 3.0%. JSON's
repetition is dominated by a few very hot, short structural tokens (`":`,
`",`, digit runs); once those are captured, the long tail of pairs that
occur exactly 2-3 times cost more in RULE_BITS+2.5 than they save in root
bits. So **the right min_freq is corpus-dependent** and no single fixed
value is a free lunch — exactly the failure mode the task asked us to
find. (This is also why PLAN's own idealised table, min_freq=2 only,
looked uniformly good: it only ever tested dictionary corpora.)

### A2: MDL deletion (the fix that needs no per-corpus knob)

Method: score every rule that is structurally safe to delete (nobody's
child — deleting it can't break the binary-DAG invariant) by the *exact*
isolated effect on the objective of splicing its root occurrences back to
its two children, using the identity `sum_s -c_s log2(c_s/M) = M log2 M -
sum_s c_s log2 c_s` (see "what failed" below for why this had to be
exact, not an average-bits approximation). Rank by benefit, then binary-
search-by-halving the ranked prefix against the *real* recomputed
objective (individually-profitable deletions still interact — several can
dump their occurrences onto the same child) and only ever commit a prefix
that provably lowers the real cost. Repeat in rounds (deleting a rule can
free up its own children) until nothing helps. Compaction renumbers rule
ids, preserving child-before-parent order.

Applied on top of both A1(mf=2) and A3:

| file (block=65536) | rules deleted | rounds | est_rb13 before -> after | A2 wall time |
|---|---:|---:|---|---:|
| freedict.eval8 | 8,527 (a3 base) | 4 | 647,007 -> 642,525 | 18.8 ms |
| gcide.eval8 | 20,364 (a3 base) | 4 | 1,501,323 -> 1,491,098 | 50.4 ms |
| omw.eval8 | 1,228 (a3 base) | 4 | 389,478 -> 388,897 | (fast, <5ms) |
| omw.untouched | 488 (a1 base) | 4 | 70,212 -> 69,988 | (fast, <5ms) |
| json.eval8 | 44,851 (a3 base) | 8 | 1,172,409 -> 1,104,234 | 35.1 ms |
| macho.eval8 | 44,477 (a3 base) | 8 | 2,805,782 -> 2,762,722 | 116.3 ms |
| zigsrc.eval8 | 8,669 (a3 base) | 7 | 1,232,662 -> 1,227,395 | 44.0 ms |

A2 **always helped, on every file, in both directions of A1's sweep
result** — it recovers essentially all of the mf2-vs-mf6 gap on
`json.eval8` (1,104,234 after A2, vs 1,143,660 for the *best hand-tuned*
min_freq) **without ever being told the corpus was JSON**. That is the
headline result of this lane: you don't need to guess min_freq per
corpus; build the full grammar and let deletion prune it back.

### A3: saving-priority pair selection vs raw frequency

Ranking round-candidates by `count*(bits(a)+bits(b)-bits_new) - 13` instead
of raw `count` (still subject to the same per-round role-consistency
constraint) changes *which* pairs win ties for shared symbols within a
round, which cascades into a measurably different final grammar:

| file (block=65536) | a1 (freq) est_rb13 | a3 (saving) est_rb13 | delta |
|---|---:|---:|---:|
| freedict.eval8 | 652,035 | 647,007 | -0.77% |
| gcide.eval8 | 1,513,669 | 1,501,323 | -0.82% |
| omw.eval8 | 399,638 | 389,478 | -2.54% |
| macho.eval8 | 2,824,077 | 2,805,782 | -0.65% |
| zigsrc.eval8 | 1,241,599 | 1,232,662 | -0.72% |
| json.eval8 | 1,178,976 | 1,172,409 | -0.56% |

Saving-priority beats frequency-priority on every file tested, for free
(same asymptotic build cost — it only adds one more O(live) tally pass per
round). It stacks with A2 (see `a3+a2` rows in the TSV): A2 on top of A3
consistently beat A2 on top of A1 too.

### A4: optimal DP re-parse

Method: materialise every rule's expansion (skip any longer than 256
bytes, and anything built from a skipped rule — a bounded approximation),
insert all of them plus the 256 literal bytes into a byte trie, then run a
shortest-total-code-length DP over each block's raw bytes against the
*current* per-symbol static code lengths, backtrack to get a new root
tokenisation, recount, and repeat (up to 3 times). Applied to whichever of
{a1+a2, a3+a2} was best per file:

| file (block=65536) | before (best-so-far) | after A4 | gain | A4 wall time |
|---|---:|---:|---:|---:|
| freedict.eval8 | 642,525 | 628,252 | 2.22% | 8.17 s |
| gcide.eval8 | 1,491,098 | 1,454,443 | 2.46% | 3.39 s |
| json.eval8 | 1,104,234 | 1,078,937 | 2.29% | 2.17 s |
| macho.eval8 | 2,762,722 | 2,734,477 | 1.02% | 11.6 s |
| omw.eval8 | 388,897 | 388,897 | 0% (rejected) | fast |
| zigsrc.eval8 | 1,227,395 | 1,227,395 | 0% (rejected) | fast |

A4 gives a real further 1-2.5% on about half the files and correctly
**does nothing** (safe no-op, verified) on the other half rather than
regressing — see "what failed" for why that safety check is load-bearing.
It is also by far the most expensive idea here: 2-12 **seconds** per 8 MiB
file vs 20-120 **milliseconds** for A2, and often longer than the entire
build. The cost is almost all trie construction/lookup via
`std.AutoHashMap` per edge; a real Aho-Corasick with array transitions (or
a smaller length cap) would likely cut this 5-10x, but at that point A2's
cost/benefit ratio is hard to beat.

### A5: structural rules and the DEF-tree accounting

Rules that are used exactly once (single parent) and never appear as a
root are pure structural filler under the naive `RULE_BITS`-per-rule
charge, but a real DEF-tree encoder (walk rules in an order, `DEF
emit(left) emit(right)`) would code such a rule as roughly a 1-bit "yes,
inline here" flag, not a full id pair. `est-deftree` charges those rules
1.5 bits instead of RULE_BITS:

| file | rules | trivial (single-parent, g=0) | est_rb13 | est-deftree | saved |
|---|---:|---:|---:|---:|---:|
| freedict.eval8 | 69,771 | 9,842 (14.1%) | 652,035 | 637,887 | 2.2% |
| gcide.eval8 | 124,584 | 7,485 (6.0%) | 1,513,669 | 1,502,909 | 0.7% |
| omw.eval8 | 107,335 | 61,016 (**56.8%**) | 399,638 | 311,928 | **21.9%** |
| omw.untouched | 18,021 | 8,550 (47.4%) | 70,220 | 57,929 | 17.5% |

OMW's grammar is *dominated* by rules that fire exactly once as a
structural intermediate and never recur as a root — for OMW, a real
DEF-tree/structural encoder (Lane B's remit) is worth far more than
anything in this lane. Full per-(file,block) numbers are in the TSV
(`trivial_rules` and `est_deftree` columns).

### A6: builder speed

Flat 65536-entry array for the round-0 byte-pair count (no hashing while
every live symbol is still a raw byte) plus sizing later rounds' hash
tables off the *previous* round's actual distinct-pair count (`table.used`)
instead of `2 * live_len`:

| file (block=65536) | fast_count=true | fast_count=false | speedup |
|---|---:|---:|---:|
| freedict.eval8 | 563 ms | 824 ms | 1.46x |
| gcide.eval8 | 1,086 ms | 2,122 ms | 1.95x |
| omw.eval8 | 554 ms | 1,419 ms | 2.56x |
| json.eval8 | 810 ms | 1,501 ms | 1.85x |
| macho.eval8 | 3,406 ms | 6,158 ms | 1.81x |
| zigsrc.eval8 | 1,560 ms | 2,231 ms | 1.43x |

~1.4-2.6x faster (indicative, shared machine), all producing byte-identical
grammars to the unoptimised path (same selection logic, only the counting
data structure changed). Not attempted: recounting only where the
sequence changed between rounds (the builder's own compaction pass already
touches most of the live array after round 1, so the expected win looked
small relative to the implementation risk given the time budget).

## What failed and why (read before reusing this code)

1. **First MDL deletion attempt was badly wrong in the harmful direction**:
   scoring a candidate rule's children by their *current* per-occurrence
   cost `-log2(g[child]/M)`, falling back to an arbitrary
   `-log2(0.5/M)` when a child had zero current root occurrences (common —
   many children are themselves purely-structural rules). That fallback
   systematically over-stated the benefit of deleting almost every
   candidate (17,199 of 18,021 rules on `omw.untouched`!), and applying
   them all at once roughly **quadrupled** the estimated cost
   (70,220 -> 282,025 bytes) before the fix. Root cause: deleting a rule
   changes the *total* root count M, and `-log2(c/M)` for every other
   untouched symbol quietly gets a hair more expensive too — summed over
   ~M occurrences that is not negligible. Fixed by using the exact
   identity `root_bits = M log2 M - sum_s c_s log2(c_s)` (so `f(0)=0`
   handles the zero-count case exactly, no fallback needed, and the global
   `M log2 M` term is accounted for). After the fix, single-rule benefit
   estimates matched a from-scratch recount to within floating-point
   noise, and the same file now shows a real, small, verified gain
   (70,220 -> 70,014 bytes) instead of a 4x regression.
2. **Even with the fixed formula, applying every individually-profitable
   deletion in one batch can still regress**, because many rules can
   route their occurrences onto the *same* shared child, and each
   candidate's isolated projection assumes it's the only change. Fixed
   with a cheap simulate-and-compare safety net: rank by benefit, try the
   full ranked prefix, halve it until a prefix actually lowers the real
   recomputed objective (or accept nothing). Not a true largest-good-
   prefix search (that would need true binary search under a monotonicity
   assumption that isn't guaranteed) but simple, `O(log n)` simulations
   per round, and safe by construction.
3. **A4's DP regressed on the very first iteration** on some files
   (e.g. `omw.untouched`, 70,014 -> 75,531 bytes) despite being a
   textbook-correct shortest-path re-parse. This is not a bug: the DP
   minimises `sum(bits[s])` for a *fixed* code-length table taken from the
   grammar's own current parse, but the reported objective recounts a
   fresh table from whatever tokens the DP actually chose — a classic
   chicken-and-egg problem (the code lengths depend on the parse being
   chosen). A parse that's optimal for yesterday's frequencies can easily
   be worse once you honestly recount. Fixed the same way as #2: compute
   the real objective after every iteration and stop (keeping the last
   good state) the moment an iteration doesn't help, rather than trusting
   the DP's own optimality claim past the first recount.
4. **Not attempted / left for a follow-up lane**: a true Aho-Corasick
   automaton with array transitions for A4 (would likely make the DP
   5-10x cheaper, per the profiling above); recount-only-changed-regions
   for A6; combining A3's saving-priority ranking *inside* the same round
   as A2's deletion (currently A2 always runs as a separate post-pass).

## Best grammar per (file, block)

Written to `dumps/a_<file>.<block>.best.b4sd` (binary rules, children ids
< parent id, per-block root streams — identical layout to gprobe's dumps).
Every one passed `verifyExact` before being written.

| file | block | best variant | est_rb13 bytes |
|---|---:|---|---:|
| freedict.eval8 | 65536 | a3+a2+a4 | 628,252 |
| freedict.eval8 | 16384 | a3+a2+a4 | 630,440 |
| freedict.untouched | 65536 | a1_mf2+a2+a4 | 93,608 |
| gcide.eval8 | 65536 | a3+a2+a4 | 1,454,443 |
| gcide.eval8 | 16384 | a3+a2+a4 | 1,456,071 |
| gcide.untouched | 65536 | a1_mf2+a2+a4 | 203,721 |
| omw.eval8 | 65536 | a3+a2 | 388,897 |
| omw.eval8 | 16384 | a3+a2 | 395,060 |
| omw.untouched | 65536 | a3+a2 | 69,988 |
| json.eval8 | 65536 | a3+a2+a4 | 1,078,937 |
| macho.eval8 | 65536 | a3+a2+a4 | 2,734,477 |
| zigsrc.eval8 | 65536 | a3+a2 | 1,227,395 |

Overall, baseline (a1, min_freq=2) -> best: **+1.1% to +8.5%** smaller
under the objective, with a median around **+3%**, for a combined cost of
tens of milliseconds (A2+A3, essentially free) plus, optionally, a few
seconds (A4, worth it on about half the files tested).

Raw TSV (12 combos x 9 variant rows = 106 lines, header included) was
produced by `bin/gramlab` on this run; re-run it to regenerate — it is
deterministic (two independent runs produced byte-identical rules/roots/
cost columns, confirmed diff-clean).
