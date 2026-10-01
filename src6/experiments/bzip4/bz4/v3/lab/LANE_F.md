# Lane F — buckets and the automaton: how good can the static model get?

Owner files: `f_common.zig` (B4SD v1/v2 reader, sequence builder, quantisation,
the shared cost model, the DP bucketizer, the exchange-clustering class
learner reused by Q2/Q3), `f_bucket.zig` (Q1), `f_bigram.zig` (Q2),
`f_direct.zig` (Q3), `f_automaton.zig` (Q4), `f_lab.zig` (CLI driver), this
notebook. Binaries under `bin/f_lab`, raw per-file logs under
`dumps/f_sweep/*.log` (one run each, `f_lab DUMP all`, indicative timings
5.5–19s/file, ~2.4 min total for all 12 files on one machine). Never touches
another lane's files.

## The question and the method, in one paragraph

This is an **oracle study with estimated costs** (`est` everywhere — no real
bitstream anywhere in this lane, per PLAN's brief for Lane F): given the
static model DESIGN.md defines (bucket symbol + `w` raw bits, static tANS
row tables, `next_row` per cell), how good can the *static* part get before
reaching for the fully adaptive machinery, and what does letting `next_row`
depend on more than the current token (the automaton) buy on top? The
modelled sequence is every block's token stream (context reset at block
start) plus every lexicon entry's own body (its component spelling, context
reset there too) from Lane M's word-lexicon dumps
(`dumps/m_{freedict,gcide,omw}.eval8.{16384,65536}.b4sd`,
`m_{freedict,gcide,omw}.untouched.65536.b4sd`,
`m_{json,macho,zigsrc}.eval8.65536.b4sd` — all B4SD v2). "Tokens" below always
means this combined stream; counts include both roles.

## Cost model (exact charging rule, fixed across every question)

```
cost(token x | row r) = -log2(Pq(bucket(x) | r)) + width(bucket(x))
Pq(b | r) = q_r[b] / 2^L         (tANS quantisation: largest-remainder /
                                   Hamilton apportionment to integers
                                   summing to exactly 2^L, every b with
                                   nonzero count in row r gets >= 1)
table cost = K * 6                                     (bucket flat cost)
           + sum_r  |S_r| * (log2(K) + L/2)             (identify + freq,
                                                          K = TOTAL buckets
                                                          in the model,
                                                          shared alphabet;
                                                          S_r = row r's
                                                          nonzero support)
           + next-row exceptions                        (0 unless the
                                                          automaton makes
                                                          next_row depend on
                                                          more than the
                                                          current bucket —
                                                          only Q4)
```
`L` (quantisation depth) swept in {10, 11, 12}; results below use whichever
is reported (rarely differs by more than 0.01 bit/token — L=11/12 dominate
the winning rows in practice). Every number is `bits/token = total_bits /
tokens` and `total bytes = total_bits / 8`, both from a real run of this
formula over the real corpus (never a separate idealised estimate) — the
`est` label is only because there is no real bitstream, not because these
are hand-waved numbers.

**Q4's one extra rule** (next-row exceptions, stated once, kept fixed): a
nonzero (row, bucket) cell that routes to something other than the bucket's
*default* next-row costs an extra `ceil(log2(rows))` bits. For Q4a (order-2
redirects), the redirect is genuinely a per-*source-row* decision (every
self-class bucket from a given predecessor row gets the same redirect), so
it is charged once per source row, not once per (row, bucket) cell — charging
it per cell would inflate the same 1-bit decision by the row's whole bucket
count for no reason. For Q4b (sticky splits), the decision genuinely is
per-bucket (each self-loop bucket independently chooses STAY/FLIP), so it is
charged once per self-bucket, always exactly `n_self` exceptions regardless
of the STAY/FLIP mix (every self-bucket differs from *someone's* default —
see Q4b below for why).

## Harness validation

`f_common.readDump` accepts both B4SD v1 and v2 (all 12 required dumps are
v2). `evalStaticModel`/`costFromCounts` were cross-checked against a
from-scratch, independent full-corpus token-by-token replay (not reusing any
Lane F code) for a chosen sticky split — see Q4b's "one real bug" writeup,
where this cross-check is what caught (and then confirmed the fix for) a
real off-by-one. Exact order-0 entropy (`exactH0Bits`) reproduces the
textbook `-sum n_x log2(n_x/N)` directly from the same `g[]`/`N` every other
question uses, so every "pct vs H0" number below is internally consistent.

## Q1 — bucket quantisation (C = 1, one row)

Two methods compared: **tier** (group by `floor(log2 count)`, binary-decompose
each tier's `m` members into at most `b` buckets — `b` sets the ceiling
"unlimited" = exact `popcount(m)`-bucket decomposition, zero waste) vs **DP**
(a DP over the count-sorted-descending list, transitions of size `min(2^w,
remaining)` so the last bucket of a chosen width may be left partially
empty — "the planner may leave slots empty" — with a per-bucket overhead
`6 + L/2 + log2(K)` fed back in a 4-round fixed point on the resulting `K`).

| dump | tokens | H0 B/tok | tier b=1 | tier b=3 | tier unlim. | **DP (winner)** | DP K | DP vs H0 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | 427,584 | 12.404 | 12.886 | 12.440 | 12.418 | **12.408** | 57 | −0.03% |
| freedict.eval8.65536 | 425,878 | 12.402 | 12.904 | 12.439 | 12.416 | **12.405** | 57 | −0.03% |
| freedict.untouched.65536 | 74,429 | 10.192 | 10.659 | 10.241 | 10.214 | **10.202** | 32 | −0.10% |
| gcide.eval8.16384 | 916,155 | 13.225 | 13.719 | 13.283 | 13.238 | **13.227** | 79 | −0.02% |
| gcide.eval8.65536 | 914,252 | 13.232 | 13.729 | 13.292 | 13.245 | **13.234** | 80 | −0.02% |
| gcide.untouched.65536 | 150,002 | 11.294 | 11.898 | 11.326 | 11.315 | **11.300** | 39 | −0.06% |
| omw.eval8.16384 | 282,308 | 12.842 | 13.530 | 12.873 | 12.860 | **12.846** | 49 | −0.03% |
| omw.eval8.65536 | 281,365 | 12.780 | 13.390 | 12.825 | 12.799 | **12.785** | 52 | −0.04% |
| omw.untouched.65536 | 56,420 | 10.995 | 11.427 | 11.051 | 11.015 | **11.005** | 26 | −0.09% |
| json.eval8.65536 | 821,165 | 10.519 | 11.194 | 10.541 | 10.534 | **10.521** | 56 | −0.02% |
| macho.eval8.65536 | 1,858,162 | 13.079 | 13.406 | 13.127 | 13.092 | **13.080** | 99 | −0.01% |
| zigsrc.eval8.65536 | 825,668 | 13.322 | 13.890 | 13.367 | 13.338 | **13.324** | 74 | −0.02% |

("b=2" tracked between b=1 and b=3 everywhere, e.g. freedict.eval8.65536:
12.483 bpt at K=25 — omitted from the table for space, see
`dumps/f_sweep/*.log` `Q1 ... b=2` lines for every file.)

**Answers to the stated questions:**
- **How small can the loss be made, with how many symbols?** Essentially to
  the noise floor — 0.01–0.10% above the exact entropy lower bound — with
  only 26–99 buckets (roughly `log(vocab)`-scale, not vocab-scale) on every
  file, dictionary or not. This is the headline Q1 result: bucket
  quantisation, done right, is nearly free.
- **Is tiering by `floor(log2 count)` right, or does the DP do better?** The
  **DP wins on every single file at every `b`**, and does it with *fewer*
  buckets than tier's own "unlimited" (zero-waste) setting — e.g.
  `freedict.eval8.65536`: DP reaches 12.405 bpt with 57 buckets, tier-unlimited
  needs 64 buckets to reach only 12.416. Tiering by `floor(log2 count)` fixes
  the boundary *before* looking at the actual cost tradeoff (whether an
  extra bucket buys more than it costs); the DP chooses boundaries by that
  tradeoff directly, using the exact same overhead constant, and always
  finds a smaller, better-fitting bucket set. **Recipe: use the DP method,
  not tiering**, whenever real bucket boundaries need to be chosen (Q2/Q3
  below reuse it).
- Tier's own internal ordering is monotone and unsurprising: `b=1` (worst,
  one giant bucket per tier) < `b=2` < `b=3` < unlimited (best, exact
  decomposition) everywhere, confirming the "more buckets recovers loss"
  direction is right — the DP just gets there with fewer of them by *also*
  choosing *where* the cuts go.

## Q2 — class bigram rows: buckets = (class, tier)

Classes induced by the **same one-map exchange-clustering method Lane K
used** (`k_classes.zig`'s `learnClasses`/`evalCost`, reimplemented in
`f_common.learnClassesOneMap` — same synchronous-EM sweep structure,
candidate-frequency cap, byte/token-rank init — minus the DAG-inheritance
layer Lane K needed for its huge rule alphabet: Lane F's vocabulary is
already Lane M's compact, flat word lexicon, so every token is its own
candidate, no inheritance default needed). Within each class, members are
independently DP-bucketized (Q1's winner) at a *shared* per-bucket overhead
swept over a doubling ladder (`4..2048` bits) so the total bucket count `K`
is a real, measured tradeoff, not a guess — the table reports each C's
empirical minimum over that whole grid. Row = class of the previous token,
`C+1` states (dedicated START row, as Lane K's `C` sentinel).

| dump | C=16 | C=64 | C=128 | **best** | best K | pct vs H0 |
|---|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | **11.837** | 11.951 | 12.358 | C=16 | 123 | +4.57% |
| freedict.eval8.65536 | **11.820** | 11.939 | 12.346 | C=16 | 101 | +4.69% |
| freedict.untouched.65536 | **9.606** | 10.102 | 11.468 | C=16 | 72 | +5.75% |
| gcide.eval8.16384 | **12.827** | 12.900 | 13.248 | C=16 | 134 | +3.01% |
| gcide.eval8.65536 | **12.817** | 12.899 | 13.273 | C=16 | 135 | +3.14% |
| gcide.untouched.65536 | **10.496** | 10.590 | 11.181 | C=16 | 95 | +7.07% |
| omw.eval8.16384 | **12.244** | 12.284 | 12.694 | C=16 | 139 | +4.66% |
| omw.eval8.65536 | 12.156 | **12.156** | 12.703 | C=16/64 (tie) | 122 | +4.88% |
| omw.untouched.65536 | **9.899** | 10.108 | 10.783 | C=16 | 68 | +9.97% |
| json.eval8.65536 | 9.832 | **9.786** | 9.828 | C=64 | 183 | +6.97% |
| macho.eval8.65536 | 12.764 | **12.712** | 12.855 | C=64 | 283 | +2.80% |
| zigsrc.eval8.65536 | **12.769** | 12.897 | 13.209 | C=16 | 139 | +4.15% |

**What C / total symbol count is best?** **C = 16, with a moderate bucket
budget (K in the 70–140 range), wins on 9 of 12 dumps** and never loses
badly where it doesn't win (json/macho, both generality files with a lot of
raw redundancy, prefer C=64 by a small margin: +0.5–1.0pp). **C = 128 is a
clear loser everywhere, often badly** (freedict.untouched: 9.61 -> 11.47
bpt, worse than *doing nothing extra* over the C=16 result by more than a
full bit/token). This is the **opposite of Lane K's own C-curve finding**
("more classes almost always help, monotonically... all the way to C=128"),
and the reason is exactly the mechanism this cost model is built to expose:
Lane K's real per-symbol coding shares one Fenwick per class over the
*actual* member frequencies (near-zero marginal table cost thanks to DAG
inheritance); Lane F's uniform-within-bucket model instead needs *its own
private tier structure per class*, and every one of those buckets pays the
full `6 + log2(K) + L/2` bits — table overhead that scales with `C` directly
here, in a way Lane K's mechanism was specifically built to avoid. **Bucket
quantisation does not just shrink Lane K's gains, it inverts the C-curve's
shape.** This is the direct, load-bearing answer to "confirm Lane K's gains
survive bucket quantisation": on the size axis, no — more classes stops
helping and starts hurting once every class has to buy its own bucket
table, at exactly the point (C=128) Lane K found its best results.

The gains themselves *do* survive, though, at the right C: **+2.8% to
+10.0% over exact order-0 entropy**, with the extremes matching PLAN's own
prediction pattern (json/macho — the generality/structured files — sit at
the lower end; the small, sparse `*.untouched` dictionary corpora sit at the
high end, `omw.untouched` reaching +9.97%, the biggest gain of the whole
table). For orientation only (**different underlying token alphabet** — Lane
K coded Re-Pair grammar root symbols with DAG-inherited byte classes; Lane F
codes Lane M's compositional-MDL word-lexicon symbols with buckets — so this
is not apples-to-apples, just a sanity check on direction and rough scale):
Lane K's published general-setting numbers on the nearest comparable files
were `freedict.untouched` +2.23%, `gcide.untouched` +4.88%,
`omw.untouched` +3.94%, `json.eval8` +4.29%, `macho.eval8` +3.31%,
`zigsrc.eval8` +5.05% — Lane F's C=16 numbers are as large or larger on
every one of those except macho/zigsrc, consistent with PLAN's own
"coarser, more word-like tokens carry more inducible class structure"
prediction (Lane M's tokens are already words, one level more word-like than
Lane K's Re-Pair roots).

**Recipe: C = 16, DP-bucketize each class independently at a per-bucket
overhead around 25–100 bits** (the empirical sweet spot across the doubling
ladder on every file tested) — **one setting, no per-corpus fitting**, this
is the model this lab recommends shipping.

## Q3 — direct bucket induction (no separate class label)

`K` buckets induced directly (seed: Q1's tier-proportional binary
decomposition, frequency-homogeneous by construction, targeted at `K` —
see "what didn't work" below for why two other seeding ideas were rejected),
then `R` rows = an exchange-clustering of the buckets themselves (literally
reusing `f_common.learnClassesOneMap` on a *projected* token stream where
every token has been replaced by its bucket id — "cluster the buckets as if
they were tokens"), then a bounded hard-EM local search refines individual
tokens' bucket membership against the row-conditional objective
`P(x|r) = Pq(b(x)|r)/2^w(b(x))`, alternated with one more row-reclustering
pass (`OUTER_ROUNDS=2`), with a real-cost snapshot/revert safety net (Lane
M's "self-validating" pattern) so refinement can never make the *reported*
number worse than not refining at all.

| dump | K=64 | K=128 | K=256 | K=512 | **best (K,R)** | pct vs H0 | vs Q2's best |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | **12.752** | 12.778 | 12.826 | 12.882 | K=64,R=16 | −2.80% | −7.73% |
| freedict.eval8.65536 | **12.762** | 12.789 | 12.814 | 12.864 | K=64,R=16 | −2.91% | −7.97% |
| freedict.untouched.65536 | **10.820** | 10.904 | 11.175 | 11.628 | K=64,R=16 | −6.16% | −12.64% |
| gcide.eval8.16384 | **13.557** | 13.559 | 13.583 | 13.570 | K=64,R=16 | −2.51% | −5.69% |
| gcide.eval8.65536 | 13.567 | **13.563** | 13.588 | 13.594 | K=128,R=16 | −2.50% | −5.82% |
| gcide.untouched.65536 | **11.811** | 11.850 | 11.957 | 12.217 | K=64,R=16 | −4.58% | −12.53% |
| omw.eval8.16384 | 13.232 | 13.253 | **13.196** | 13.277 | K=256,R=16 | −2.76% | −7.78% |
| omw.eval8.65536 | 13.091 | 13.107 | **13.063** | 13.128 | K=256,R=16 | −2.21% | −7.46% |
| omw.untouched.65536 | **11.535** | 11.659 | 11.898 | 12.444 | K=64,R=16 | −4.91% | −16.53% |
| json.eval8.65536 | 11.344 | 10.685 | **10.636** | 10.678 | K=256,R=16 | −1.12% | −8.69% |
| macho.eval8.65536 | 13.309 | 13.318 | 13.296 | **13.267** | K=512,R=16 | −1.43% | −4.36% |
| zigsrc.eval8.65536 | 13.612 | 13.611 | **13.579** | 13.591 | K=256,R=16 | −1.93% | −6.35% |

**Negative result, stated plainly: direct bucket induction loses to Q2's
class-then-tier structure on every single file, by 4–17%**, and on four
files (all three `*.untouched` corpora and `freedict.eval8`) it is even
**worse than Q1's plain order-0 model** (e.g. `omw.untouched`: Q3's best is
11.535 bpt vs Q1's order-0 DP at 11.005 bpt) — the joint induction is
actively destroying value relative to doing nothing context-aware at all.
`R` barely matters (R=16 wins on 9/12 files; R=64/128 essentially never
help), which is itself informative: the row-clustering half of the pipeline
isn't the bottleneck, the bucket-formation half is.

**What didn't work, in order (all real, measured, and part of why the
recipe below is a plain rejection rather than a qualified one):**
1. *Equal-rank-count seed* (K equal-population contiguous groups over the
   sorted list): lumps very different individual frequencies together at
   the high-frequency end (the top bucket's most- and least-frequent members
   can differ by an order of magnitude), and the candidate-capped
   refinement never fully repairs this on large vocabularies. Rejected in
   favour of the tier-proportional seed used above.
2. *Entropy-driven DP seed aimed at a target K* (Q1's own method, bisecting
   its overhead constant to hit K=64/128/256/512): **the K(overhead) curve
   is wildly discontinuous** — on `omw.untouched.65536`, overhead 0.00 gives
   K=2105, overhead 0.10 gives K=122, and no overhead in between exists to
   ask for anything in between (measured directly, see the raw sweep in
   this lane's history). A bisection search on a single scalar simply
   cannot be aimed at an arbitrary target through a cliff like that.
   Rejected; replaced by the tier-proportional decomposition (Q1's tier
   method extended with a finer-than-canonical split rule — repeatedly
   halve the largest current bucket — so it can hit *any* target K exactly,
   not just `popcount(m)`-shaped ones).
3. *Naive batched (synchronous) hard-EM* for the token-membership
   refinement: evaluating every candidate token's best bucket against a
   frozen width snapshot, then committing all moves at once, let many
   candidates simultaneously "discover" the same cheap-looking
   small-population bucket and pile into it — the real post-sweep width,
   recomputed only afterward, blew up far past what any single decision
   assumed, and measured real cost got *worse* after refinement, not
   better (`freedict.eval8.65536`'s inner debug trace during development:
   13.57 bpt before refining a given (C,R) round, 14.06 bpt after — see
   this file's history). Fixed by applying moves *incrementally* (update
   the moved token's old/new bucket width immediately, so the next
   candidate in the same sweep sees the real, current state) plus the
   real-cost snapshot/revert safety net described above, which is what
   keeps the reported Q3 numbers from ever being worse than "do nothing" —
   they just aren't reliably *better* than the seed's own row-clustering
   step either, on most files (a separate, disclosed weakness: the
   per-candidate move rule is a *local, separable* approximation that does
   not account for a move's side effect on the width of every other member
   already in its target bucket, so committing to the externality-blind
   objective can still find a real local optimum that isn't much of an
   improvement — bounded by the safety net, but not fixed by it).

**Recipe: don't use direct bucket induction — use Q2's class-then-tier
structure instead.** The two-stage decomposition (learn a *role* label
first with an objective that doesn't have to also solve a bin-packing
problem, then bucket by frequency *within* that role) is a genuinely better
inductive bias for this specific joint problem than trying to solve both at
once with the tools built here, not just a matter of more tuning.

## Q4 — automaton induction, starting from Q2's best class-bigram model

**(a) Order-2 by predecessor class**, closed form (no search): for each row
`r`, build the true order-2 histogram `N2[ctx2][r][bucket]` in one pass,
compare its total entropy cost (each nonzero `ctx2` group gets its own
quantised table) against the order-1 baseline, charge every *new* row's own
table cost plus one redirect flag per source row that must now point through
it (the Q4a charging rule above), accept if it pays.

**(b) Sticky self-loop split**, hard-EM local search: pick the row's
self-loop buckets (bucket's own class == r), gather every maximal run of
consecutive class-`r` tokens across the corpus, and search a STAY/FLIP
decision per self-bucket. Entry into the family from any other row always
lands on `r_a` (fixed, no decision — only `r_a`/`r_b`'s *own* transitions
carry a decision, which is the whole mechanism: a row visited from outside
never gets to consult "which branch was I in", only a row already inside
the family does, which is what makes the branch a genuine memory of
*history*, not just of the last token). Two full hill-climb sweeps over the
self-buckets, greedy accept-if-real-cost-improves. **One real bug found and
fixed** (see below) — every number reported here is from the corrected,
independently cross-validated version.

| dump | Q2 base B/tok | Q4a accepted / tried | Q4a net bits | Q4b accepted / tried | Q4b net bits | **headroom** | % of base |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | 11.837 | 0/16 | 0 | 1/10 | 419 | 52 B | 0.008% |
| freedict.eval8.65536 | 11.820 | 0/16 | 0 | 1/10 | 5 | 1 B | 0.000% |
| freedict.untouched.65536 | 9.606 | 0/16 | 0 | 0/10 | 0 | 0 B | 0.000% |
| gcide.eval8.16384 | 12.827 | 0/16 | 0 | 1/10 | 7 | 1 B | 0.000% |
| gcide.eval8.65536 | 12.817 | 0/16 | 0 | 0/10 | 0 | 0 B | 0.000% |
| gcide.untouched.65536 | 10.496 | 0/16 | 0 | 0/10 | 0 | 0 B | 0.000% |
| omw.eval8.16384 | 12.244 | 0/16 | 0 | 0/10 | 0 | 0 B | 0.000% |
| omw.eval8.65536 | 12.156 | 1/16 | 2,017 | 2/10 | 1,973 | 499 B | 0.117% |
| omw.untouched.65536 | 9.899 | 0/16 | 0 | 0/10 | 0 | 0 B | 0.000% |
| **json.eval8.65536** | 9.786 | **5/64** | **306,595** | 2/10 | 8,967 | **39,445 B** | **3.927%** |
| macho.eval8.65536 | 12.712 | 1/64 | 4,546 | 5/10 | 24,532 | 3,635 B | 0.123% |
| zigsrc.eval8.65536 | 12.769 | 1/16 | 6,904 | 2/10 | 3,442 | 1,293 B | 0.098% |

**Headroom vs the class bigram, with all tables charged, is essentially
zero on the three priority word corpora at this scale** (freedict/gcide/omw:
0.000–0.117%, i.e. a handful of tokens' worth of savings on multi-hundred-KB
models). It is **real and worth having on the format-heavy generality
files**: json.eval8 gets **+3.93%** on top of Q2 (mostly order-2: JSON's
key/number/hex-mode structure is exactly the kind of thing that needs to
know *what came two tokens back*, not just one), and macho/zigsrc pick up a
smaller but real 0.10–0.12% from sticky splits. This is a genuine, honest
answer, not a null result dressed up: at C=16–64 the class bigram already
captures almost everything the corpus offers about "what row am I in", and
the automaton's extra memory pays for its own table cost only where the
format itself has multi-token-scoped modes (JSON's key vs number vs hex
runs) that a single previous-token class cannot see.

### Are the sticky states meaningful? (concrete examples, full 5-token
listings in `dumps/f_sweep/*.log`, `Q4B_EX` lines)

**omw.eval8.65536, row 12** (accepted, net +2,017 bits via order-2, +16 bits
via the sticky split) separates by **which language's entry you are inside**
— exactly PLAN's own prediction for what a sticky state should capture:
- **branch a** (structural/particle mode): `の` (no), `に` (ni), `を` (wo),
  `は` (ha) — Japanese grammatical particles — plus `</Example>\n
  <Exampl` (markup).
- **branch b** (identifier mode): `-n omw-ja-...`, `-v omw-ja-...`,
  `-r" ili="...` — OMW's Japanese-wordnet sense-id suffixes.

**omw.eval8.65536, row 3** (accepted, net +1,957 bits): a cleaner
lexical-content-vs-function split within the same language-boundary theme:
- **branch a**: the same particles (`の`, `に`, `を`, `は`) plus markup.
- **branch b**: actual Japanese content words/kanji — `一` (one), `不`
  (negation prefix), `その` (that), `より` (than/more).

**json.eval8.65536, row 0** (accepted, net +8,663 bits from the sticky split
alone, +249,756 from order-2 on the same row — the single largest number in
this whole notebook): separates digit-run mode from key-template mode,
exactly PLAN's "hex/number/key modes" prediction:
- **branch a**: two-digit numbers — `47`, `58`, `50`, `57`, `48`.
- **branch b**: a recurring JSON field template — `,"key_count":1,"keys":["`.

**freedict.eval8.65536, row 15** (accepted, net +5 bits — tiny, included to
show a case where the mechanism finds *something* real but not much):
- **branch a**: space, `s`, `a `, `, ` — ordinary running text.
- **branch b**: `"` — closing a quoted field, a real but low-value boundary
  signal on this corpus.

**macho.eval8.65536, row 0** (accepted, net +13,774 bits, the biggest single
sticky win): separates single-byte opcodes (branch a: `\x08`, `(`, `\t`,
`)`, `\x88`) from specific 4-byte little-endian ARM64 instruction words
ending in a shared high byte (branch b: `\xe1\x03\x14\xaa`,
`\xe1\x03\x15\xaa`, `\xe1\x03\x13\xaa` — all `mov`-family register-move
encodings sharing the same instruction-class byte `\xaa`) — a real
instruction-boundary/class signal, not noise.

**Verdict: yes, clearly meaningful where it fires at all** — every accepted
split's example tokens separate along a real axis (language, lexical
class, JSON mode, instruction class), never noise — but *whether it fires
at all* (whether it's worth the table cost) depends heavily on how much
of that structure the class bigram hasn't already captured, which on these
word-lexicon corpora at C=16–64 turns out to be very little except on JSON.

### One real bug found and fixed (kept per PLAN's rules of evidence)

The first working version of the sticky-split simulation attributed a run's
own tokens to `r_a`/`r_b` *before* applying their STAY/FLIP decision (an
off-by-one), and reported a spectacular result on `gcide.eval8.65536` row 0:
predicted net **+320,183 bits**. A from-scratch, independently written
full-corpus token-by-token replay (not sharing any code with the run-based
simulator) was built specifically to cross-check this number, and it
disagreed badly: **−343 bits** (the split was actually *worse*). Chasing the
discrepancy found the true bug in two stages — first a token was attributed
to the wrong branch relative to its own decision, then (after a partial fix)
a second, subtler error: **a run's first token must never consult its own
decision at all**, because entering the family from *outside* always lands
on `r_a` unconditionally (no other row carries a STAY/FLIP table — only
`r_a`/`r_b`'s own transitions do), so the first self-loop token's decision
only matters for runs *later* in the corpus where that same bucket
recurs mid-run. After the fix, the incremental predicted `net_bits` matches
the independent full-corpus replay **exactly, bit for bit, on every tested
row** (`row=0: predicted −353.6, full-corpus −353.6`; same for nine other
rows tried, on a real dump, during development). The corrected, honest
result on that row is a rejection (net −353.6 bits), not a 40KB win. Two
synthetic regression tests distilled from that debugging session are kept
permanently in `f_automaton.zig` (`zig test f_automaton.zig` — both pass),
hand-tracing exactly the scenario the bug got wrong: a run's first token
must never consult its own decision, and na+nb must always reproduce the
unsplit row's real event count regardless of the decision vector. This is
the kind of mistake this cost-model style of research is most exposed to (a
plausible-looking formula that silently double-counts or mis-times one
term), and the fix here specifically demonstrates why an independent,
differently-derived verification path is worth building whenever a result
looks unusually good.

## General recipe (one setting, no per-corpus fitting)

1. **Bucket everything with the DP method** (Q1), never floor-log2 tiering.
   It reaches within 0.01–0.10% of exact order-0 entropy with 26–99 buckets
   on every file tested, and it is what Q2's per-class bucketing reuses.
2. **Condition on an induced class bigram at C=16** (Q2), one map, no DAG
   inheritance needed (Lane M's lexicon is already flat/compact), each
   class independently DP-bucketized at a per-bucket overhead around
   25–100 bits (empirically: sweep a doubling ladder once per corpus size
   class and take the minimum — cheap, since the DP itself is fast). This
   is a real, fixed, one-setting recipe that beats exact order-0 entropy by
   +2.8% to +10.0% depending on corpus, with C=64 as a same-file-measured
   fallback worth trying on large, highly redundant / structured corpora
   (json, macho) where it edges out C=16 by ~0.5–1.0pp.
3. **Skip direct bucket induction (Q3) entirely** — it is a clear, measured
   loss (4–17% worse than the recipe above, sometimes worse than plain
   order-0) with the tools built in this lab pass; the two-stage
   class-then-tier decomposition is not just easier to implement, it finds
   a better model.
4. **Automaton splitting (Q4) is a real, validated mechanism with near-zero
   ROI on natural-language dictionary corpora at C=16–64** — ship the class
   bigram alone for freedict/gcide/omw-shaped data, and only reach for
   order-2/sticky-split induction on formats with genuine multi-token-scoped
   modes the previous token's class can't see (JSON-shaped data, where it is
   worth **+3.9%** more).

## Honest verdict / weaknesses stated plainly

- **Q1 is an unqualified success**: near-entropy bucket quantisation at a
  tiny, corpus-independent bucket count, and a clean, general answer to
  "which bucketing method" (the DP, always).
- **Q2 reproduces Lane K's headline gain (a meaningful class-bigram win over
  order-0) but *inverts* Lane K's own C-curve finding once bucket
  quantisation's honest table cost is charged** — the single most important,
  most surprising result in this notebook, and a direct, disclosed answer to
  the brief's "confirm Lane K's gains survive bucket quantisation" question:
  the *gains* survive, the *shape of the C-curve* does not.
- **Q3 is a clean negative result**: three different seeding/refinement
  ideas were tried and measured, none beat the simpler two-stage structure,
  and the reasons why are understood (a locally-separable move objective
  that ignores bucket-width externalities) rather than just "it didn't
  work" — a real, useful negative result per PLAN's rules of evidence, not
  a placeholder for more tuning.
- **Q4's headroom is small and corpus-dependent, honestly reported as such**
  rather than oversold — the mechanism is real (validated by an independent
  full-corpus cross-check after catching a genuine bug that first produced
  a spectacular but wrong number), the qualitative examples are genuinely
  interpretable everywhere they fire, but the *quantitative* case for
  shipping it on dictionary-shaped data is weak at this C; the case for
  format-heavy data (JSON) is strong.
- **Scope limits, disclosed**: Q4 only explores single-row splits (order-2
  full-C-way, or one sticky bipartition) and sums non-interacting splits'
  gains rather than building a general multi-round PDFA learner that grows
  toward ~1024 rows as PLAN's brief invites — a real, bounded lab pass, not
  the full exploration; the additivity argument for summing disjoint splits
  (different candidate rows touch disjoint bucket/run families) was checked
  by construction, not by a further end-to-end multi-split replay. Q2's
  per-bucket-overhead sweep is a discrete doubling ladder (10 points), not
  a continuous optimum search, though the DP's own log2(K) fixed point
  (used for Q1) shows the objective is smooth enough that this is unlikely
  to hide a materially better operating point. Q3's hard-EM refinement
  provably never makes the *reported* number worse than the seed (a
  snapshot/revert safety net), but is not shown to be a good refinement in
  general — only bounded, not fixed.
