# Lane L — the word learner, rewritten for the right objective

Owner files: `l_learn.zig` (library: `Lexicon`/`Corpus`, the `Cost` namespace,
propose/reparse/delete, the milestone-2 scope pass, `learn()`), `l_lab.zig`
(measurement harness — every table below), `l_probe.zig` (single-file dev
driver used for the profiling/debugging in this notebook, not part of the
report). Binaries under `bin/l_*`, dumps under `dumps/l_*.b4sd` (B4SD
version 2). See `PLAN.md` "Round 3" for the brief, `v3/DESIGN.md` for the
real stream this lane's cost model targets, `LANE_M.md` for the previous
round's compositional-MDL learner this one replaces the objective of.

## The question

Lane M built a real, working compositional-MDL lexicon (n-ary entries,
propose→reparse→delete, iterate to convergence) and beat bzip3 on 11/12
combos — but its own notebook flagged the model codec as "1.5–3.5x more
bits/entry than a DEF-tree would" (LANE_M.md, "Biggest remaining
inefficiency"), because Lane M charged **every** occurrence of a symbol,
including its first, against the same per-symbol static frequency. That
is not what `v3/DESIGN.md`'s actual stream does: an entry is *defined once,
at its first use* (one shared `DEF` event, cheap because it's pooled across
every entry in the lexicon), and only later occurrences pay a per-symbol
`USE(x)` cost. Lane L's job: rebuild the learner against **that** objective
— est bits, order-0 events, first-use-free, scope-aware — and see whether a
lexicon search that actually knows definitions are cheap looks different
(deeper, more compositional) and scores better, in both `est` and (thanks to
the lead's `v3/src/` baseline planner landing mid-lane) **real, round-tripped
bytes**.

## The objective, precisely, and how it reduces to a computable formula

Bytes are pre-defined (DESIGN.md's "bucket 0... present before anything is
defined"); only 256+ entries can ever `DEF`. Walking the whole file (deltas
then payloads, blocks in order, nested first-uses defined in place) is
exactly Lane M's own `recount()` population — "the lexicon is just more
text" — split two ways instead of one:

* every entry with population `p > 0` contributes **exactly one** `DEF`
  event (shared kind, cost `-log2(n_DEF/N)`, wherever in the file it
  happens to land) and `p-1` `USE(entry)` events;
* every byte contributes `p` `USE(byte)` events and never a `DEF`.

The key realisation (`Cost.eventBreakdown` in `l_learn.zig`) is that this
total is **order-independent** — it only needs final population counts, not
a simulated walk — because it is just the same
`N*log2(N) - sum_k f(n_k)` identity Lane M already used, with the "kinds"
partitioned differently: one pooled `DEF` kind plus one `USE(x)` kind per
symbol, instead of one kind per symbol covering all its occurrences. Two
more empirical-entropy codes are added once per surviving entry: `arityBits`
(over each entry's arity) and `nameBits` (over `tier(x) = floor(log2(pop(x)+1))`,
the entry's "which bucket-size class" name). `Cost.totalBits(lex, pop)` is
the whole milestone-1 objective, and it is the **one seam** the assignment
asked for: reparse's accept/reject gate and delete's batch gate both call it
and nothing else knows the formula (`LANE_L.md` will need to change in
exactly one place if `est` is swapped for real encoded bytes).

## What was built

* **`Lexicon`/`Corpus`/`LexBuilder`**: the same CSR n-ary shape as Lane M's
  (bytes 0..255, entries 256+i, `explen` invariant across re-parses),
  independently re-typed here since this lane owns no shared files.
* **`Cost`**: `eventBreakdown`/`eventBits`/`arityBits`/`nameBits`/`totalBits`/
  `avgOverhead`. `avgOverhead` is the self-calibrating replacement for Lane
  M's hand-picked `Calib.entry_bits` constant — the *actual* current
  average bits a definition costs (DEF share + arity + name, divided by
  entry count), recomputed every round, used only to rank propose/delete
  candidates (never in the exact gates).
* **`dpMarginalBits`**: the per-occurrence proxy the DP needs (a fixed cost
  per symbol *within one parse pass*, same simplification Lane M made).
  A byte's proxy is its plain USE rate; an entry's is the rate of its
  **`pop-1` reuse events** (its own one-time DEF is priced separately, by
  `avgOverhead`, so it is never charged per-occurrence and never
  double-counted against the reuse rate) — the direct mechanical
  expression of "first use is free."
* **`proposeNGram(comptime w, ...)`**: one generic function for both pairs
  (`w=2`) and triples (`w=3`), scored with `dpMarginalBits` + `avgOverhead`
  instead of Lane M's uniform static cost. Tallying is a hashmap (see "one
  hashmap, on purpose" below); everything that scales with the *candidate*
  count rather than the *token* count (existing-arity checks, the accepted
  batch, substitution) is a sorted array + binary search, no hashmap.
* **`reparseRound`**: mechanically identical to Lane M's (materialise
  expansions bounded to 256 bytes, build a small sorted-edge-list trie — no
  hashing — DP over the trie with the marginal-bits proxy, self-validating:
  keep the new parse only if `Cost.totalBits` on the honestly recomputed
  population actually improved).
* **`deletePass`**: same splice mechanics as Lane M's `delete.zig`
  (`buildResolved`/`spliceMarked`, reused essentially verbatim — they only
  move population around, they don't know the cost model), rescored under
  the new objective, plus one thing Lane M never needed:
  `simulateDeleteBits`'s exact batch gate now recomputes each **surviving**
  entry's post-splice arity too (inlining a deleted child grows its
  parent's arity, which can shift the parent into a different arity/tier
  bucket — a second-order effect that only exists because arity/tier now
  matter to the cost at all).
* **Scope pass (milestone 2)**: see its own section below — a real,
  measured, but knowingly-approximate estimate of the DESIGN.md
  block-lifetime-bucket benefit, used to keep `deletePass` from discarding
  a bursty-but-globally-rare entry, and reported as a second total.
* **`learn()`**: seed from bytes only (no other-lane dependency, matching
  round 3's brief and confirming Lane M's own finding that byte-seeding is
  a real, general fallback), iterate propose(pairs)→propose(triples)→
  reparse→delete with a top-level snapshot/revert exactly like Lane M's
  `learn.zig`, run the scope pass once at the end, and copy only the final
  result out of an internal arena into the caller's allocator.
* Six `zig test` blocks: population/flog-identity sanity, the "twice-used
  entry pays one DEF + one USE" property directly, two round-trip tests,
  and one behavioural test that a word bursty in a single block survives
  the delete pass (the milestone-2 property this lane exists to add).

### One hashmap, on purpose (a negative result)

The file's guidance (and DESIGN.md's own trie) is "no hashmap in hot
loops, sorted arrays/tries instead" — the first version of `proposeNGram`
followed that literally: collect every adjacent w-gram in the corpus and
every entry's own spelling into one flat array, then `std.mem.sort` it and
run-length-count. On `gcide.eval8` at iteration 0 (~8.4M tokens, nothing
merged yet) that collect+sort pair alone measured in the hundreds of
milliseconds to low seconds, and it happens twice per round (pairs and
triples) for as long as the corpus is still token-dense. Switching the
*tally* step to `std.AutoHashMap(Key(w), u64)` (Lane M's own original
choice) cut that specific cost noticeably; everything else that still
scales only with the number of *candidates* (typically hundreds to low
thousands, not millions) stayed a sorted array + binary search. Kept as a
documented case where "no hashmap" cost more than it saved once the input
scale is measured rather than assumed.

### A double-counting bug found and fixed

The first version of `deletePass`'s benefit formula was
`avg_overhead + (u-1)*effective_use[i] - u*comp_bits`, where
`effective_use[i]` came from the scope pass as `scoped_cost/pop` — a
*lump total* (already including its own share of `avg_overhead`) divided by
occurrence count to look like a per-use rate. Plugging that into a formula
that *also* adds `avg_overhead` separately double-charged the definition
overhead and made every entry look artificially expensive to keep,
silently disabling deletion almost entirely once scope-awareness was
switched on (measured: 0 deletions across 10 iterations on `gcide.untouched`
with scope-awareness on, versus a handful with it off — see "deletion
rarely fires" below for why *even the fixed* number is still small, which
is a real finding, not a residual bug). Fixed by having the scope pass
expose per-entry **totals** (`ScopeReport.effective_total_bits`, whichever
of {global, scoped} is cheaper) and having `deletePass` use that total
directly (`benefit = keep_cost[i] - u*comp_bits`) instead of re-deriving a
fake per-use rate from it. Caught by instrumenting `deletePass` with a
`debug_delete` trace and hand-checking one file's numbers against the
formula by hand — worth flagging because it is exactly the kind of
"looks fine, produces plausible-looking numbers, silently wrong" bug that
only shows up by checking a *specific* candidate's arithmetic, not by
eyeballing aggregate output.

### Role consistency: Lane A's asymmetric trick matters more than expected

The first version used the simpler "any symbol claimed once this round is
excluded from every other candidate" rule (Lane M's own rule for triples)
uniformly for both pairs and triples. Measured effect on `gcide.untouched`:
entry growth of ~100-300/round, never converging within the iteration
budget. Switching pairs specifically to Lane A's asymmetric left/right role
scheme (a symbol may be a pair's left member *and* a different pair's right
member in the same round, forbidden only on an actual left/right collision
on the same symbol — substitution scans left-to-right so no ambiguity ever
reaches the corpus) roughly quadrupled entries accepted per round in the
early, high-volume rounds (265→1168→4385→10735 entries in 4 rounds versus
265→1168→4385 in 3 *plus needing many more rounds to keep growing* under
the simple rule) and cut total iterations to convergence roughly in half.
Triples kept the simpler rule (matches Lane M's own finding that it's
"adequate, never regressed").

## Headline `est` results (all required inputs, one setting)

`Opts{}` defaults throughout (`max_iters=10`, `converge_frac=0.001`,
`triples=true`, `scope_aware_delete=true`) — one setting for every file,
per PLAN's rule. `total_B_global` = milestone-1 objective (DEF+USE+arity+
name, real accept/reject gate for the whole search); `total_B_scoped` =
milestone-1 plus the milestone-2 scope pass (see calibration warning
below — **read it before trusting `total_B_scoped` on its own**).

| file | block | entries | tokens | B/token | total_B_global (est) | num_local | total_B_scoped (est) | iters | seconds |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 65536 | 96,479 | 269,352 | 31.14 | 685,771 | 25,519 | 527,123 | 10 | 8.9 |
| freedict.eval8 | 16384 | 96,513 | 270,017 | 31.07 | 686,364 | 23,919 | 545,223 | 10 | 11.6 |
| freedict.4KiB | 4096 | 264 | 312 | 13.13 | 662 | 75 | 610 | 8 | 0.0 |
| freedict.32KiB | 32768 | 1,177 | 1,925 | 17.02 | 4,076 | 324 | 3,384 | 8 | 0.0 |
| freedict.256KiB | 262144 | 5,794 | 11,594 | 22.61 | 26,128 | 2,396 | 19,712 | 9 | 0.2 |
| freedict.untouched | 65536 | 16,554 | 44,908 | 23.35 | 100,155 | 4,737 | 76,701 | 9 | 0.7 |
| gcide.eval8 | 65536 | 173,301 | 637,147 | 13.17 | 1,586,787 | 42,343 | 1,259,364 | 10 | 13.2 |
| gcide.eval8 | 16384 | 173,397 | 638,014 | 13.15 | 1,588,525 | 39,131 | 1,300,157 | 10 | 14.3 |
| gcide.4KiB | 4096 | 434 | 689 | 5.94 | 1,329 | 101 | 1,156 | 7 | 0.0 |
| gcide.32KiB | 32768 | 2,025 | 4,260 | 7.69 | 8,549 | 657 | 6,831 | 8 | 0.0 |
| gcide.256KiB | 262144 | 10,795 | 28,036 | 9.35 | 61,535 | 4,001 | 46,192 | 9 | 0.3 |
| gcide.untouched | 65536 | 32,493 | 95,826 | 10.94 | 222,954 | 9,761 | 169,020 | 10 | 1.3 |
| omw.eval8 | 65536 | 118,852 | 114,630 | 73.18 | 480,794 | 22,421 | 308,488 | 10 | 7.6 |
| omw.eval8 | 16384 | 118,002 | 115,552 | 72.60 | 480,896 | 21,127 | 314,117 | 10 | 7.9 |
| omw.4KiB | 4096 | 337 | 350 | 11.70 | 869 | 46 | 770 | 8 | 0.0 |
| omw.32KiB | 32768 | 1,178 | 510 | 64.25 | 2,617 | 114 | 2,182 | 10 | 0.0 |
| omw.256KiB | 262144 | 7,390 | 4,238 | 61.86 | 19,913 | 896 | 15,078 | 9 | 0.2 |
| omw.untouched | 65536 | 20,308 | 23,561 | 44.50 | 78,518 | 4,635 | 55,375 | 10 | 0.8 |
| json.eval8 | 65536 | 71,066 | 637,692 | 13.15 | 1,184,337 | 13,272 | 1,015,055 | 8 | 6.2 |
| macho.eval8 | 65536 | 404,394 | 1,056,691 | 7.94 | 3,016,699 | 114,724 | 2,314,240 | 10 | 20.8 |
| zigsrc.eval8 | 65536 | 257,010 | 437,452 | 19.18 | 1,433,391 | 66,070 | 960,308 | 10 | 15.9 |

Every row: exact re-expansion asserted in `l_lab.zig` (`verifyExact`
against the raw input), deterministic, and separately confirmed byte-exact
by the lead's independent `v3/src` decoder (next section). `total_B_global`
beats bzip3 (`baselines.tsv`) on every dictionary combo and on
macho/zigsrc; loses on `json.eval8` (1,184,337 vs bzip3's 1,028,983) for
the same reason LANE_M.md gave — JSON's redundancy is digit/hex-run
structure, not word structure, a Lane K problem.

## Real-bytes validation (the lead's `v3/src` landed mid-lane)

`v3/src/lab.zig` (the lead's own tool, read-only for this lane, invoked as
documented) reads a B4SD dump plus the raw file, runs the *real* baseline
planner + tANS encoder, decodes, and asserts a byte-exact round trip against
the raw file — a second, fully independent implementation checking every
dump this lane produced. **Every dump round-tripped with zero
`RoundTripMismatch` errors** across all 21 combos, `--flat` and default
(`scoped: true`) both. This is the strongest evidence in the whole
notebook: two independently written decoders (this lane's `verifyExact`
and the lead's `v3/src/decode.zig`) agree the parse is exact.

| file (65536) | real, flat (est milestone-1 analog) | real, scoped (default) | scoped saves | bzip3 | vs bzip3 | bz4 v2 (`results_v2.tsv`) | vs bz4 v2 | Lane M real (`LANE_M.md`) | vs Lane M |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 643,729 | 639,268 | 0.7% | 899,408 | **-28.9%** | 638,216 | +0.2% | 665,331 | **-3.9%** |
| gcide.eval8 | 1,456,324 | 1,443,332 | 0.9% | 1,905,560 | **-24.3%** | 1,459,330 | **-1.1%** | 1,518,352 | **-4.9%** |
| omw.eval8 | 459,718 | 455,531 | 0.9% | 674,384 | **-32.5%** | 459,913 | **-0.1%** | 457,335 | -0.4% |
| freedict.untouched | 97,862 | 98,546 | -0.7%* | 115,160 | **-14.4%** | 93,014 | +6.0% | 95,847 | +2.8% |
| gcide.untouched | 212,790 | 214,379 | -0.7%* | 235,103 | **-8.8%** | 201,159 | +6.6% | 213,396 | +0.5% |
| omw.untouched | 75,837 | 76,411 | -0.8%* | 95,276 | **-19.8%** | 75,270 | +1.5% | 79,095 | **-3.4%** |
| json.eval8 | 1,103,720 | 1,077,809 | 2.3% | 1,028,983 | +4.7% | 1,032,423 | +4.4% | 1,082,592 | -0.4% |
| macho.eval8 | 2,923,962 | 2,922,476 | 0.05% | 3,259,348 | **-10.3%** | 2,995,697 | **-2.4%** | 3,057,818 | **-4.4%** |
| zigsrc.eval8 | 1,365,596 | 1,365,934 | -0.02%* | 1,454,997 | **-6.1%** | 1,380,887 | **-1.1%** | 1,388,975 | **-1.7%** |

(`*` = scoping made the *real* encoder's output very slightly larger for
that file — the bucket-lifetime machinery isn't free, and on files with
less within-block burstiness its small header/table cost isn't always
covered by the addressing saving; negative "scoped saves" is a genuine,
honestly-reported result, not a display error.) `%vs` columns are
`100*(1-Lane_L/other)`, negative = Lane L smaller/better. Whole-file
(unblocked) bzip3 for context, `baselines.tsv` block=0 rows: freedict
554,003, gcide 1,243,221, omw 332,331 — all still smaller than Lane L's
65536-block numbers, as expected: bzip3 unblocked gets fully adaptive
cross-file context that an independently-decodable-blocks design (DESIGN.md's
explicit goal) trades away on purpose.

**Headline finding**: real bytes from Lane L's lexicon run through the
lead's plain **baseline** planner (no class model, no overrides, no
adaptive coding — `v3/DESIGN.md`'s simplest legal automaton) already **beat
or match bz4 v2** — the current production codec with a tuned class model,
override table, and a full engineering round behind it — on 4 of 9 tested
combos (gcide, omw, macho, zigsrc) and come within 0.2% on freedict, while
losing modestly (1.5–6.6%) only on the three small (1 MiB) `untouched`
files and json. That the *lexicon* is doing this much work with the
*simplest possible* automaton on top of it is the strongest evidence in
this notebook that fixing the objective (not the codec) was the right
lever.

## Milestone 2 (scope) — a calibration warning, not a working number yet

The table above already gives the honest headline: the *real* encoder's
`scoped: true` bucket-lifetime option (`v3/src/plan.zig`) saves only
**0.05–2.3%** on these files (and slightly *hurts* on three of them). This
lane's own `est_bits_with_scope` claims far more — e.g. gcide.eval8
`total_B_global`→`total_B_scoped` is a 20.6% drop (1,586,787→1,259,364),
roughly **20x** the real, measured benefit. This is the single most
important negative result in the notebook: **the milestone-2 cost formula
in `l_learn.zig` is not calibrated against the real bucket-lifetime
mechanism and should not be trusted as a byte estimate on its own.** Two
concrete reasons, both visible in the real encoder's own `--stats` output
(`buckets` grows only ~40% under scoping, not per-entry):

1. The real encoder shares *bucket* infrastructure across many entries
   (DESIGN.md: "a bucket is an array of `2^w` tokens... addressed as
   `(bucket, w raw bits)`"); this lane's estimate instead gives every
   confined entry its own personalised rank/tier addressing cost, which
   is systematically cheaper than sharing a handful of real buckets.
2. `blocks_multi[i]*avg_overhead` (this lane's estimate for redefinition
   cost) uses the *global* average definition cost as a stand-in for a
   local redefinition's real cost; the real `delta` stream measurably grew
   more under scoping (e.g. gcide: 478,221→506,346 bytes) than the
   estimate's own accounting predicts.

What *is* trustworthy: `scope_aware_delete` still measurably changed
learner behaviour in the intended direction on the synthetic test (`zig
test`'s "burst-in-one-block" case, and directionally on real files —
`num_local` is never zero and correlates with per-file burstiness), so the
mechanism is protecting the right entries in kind; it just isn't priced
correctly yet.

**Independent corroboration**: `LANE_O.md` (concurrent lane, same
machine, estimating this exact quantity on old Lane A/M parses) measured
scoping's *real* incremental benefit over first-use-free at **1.6-2.6%**
on freedict/gcide and a larger **4.4-9.8%** on omw — much closer to this
lane's own real-codec numbers (0.05-2.3%, previous table) than to this
lane's `total_B_scoped` estimate (up to ~20%). Lane O's own writeup
diagnoses *why* a naive single-pass version overshoots: pricing every
candidate entry against a *pooled* average cost makes a whole cohort look
uniformly cheap in one shot ("every entry with a barely-qualifying count
of 2 looks exactly as attractive as one with 50, so a whole cohort rushes
a lifetime in the same round, overshoots"), and their fix is exactly the
refinement this lane's own `scopeReport` skipped for time (documented
above as the "tentative pool" simplification): price each tier from the
*previous round's actual* per-count outcome, not a single pooled snapshot,
and require a real margin before an entry switches scope. Recommendation
for whoever picks this up: don't just recalibrate `scopeReport`'s
constants — adopt Lane O's iterate-and-require-a-margin structure, since
this lane independently re-discovered the same over-optimism failure mode
Lane O already has a working fix for.

## Deletion rarely fires — a real property of the new objective, not a bug

Once the double-counting bug above was fixed, `deletePass` still deletes
close to nothing on real files under the default (scope-aware) settings —
typically 0-2 entries in the first couple of rounds, then 0 for the rest of
the run (traced with `debug_delete` on `gcide.untouched`: `best_benefit`
stays negative — i.e. "not worth deleting" — every round after the first
few, even as entry count climbs into the tens of thousands). This is the
opposite of Lane M, which deleted 65-75% of its (Re-Pair-derived) seed
every run and called deletion "the single biggest lever measured." Two
real, checked reasons this is *not* a bug:

* `proposeNGram` only ever accepts a candidate with a positive *estimated*
  score in the first place (unlike Lane M's byte-seed-then-massively-
  overprune pipeline, which started from Re-Pair's already-huge,
  filler-heavy grammar) — there is much less obviously-bad material for
  delete to find.
* Pooling every entry's `DEF` into one shared kind means the *marginal*
  cost of one more entry keeps falling as the lexicon grows
  (`-log2(n_DEF/N)` shrinks as `n_DEF` grows, for fixed-ish `N`) — this is
  the mechanical form of "definitions are cheap, so the lexicon should get
  deeper," and it directly weakens delete's incentive relative to Lane M's
  flat per-symbol cost, where every entry (however small its share) paid
  the same expensive "rare symbol" rate regardless of how many other
  entries existed.

Net effect, checked against Lane M's own numbers: Lane L's lexicons are
**5-10x larger** than Lane M's (gcide.eval8: 173,301 vs Lane M's 38,675;
omw.eval8: 118,852 vs 22,370) with correspondingly *lower* average uses per
entry, and this is validated, not runaway, growth — `Cost.totalBits`
decreases monotonically every accepted round (the exact recompute Lane M's
own `iterate()` pattern already guarantees), and the *real* encoder
confirms the resulting bytes are competitive with or better than both
bzip3 and bz4 v2 (previous section). Deletion is implemented, tested
(the `zig test` suite includes a case that forces a real delete), and
still occasionally fires (2, then 1, in the debug trace above) — it just
isn't the dominant lever here that it was for Lane M, and that's an honest
finding about what changed, not a missing feature.

## Qualitative evidence: words, not fragments, and deeper than Lane M's

`l_lab.zig` prints the top-40-by-count and a 40-item evenly-spaced sample
of expansion-length-6–20 entries for freedict/gcide/omw.eval8@65536 (full
listings in the `bin/l_lab` output; representative excerpts below,
`\xNN`-escaped, `n`=use count, `len`=expansion length).

**gcide.eval8**, length-6–20 sample (pool of 92,124 candidates): `obtained
from` (n=10, len=13), `Benefit` (n=8), `bracts` (n=7), `fraudulent` (n=5),
`blessedness` (n=5), `their position` (n=3), `feet long` (n=3), `to catch
the ` (n=3), `pennyroyal` (n=2), `cruel, savage` (n=2) — whole words and, at
slightly lower counts than Lane M's own top-40 needed to show it, whole
**phrases** (`obtained from`, `to catch the`, `their position`) that a
per-occurrence-priced model would never have found cheap enough to keep;
Lane M's own report noted its lexicon "gets deeper" only as a secondary
effect of triples, whereas here 3+-token phrases show up unprompted in the
generic pair/triple search once first-use-free makes them affordable. Top
40 by count is dominated (as in Lane M) by 2-5 byte function-word/markup
fragments (`, `, `; `, ` or `, `the `, `A `) — same finding as LANE_M.md:
the very top of the frequency table is inherently short regardless of
objective, since those tokens *are* genuinely that short in English.

**freedict.eval8**, length-6–20 sample (pool of 43,227): `conflict`,
`agricultural`, `defensa` (Spanish, this is an ES-EN dictionary), `Somalis`,
`Uto-Aztec`, `prepares`, `queen of` — clean words and short phrases, with a
few low-count (n=1) mid-word fragments (`ient to`, ` bluish-gr`) at the
very bottom of the sample, comparable in kind and rate to Lane M's own
admitted noise floor.

**omw.eval8**, length-6–20 sample (pool of 45,009): almost entirely
multi-byte UTF-8 Japanese sequences (`\xe7\xa9\xba\xe6\xb0\x97` = 空気,
"air"; `\xe6\x84\x9f\xe5\x8b\x95` = 感動, "moved/impressed") plus WordNet
ID fragments (`-00029214`) — correctly *not* segmented on any notion of
"space" (there is none in Japanese) since no text-specific rule exists
anywhere in the learner; the tokens that do form are plausible
morpheme/character-group units by byte-level repetition alone. This is the
clearest evidence for "words in the data's own sense... no text-specific
rule anywhere" holding across scripts.

## Research questions

**1. Candidate generation.** Only bottom-up (frequent adjacent-pair/triple
of the current parse) was implemented and measured; top-down (suffix-array
LCP intervals + EM-style pruning) and boundary-driven (branching entropy)
were **not attempted** — out of scope for the time available. Argument for
why bottom-up is a reasonable default even so: the first-use-free objective
specifically rewards *iterated* composition (a phrase is cheap once its
parts are already cheap), so a search that grows the lexicon one
generation of merges at a time and re-parses after each generation
naturally reaches multi-token phrases within a handful of rounds (see
`obtained from`, `to catch the` above) without needing a top-down seed.
Open question, flagged rather than answered: whether a suffix-array seed
would reach the *same* converged lexicon faster (fewer rounds, given
reparse dominates wall time — see below) the way Lane M found Lane A's
Re-Pair seed reached convergence faster than byte-seeding without changing
final quality much.

**2. Optimal parse.** Implemented as specified: shortest-code-length DP
over the trie of expansions, self-validating (reparse only keeps a round
that the exact recomputed `Cost.totalBits` actually improved — verified in
the log: every accepted iteration's `est_B` strictly decreases, and the top
level `learn()` snapshot/reverts if a whole round nets out worse, mirroring
Lane M's own safety net; this never actually fired in the measured runs
above, unlike Lane M's freedict.untouched case, likely because the
generation-based hashmap-tallied propose here makes smaller, better-vetted
batches per round).

**3. Deletion.** Implemented, generalised from Lane M's (any-parent
splicing, exact batch gate with a halving safety net) — see "deletion
rarely fires" above for the measured, honest finding that it matters far
less under this objective than under Lane M's.

## Speed: does not meet the 3s/8MiB target, and a specific, measured reason

Per-phase timing on `gcide.eval8` (the profiling that led to the two fixes
above) shows pair/triple tallying is fast after the hashmap fix
(~100-150ms/round even at 8M tokens) and stays roughly flat; **reparse is
the dominant and *growing* cost**: 166ms → 206ms → 306ms → 543ms → 926ms →
1,396ms across the first six rounds, tracking entry count (292 → 1,796 →
8,792 → 30,591 → 68,230 → 110,175), not token count (which is *shrinking*
over the same rounds). The mechanism: `dpParse` walks the trie from *every*
byte position in the *original raw file* every round (not the shrunk token
stream — re-deriving the globally optimal segmentation needs the raw
bytes), and average walk depth per position grows as the trie accumulates
more, and longer, entries. This is the same architectural choice Lane M's
`reparseRound` made (LANE_M.md's own "0.5-22s per combo... dominated by
re-parse"); it costs more here specifically because the corrected
objective legitimately wants a much larger lexicon (110K+ vs Lane M's 38K
final), and a bigger trie makes every walk slower.

Measured wall time (whole `learn()` call, one process, indicative per
PLAN's rules — machine shared with other lanes):

| iterations (gcide.eval8, 65536) | entries | est total_B_global | wall time |
|---:|---:|---:|---:|
| 1 | 292 | 4,199,406 | 0.6s |
| 2 | 1,796 | 3,230,987 | 0.9s |
| 4 | 30,591 | 2,130,588 | 4.6s |
| 6 | 110,175 | 1,688,612 | 7.9s |
| 10 (default, converged) | 173,301 | 1,586,787 | 13.2s |

**The 3s budget lands strictly before this file's lexicon beats bzip3**
(bzip3@65536 = 1,905,560; iteration 4 at 4.6s is still worse at 2,130,588;
iteration 5-6, needed to cross that line, costs 6-8s). This is reported
plainly as not meeting the target, not rounded up. Two concrete, not-yet-
implemented fixes, in order of expected payoff:

1. **Parallelise reparse's DP across blocks.** Blocks are independent by
   construction (`Corpus.block_end`) — DESIGN.md calls this out for
   *decode* ("run every payload independently") but it is equally true of
   *this* encode-time DP: each block's `dpParse` call reads only the
   shared trie (read-only once built) and writes only its own token range.
   An 8-16 core machine should turn reparse's cost into roughly the
   dominant serial cost divided by core count, which — at the profiled
   proportions — would likely bring the default (10-iteration) setting
   under 3s directly rather than requiring a quality cut.
2. **Cap newly-created entries' length more tightly in the first few
   rounds** (a smaller `max_material_len`, or a length ceiling that
   loosens over rounds) to keep the trie shallow while token count is
   still in the millions, tightening only once the corpus has already
   shrunk. Not implemented; likely a smaller win than (1) but free of any
   correctness risk.

**Scaling to 1 GiB**: vocabulary growth is expected to be sub-linear in
input size (Heaps'-law-shaped, as it is for Lane M's grammars across the
8 MiB vs 1 MiB file pairs in `LANE_M.md`), so trie depth should grow much
slower than input size; the per-byte DP-walk cost should stay roughly
bounded, making total reparse cost close to linear in input size at a
*fixed* iteration count. Combined with (1)'s embarrassingly-parallel block
structure, a 1 GiB file on a 16+ core machine should land in the same
order of wall-clock time as today's single-threaded 8 MiB run — a
plausible, but unimplemented and therefore unverified, path; flagged
honestly as a claim rather than a measurement.

## Recommended general algorithm (for whoever builds the real v3 lexicon stage)

1. Seed from bytes (no other-lane dependency; a real, general fallback,
   confirmed again here as in Lane M).
2. Iterate propose(pairs, Lane A's asymmetric role rule)→propose(triples,
   simple exclusion rule)→reparse (self-validating DP)→delete (exact
   batch gate, halving safety net) to convergence, scoring every step with
   `Cost.totalBits`'s DEF/USE/arity/name decomposition — *not* a flat
   per-symbol code — so definitions are correctly cheap and the lexicon is
   allowed to get as deep and compositional as it wants to.
3. Tally pair/triple windows with a hashmap; keep everything else
   (existing-entry checks, accepted-batch substitution, the trie) as
   sorted arrays/tries — this is the actual fast combination, measured,
   not assumed from the "no hashmaps" heuristic alone.
4. Treat the milestone-2 scope pass as a *delete-time hint* (protects
   bursty entries from looking falsely worthless) rather than a byte
   estimate — recalibrate its per-tier cost against real `v3/src` runs
   before quoting `total_B_scoped` as a number.
5. Before scaling past 8 MiB: parallelise reparse's per-block DP first;
   it is the dominant and the most embarrassingly parallel cost.

## Limitations (kept per PLAN's rules of evidence)

* Milestone-2 scope estimate is **not calibrated** against real bytes
  (previous section) — real benefit measured at 0.05-2.3%, this lane's own
  estimate claims up to ~20x that; use `num_local`/`is_local` as a
  qualitative signal, not `total_B_scoped` as a quantitative one, until
  recalibrated.
* Scope candidates are restricted to entries used only at the corpus's top
  level (never as another entry's spelling component) and to whole-block
  granularity; singleton-block occurrences of a chosen-local entry are
  *not* physically re-spelled to bytes (documented simplification — see
  the scope-pass doc comment in `l_learn.zig`), since an entry that exists
  at all is never more expensive to reference again than to respell.
* Top-down (suffix-array) and boundary-driven (branching-entropy) candidate
  generation were not attempted — time budget went to getting the
  objective, the real-codec validation, and the scope pass working and
  measured instead. Flagged as the clearest next research question, not
  silently skipped.
* Speed target (8 MiB ≤ 3s ReleaseFast) is **not met**: default settings
  take 7-21s on the 8 MiB files depending on corpus (macho slowest at
  20.8s, freedict fastest at 8.9s); root cause identified and measured
  (reparse's per-round DP cost scales with entry count, which this
  objective deliberately grows large), fix identified (parallelise the
  independent per-block DP) but not implemented.
* `l_learn.zig` is ~1,420 lines against the "~700" target. The overrun is
  concentrated in three places the milestone genuinely needs that a flat
  per-symbol cost model (Lane M's own core, ~1,200 lines across
  `lexicon.zig`+`propose.zig`+`parse.zig`+`delete.zig`+`learn.zig`, before
  its separate codec) didn't: the DEF/USE/arity/name decomposition itself
  (`Cost`, ~150 lines), the scope pass (~140 lines), and the generic
  `comptime w` pair/triple machinery (~220 lines, though this *saved*
  lines relative to writing pairs and triples out twice).
* `avgOverhead`'s bootstrap value (10.0 bits, used only before any entry
  exists) is a hand-picked constant, same caveat Lane M's own `Calib`
  struct carried — it only affects the very first round's aggressiveness
  and is corrected by the self-validating gates immediately after.

## Encode/decode timing (from the real `v3/src/lab.zig` runs)

Real `encode_ms` from the same runs used for the real-bytes table: 494ms
(freedict.eval8), 1,020ms (gcide.eval8), 356ms (omw.eval8) — all far faster
than this lane's own `learn()` (which is the *search*, run once; the
*encode* of an already-found parse is comparatively cheap, matching
LANE_M.md's own finding "codec `encode()` is 5-40ms... negligible next to
the MDL loop itself"). Real decode: 554-660 MB/s on the three eval8
dictionary files at default settings, dropping to ~300 MB/s on `--stats`-
scoped runs with far more buckets (macho: 162-172 MB/s, the most complex
lexicon); all measured on a shared machine, indicative only per PLAN's
rules.
