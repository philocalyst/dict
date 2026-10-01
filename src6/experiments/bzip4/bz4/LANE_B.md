# Lane B — model codec: how few bits/rule for a real, decodable grammar?

Owner files: `modelcodec.zig` (codec + `zig test` suite), `modellab.zig` (CLI),
`bin/modellab`. Never touches git or files outside this directory.

## Contract recap

MODEL = the rule DAG (children `a,b` for every rule; ids `0..255` = bytes,
`256+i` = rule `i`, children always `<` parent) + `g[s]` (root occurrence
count) for every symbol. `encodeModel(dump, variant) -> ModelBytes` is a real
range-coded (`rc.zig`) stream; `decodeModel(alloc, bytes) -> DecodedModel`
is a genuinely separate function — it takes **only** the byte slice (the
variant tag is read back out of a small raw header inside those bytes, never
passed in by the caller) and reconstructs a renumbered rule set + `g'`. No
permutation is ever transmitted: the decoder discovers the renumbering by
replaying the same post-order DEF-tree walk the encoder used, id-for-id.

`readDump` parses the B4SD format from `PLAN.md` and computes `g[s]` by
summing occurrences of `s` across every block's root-symbol list.

## Design: DEF-tree, post-order numbering

Top-level rules (nobody's child) are walked in an encoder-chosen order.
`emit(s)`: if `s` is a byte or already defined in *this walk*, code `REF(s)`;
otherwise code `DEF`, recursively `emit(left)`, `emit(right)`, and only then
does `s` receive the next id (so ids stay post-order/child-before-parent).
The chosen top-level order is never transmitted — the decoder just runs
`while (defined_count < rule_count) decodeOneTopLevelDef()` and discovers
structure purely from the DEF/REF flags in the bitstream, so any ordering
heuristic is free.

Two independent range-coder streams are used per model: one for structure
(flags, REF codes, `c[s]` transmissions) and one for `g[s]` counts, so the
report below can honestly split "structure bits" from "g-count bits" (cost:
one extra 8-byte rc flush, folded into the header/struct byte count).

## Variants implemented

| tag | top-level order | REF model | slot split | rich g-context |
|---|---|---|---|---|
| `v0_naive` | n/a | 2 fixed-width ids/rule, fixed-width g | – | – |
| `v1_creation` | creation (original id order) | adaptive order-0 Fenwick | no | no |
| `v2_lex_recency` | lex (byte-prefix of expansion) | adaptive + 64-slot MRU cache | no | no |
| `v3_urn` | lex | **urn**: transmit `c[s]` at DEF, exact `remaining/total` | no | no |
| `v4_slotsplit` | lex | urn, `cL[s]`/`cR[s]` transmitted separately | **yes** | no |
| `v5_gctx` | lex | urn | yes | **yes** (top-level × c-bucket × left-child-g≠0 × len-bucket) |
| `v1x_urn_isolated` | creation | urn | no | no | *(ablation: isolates urn vs V1's freq, same order/cache)* |
| `v2x_gctx_on_freq` | lex | adaptive freq (no urn) | no | yes | *(ablation: V5's g-context without urn/slot-split cost)* |
| `v2y_leftchild_order` | **left-child id** | adaptive freq | no | yes | *(ablation: PLAN's third ordering)* |

`c[s]`/`g[s]` are coded with an adaptive unary-length-prefix + raw-mantissa
universal code (`GammaCtx`), wrapped in a cheap dedicated zero-flag
(`CountCtx`) since most values are 0 or 1. The DEF/REF flag is an adaptive
bit conditioned on {slot, depth bucket, was-the-sibling-a-DEF}. Every REF
first tries a 64-slot MRU cache (hit → adaptive hit-bit + 6-bit slot index;
miss → adaptive hit-bit + full model code), which is exactly what makes
"abandon / abandoned / abandoning" cluster cheaply under a lexicographic or
left-child-id top-level walk. `urn` mode's `c[s]` is skipped entirely for
top-level rules (they're never referenced, so it's provably always 0 — free).

## Verification (the part I'd stake the numbers on)

`verifyModel(alloc, dump, decoded)` never touches encoder internals. It
computes a structural (Merkle, Wyhash-based) hash + length for every symbol
on **both** sides via one O(rule_count) pass (children ids are always
smaller, so no recursion needed), matches old↔new ids through a hash→bucket
map, and checks: every old id matched exactly one new id and vice versa,
`g[old] == g'[new]` for every matched pair, and — as a belt-and-suspenders
guard against hash collisions or logic bugs the hash alone couldn't catch —
fully materializes and byte-compares the 32 largest rules' actual
expansions on both sides.

`modelcodec.zig` has three `zig test` cases (no file I/O, hand-built
grammars, runs anywhere): a synthetic-grammar roundtrip through
`encodeModel`→`decodeModel`→`verifyModel` for **every** variant, and a
corruption-fuzz test that flips every interior byte (excluding each
independent rc sub-stream's 8-byte flush tail, which legitimately carries no
information) of a 33-rule chained grammar's encoding and requires ≥90% of
flips to be caught (decode error or `verify.ok == false`).

**That fuzz test earned its keep**: it crashed twice during development on
real bugs, both now fixed (and now covered by the passing test):
1. A corrupted stream where both children of a node routinely decode as
   "still undefined" grows the DEF-tree as a full binary tree of spurious
   DEFs — `2^depth` nodes — which can exhaust the transmitted rule count via
   *width*, not depth, at a much shallower recursion than any depth bound
   would catch, writing past `rules_out`. Fixed by checking the shared
   `next_new_id` counter against `rules_out.len` at the exact point of
   consumption; an entry check based on `defined_count` is insufficient
   because several calls can be simultaneously "in flight" (each waiting on
   a child) and each sees a stale, not-yet-incremented count.
2. The adaptive gamma decoder's unary length prefix could decode `nb=33`
   for a `u32` payload; casting `nb-1=32` into a `u5` shift amount panicked.
   Fixed by capping `nb` at 32, matching the encoder's real maximum.

Both are decoder robustness fixes for corrupted/adversarial input — genuine
encoder output never exercises either path — but they'd have been embarrassing
crashes to ship undetected, and no amount of honest-roundtrip testing on real
dumps would have found them (I ran all 81 dump×variant combinations below,
zero crashes, before I thought to fuzz).

**Result across the full required matrix (9 dumps × 9 variants = 81 runs,
plus both unit tests): every single run reports `verify=OK`, `0/0/0/0`
mismatches (unmatched-old / unmatched-new / g-mismatches / spot-mismatches).**

## Results: best variant per dump

`v2y_leftchild_order` (freq + 64-slot cache + rich g-context, top-level
order by left-child id) wins 7 of 9 dumps; `v2x_gctx_on_freq` (same but lex
byte-prefix order) wins the other 2, by <0.01 bits/rule. Neither the urn
trick nor slot-split make the cut anywhere.

| dump | rules | model bytes | **bits/rule** | struct b/r | g b/r | decode ms | ns/rule |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16k.full | 70,003 | 170,136 | **19.44** | 16.92 | 2.52 | 43.1 | 616 |
| freedict.untouched.64k.full | 12,546 | 27,870 | **17.77** | 15.17 | 2.60 | 3.6 | 287 |
| gcide.eval8.16k.full | 125,124 | 318,240 | **20.35** | 17.56 | 2.79 | 49.0 | 392 |
| gcide.untouched.64k.full | 23,802 | 56,498 | **18.99** | 16.26 | 2.73 | 7.6 | 319 |
| json.eval8.64k.full | 62,809 | 124,043 | **15.80** | 12.59 | 3.21 | 19.4 | 310 |
| macho.eval8.64k.full | 346,709 | 856,107 | **19.75** | 17.71 | 2.04 | 198.7 | 573 |
| omw.eval8.16k.full | 107,117 | 218,704 | **16.33** | 14.98 | 1.36 | 30.5 | 285 |
| omw.untouched.64k.full | 18,021 | 35,672 | **15.84** | 14.18 | 1.66 | 4.3 | 240 |
| zigsrc.eval8.64k.full | 210,725 | 500,429 | **19.00** | 17.21 | 1.78 | 88.9 | 422 |

We did **not** reach the 12–14 bits/rule target on any corpus (closest:
json at 15.8, omw at ~15.8–16.3; farthest: gcide at ~20.3, the dictionary
corpus with the least byte-level substring reuse per grammar rule). Decode
is ~250–600 ns/rule — model decode "startup cost" for macho's 346k rules is
~200 ms, which is real if blocks are small; timings are single-machine and
shared with other lanes per PLAN's rules of evidence, so treat as indicative.

## Ablation (gcide.eval8.16k.full — hardest case — and json.eval8.64k.full — easiest)

| variant | gcide bits/rule | gcide struct/g | json bits/rule | json struct/g | what changed |
|---|---:|---|---:|---|---|
| v0_naive | 42.97 | 31.95 / 11.02 | 40.03 | 29.99 / 10.04 | 2 fixed-width ids + fixed-width g |
| v1_creation | 24.40 | 21.64 / 2.76 | 21.57 | 19.09 / 2.48 | + DEF-tree (REF="already defined" is cheap) |
| v2_lex_recency | 20.86 | 17.57 / 3.29 | 16.97 | 13.45 / 3.52 | + lex top-level order + 64-slot MRU cache |
| v1x_urn_isolated | 24.61 | 21.84 / 2.76 | 21.55 | 19.06 / 2.48 | urn *alone* (creation order, no cache) vs v1: **worse** |
| v3_urn | 21.16 | 17.87 / 3.29 | 17.03 | 13.51 / 3.52 | urn *on top of* v2's order+cache: still **worse than v2** |
| v4_slotsplit | 21.72 | 18.43 / 3.29 | 16.92 | 13.40 / 3.52 | + split cL/cR, two urns: worse almost everywhere |
| v5_gctx | 21.26 | 18.43 / 2.83 | 16.66 | 13.40 / 3.26 | + rich g-context on top of v4: recovers some, still ≥ v2 |
| v2x_gctx_on_freq | 20.48 | 17.57 / 2.91 | 16.74 | 13.45 / 3.29 | v2 (**freq, no urn**) + rich g-context: **beats v5** |
| v2y_leftchild_order | **20.35** | 17.56 / 2.79 | **15.80** | **12.59** / 3.21 | v2x but top-level order = left-child id: best overall |

Reading the table: DEF-tree structure (V0→V1) is the single biggest win
(roughly halves bits/rule). Ordering + recency cache (V1→V2) is the second
biggest (another 10–15%). Everything after that — the urn trick, slot
splitting — is a **negative result**: it never beats plain V2. Rich
g-context is a small, real, additive win (~0.3–0.5 bits/rule) that is best
harvested *without* paying urn's structure-side tax, i.e. bolted onto V2
(giving v2x/v2y) rather than onto V4/V5 as originally planned.

## Failures / negative results (kept per PLAN's rules of evidence)

- **Urn trick (V3) underperforms plain adaptive frequency, holding
  everything else fixed** (`v1x_urn_isolated` vs `v1_creation`: worse on
  every single one of the 9 required dumps, by 0.1–0.7 bits/rule). Cause,
  from the diagnostics below: most rules are referenced only 0–2 times
  total, so "exact remaining/total accounting" has almost nothing to
  concentrate probability around — while transmitting `c[s]` (or `cL`/`cR`)
  costs ~1–2 bits per internal rule unconditionally. The tax isn't repaid.
- **Slot split (V4) compounds the tax**: two zero-flagged gamma codes
  (`cL`, `cR`) instead of one, for no compensating accuracy gain in any
  corpus tested. V4 is the worst of the "smart" variants everywhere.
- **Cache size 32→64 was a wash.** Hit rate barely moved and the wider
  6-bit slot index sometimes cost more than the extra hits saved.
- **Lex order vs left-child-id order**: no clean winner; left-child order
  wins 7/9 required dumps but the margin is under 0.5 bits/rule everywhere,
  and json (repetitive, structured text) prefers left-child order by a full
  bit/rule while omw prefers lex order slightly. Both clearly beat creation
  order (V1) by 3–5 bits/rule.
- Net: I did not end up recommending the variant the PLAN's ordering (V1→V5)
  implies is "final" (V5). The best real variant found is V2's structure
  (order + 64-slot cache + plain adaptive frequency) plus V5's g-context
  idea alone — `v2x_gctx_on_freq` / `v2y_leftchild_order`.

## Diagnostics: why 12–14 bits/rule wasn't reached

Instrumented `gcide.eval8.16k.full` (the hardest required dump; 125,124
rules, `v2x`/`v2y` config, cache=64):

- **77,423 / 125,124 rules (62%) are top-level** (nobody's child) — the
  "full" grammar is more a flat forest of once-used substrings than a deep,
  richly-shared DAG. Every top-level rule is *never* a REF target by
  construction, so they cost nothing to reference but also can't help
  compress other rules.
- Of the 202,547 total REF events, only **38.6% hit the 64-slot recency
  cache**; the other 61.4% fall back to a model over an effective alphabet
  of ~48,000 possible targets (256 bytes + ~47,700 internal, referenced-at-
  least-once rules — top-level rules are excluded by construction).
  Uniform-over-48k is ~15.5 bits, which is roughly what a cache miss costs;
  a weighted 39%-cheap/61%-expensive mix lands almost exactly on the
  ~17–18 struct-bits/rule we measure.
- **91% of REFs target another rule, not a raw byte** — the cheap case
  (bytes, skewed like English letter frequency) is a small minority of the
  coding work; the hard case (picking one specific internal rule out of
  tens of thousands, most used only once or twice ever) dominates.
- This matches PLAN's own warning that "most rules have c=1 or c=0": there
  just isn't a skewed-enough usage distribution among internal rules for
  either an adaptive counter or exact urn accounting to exploit — the
  *only* lever that materially worked was recency (temporal/positional
  locality from a good walk order), not probability modeling of the
  REF alphabet itself.
- json (json.eval8.64k) is close to target (15.8) because it repeats a
  small vocabulary of key names/punctuation constantly (higher effective
  reuse per rule, better cache hit rate); gcide/macho are farthest because
  dictionary prose and machine code both have long, low-reuse tails of
  once-off substrings.

## What I believe is the next biggest inefficiency

The recency cache (a flat, uncontextualized 64-slot MRU) is doing all of the
real work and is clearly under-powered relative to the ~48k-symbol miss
alphabet: **the walk order determines almost the entire result, and neither
order I tried (lex byte-prefix, left-child id) captures the real sharing
structure directly** — both are proxies. The PLAN's own idea I did *not*
get to implement is the more promising lever left on the table: instead of
sorting the *top-level* list once and hoping REFs cluster as a side effect,
walk the reference graph itself — e.g. group rules by shared parent-context
(rules that are the left child of the *same* other rule, or that share a
right-sibling byte) and interleave the cache with an explicit small
per-context table keyed by "last symbol referenced in this exact slot of
this exact rule shape," rather than one global MRU list. Given the 62%
top-level / low-reuse-multiplicity structure measured above, I'd also try
architecture-level alternatives before more REF-model cleverness: growing
the grammar less far (stopping before `min_freq=2` picks up rules used only
once or twice, which cost nearly a full `log2(alphabet)` each to reference
and buy almost nothing), or moving the low-reuse tail into the block/root
stream (Lane S/X's territory) instead of the shared model, since a rule
referenced once is, by definition, cheaper to store inline than to name.
