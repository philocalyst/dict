# Lane O — first-use-free and scoped (bursty) definitions: what are they worth?

Owner files: `v3/lab/o_scope.zig`, this notebook. All numbers below are `est`
(order-0, -log2(p) event-cost estimates, never coded to real bits). Every
dump was re-expanded block-by-block and byte-compared against its
`data/<file>.bin` before any number from it was trusted (`validate()` in
`o_scope.zig`); all 24 dumps in scope passed. Build/run:

```
zig build-exe -O ReleaseFast v3/lab/o_scope.zig -femit-bin=bin/o_scope
bin/o_scope                # all 24 inputs, ~17s total
bin/o_scope freedict -v    # filter by substring, -v prints per-round trace
```

## Method (see `o_scope.zig` for the exact formulas)

- **N** = total token occurrences in "text" (every block's stream + every
  entry's body, counted once regardless of how often the entry is used) is
  the same invariant quantity under V0 and V1; V2 changes it because
  inlining an entry replaces 1 occurrence with (arity) child occurrences.
- **V0** (reference): USE(x) per occurrence, order-0 over the whole
  alphabet, +2 bits flat per entry for arity. This is what `LANE_M.md` /
  `results_v2.tsv`'s "lexicon global, no first-use trick" baseline
  corresponds to.
- **V1** (first-use-free): one shared `DEF` event per entry (its first
  occurrence), all later occurrences are ordinary `USE(x)`; each `DEF` adds
  the entropy cost of the entry's arity and of `tier(u_x)=floor(log2(u_x+1))`
  as a stand-in for `NAME`.
- **V2** (scoped): each entry is global (as V1) or local with lifetime
  `2^s` blocks, decided per entry to minimise its own est cost, entries
  processed parents-before-children (decreasing expansion length — provably
  a valid order here, since arity ≥ 2 makes a parent's expansion strictly
  longer than any one child's). A local entry is redefined in every window
  of `2^s` blocks where it occurs ≥ 2 times; where it occurs exactly once it
  is inlined for free (no name), and its children's occurrence counts pick
  up the difference recursively. `NAME` in V2 is the entropy cost of which
  scope (global vs. `local s`) a definition instance chose, over all
  definition instances (a bursty entry redefined in 9 windows pays `NAME`
  9 times). `LOCAL(s,j)`, `j = floor(log2(rank+1))`, ranks entries by
  descending in-window use count among lifetime-`s` entries active in that
  window; cost is `-log2(n_{s,j}/N) + j` raw bits. Iterated 8 rounds
  (round 0 = force everyone global, to bootstrap a price table), **best
  round kept** (see pitfall below) — global is always an available choice
  so V2 can never end up worse than round 0's all-global baseline.
  For the v1 Re-Pair dumps, entries can also **dissolve** (deleted
  everywhere, inlined at every single occurrence, no shared/ranked cost).

### A real pitfall, and the fix

The naive version of this scheme (score each entry by "-log2(own price)
under last round's *pooled* average price per lifetime") is a
tragedy-of-the-commons: every entry with a barely-qualifying in-window count
of 2 looks exactly as attractive as one with 50, so a whole cohort rushes a
lifetime in the same round, overshoots (real per-window ranks turn out much
worse once everyone has piled in), and — with more `s` options to spread
across — this got *worse*, not better (`S={0,2,4}` and `S={0..6}` first
landed strictly worse than plain V1, occasionally worse than V0). Two fixes
made it converge sensibly: (1) price `LOCAL(s, count)` from the previous
round's *actual* per-count outcome, not a pooled mean across all counts —
this alone stopped mass adoption from looking uniformly cheap; (2) require
a real margin (15%) over the global cost before switching away from it, so
marginal cases wait a round for firmer prices instead of piling in at once.
After that, `S={0}` ⊆ `S={0,2,4}` ⊆ `S={0..6}` improve roughly (not
strictly — this is still a greedy heuristic) as expected. Also: an "inlined"
occurrence in the naive version was priced at 0 to the entry itself, which
is true of its *own* event but not of the system — it still has to code the
inlined body somewhere. Both `dissolve` and the "occurs-once" branch of
local scope are now priced at the *static* (round-independent, from raw
text-occurrence counts) cost of coding that body's children directly, which
is what stopped every dispersed entry from looking like a free lunch.

## Main table — bytes (est), % vs V0

### Word-lexicon dumps (v2, priority: freedict/gcide/omw)

| file | V0 | V1 (%) | V2 S={0} (%) | V2 S={0,2,4} (%) | V2 S={0..6} (%) | real v2 total | real bzip3 |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | 668,037 | 647,577 (−3.1) | 633,676 (−5.1) | **633,153 (−5.2)** | 634,836 (−5.0) | 647,834 | 1,189,002 |
| freedict.eval8.65536 | 665,253 | 644,800 (−3.1) | **630,479 (−5.2)** | 631,982 (−5.0) | 630,684 (−5.2) | 638,216 | 899,408 |
| freedict.untouched.65536 | 95,654 | 93,465 (−2.3) | 91,927 (−3.9) | **91,924 (−3.9)** | 91,970 (−3.9) | 93,014 | 115,160 |
| gcide.eval8.16384 | 1,524,146 | 1,479,666 (−2.9) | 1,440,961 (−5.5) | **1,440,553 (−5.5)** | 1,443,621 (−5.3) | 1,465,897 | 2,362,319 |
| gcide.eval8.65536 | 1,521,853 | 1,477,264 (−2.9) | **1,441,530 (−5.3)** | 1,445,001 (−5.1) | 1,441,946 (−5.3) | 1,459,330 | 1,905,560 |
| gcide.untouched.65536 | 213,724 | 206,911 (−3.2) | 203,170 (−4.9) | **203,101 (−5.0)** | 203,431 (−4.8) | 201,159 | 235,103 |
| omw.eval8.16384 | 458,947 | 435,405 (−5.1) | 393,776 (−14.2) | **392,579 (−14.5)** | 393,103 (−14.4) | 472,401 | 1,124,142 |
| omw.eval8.65536 | 455,077 | 432,564 (−5.0) | 394,417 (−13.3) | 395,967 (−13.0) | **394,591 (−13.3)** | 459,913 | 674,384 |
| omw.untouched.65536 | 78,676 | 75,339 (−4.2) | 72,070 (−8.4) | **72,013 (−8.5)** | 72,467 (−7.9) | 75,270 | 95,276 |
| json.eval8.65536 | 1,081,655 | 1,076,155 (−0.5) | 1,015,037 (−6.2) | **1,014,940 (−6.2)** | 1,015,068 (−6.2) | 1,032,423 | 1,028,983 |
| macho.eval8.65536 | 3,057,016 | 2,964,836 (−3.0) | **2,861,545 (−6.4)** | 2,871,438 (−6.1) | 2,866,259 (−6.2) | 2,995,697 | 3,259,348 |
| zigsrc.eval8.65536 | 1,387,601 | 1,329,216 (−4.2) | **1,264,592 (−8.9)** | 1,269,664 (−8.5) | 1,267,114 (−8.7) | 1,380,887 | 1,454,997 |

### Full Re-Pair grammars (v1, dissolve allowed; n_dissolved=0 in every run — see verdict)

| file | V0 | V1 (%) | V2 S={0} (%) | V2 S={0,2,4} (%) | V2 S={0..6} (%) | real static total | real bzip3 |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16k | 778,797 | 659,333 (−15.3) | 630,630 (−19.0) | **629,947 (−19.1)** | 632,431 (−18.8) | 681,709 | 1,189,002 |
| freedict.eval8.64k | 776,015 | 656,959 (−15.3) | **633,979 (−18.3)** | 636,008 (−18.0) | 634,187 (−18.3) | 675,787 | 899,408 |
| gcide.eval8.16k | 1,749,862 | 1,527,489 (−12.7) | 1,470,320 (−16.0) | **1,470,102 (−16.0)** | 1,476,175 (−15.6) | 1,566,358 | 2,362,319 |
| gcide.eval8.64k | 1,746,165 | 1,524,951 (−12.7) | **1,478,707 (−15.3)** | 1,482,878 (−15.1) | 1,478,872 (−15.3) | 1,561,346 | 1,905,560 |
| omw.eval8.16k | 646,953 | 435,258 (−32.7) | 380,241 (−41.2) | 380,319 (−41.2) | **380,006 (−41.3)** | 407,330 | 1,124,142 |
| omw.eval8.64k | 642,971 | 430,289 (−33.1) | **380,562 (−40.8)** | 380,652 (−40.8) | 380,621 (−40.8) | 396,852 | 674,384 |
| json.eval8.16k | 1,250,983 | 1,150,496 (−8.0) | 1,095,464 (−12.4) | **1,094,241 (−12.5)** | 1,097,617 (−12.3) | 1,119,517 | 1,314,524 |
| json.eval8.64k | 1,251,166 | 1,150,587 (−8.0) | **1,096,660 (−12.3)** | 1,101,334 (−12.0) | 1,097,037 (−12.3) | 1,114,195 | 1,028,983 |
| macho.eval8.16k | 3,637,838 | 2,918,793 (−19.8) | **2,747,338 (−24.5)** | 2,750,039 (−24.4) | 2,754,444 (−24.3) | 2,940,018 | 3,857,767 |
| macho.eval8.64k | 3,637,289 | 2,917,429 (−19.8) | **2,779,026 (−23.6)** | 2,783,259 (−23.5) | 2,780,234 (−23.6) | 2,934,113 | 3,259,348 |
| zigsrc.eval8.16k | 1,739,436 | 1,313,288 (−24.5) | **1,215,651 (−30.1)** | 1,219,595 (−29.9) | 1,222,100 (−29.7) | 1,322,796 | 1,837,421 |
| zigsrc.eval8.64k | 1,738,390 | 1,310,591 (−24.6) | **1,214,731 (−30.1)** | 1,220,344 (−29.8) | 1,217,496 (−30.0) | 1,316,201 | 1,454,997 |

Bold = cheapest V2 variant for that row (differences between S-sets are
mostly inside the greedy search's own noise, not a clean monotone trend).

## V0/V1 vs the known real totals ("how close")

V0 (naive global order-0 + flat 2-bit arity) vs `results_v2.tsv`'s real,
fully-charged v2 total (lexicon + class model + directory + payload): within
**+2% to +6%** on freedict/gcide/json/macho/zigsrc (est runs a bit high, as
expected for an order-0 model with no class/context help); on **omw it runs
1–3% *under* the real total** — omw's real integrated codec is already known
(from `LANE_M.md`) to do worse than its own round-1 static baseline there,
so this isn't a bug in the estimate.

V0 vs the real full-grammar totals in `results_v1.tsv` (their "V1" column —
unrelated name clash, that's "round-1 static grammar codec", not this
lane's V1) is a much worse match: **+12% to +32%** on json/macho/zigsrc/gcide
and **+59–62% on omw**. That gap is almost entirely explained by first-use:
this lane's **V1 estimate** lands within **±1% to +7%** of the same real
totals (freedict/macho/zigsrc/gcide within 1%, omw within 7%, json within
3%) even though the real `results_v1.tsv` codec already does its own
(better) form of first-occurrence/DEF-tree coding — i.e. first-use-free
alone recovers essentially all of the gap between naive order-0 and a real
working grammar coder. For the v2 word-lexicon dumps V1 vs real is even
tighter: **±1% on freedict, +1% on gcide, +4% on json, −1 to −4% on
macho/zigsrc**, and −8% on omw (again, omw's real system is the outlier).

## Detail: scoping mechanics on the priority word corpora (V2, S={0,2,4})

| file | frac. local | mean bits/global-use | mean bits/local-use | # global defs | # local defs (entities) | # local def *instances* | s histogram |
|---|---:|---:|---:|---:|---:|---:|---|
| freedict.eval8.16384 | 0.078 | 12.65 | 9.08 | 16,012 | 4,240 | 8,388 | {0:3356, 4:884} |
| freedict.eval8.65536 | 0.071 | 12.65 | 9.79 | 16,231 | 4,009 | 7,464 | {0:3696, 4:313} |
| freedict.untouched.65536 | 0.043 | 10.76 | 9.45 | 3,001 | 315 | 443 | {0:315} |
| gcide.eval8.16384 | 0.079 | 13.40 | 9.15 | 30,662 | 7,908 | 15,175 | {0:6855, 4:1053} |
| gcide.eval8.65536 | 0.077 | 13.42 | 10.38 | 30,866 | 7,809 | 14,255 | {0:7105, 2:15, 4:689} |
| gcide.untouched.65536 | 0.059 | 11.78 | 10.37 | 6,955 | 898 | 1,257 | {0:898} |
| omw.eval8.16384 | 0.252 | 11.88 | 8.27 | 10,426 | 12,681 | 17,783 | {0:10569, 2:731, 4:1381} |
| omw.eval8.65536 | 0.252 | 11.82 | 9.29 | 9,850 | 12,520 | 16,773 | {0:12186, 2:283, 4:51} |
| omw.untouched.65536 | 0.191 | 10.66 | 9.98 | 2,793 | 1,747 | 2,107 | {0:1747} |

("local defs (entities)" = distinct entries that ever go local; "def
instances" ≥ entities because a bursty local entry is redefined once per
window it's active in — that's the mechanism the whole scheme is testing.)
For json/macho/zigsrc and the v1 Re-Pair dumps, `frac_local` runs
0.10–0.36, `mean_local_bits` 7.3–11.4, roughly the same shape; see the raw
run log for exact numbers if needed (`bin/o_scope > log; grep -A4 '=='`).

## Verdict

- **First-use-free (V1) is the single biggest lever here**, worth
  **2.3–5.1%** over V0 on the word-lexicon dumps and a much larger
  **8–33%** on the full Re-Pair grammars (the fuller Re-Pair alphabet has
  far more entries used only 2–5 times, exactly where "first use is free"
  pays hardest — matches round 3's "rules used twice do not pay" note).
  It is cheap to reason about (no iteration, no search) and closely tracks
  what the real, already-working codecs achieve (see above), so this part
  of DESIGN.md's claim is solid and low-risk to build.
- **Scoping (local/bursty definitions) adds a real but smaller second
  win on top of V1** (best-S `pct_vs_V1` from the run log): **1.6–2.6%**
  more on freedict/gcide, **3.5–5.7%** more on json/macho/zigsrc, and a
  striking **4.4–9.8%** more on omw (word-lexicon dumps); on the v1
  Re-Pair grammars, **3.0–7.4%** more on freedict/gcide/json/macho/zigsrc
  and **11.6–12.7%** more on omw. Combined with V1, total gains
  over V0 land at **5–9%** on freedict/gcide/json/macho/zigsrc,
  **13–15%** on omw (word-lexicon dumps), and **12–41%** on the full
  Re-Pair grammars (again mostly first-use-free, scoping adding a few more
  points). **omw is the standout for scoping specifically** — it has the
  highest `frac_local` (19–36%) everywhere it appears, consistent with OMW
  entries containing many short, self-referential glosses that repeat a
  headword or gloss token heavily within one entry.
- **Which lifetimes matter: overwhelmingly `s=0` (single block).** Across
  every run, the `s=0` histogram bucket dominates; `s=2` and `s=4` pick up
  a modest number of entries (hundreds to low thousands) and shave another
  fraction of a percent to ~1% off `s=0` alone in about half the runs, but
  it's inside the noise of this greedy search in the other half (`S={0..6}`
  is not reliably better than `S={0,2,4}`, and both are only sometimes
  better than plain `S={0}`). The practical reading: **most burstiness is
  a within-one-block phenomenon** (a headword repeated inside its own
  dictionary entry, or a JSON key repeated within one object dump) — the
  DESIGN.md motivation is right, but a single "block-local" bucket
  probably captures most of the win; a handful of longer lifetimes (2–4
  blocks) are worth having but are not where the money is.
- **Mean bits per LOCAL use (7.3–11.4, mostly 8–10) vs GLOBAL use
  (9.7–16.5, mostly 11–15)**: local uses cost roughly **2–5 bits less**
  than global on the same corpus, well short of DESIGN.md's aspirational
  "~6 bits instead of ~17" but a solid, consistent win — 17 bits/use for
  global was never observed here at all (order-0 global USE cost lands in
  the 10–16 bit range for these corpora, since there's no class/context
  model on top), so "~6 vs ~17" looks like it describes the tails (a truly
  hapax-adjacent entry vs a maximally bursty one), not the corpus average.
- **Dissolve never won on any of the 12 full Re-Pair dumps** (`n_dissolved
  = 0` everywhere), which is a genuine surprise given round 3's own framing
  ("rules used twice do not pay") — every entry in the "full" grammar
  (min-frequency 2) still preferred first-use-free global or a local scope
  over full inlining once its DEF was first-use-free. Two live
  possibilities, not resolved here: either first-use-free already captures
  essentially all of the "rules used twice don't pay" effect (so the extra
  dissolve escape hatch is redundant once V1 exists), or the static,
  round-independent per-symbol price this lane uses to estimate the
  "inline instead" cost is too pessimistic for very cheap fragment
  children. Worth a follow-up with a live (not static) inline-cost
  estimate before concluding dissolve is unnecessary in the real format.
- **What this estimate ignores** (per PLAN.md, labelled here so no one
  double-counts it later): no context/automaton modelling (K lane) on top —
  every USE/DEF/NAME/LOCAL event is order-0 and pooled globally, not
  per-row; no real bucket quantisation (buckets are powers of two with
  possible empty slots in the real format, raw bits here are continuous
  `j`, not the true occupied-slot count); NAME's real cost is `name_row`-
  dependent (the row the body ends in) and this lane prices it as one
  global scope-frequency table; the V2 search is a greedy, damped,
  best-of-8-rounds coordinate descent, not a joint optimum — treat the
  gap between `S={0}` and larger `S` sets as noisy, not a clean ordering;
  and the dissolve/local "inline" cost uses a **static** per-symbol price
  from raw occurrence counts, not the live, round-dependent price a fully
  worked-out version would use.
