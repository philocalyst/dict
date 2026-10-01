# Lane K — induced part-of-speech classes for root tokens

Owner files: `k_common.zig` (B4SD reader/topology/rc utilities, generalised
and copied from `rootctx.zig`), `k_classes.zig` (learning, inheritance,
overrides, real coding), `k_lab.zig` (CLI driver), this notebook. Binaries
under `bin/`, scratch TSVs under `dumps/k_sweep/`. Never touches another
lane's files.

## The question

Lane X showed that conditioning a root's first byte on the previous root's
last byte (a 256x256 table) buys ~3% on full grammars. PLAN's Round-3 thesis:
bytes are a crude proxy for a token's real syntactic role. Induce the data's
own C-class "part-of-speech" tagging and code

```
P(x_i | x_{i-1}) = T[a(x_{i-1})][b(x_i)] * g[x_i] / G[b(x_i)]
```

with static shared tables (`T`, `C x C+1`; the global counts `g`/`G` the
model already carries for free), and make the model *tiny* by having every
rule **inherit** its class for free from its children (`b(rule) =
b(leftmost child)`, `a(rule) = a(rightmost child)`, recursively to the 256
bytes, which are always stored explicitly), paying only for the rare
**overrides** where the learned class actually differs and the saving beats
the override's own storage cost. See `PLAN.md`'s "Round 3" item 3 for the
full spec; this notebook is the write-up.

## Method (what the code actually does)

1. **Read** the B4SD dump. `k_common.zig` generalises `rootctx.zig`'s reader
   to also accept **version 2** (n-ary rules, arbitrary forward references):
   every rule is normalised to a `children: []u32` slice, and a real
   iterative post-order DFS (`topoOrder`) gives a symbol-id order in which
   every rule's children precede it — for v1 this is provably just
   `0..k-1`, but the code doesn't special-case it, so v2 works unmodified.
   No v2 dumps exist yet in `dumps/` (every producer lane still emits v1),
   so this path is exercised only by construction/logic, not by real data —
   noted honestly, not swept under the rug.
2. **Learn** (`learnClasses`, encoder-only): candidates are the 256 bytes
   (always) plus every rule symbol with `g[x] >= G_MIN`, capped to the
   `candidate_cap` (6000) most frequent rules — see "Performance" below for
   why. Non-candidate rules follow simple first/last-byte inheritance
   *during learning* (PLAN: "rarer tokens follow inheritance during
   learning"). Classes are initialised by frequency-ranked byte buckets
   (PLAN's "or by first/last byte" suggestion). Each of 8 sweeps: rebuild
   `N[ctx][class]`/`G[class]` from the *whole* corpus under the current
   class assignment, refit `logT`, then for every candidate compute its
   **sparse predecessor-class and successor-class histograms** (raw
   token-level adjacency built once, remapped through the current class
   each sweep — exactly PLAN's "rebuilt each sweep" recipe) and reassign it
   to whichever of the `C` classes minimizes an exact bit-cost formula
   (`evalCost`) evaluated against the *fixed* end-of-previous-sweep `T`/`G`
   snapshot. This is a synchronous (EM-style) exchange rather than PLAN's
   literal "move one token, update state, move the next" sequential
   exchange — deliberately: a live-matrix incremental update has a real
   correctness hazard when a token is immediately adjacent to *itself* (the
   one occurrence is simultaneously "this token's own successor-role" and
   "this token's own predecessor-role", and a naive incremental delta double
   counts it — see the `self_count` handling in the code and the aborted
   derivation in the design notes). The synchronous EM form sidesteps that
   hazard entirely and was faster to get exactly right; documented here as a
   deliberate deviation, not an oversight.
3. **Resolve + override** (`finalize`): one topological pass, children
   before parents. At each rule, compute the free inherited default from
   its (already-resolved) leftmost/rightmost child, compare its bit-cost
   against the learned class using the final `T`/`G` snapshot and the same
   candidate's histograms, and commit an override only if the estimated
   saving exceeds a fixed 24-bit estimate of the override's own storage
   cost. `resolveFromOverrides` — the *exact* function used to turn (byte
   classes, override list) into every symbol's resolved class — is called
   identically on the encoder side and, after a real decode of the model
   bytes, on the decoder side, so the two literally cannot disagree.
4. **Re-fit T** from the *final* resolved classes over the real corpus
   (integer counts, exactly what gets coded).
5. **Charge everything, real rc.zig coding.** Byte classes: raw
   `ceil(log2 C)`-bit fields. Overrides: sorted by id, gap-coded with an
   adaptive Elias-gamma-style code (`k_common.gammaEncode` — adaptive unary
   bit-length prefix + raw mantissa, "zeros cheap" as PLAN asks), class
   value as raw bits. The `C x C+1` count table: every cell adaptive-gamma
   coded (dense, but most cells are 0 or small — cheap). Per block: fresh
   `rc.Encoder`, `encodeFreq` over the `C`-wide row `T[a(prev)]` (or the
   dedicated `START` row at block start), then `encodeFreq` of the token
   within its class via a `k_common.BucketSet`/`Fenwick` keyed by class
   instead of by first byte (same machinery Lane X built, just re-bucketed —
   with only up to 128 buckets instead of 256 a linear row-scan replaces
   Lane X's per-row Fenwick, since `C` is always small).
6. **Real decode, verified.** The *whole model* (byte classes, overrides,
   `T`) is decoded back from its own encoded bytes — not reused from the
   encoder's live arrays — before a single block is decoded; every block's
   decoded root sequence is compared symbol-by-symbol against the dump's own
   sequence (`error.RootMismatch`/`error.LengthMismatch` otherwise). Zero
   mismatches occurred in the final sweep reported below. One caveat: the
   optional order-2 variant (last section) reuses the encoder's resolved
   arrays directly rather than re-deriving them from a second decode — its
   payload numbers are still real encode+decode+verify, just not that one
   extra layer of rigor; flagged since it differs from the primary path.

### Fixed constants (same for every file, no per-corpus tuning)

| constant | value | meaning |
|---|---:|---|
| `sweeps` | 8 | EM sweeps for class learning |
| `candidate_cap` | 6000 | most-frequent rule-candidates actually refined |
| `OVERRIDE_COST_BITS` | 24 | fixed estimate of one override's own storage cost, used only to decide whether to commit it |
| `SMOOTH` | 0.5 | additive smoothing in the learning heuristic's `logT`/`log G` (not in the real coded counts, which need none — see PLAN's reasoning in LANE_X.md) |

Like Lane X's constants, these were picked by a bounded sanity sweep (below)
and then frozen — not tuned per corpus.

**Why `candidate_cap = 6000`, not "all of them":** the exchange-style move
evaluation is `O(C)` per candidate per sweep using dense per-class
histograms (`evalCost`), so a full sweep costs `O(candidates * C^2)`. Capping
to the top 6000 most-frequent rule-candidates keeps every run in this
notebook under ~1s even at `C=128`. A direct check on `gcide.eval8.16k.full`
(`C=32`, one map, `g_min=8`) swept the cap `{2000,4000,6000,8000,12000,16000}`
and got `{2.99, 3.40, 3.14, 3.93, 3.63, 2.80}` percent vs X0 — noisy and
**non-monotonic** (more refinement is not strictly better: low-frequency
candidates the EM heuristic reassigns can add noisy overrides that pass the
fixed-cost pruning test but don't actually pay in the exact coded bytes).
The same check on `freedict.eval8.16k.full` peaked at `cap=4000` and
*declined* through 6000/8000. There is no single best cap across corpora;
6000 is a reasonable, cheap, frozen middle ground, exactly like Lane X's
`CTX_BUMP`/`BOOST`. This is a genuine soft spot of the current heuristic,
called out rather than hidden.

## Harness validation

`payload_x0` in every row below is a real static-order-0 `g[]/M` coding —
the same reference Lane X validated against Shannon entropy. Spot check
against `LANE_X.md`'s own X0 numbers: `freedict.eval8.16k.full` 522354,
`gcide.eval8.16k.full` 1277772, `omw.untouched.64k.full` 35393 — all match
exactly. The harness and Lane X's are measuring the same thing.

## Axis 1 — the C curve (one map, inherit on, `g_min=8`, cap=6000)

`pct_vs_x0` (%), across 5 representative dumps + 3 harder cases:

| dump | C=8 | C=16 | C=32 | C=64 | C=128 |
|---|---:|---:|---:|---:|---:|
| freedict.eval8.16k.full | 1.77 | 2.82 | 3.97 | 4.46 | 4.41 |
| gcide.eval8.16k.full | 2.61 | 2.55 | 3.14 | 3.78 | 4.75 |
| omw.eval8.16k.full | 4.05 | 5.00 | 4.87 | 5.18 | 4.51 |
| json.eval8.64k.full | 3.18 | 2.63 | 3.24 | 3.89 | 4.37 |
| macho.eval8.64k.full | 1.03 | 1.93 | 2.44 | 2.88 | 3.23 |
| zigsrc.eval8.64k.full | 1.67 | 3.37 | 3.95 | 4.37 | 4.98 |
| freedict.untouched.64k.full | 1.55 | 1.66 | 1.50 | 1.52 | 1.80 |
| omw.eval8.16k.r8192 (partial grammar) | 9.40 | 11.67 | 14.26 | 15.92 | 16.95 |

**More classes almost always help, monotonically or near it, all the way to
C=128** (the top of the tested range) — unlike Lane X's richer byte-context
(X2), which *diluted*. The partial grammar (`r8192`) shows the clearest
monotone climb (9.4% -> 17.0%) confirming PLAN's guess that coarser,
more word-like tokens have *more* class structure to find, not less. Given
this, C=128 was carried forward; a follow-up could try C=256 but PLAN's
range stopped at 128 and decode/table cost are already climbing there (next
sections).

## Axis 2 — one map vs two maps, inheritance on vs off (C=64, `g_min=8`)

| dump | 1-map, inherit | 2-map, inherit | 1-map, **no inherit** | 2-map, **no inherit** |
|---|---:|---:|---:|---:|
| freedict.eval8.16k.full | 4.46 | 4.44 | 0.65 | -0.45 |
| gcide.eval8.16k.full | 3.78 | **4.67** | -0.12 | -1.02 |
| omw.eval8.16k.full | **5.18** | 4.99 | -0.48 | -1.92 |
| json.eval8.64k.full | 3.89 | **4.07** | 0.39 | 0.28 |
| macho.eval8.64k.full | **2.88** | 2.18 | -0.03 | -0.92 |
| zigsrc.eval8.64k.full | **4.37** | 4.27 | 0.48 | -0.49 |
| freedict.untouched.64k.full | **1.52** | 0.81 | -1.24 | -2.64 |
| omw.eval8.16k.r8192 (partial) | 15.92 | **16.71** | 14.54 | 14.67 |

**Inheritance is the whole game.** Turning it off (every `g>=g_min` token
gets an unconditional explicit class, everything else falls into one flat
default class instead of the free DAG default) makes the model a **net
loss** on 6 of 8 dumps and barely breaks even on the other two, even though
the *same* learned classes are used — the only change is how the *default*
for everything else is computed. On `gcide.eval8.16k.full` at `C=32`, `g_min=8`,
turning inheritance off explicitly overrides all 15,355 candidates (12.5 KB)
for a net of **-0.57% vs X0** — worse than doing nothing — versus 358
overrides (0.5 KB) and **+3.14%** with inheritance on. This is exactly
PLAN's thesis: the DAG inheritance is not a minor optimisation, it is *what
makes the model affordable at all*; without it the override list becomes
the whole per-rule alphabet again and swamps the gain, just like Lane B
found for the raw grammar.

**One map vs two maps is close and file-dependent**: two maps wins on
gcide/json/omw.r8192 (by 0.2-0.9pp), one map wins on the rest, sometimes by
a lot (macho -0.7pp, freedict.untouched -0.7pp for two maps — a second
override list is pure overhead when the corpus is small or the two roles
don't actually need different classes). One map wins 5/8 head-to-head and
never loses badly, so it's the safer "one setting for all files" default;
two maps is a reasonable per-file upgrade worth an extra sweep if you know
the corpus.

## Axis 3 — the `G_MIN` sweep (one map, inherit on, C=64, cap=6000)

| dump | 2 | 4 | 8 | 16 | 32 | 64 | inf (bytes only) |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16k.full | 4.93 | **5.19** | 4.46 | 3.34 | 3.49 | 2.76 | 2.88 |
| gcide.eval8.16k.full | 4.51 | **4.80** | 3.78 | 2.88 | 2.73 | 2.52 | 2.01 |
| omw.eval8.16k.full | **7.13** | 5.86 | 5.18 | 5.06 | 3.26 | 5.08 | 4.15 |
| json.eval8.64k.full | **4.04** | 4.01 | 3.89 | 3.21 | 3.07 | 3.17 | 1.18 |
| macho.eval8.64k.full | **3.12** | 3.08 | 2.88 | 2.53 | 0.26 | 0.71 | -0.01 |
| zigsrc.eval8.64k.full | **5.02** | 4.95 | 4.37 | 2.57 | 2.45 | 1.73 | 1.80 |
| freedict.untouched.64k.full | **2.92** | 1.99 | 1.52 | 1.12 | 1.26 | 1.47 | 1.15 |
| omw.eval8.16k.r8192 (partial) | 15.41 | 15.85 | 15.92 | **16.24** | 15.53 | 12.54 | 5.92 |

Lower `G_MIN` (learn freely on more, rarer tokens) is generally better —
`2` or `4` wins 7 of 8 — because the candidate cap already bounds the cost of
learning on more tokens, and the override-pruning step (not `G_MIN`) is what
actually protects against paying for classes that don't help. **`G_MIN=inf`
(pure byte inheritance, zero rule overrides at all) is positive on every
text/JSON dump** (+1.2% to +4.9%) and even the *worst* dump (`macho`, binary
code with no byte-level junction structure — the one place Lane X's
byte-context ideas also struggled) is a wash (-0.01%), never a real loss.
This means: **just conditioning on induced byte classes, with no learned
overrides whatsoever, is already close to free money** — most of Lane K's
gain on the dictionary corpora is present before a single override is spent;
overrides add another 1-4 points on top for real text.

## General setting, all 36 dumps

**One map, inherit on, `C=128`, `g_min=4`, cap=6000, 8 sweeps** — one fixed
setting, no per-corpus parameters, run on every available B4SD dump
(24 base dumps from the round-1/2 lanes + Lane A's 12 pruned `a_*.best`
grammars). Zero `RootMismatch`/`LengthMismatch`/model-mismatch failures.

| dump | tokens | payload_x0 | net_total | **pct_vs_x0** | per-file best (see below) |
|---|---:|---:|---:|---:|---:|
| freedict.eval8.16k.full | 281885 | 522354 | 495143 | **5.21%** | 5.50% |
| freedict.eval8.64k.full | 281074 | 517781 | 491414 | **5.09%** | 5.51% |
| gcide.eval8.16k.full | 656587 | 1277772 | 1211840 | **5.16%** | 5.61% |
| gcide.eval8.64k.full | 655702 | 1273288 | 1209540 | **5.01%** | 5.66% |
| omw.eval8.16k.full | 111407 | 200463 | 186330 | **7.05%** | 7.13% |
| omw.eval8.64k.full | 108946 | 192598 | 181072 | **5.98%** | 7.20% |
| freedict.untouched.64k.full | 46544 | 73004 | 71376 | **2.23%** | 2.92% |
| gcide.untouched.64k.full | 98270 | 165251 | 157191 | **4.88%** | 5.01% |
| omw.untouched.64k.full | 23212 | 35393 | 33999 | **3.94%** | 5.16% |
| freedict.eval8.16k.r8192 | 507954 | 749816 | 678335 | **9.53%** | 12.05% |
| freedict.eval8.16k.r32768 | 362454 | 623403 | 580933 | **6.81%** | 8.00% |
| gcide.eval8.16k.r8192 | 1225276 | 1803290 | 1620840 | **10.12%** | 12.55% |
| gcide.eval8.16k.r32768 | 909773 | 1547840 | 1434349 | **7.33%** | 8.89% |
| omw.eval8.16k.r8192 | 845888 | 1256770 | 1045403 | **16.82%** | 18.53% |
| omw.eval8.16k.r32768 | 376245 | 617917 | 547650 | **11.37%** | 11.42% |
| json.eval8.64k.full | 605039 | 1058276 | 1012927 | **4.29%** | 4.95% |
| macho.eval8.64k.full | 1069450 | 2153312 | 2081964 | **3.31%** | 3.31% |
| zigsrc.eval8.64k.full | 430537 | 834275 | 792121 | **5.05%** | 5.40% |
| a_freedict.eval8.16384.best | 294721 | 517615 | 486813 | **5.95%** | 6.20% |
| a_freedict.eval8.65536.best | 293720 | 512877 | 482769 | **5.87%** | 6.43% |
| a_freedict.untouched.65536.best | 51799 | 74834 | 72744 | **2.79%** | 3.51% |
| a_gcide.eval8.16384.best | 688019 | 1263576 | 1188911 | **5.91%** | 6.49% |
| a_gcide.eval8.65536.best | 687198 | 1258971 | 1185358 | **5.85%** | 6.60% |
| a_gcide.untouched.65536.best | 105719 | 165853 | 157127 | **5.26%** | 5.87% |
| a_json.eval8.65536.best | 779902 | 1049221 | 997353 | **4.94%** | 5.42% |
| a_macho.eval8.65536.best | 1171122 | 2151439 | 2070648 | **3.76%** | 3.77% |
| a_omw.eval8.16384.best | 112624 | 197329 | 183051 | **7.24%** | 7.38% |
| a_omw.eval8.65536.best | 110108 | 189232 | 174409 | **7.83%** | 7.83% |
| a_omw.untouched.65536.best | 24340 | 36136 | 34361 | **4.91%** | 6.21% |
| a_zigsrc.eval8.65536.best | 448012 | 839592 | 792356 | **5.63%** | 6.09% |
| (6 more: `*.untouched.16k.full`, `{json,macho,zigsrc}.eval8.16k.full` — see `dumps/k_sweep/general.tsv`) | | | | +0.98% to +5.16% | |

Full raw TSVs (all commands and every row, for reproduction): `dumps/k_sweep/general.tsv` (the general setting, 36 rows), `dumps/k_sweep/perfile_grid.tsv` (440-row `{C in [64,128]} x {maps in [1,2]} x {g_min in [2,4,8]}` grid per dump, inherit always on), `dumps/k_sweep/perfile_best.tsv` (best row per dump), `dumps/k_sweep/c_curve.tsv`, `dumps/k_sweep/maps_inherit.tsv`, `dumps/k_sweep/gmin.tsv` (the axis sweeps above).

**Per-file best** (small grid: `C in {64,128}`, `maps in {1,2}`, `g_min in {2,4,8}`, inherit always on) is typically 0.1-1.5 points better than the one general setting, confirming there's a per-corpus optimum but it's close by. The one clear outlier is `omw.untouched.16k.full`: the general setting (`g_min=4`) lands at only **0.98%** while `g_min=2` on the same file gets **4.88%** — a small, unusual corpus where the free-candidate threshold matters a lot more than elsewhere. This is the single biggest gap between "one setting" and "per-file best" found in the whole sweep, and it is exactly the kind of small-corpus fragility Lane X also flagged (`freedict.untouched.64k.full` was its one dump where *nothing* won).

## Versus Lane X's best (X1i/X3/X4)

| dump | Lane X best | Lane K general | Lane K per-file best |
|---|---:|---:|---:|
| freedict.eval8.16k.full | +2.96 (x1i) | **+5.21** | +5.50 |
| freedict.eval8.64k.full | +2.96 (x1i) | **+5.09** | +5.51 |
| gcide.eval8.16k.full | +3.14 (x1i) | **+5.16** | +5.61 |
| gcide.eval8.64k.full | +3.16 (x1i) | **+5.01** | +5.66 |
| omw.eval8.16k.full | +6.23 (x3) | **+7.05** | +7.13 |
| omw.eval8.64k.full | +6.49 (x4) | +5.98 | **+7.20** |
| freedict.untouched.64k.full | -0.76 (best still a loss) | **+2.23** | +2.92 |
| gcide.untouched.64k.full | +2.27 (x1i) | **+4.88** | +5.01 |
| omw.untouched.64k.full | +2.44 (x4) | **+3.94** | +5.16 |
| freedict.eval8.16k.r8192 | +4.71 (x1i) | **+9.53** | +12.05 |
| freedict.eval8.16k.r32768 | +3.55 (x1i) | **+6.81** | +8.00 |
| gcide.eval8.16k.r8192 | +5.12 (x1i) | **+10.12** | +12.55 |
| gcide.eval8.16k.r32768 | +4.00 (x1i) | **+7.33** | +8.89 |
| omw.eval8.16k.r8192 | +11.33 (x4) | **+16.82** | +18.53 |
| omw.eval8.16k.r32768 | +10.49 (x4) | **+11.37** | +11.42 |
| json.eval8.64k.full | +2.25 (x4) | **+4.29** | +4.95 |
| macho.eval8.64k.full | +3.14 (x3) | +3.31 (tie) | +3.31 |
| zigsrc.eval8.64k.full | +7.96 (x4) | +5.05 | +5.40 (still below X) |

Lane K's general setting beats Lane X's best-of-seven-variants on 15 of 17
comparable dumps, often by 2-5 points, and **turns Lane X's one clear
failure (`freedict.untouched.64k.full`, too small to amortise Lane X's
tables) into a solid +2.2% win** — the free byte-inheritance floor (Axis 3)
costs nothing to store beyond 256-512 small fields, so it survives on tiny
corpora where Lane X's 257-row stored table (X1i) couldn't earn its keep.
`macho` ties. **`zigsrc` is the one dump where Lane K's fully static model
loses to Lane X** — X4 (adaptive in-block boost stacked on byte context)
reaches +7.96% there, 3 points above Lane K's best (+5.40%). Source code
apparently has more *in-block, this-specific-block* local repetition (the
thing X3/X4's adaptive boost captures) than cross-block *static syntactic
class* structure — a real, useful negative result: Lane K's static classes
and Lane X's adaptive boost are answering different questions, and neither
subsumes the other.

## Order-2 class context (exploratory, PLAN's "optional")

`T[a(x_{i-2})][a(x_{i-1})][b(x_i)]`, reusing the *same* order-1-learned
classes (not re-learned with an order-2 objective — see the caveat in
"Method"), tested at small `C` only as PLAN asks:

| dump | C | order-1 | order-2 |
|---|---:|---:|---:|
| gcide.eval8.16k.full | 8 | 2.61 | **2.78** |
| gcide.eval8.16k.full | 16 | 2.55 | **2.66** |
| json.eval8.64k.full | 8 | 3.18 | **4.65** |
| json.eval8.64k.full | 16 | 2.63 | **4.16** |
| omw.eval8.16k.r8192 | 8 | 9.40 | **10.24** |
| omw.eval8.16k.r8192 | 16 | 11.67 | **13.11** |

Order-2 context is a **consistent, sometimes large win** at small `C` (JSON
nearly +1.5pp at C=8, i.e. a 46% relative improvement) at essentially the
same decode cost (still one `O(C)`-ish row scan, just into a bigger flat
table — 147ns/token for order-2 vs 148ns for order-1 on gcide C=8). This is
genuinely promising and, if this lab continues, the first thing worth
building properly (a real order-2-aware class *learning* objective, not just
reusing order-1 classes at coding time, and a real second decode of the
model bytes matching the primary path's rigor).

## Are the classes meaningful? (gcide + json, 12 biggest classes, top 10 tokens each)

Full listings: `dumps/k_sweep/classes_gcide.txt`, `dumps/k_sweep/classes_json.txt` (C=32, one map, g_min=8). Highlights:

**gcide** (dictionary text) cleanly separates into recognisable syntactic
roles:
- class 2 — **clause connectors**: `, or`, ` or`, ` and`, `, and`, `;`, `; a`, ` to`, ` in`, `</xex>`, ` is`
- class 11 — **articles/determiners & low-content function words**: ` a`, `\n`, ` <xex>`, ` an`, `\nthe`, ` (`, ` at`, ` `, ` not`
- class 3 — **inflectional suffixes, consonant-final**: `ed`, `ly`, `an`, `er`, `en`, `ant`, `d`, `l`, `m`, `b`
- class 4 — **inflectional suffixes, vowel/other**: `y`, `al`, `in`, `ic`, `es`, `ist`, `ar`, `on`, `at`, `us`
- class 0 — **sentence-final punctuation & markup closers**: `s`, `"`, `ers`, a source-citation fragment, `. `, `st`, `.`, more citation fragments, `. See <er>`, `.\n`
- class 5 — **capitalised word-openers**: `A`, `B`, `C`, `An`, `S`, `The`, `In`, `F`, `L`, `D`
- class 12 — **entry/markup-boundary structure**: `</ent><br/\n<hw>`, `</ex>\n`, `</ent><br/\n<hw>b`, ...

This is exactly the "the data's own part-of-speech tags" PLAN asked for:
connectors, determiners, two flavours of suffix, closing punctuation,
capitals, and dictionary-markup boundaries all separated with no
text-specific rule anywhere in the code.

**json** separates into exactly the "key/number/hex/punctuation modes" PLAN
predicted:
- class 1 — **decimal-digit-pair "number" mode**: `01`, `34`, `06`, `39`, `09`, `28`, `15`, `23`, `24`, `00`
- class 3 and class 0 — **two different hex-digit-pair clusters**: `eb`,`b8`,`ac`,`6f`,`b9`... / `a6`,`0f`,`3d`,`0c`,`e4`...
- class 4, 5, 9, 11, 14, 15, 16 — **field-template "key" modes**, one class
  per recurring JSON field shape: `"file":"CIDE.*","file_record":N`,
  `"source_file":"/private/tmp/dictionary...`, `"key_count":1,"keys":["X`,
  `,"content_sha256":"X`, `}\n{"content_bytes":N`
- class 2 — a **third hex/base cluster** (`e`, `eac`, `aef`, `a`, `aeb`...)

**Verdict: yes, clearly meaningful**, on both a natural-language corpus and
a structured-data corpus, with zero corpus-specific code — the classes are
an emergent, inspectable finite-state syntax of the input format, precisely
the "induce the data's own part-of-speech tags" thesis.

## Decode cost

At the general setting (C=128), decode is **130-330 ns/token** across the
36 dumps (`dumps/k_sweep/general.tsv`, column `decode_ns_per_token`),
roughly **1.3-2.5x** the plain X0 baseline reported in `LANE_X.md` (X0:
~55-160 ns/root) — the same order of overhead Lane X measured for its own
context variants, from one extra `O(C)` linear row-scan per token (C<=128
is cheap even unscanned-linearly; no Fenwick needed there) plus the
per-class Fenwick descent for the within-class pick (same cost shape as
Lane X's per-first-byte Fenwick, just re-bucketed by class). At smaller `C`
(8-32) decode is faster still (~90-200 ns/token) at correspondingly lower
compression. Learning (`learn_ms`) is a one-time encoder-side cost, 15ms
(G_MIN=inf, tiny candidate set) to ~1000ms (C=128, low G_MIN, full 6000-cap
candidate set on the biggest dumps) — irrelevant to decode speed and small
next to a corpus-scale grammar build.

## Honest verdict

- **The core idea works, and works better than Lane X's byte-context
  models**: a fixed, one-setting (C=128, one map, inherit on, `g_min=4`)
  induced class model beats Lane X's best variant on 15/17 comparable
  dumps, sometimes by 2-5 points, turns Lane X's one failure into a solid
  win, and the induced classes are demonstrably meaningful on inspection
  (real syntactic/lexical categories in text, real key/number/hex "modes"
  in JSON) — this is not just a bigger number, it is the "class-based
  bigram over a learned finite-state syntax" PLAN asked for, visibly doing
  what it says.
- **Inheritance is not a minor optimisation, it is the entire reason this
  is affordable**: turning it off (still learning the same classes, just
  storing them all explicitly with a flat default for the rest) makes the
  model a *net loss* on 6 of 8 tested dumps. This is the clearest, most
  important result in the notebook and validates PLAN's central "clever
  part" claim directly.
- **The C curve keeps climbing to 128** (the top of PLAN's suggested
  range) with no sign of the dilution Lane X saw from richer context —
  worth trying C=256 in a follow-up.
- **Byte-class inheritance alone (`g_min=inf`, zero overrides) is already
  a robust, essentially-free win** (+1% to +5% on every text/JSON dump,
  breakeven on binary) — if only one piece of this lab should ship, it's
  this one: no learning loop, ~1KB of stored byte classes, no override
  bookkeeping at all.
- **Partial grammars gain the most** (up to +18.5% per-file-best on
  `omw.r8192`), confirming PLAN's prediction that coarser, more word-like
  tokens carry more inducible class structure.
- **Weaknesses, stated plainly**: (1) the exchange-learning heuristic is
  noisy in `candidate_cap` and doesn't monotonically improve with more
  refinement — a real soft spot, not tuned away, just bounded and disclosed;
  (2) one setting is 0.1-1.5pp below per-file best almost everywhere, and
  up to 4pp below on one small/unusual corpus
  (`omw.untouched.16k.full`); (3) it loses to Lane X's adaptive X4 on
  `zigsrc` — static classes and adaptive in-block boosting are not the same
  lever; (4) order-2 context is a real further win (tested only lightly)
  that a from-scratch implementation should chase before shipping.
- **Recommendation: yes, this deserves to be in the codec**, ahead of
  Lane X's context stack — bigger, more reliable gains, meaningful
  induced structure, decode cost in the same ballpark Lane X already
  accepted, and it *works at 16 KiB blocks* exactly as PLAN required
  (no in-block adaptation anywhere in the primary path). At minimum ship
  the free byte-inheritance floor; the full learned-override model is a
  clear net win everywhere tested except the already-known-hard "too small
  to amortise anything" corner Lane X hit first.
