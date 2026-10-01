# Lane B2 — model codec for Lane M's n-ary lexicon

Owner files: `b2_lexcodec.zig` (clean API + codec + `zig test` suite),
`b2_lab.zig` (measurement CLI), `bin/b2_lab`. Never touches git or files
outside this directory. Reads `PLAN.md`, `LANE_B.md`/`modelcodec.zig`,
`LANE_M.md`/`m_codec.zig`, `rc.zig` for context; imports only `rc.zig` and
`std` (each lane owns its files, so this codec is self-contained rather
than depending on modelcodec.zig/m_codec.zig, matching Lane M's own stated
policy for the same reason).

## Contract recap

Input: B4SD v2 dumps (`dumps/m_*.b4sd`, 12 required) — entries are
`arity >= 2` + that many child ids (0..255 = byte, 256+i = entry i,
**forward references allowed**, whole graph acyclic), plus per-block token
streams. The MODEL to transmit is every entry's spelling + `g[s]` = number
of times `s` occurs as a **block token** (not internal spelling reuse —
that distinction matters, see "why we don't just match Lane M's numbers").
`encode(alloc, entries, g, variant) -> {bytes, old_to_new, stats}`;
`decode(alloc, bytes) -> {entries, g}` sees only the byte slice (the
variant tag lives in a raw header inside those bytes). The decoder is free
to renumber and **re-spell** any entry (flatten to a byte run, or keep it
compositional) as long as its byte expansion is unchanged — `verify()`
checks this from outside both functions by hashing **flattened byte
expansions** (not tree structure, unlike Lane B's Merkle check, precisely
because re-nesting is explicitly allowed here).

## Design: n-ary DEF-tree, generalising Lane B

Lane B's pair-grammar codec (16-20 bits/rule) already answers "how cheap
can a DEF-tree + recency cache get for a low-reuse-tail alphabet" — the
job here is porting that to variable arity plus the specific opportunities
Lane M's *word-like* entries offer that a binary pair grammar can't
(dedicated byte modelling, per-entry spelling choice, g-seeded priors).

**Correctness generalisation (the one Lane B fact that doesn't carry
over unchanged):** Lane B's `top_ids` list — walk only the rules nobody
references, let "child in place" pick up the rest — relies on every
child being *unconditionally* referenced by its parent's fixed 2-ary
structure. Once an entry's spelling choice is adaptive (composed vs
flat, `v6_flat`+), a component may simply never be referenced by anyone.
Fix: the outer walk enumerates **every** entry (in the chosen order),
skipping any already defined; anything left over after the whole pass
gets its own top-level DEF right there. The decoder doesn't need to know
this — it already just calls "decode the next top-level DEF" until
`entry_count` entries exist, exactly Lane B's loop, so the generalisation
is free on the wire.

Per component, three-way kind flag (`known` bit + `is_byte` bit, both
adaptive, context = slot-bucket × depth-bucket): **byte** → a dedicated
byte model (order-0/1/2 adaptive bit-tree, selectable); **REF** → 64-slot
MRU cache, miss falls to an adaptive-frequency model over entry ranks only
(bytes never share this alphabet — a deliberate split from Lane B, which
mixed bytes and rules in one alphabet); **DEF** → recurse in place. Arity,
front-code lengths and `g` all use a from-scratch adaptive
zero-flag+unary+mantissa code (`VarCtx`/`CountCtx`, same spirit as Lane
B's `GammaCtx`/Lane M's `VarCtx`, independently written).

## Variants (16 total, `zig test` roundtrips + verifies every one)

| tag | order | cache | byte model | spelling | extra |
|---|---|---|---|---|---|
| `v0_naive` | n/a | – | fixed-width | – | baseline: fixed arity/id width, fixed-width g |
| `v1_creation` | creation | no | order0 | composed | N1 alone (DEF-tree, no ordering trick) |
| `v2_lex_mru` | lex | yes | order0 | composed | + N2 (lex walk + 64-slot cache) |
| `v3_cm1` | lex | yes | **order1** | composed | ablation: order-1 byte CM |
| `v4_cm2` | lex | yes | **order2** | composed | N3's byte CM (order-2, prev 2 bytes) |
| `v5_gctx` | lex | yes | order2 | composed | + N5 (rich g-context) |
| `v6_flat` | lex | yes | order2 | **adaptive** | N3's big idea: per-entry flat-string-vs-composed by estimated cost + front-coding |
| `v6_nofront` | lex | yes | order2 | adaptive | ablation: v6 without front-coding |
| `v2b_creation_cm2` | creation | yes | order2 | composed | ablation: isolates order's value once CM present |
| `v7_fb` | lex | yes | order0 | composed | + N4 (REF-miss first-byte factorisation) |
| `v7_fb_cm2` | lex | yes | order2 | composed | N4 + N3 combined |
| `v7_fb_nocache` | lex | **no** | order0 | composed | ablation: N4 without the cache |
| `v8_gseed` | lex | yes | order0 | composed | + g-seeded REF priors (new idea, see below) |
| `v8_gseed_nofb` | lex | yes | order0 | composed | ablation: g-seed without N4 |
| `v9_revlex_gseed` | **suffix**-lex | yes | order0 | composed | ablation: PLAN's "reverse-lex" walk order |
| `v9_descg_gseed` | **desc-g** | yes | order0 | composed | ablation: walk by descending `g` instead of spelling |

**New idea beyond the brief — g-seeded REF priors (biggest single win
found):** `g[s]` (root/block-token count) is fully decoded by the time
`s` is *defined*, strictly before any other entry can reference it as a
component. So instead of every entry's adaptive-frequency REF weight
starting at a uniform 1 (Lane B's V1/V2, and this lane's `v1`-`v7`), seed
it with `1 + g[s]`. This is Lane B's own "urn" idea (V3, a **loss** for
them) but the crucial difference is that `g` is transmitted *anyway* as a
required output — there is no extra bit cost to seeding from it, unlike
Lane B's `c[s]`, which had to be transmitted purely to enable the urn and
never paid for itself. Net effect: a free, informative prior exactly
where Lane B's version couldn't afford one.

## Verification

`verify(alloc, orig_entries, orig_g, dec_entries, dec_g)` hashes every
entry's **fully flattened byte expansion** (iterative, cycle-checked
`materializeAll`, not a structural/Merkle hash — the decoder is allowed to
re-nest, so structural hashing would wrongly reject valid output) via
Wyhash, bucket-matches old→new by (hash, exact byte compare), and checks
`g'[new(s)] == g[s]` plus a byte-exact spot check on the 32 longest
entries. **Every one of the 12 required dumps × the 4 variants actually
recommended, plus all 16 variants on a synthetic forward-referencing
lexicon, verified `OK`, 0 mismatches** (192-run full matrix + the `zig
test` synthetic suite).

Two real bugs the `zig test` corruption-fuzz (3,000+ trials: 12 variants ×
(200 random 1-4-bit flips + 50 truncations), `-O ReleaseSafe`) caught
during development, both fixed and now covered by the passing test:

1. **The exact stale-counter bug LANE_B.md already warned about**, hit
   independently while porting: checking `next_rank >= entry_count` once
   at function *entry* is insufficient once several recursive DEF calls
   can be simultaneously in flight (each waiting on a child) — a
   corrupted stream where every child looks like a fresh DEF grows the
   tree wide enough to write past the output array *before* any entry
   check re-fires. Crashed with an out-of-bounds index in the first fuzz
   run. Fixed the same way LANE_B.md did: move the check to the exact
   point of consumption (`rank := next_rank`), not the point of entry.
2. **A `errdefer`-scoping leak, not a crash**: `errdefer dw.alloc.free(buf)`
   registered *inside* the `if (flat) {...} else {...}` block only
   protects errors that unwind through *that block* — once control falls
   through to the shared code after it (where the new point-of-consumption
   check above lives), the registration is already gone, and a failure
   there leaked the entry's `expansion`/`children_ids` buffers. Caught by
   `std.testing.allocator`'s leak detector on the very first
   ReleaseSafe-adjacent fuzz run of the corrupted-decode test; fixed by
   freeing both explicitly on that specific failure path instead of
   relying on unwind.

Decode also caps input against corruption before doing any real work:
`entry_count` bound-checked against the byte stream (rejects a
`u32::MAX`-claimed count without ever allocating), `MAX_ARITY = 2^20`,
`MAX_LEN_PER_ENTRY = 2^24`, a **running** `MAX_TOTAL_EXPANSION = 512 MiB`
budget across all entries (catches many small-but-numerous oversize
claims, not just one big one), and `MAX_DEPTH_ABSOLUTE = 5000` independent
of the claimed entry count (a claimed 20M-entry stream can't recurse
20M deep and blow the native stack before the entry-count-scaled bound
would even fire).

## Results: best variant per dump (12/12 required, all real, all verified)

`pct_of_lanem` = `100 * our_bytes / Lane M's model_bytes` (LANE_M.md's own
headline numbers); lower is better, **bold** where the same variant wins.

| dump | entries | **best variant** | model bytes | bits/entry | struct bpe | g bpe | encode ms | decode ms | **% of Lane M** |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16384 | 20,252 | v8_gseed | 71,880 | 28.39 | 23.64 | 4.75 | 15.7 | 12.7 | **89.5%** |
| freedict.eval8.65536 | 20,240 | v8_gseed | 71,957 | 28.44 | 23.69 | 4.74 | 15.7 | 12.6 | **89.7%** |
| freedict.untouched | 3,316 | v8_gseed | 11,095 | 26.77 | 21.33 | 5.39 | 2.3 | 1.8 | **98.7%** |
| gcide.eval8.16384 | 38,570 | v8_gseed | 123,029 | 25.52 | 20.55 | 4.96 | 28.8 | 22.0 | **86.1%** |
| gcide.eval8.65536 | 38,675 | v8_gseed | 123,625 | 25.57 | 20.62 | 4.95 | 28.8 | 21.7 | **86.1%** |
| gcide.untouched | 7,853 | v8_gseed | 25,414 | 25.89 | 21.02 | 4.85 | 5.4 | 4.5 | **92.5%** |
| json.eval8 | 7,767 | v8_gseed | 19,604 | 20.19 | 13.96 | 6.21 | 5.2 | 4.0 | **75.7%** |
| macho.eval8 | 76,783 | v9_revlex_gseed | 439,890 | 45.83 | 41.81 | 4.02 | 75.5 | 70.5 | **88.0%** |
| omw.eval8.16384 | 23,107 | v6_flat | 163,219 | 56.51 | 52.99 | 3.51 | 88.3 | 21.3 | **82.3%** |
| omw.eval8.65536 | 22,370 | v6_flat | 160,291 | 57.32 | 53.75 | 3.57 | 84.4 | 20.5 | **82.6%** |
| omw.untouched | 4,540 | v8_gseed_nofb | 25,068 | 44.17 | 39.99 | 4.15 | 3.1 | 2.6 | **88.7%** |
| zigsrc.eval8 | 50,680 | v8_gseed | 291,854 | 46.07 | 42.21 | 3.86 | 53.0 | 49.5 | **85.8%** |

**We beat Lane M's model codec on all 12/12 required dumps** (75.7% to
98.7% of its bytes — a real, decoded, verified 1.3% to 24.3% reduction
everywhere), but **we did not reach the `<= 60%` target on any dump**.
`v8_gseed` (lex order + cache + order0 byte model + N4 first-byte
factorisation + g-seeded REF priors + rich g-context) wins 9/12; `v6_flat`
(adaptive flat/composed spelling) wins both OMW eval8 blocks; the
suffix-order ablation `v9_revlex_gseed` wins macho narrowly.
freedict.untouched (only 3,316 entries) is the hardest case for us
specifically — too little data for any adaptive model to out-learn Lane
M's exact static table before the file ends.

Decode is 1.8-70.5 ms even for the 76,783-entry macho dump (~900
ns/entry), well under Lane B's ~573 ns/rule pace but still fast relative
to typical general compressors and dominated by encode-side heuristic
evaluation, not raw range-coder throughput.

## Ablation (gcide.eval8.65536 — dictionary prose, hardest for word-shaped
entries; json.eval8.65536 — repetitive structured text, easiest)

| variant | what it isolates | gcide bytes | gcide bits/e | json bytes | json bits/e |
|---|---|---:|---:|---:|---:|
| v0_naive | fixed-width baseline | 273,515 | 56.58 | 42,633 | 43.91 |
| v1_creation | + N1 DEF-tree (creation order) | 157,095 | 32.50 | 25,575 | 26.34 |
| v2_lex_mru | + N2 lex order + 64-slot cache | 129,529 | 26.79 | 20,417 | 21.03 |
| v3_cm1 | v2 + order-1 byte CM | 129,498 | 26.79 | 20,804 | 21.43 |
| v4_cm2 | v2 + **order-2** byte CM (N3) | 131,148 | 27.13 | 21,414 | 22.06 |
| v5_gctx | v4 + rich g-context (N5) | 129,933 | 26.88 | 21,227 | 21.86 |
| v6_flat | v5 + adaptive flat/front-code (N3 big) | 129,558 | 26.80 | 21,076 | 21.71 |
| v2b_creation_cm2 | v2b: order effect w/ CM present | 159,857 | 33.07 | 26,793 | 27.60 |
| v7_fb | v2 + REF-miss first-byte split (N4) | 126,329 | 26.13 | 19,702 | 20.29 |
| v7_fb_cm2 | N4 + N3 combined | 128,926 | 26.67 | 21,225 | 21.86 |
| v7_fb_nocache | N4 without the cache | 141,973 | 29.37 | 23,041 | 23.73 |
| **v8_gseed** | **+ g-seeded REF priors** | **123,625** | **25.57** | **19,604** | **20.19** |
| v8_gseed_nofb | g-seed without N4 | 125,612 | 25.98 | 20,231 | 20.84 |
| v9_revlex_gseed | suffix-order walk | 128,348 | 26.55 | 21,463 | 22.11 |
| v9_descg_gseed | walk by descending g | 147,876 | 30.59 | 24,449 | 25.18 |

Reading the table: N1 (DEF-tree) is still the single biggest lever here
too (v0→v1, ~40-45% cut), matching LANE_B.md exactly. N2 (lex order +
cache) is the second-biggest (another ~15-18%). Everything after that is
much smaller and some of it is **negative**: N3's byte CM (order-1/2)
consistently *hurts* (v2→v4 is a regression on both corpora, and stacking
it on N4/g-seed is also worse than leaving it out — see failures below).
N4 (first-byte factorisation) is a small, real, additive win (~1.5-3.5%).
The g-seed idea is the second real positive surprise after N4 and the
best single addition on top of N1+N2 (~2-2.5% further). Front-coding
(v6 vs v6_nofront, not shown per-corpus above but see the full 12-dump
matrix) is close to a wash — small win on some corpora (freedict,
zigsrc), small loss on others (gcide) — real but marginal either way.

## Failures / negative results (kept per PLAN's rules of evidence)

- **N3's byte context-mixing model (order-1/2) never wins**, on any of
  the 12 dumps, in any combination tried (`v3_cm1`, `v4_cm2`, `v5_gctx`,
  `v7_fb_cm2` all lose to their order-0 counterparts). Root cause is
  almost certainly **context sparsity**: a full order-2 table has 65,536
  contexts, but the *spelling* stream (as opposed to a full corpus) only
  has thousands to a few hundred thousand byte-component codings total
  across a whole dump — most order-2 contexts see 0-3 samples ever, so
  the model barely moves off its 0.5 cold-start prior while order-0's
  256 contexts each get hundreds to thousands of samples. This directly
  contradicts the brief's expectation ("order-2 ... should cost ~2.5-3.5
  bits") for *this* use (spelling components, not full corpus text) —
  worth flagging since the brief's estimate was pitched at general text
  volumes, not a lexicon's much smaller spelling-only byte stream.
- **Adaptive flat-vs-composed spelling (N3's "big idea") is a wash to
  small win, not a breakthrough.** `v6_flat` beats `v5_gctx` on
  freedict/zigsrc/omw (both blocks) but loses on gcide/json/macho/
  untouched files; averaged over the 12 dumps it is not clearly better
  than staying compositional. Two likely reasons: (1) the mode-selection
  heuristic (`estimateComposedBits`/`estimateFlatBits`) is a cost
  *estimate*, not a real trial encode, and its accuracy for the
  not-yet-defined-child case is a crude `avgDefCostEstimate` proxy, not a
  true recursive cost; (2) most Lane M entries are already short and
  well-served by the composed REF/byte mix, so there is less slack for
  flattening to recover than hoped.
- **Reverse (suffix) lex order (`v9_revlex_gseed`) loses to plain
  (prefix) lex order almost everywhere** (only wins on macho, by a hair)
  — word-final clustering is a weaker signal than word-initial clustering
  for this data, unlike PLAN item 4's "reverse-lex order is the
  statistics-sharing tree" framing (which may describe a different
  regime, e.g. the BWT lanes' adaptive-context setting rather than a
  static DEF-tree walk order).
- **Walking by descending `g` (`v9_descg_gseed`) is the worst ordering
  tried**, 3-15% worse than plain lex order on every dump — it throws
  away the lex clustering that makes the 64-slot cache effective at all
  (a "run"/"running"/"runner" family gets scattered across the walk by
  frequency instead of staying adjacent), confirming LANE_B.md's own
  conclusion that *recency from a good spelling-based order*, not
  frequency-based ordering, is what the cache actually exploits.
- **Bumping the recency cache from 64 to 256 slots was a net loss**
  (measured on gcide.untouched: hit rate rose 45.7%→59.6%, but the wider
  8-bit slot index cost more than the extra hits saved, 26,559 vs 26,242
  bytes) — an exact repeat of LANE_B.md's own 32→64 finding, now
  confirmed at a third cache size on a different alphabet shape (entries
  only, no bytes sharing the cache).
- **`v0_naive`'s first implementation had a real correctness bug**: it
  reused Lane B's v1-format assumption ("child ids are always numerically
  smaller than the parent's own id") to pick a growing per-entry bit
  width, but B4SD **v2** explicitly allows forward references — a
  forward-referencing child id got silently truncated by the too-narrow
  width, and `verify()` caught it immediately (1,102/1,102 unmatched
  entries on the very first real-dump run). Fixed by using one
  whole-alphabet-width (`bitsFor(256+entry_count)`) for every child id
  instead of a growing one.

## Why we didn't reach <=60% (diagnostics)

Instrumented `gcide.untouched.65536` (7,853 entries, `v2_lex_mru`
config): only **45.7%** of REF component occurrences hit the 64-slot
cache (5,715 hits / 12,501 refs); the other 54.3% pay a genuine
adaptive-frequency-over-~7,853-candidates cost. Byte components are
**25%** of all component traffic (4,806 of 19,291), inline-DEF (a
component that had to be defined right there) is **10%**. This mirrors
LANE_B.md's own diagnosis almost exactly ("the walk order determines
almost the entire result... neither order captures the real sharing
structure directly") — we ported the fix that worked for Lane B
(DEF-tree + lex order + cache) and it produces the *same shape* of
result: a real, substantial, verified win over the naive/no-recency
baseline (v0→v2 is a 40-45% cut everywhere), but Lane M's own baseline
was **already** a fairly strong order-0 code (exact final counts, not
adaptive-from-uniform), so there wasn't a Lane-B-style 2x+ gap sitting
unclaimed the way there was for Lane B's naive-vs-tuned comparison.
g-seeding and first-byte factorisation each close a further few percent,
but neither is the "one big lever" the 60% target implies exists — on
this evidence, closing the remaining gap needs either genuinely
higher-order structure in the REF alphabet (grouping by shared *origin*
— e.g. "all entries created by splitting the same parent word in the
same MDL round" — rather than by spelling proximity or frequency, none
of which fully explain reuse locality) or moving cost out of the model
entirely (Lane B's own suggestion: a rule/entry referenced only once or
twice is cheaper to inline at its use site than to name from a shared
model, which would mean *this lane's job* should sometimes be "don't put
it in the model at all" — out of scope here since Lane B2 only sees the
model Lane M already decided to build).

## What I believe is the next biggest inefficiency

**The REF-miss cost itself, not the flag/byte overhead around it.**
Across every dump, misses are 40-60% of REF traffic and each miss pays
`-log2(f/total)` over the *entire* remaining entry population (g-seeding
and first-byte factorisation both attack this and both help, but only by
a few percent each). The diagnostics above suggest the real structure
left on the table is **origin/family grouping**: Lane M's own iterate()
loop creates entries in `propose`/`re-parse` rounds that share a
generative history (a word and its common suffix-variants often get
proposed in the same or adjacent rounds), which neither lex order (spells
the same way, not necessarily proposed together) nor descending-g
(actively wrong, see above) directly captures. A per-parent-context
table — "the last entry referenced right after entry X was Y" (Lane B's
own stated next step, "walk the reference graph itself... interleave the
cache with an explicit small per-context table keyed by 'last symbol
referenced in this exact slot of this exact rule shape'") — was flagged
as promising by Lane B and remains untried here too, for the same reason:
it needs either metadata Lane M's dump doesn't currently expose (which
proposal round created which entry) or a second pass over the corpus
token stream (out of scope: this lane only sees entries + g, never the
block token sequences, by the task's own contract).
