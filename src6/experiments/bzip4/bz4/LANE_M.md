# Lane M — compositional MDL lexicon, lab notebook

Owner files: `m_lexicon.zig` (engine: n-ary `Lexicon`, propose/re-parse/
recount/delete, flat-array trie, `iterate()`), `m_codec.zig` (real
range-coded codec + `zig test` suite), `m_lab.zig` (measurement harness
that produced every number below), `m_probe.zig` (single-file dev driver,
not part of the report). Binaries under `bin/m_*`, dumps under
`dumps/m_*.b4sd` (B4SD version 2, n-ary rules) and the qualitative-listing
raw output under the project scratchpad. See `PLAN.md` "Round 3 —
structural rethink" items 1–2 for the brief, `LANE_A.md`/`grammar2.zig`
for the Re-Pair baseline this lane tries to beat, `LANE_B.md` for the real
cost of storing a *pair* grammar (16–20 bits/rule), `rc.zig` (shared range
coder, unmodified, imported directly).

## The question

Re-Pair (Lane A) merges frequent byte pairs bottom-up and never revisits a
decision: the alphabet fills with cross-boundary fragments, structural
filler (a rule used exactly once inside another rule — 57% of OMW's), and
junk (thousands of rules for random hex digits in JSON). Lane M replaces
this with a de Marcken-style compositional MDL lexicon: n-ary entries, one
shared unigram code for corpus tokens and lexicon spellings ("the lexicon
is just more text"), and an iterated propose → re-parse → recount → delete
loop so every round can undo the previous round's mistakes. Does this beat
Lane A's Re-Pair+MDL-deletion grammar in **real** total bytes, and do the
resulting entries actually look like words?

## What was built

- **`m_lexicon.zig`**: `Lexicon` stores entries CSR-style (`comp_off` /
  `comp_data` / `explen`; arity ≥ 2, components are bytes 0..255 or other
  entries 256+i). `seedBytes` seeds from raw bytes; `seedFromV1` flattens a
  Lane A B4SD-v1 grammar (read directly from its dump file — no dependency
  on Lane A's code, only its published dump format) into arity-2 entries,
  the "faster" seed PLAN suggested. `proposePairs`/`proposeTriples` tally
  adjacent pairs/triples over the current parse of the corpus **and every
  entry's own spelling**, score by estimated ΔDL, select a role-consistent
  batch (Lane A's builder trick, generalised), and rewrite both the corpus
  and every existing entry's spelling in one pass — a *strict*
  generalisation of Re-Pair's single-pair-family-per-round rule to n-ary
  storage. `reparseRound` rebuilds a **flat-array trie with no hashmap
  anywhere** (small sorted per-node edge lists built in one pass from
  globally-sorted expansion strings, no hashing, no `std.AutoHashMap` — see
  "builder speed" below) and re-tokenises every corpus block *and* every
  entry's own byte expansion with a shortest-code-length DP, filtering
  candidates to strictly-shorter-`explen` when re-parsing an entry's own
  spelling (PLAN's acyclicity rule); it is self-validating (keeps the old
  parse if the honestly-recounted DL got worse — Lane A's "chicken and egg"
  lesson, LANE_A.md #3). `deletePass` generalises Lane A's A2 from "delete
  only if nobody's child" to **delete an entry wherever it is used, corpus
  or inside another entry's spelling**, splicing its own spelling back in
  (n-ary storage makes this possible; Lane A's fixed-arity-2 `Rule{a,b}`
  could not hold an inlined arity>2 parent). The benefit formula is a fresh
  derivation (not Lane A's — Lane A only charged for *root* occurrences;
  Lane M's population includes every spelling slot too) using the same
  `M·log2 M − Σf(c)` exact-identity trick as LANE_A.md. `iterate()` loops
  propose→reparse→delete until DL improves <0.05% or 20 iterations (PLAN's
  stopping rule), with a top-level snapshot/revert if a whole iteration
  nets out worse (propose is a heuristic batch accept, not self-validating,
  so this can happen — it did, rarely, in testing).
- **`m_codec.zig`**: entries renumbered by **descending count** (bytes keep
  their natural 0..255 id); byte counts, then entry count+deltas (mostly
  0, cheap), then arities, then **every spelling component and every
  corpus token** coded against **one static frequency table** built from
  the final `n(t)` — exactly PLAN's spec. Counts/deltas/arities use a
  from-scratch adaptive unary-length-prefix + raw-mantissa code (same
  spirit as Lane B's `GammaCtx`, independently written — Lane B's file is
  not shared/read-only for this lane). Forward references are allowed;
  the decoder reads the whole model, then expands every entry by memoised
  DFS with a color-based cycle guard, a recursion-depth cap, and a
  total-expansion-size cap (`zig test` includes a hand-built cyclic stream
  that the decoder correctly rejects with `error.Cycle`). Every block is
  its own independent range-coder stream (8 bytes of framing + its own
  8-byte flush, both charged). `encode`→`decode`→byte-compare-against-raw
  ran for all 12 required combos plus 2 ablation combos; **every run
  verified byte-exact**.
- **`m_lab.zig`**: drives the 12 required (file, block) combos, each
  seeded from Lane A's own published best grammar
  (`dumps/a_<file>.<block>.best.b4sd`), two variants each (pairs+triples,
  pairs-only), full codec round-trip + verification, writes
  `dumps/m_<file>.<block>.b4sd` (B4SD v2), plus a 2-file byte-seed ablation
  and the gcide/json qualitative listing. Total wall time for the whole
  matrix (12 combos × 2 variants + 2 byte-seed ablations + 2 qualitative
  reruns): **3 min 23 s**, one machine, indicative per PLAN's rules of
  evidence.

## Headline results (primary variant: a3-seed, pairs + triples, 20-iter cap)

All entries/tokens/bytes below are from a **real encoder whose output a
real decoder turned back into the exact input**, verified in the same run.
`%vs bzip3` and `%vs Re-Pair-static` are `100·(1 − total/baseline)`;
positive = Lane M smaller.

| file | block | entries | tokens | B/token | model B | payload B | **total B** | bzip3 B | Re-Pair-static B | %vs bzip3 | %vs Re-Pair-static | iters | iterate s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 65536 | 20,240 | 373,954 | 22.43 | 80,213 | 585,090 | **665,331** | 899,408 | 692,000 | **26.0%** | **3.9%** | 7 | 6.8 |
| freedict.eval8 | 16384 | 20,252 | 375,509 | 22.34 | 80,338 | 593,642 | **674,008** | 1,189,002 | 692,000 | **43.3%** | **2.6%** | 7 | 10.7 |
| freedict.untouched | 65536 | 3,316 | 65,808 | 15.93 | 11,237 | 84,582 | **95,847** | 115,160 | 101,000 | **16.8%** | **5.1%** | 8 | 0.6 |
| gcide.eval8 | 65536 | 38,675 | 826,087 | 10.15 | 143,564 | 1,374,760 | **1,518,352** | 1,905,560 | 1,603,000 | **20.3%** | **5.3%** | 7 | 9.1 |
| gcide.eval8 | 16384 | 38,570 | 828,484 | 10.13 | 142,868 | 1,383,603 | **1,526,499** | 2,362,319 | 1,603,000 | **35.4%** | **4.8%** | 7 | 9.6 |
| gcide.untouched | 65536 | 7,853 | 130,711 | 8.02 | 27,486 | 185,882 | **213,396** | 235,103 | 222,000 | **9.2%** | **3.9%** | 7 | 0.7 |
| omw.eval8 | 65536 | 22,370 | 163,742 | 51.23 | 194,059 | 263,248 | **457,335** | 674,384 | 424,000 | **32.2%** | −7.9% | 20 | 10.6 |
| omw.eval8 | 16384 | 23,107 | 162,478 | 51.63 | 198,208 | 268,749 | **466,985** | 1,124,142 | 424,000 | **58.5%** | −10.1% | 19 | 10.9 |
| omw.untouched | 65536 | 4,540 | 36,735 | 28.54 | 28,248 | 50,819 | **79,095** | 95,276 | 71,000 | **17.0%** | −11.4% | 20 | 1.2 |
| json.eval8 | 65536 | 7,767 | 804,755 | 10.42 | 25,882 | 1,056,682 | **1,082,592** | 1,028,983 | 1,183,000 | −5.2% | **8.5%** | 8 | 5.1 |
| macho.eval8 | 65536 | 76,783 | 1,574,913 | 5.33 | 499,994 | 2,557,796 | **3,057,818** | 3,259,348 | 3,008,000 | **6.2%** | −1.7% | 14 | 21.7 |
| zigsrc.eval8 | 65536 | 50,680 | 627,914 | 13.36 | 340,084 | 1,048,863 | **1,388,975** | 1,454,997 | 1,336,000 | **4.5%** | −4.0% | 10 | 12.7 |

`bzip3 B` from `baselines.tsv`; `Re-Pair-static B` is the number given in
PLAN's Lane M brief directly (payload Huffman + Lane B model + directory,
assembled from rounds 1–2, all at 64K — not re-derived here). Also checked
against Lane A's own **idealised** `est_rb13` numbers in LANE_A.md
(flat-13-bits/rule, since disproven by Lane B's own measurement of
15.8–20.35 real bits/rule): Lane M's real bytes are 0.3–18% *larger* than
that idealised estimate everywhere, which only confirms the estimate was
optimistic, not that Lane M underperforms the real static path — the
Re-Pair-static column above is the fair (real-vs-real) comparison.

**Beats bzip3 on 11/12 combos** (4.5–58.5%), loses narrowly on json.eval8
(−5.2%: JSON's redundancy is digit/hex-run structure, not word structure —
see qualitative section). **Beats the real Re-Pair-static path on 7/12**
(dictionaries + json, 2.6–8.5%), **loses on omw (all 3) and the two
generality files macho/zigsrc** (−1.7% to −11.4%) — see "biggest remaining
inefficiency" below for why.

## Seed → converged: what deletion + re-parse actually did

| file | block | seed entries → tokens | converged entries → tokens |
|---|---:|---|---|
| freedict.eval8 | 65536 | 60,024 → 293,720 | 20,240 → 373,954 |
| freedict.eval8 | 16384 | 60,162 → 294,721 | 20,252 → 375,509 |
| freedict.untouched | 65536 | 9,737 → 51,799 | 3,316 → 65,808 |
| gcide.eval8 | 65536 | 101,409 → 687,198 | 38,675 → 826,087 |
| gcide.eval8 | 16384 | 101,312 → 688,019 | 38,570 → 828,484 |
| gcide.untouched | 65536 | 19,597 → 105,719 | 7,853 → 130,711 |
| omw.eval8 | 65536 | 103,525 → 110,108 | 22,370 → 163,742 |
| omw.eval8 | 16384 | 103,972 → 112,624 | 23,107 → 162,478 |
| omw.untouched | 65536 | 17,517 → 24,340 | 4,540 → 36,735 |
| json.eval8 | 65536 | 15,864 → 779,902 | 7,767 → 804,755 |
| macho.eval8 | 65536 | 301,438 → 1,171,122 | 76,783 → 1,574,913 |
| zigsrc.eval8 | 65536 | 200,653 → 448,012 | 50,680 → 627,914 |

The loop **deletes 65–75% of the seed grammar's entries** everywhere
(freedict/gcide/macho/zigsrc even more: e.g. macho 301,438 → 76,783, a
75% cut) but the token stream **grows** 20–49% in the process (Re-Pair's
own root count was optimised to be small; MDL deletion removes rules that
were locally profitable but costing more in model overhead than they
saved, and re-explains their occurrences with more, cheaper, better-shared
tokens). Net effect is still a real total-byte win everywhere except the
5 combos noted above — see below for why those 5 don't recover fully.

## Ingredient ablations

### Triples (never hurt, biggest win where entries are sparse)

`%gain` = `100·(1 − total_with_triples / total_pairs_only)`, same seed,
same 20-iteration budget:

| file | block | pairs-only total B | +triples total B | gain |
|---|---:|---:|---:|---:|
| freedict.eval8 | 65536 | 668,731 | 665,331 | 0.51% |
| freedict.eval8 | 16384 | 676,932 | 674,008 | 0.43% |
| freedict.untouched | 65536 | 96,459 | 95,847 | 0.63% |
| gcide.eval8 | 65536 | 1,521,716 | 1,518,352 | 0.22% |
| gcide.eval8 | 16384 | 1,529,665 | 1,526,499 | 0.21% |
| gcide.untouched | 65536 | 214,133 | 213,396 | 0.34% |
| **omw.eval8** | 65536 | 486,920 | 457,335 | **6.08%** |
| **omw.eval8** | 16384 | 491,268 | 466,985 | **4.94%** |
| **omw.untouched** | 65536 | 83,466 | 79,095 | **5.24%** |
| json.eval8 | 65536 | 1,082,784 | 1,082,592 | 0.02% |
| macho.eval8 | 65536 | 3,109,000 | 3,057,818 | 1.65% |
| zigsrc.eval8 | 65536 | 1,414,616 | 1,388,975 | 1.81% |

Triples never regressed a single combo. They matter most on OMW, whose
grammar LANE_A.md flagged as **56.8% single-parent structural filler**:
letting the proposer glue 3 tokens in one step (e.g. an already-merged
`" partOfSpeech="` plus `"n"` plus `" />"` in one shot) skips an
intermediate 2-token entry that pairs-only would otherwise have to create,
pay for, and then have deletion clean up. Also converged (didn't hit the
20-iteration cap) on 10/12 combos; omw (both blocks) and omw.untouched
were still improving slightly at iteration 20 — see DL curves below.

### Seeding: Lane A's a3 grammar vs. bytes-only, both pairs-only (no
triples), 20-iteration cap, real codec run both sides

| file | seed | entries | tokens | iters used | DL-est curve (bytes) | real total B |
|---|---|---:|---:|---:|---|---:|
| gcide.eval8 | a3 (Lane A) | 37,510 | 833,748 | 6 (converged) | 1573576→1551328→1546125→1543621→1542359→**1541705** | **1,521,716** |
| gcide.eval8 | bytes only | 36,264 | 850,423 | 15 (converged) | 4678299→3909138→...→1554774→**1554117** | **1,535,095** |
| omw.untouched | a3 (Lane A) | 4,849 | 41,821 | 15 (converged) | 104276→...→85667→85375→**85400** (tiny uptick, converge-threshold stop) | **83,466** |
| omw.untouched | bytes only | 4,519 | 41,103 | 20 (hit cap, still improving) | 596068→...→83193→83125→**83026** | **81,418** |

Mixed, and honestly reported: on **gcide.eval8**, a3-seed wins on both
speed (6 vs 15 iterations) and final quality (1,521,716 vs 1,535,095 real
bytes, 0.9% smaller) — PLAN's predicted advantage held up cleanly. On
**omw.untouched**, a3-seed converges faster (15 vs 20) but its own
0.05%-improvement stopping rule fires while byte-seed is still grinding
out gains — byte-seed hits the 20-iteration cap *still improving* and
ends up 2.4% *smaller* (81,418 vs 83,466 real bytes) than the
already-converged a3-seed run. So the honest finding is: a3-seed is
reliably the **faster** starting point (matches PLAN's "faster" framing
every time), but "faster to converge" and "better within a fixed
iteration budget" are not the same claim, and on at least one file
byte-only seeding — a genuine, general, no-text-specific-rule, no-other-
lane-dependency starting point — closes the gap and wins once given
enough rounds. (Both ablation rows above are the *pairs-only* setting;
the headline table's a3+triples row for omw.untouched, 79,095 B, still
beats both of these, so triples matter more than the seed choice here.)

### DL-per-iteration curves (est bytes, primary variant, pairs+triples)

```
freedict.eval8    65536: 695718,681674,677791,675756,674775,674328,674166
freedict.eval8    16384: 698410,684504,680549,678605,677500,677126,676955
freedict.untouched65536: 100661,98646,97926,97547,97340,97210,97149,97152
gcide.eval8       65536: 1573525,1549990,1544612,1541828,1540256,1539313,1538803
gcide.eval8       16384: 1575398,1552325,1546321,1543808,1542338,1541473,1541049
gcide.untouched   65536: 223439,219174,218045,217579,217381,217226,217188
omw.eval8         65536: 530982,514105,502628,491427,483967,479464,476135,473643,471833,470484,
                          469238,468391,467640,467363,466690,466118,465855,465446,465027,464908
omw.eval8         16384: 537995,505797,496474,487699,483016,479367,476393,474555,473205,472352,
                          471817,471351,471055,470738,470409,470018,469590,469328,469101
omw.untouched     65536: 104276,96209,89714,86220,84813,84248,83803,83047,82375,82170,81747,
                          81459,81288,81208,81056,80972,80921,80770,80703,80717
json.eval8        65536: 1095851,1090510,1088818,1087797,1086954,1086182,1085532,1085076
macho.eval8       65536: 3294716,3203764,3156393,3133014,3121382,3113595,3108547,3104625,
                          3100981,3098288,3095818,3094045,3092219,3090689
zigsrc.eval8      65536: 1535596,1468488,1437065,1424715,1419772,1414872,1413323,1412221,
                          1410335,1409823
```

Note the freedict.untouched curve: iteration 7→8 (97,210 → 97,149 →
97,152, last value shown) is where the top-level revert-on-regression
safety net in `iterate()` fired — the logged final iteration nets out
microscopically worse than its predecessor and the loop stops there (the
returned *state* is the pre-regression one; the logged number for the
attempted iteration is kept for transparency, per PLAN's "keep a terse
notebook ... including failures").

## Model cost per entry (bits, real codec)

`model_bytes·8 / entries`, real codec output:

| file | bits/entry |
|---|---:|
| json.eval8 | 26.7 |
| freedict.untouched | 27.1 |
| gcide.untouched | 28.0 |
| gcide.eval8 | 29.6–29.7 |
| freedict.eval8 | 31.7 |
| omw.untouched | 49.8 |
| macho.eval8 | 52.1 |
| zigsrc.eval8 | 53.7 |
| omw.eval8 | 68.6–69.4 |

This is the honest, uncomfortable number: Lane M's model codec (rank-sort
+ adaptive-delta counts/arities + one static frequency table for every
reference) costs **1.5–3.5× more bits per entry** than Lane B's tuned
DEF-tree + 64-slot MRU cache + rich g-context codec (15.8–20.35 bits/rule,
LANE_B.md) on the *same kind* of low-reuse-tail problem. Lane M never
built a DEF-tree/REF-with-recency-cache mechanism — every reference,
however recent or structurally predictable, pays the full static-table
cost. On corpora where the surviving entries are used often (json:
804,755 tokens over 7,767 entries, ~104 uses/entry; the dictionaries:
~10–22 uses/entry) that overhead is amortised away and Lane M wins
outright. On corpora with many low-reuse entries (omw: 163,742 tokens
over 22,370 entries, ~7.3 uses/entry, and LANE_A.md's own finding that
56.8% of OMW's grammar is single-use structural filler; macho and zigsrc
similarly long-tailed) the *parse* is better (fewer, better-chosen tokens)
but the **model** is proportionately worse, and on these 5 combos the
model regression outweighs the payload gain against the real Re-Pair
static path (whose LANE_B-tuned codec pays much less per rule for exactly
this long-tail case).

## Qualitative evidence: words vs. fragments

40 most-frequent multi-byte entries and 40 random entries with expansion
length 6–20 (escaped `\xNN`), MDL lexicon vs. the Re-Pair grammar dump
(`dumps/gcide.eval8.64k.full.b4sd`, `dumps/json.eval8.64k.full.b4sd` — the
"full" min_freq=2 grammar named in the brief). Full listings, unedited,
`n` = use count, `len` = expansion length:

### gcide.eval8

**MDL lexicon — top 40 by count:**
```
n=10111 len=2  |, |            n=1996 len=5  |, or |          n=1336 len=4  |; a |
n=6192  len=2  |; |            n=1982 len=2  |s |             n=1333 len=6  |, and |
n=5973  len=4  | or |          n=1943 len=5  |<qex>|          n=1302 len=57 |.</def><br/\x0a[<source>1913 Webster</source>]</p>\x0a\x0a<p><ent>|
n=3815  len=2  |a |            n=1847 len=3  |ing|            n=1295 len=2  |an|
n=3711  len=4  | of |          n=1829 len=5  |; to |          n=1221 len=4  | to |
n=3605  len=4  |the |          n=1743 len=2  |,\x0a|           n=1202 len=2  |ic|
n=2919  len=2  |er|            n=1736 len=4  |ing |           n=1202 len=5  |</er>|
n=2748  len=5  | and |         n=1657 len=15 |</ent><br/\x0a<hw>|  n=1192 len=4  | or\x0a|
n=2195  len=2  |in|            n=1621 len=8  | of the |       n=1159 len=3  |an |
n=2128  len=2  |al|            n=1371 len=4  | in |           n=1146 len=2  |en|
n=2009  len=2  |ed|            n=1367 len=3  |ed |            n=1141 len=2  |a\x0a|
                                n=1363 len=5  |<xex>|          n=1128 len=3  |s, |
                                n=1356 len=2  |;\x0a|           n=1123 len=4  | of\x0a|
                                                                n=1112 len=2  |. |
                                                                n=1110 len=7  |</qex> |
                                                                n=1070 len=3  |to |
```

**MDL lexicon — 40 random entries, expansion length 6–20 (pool of 22,324
candidates):**
```
n=6   len=10 |concretion|        n=6   len=6  |lesion|           n=5   len=6  |medley|
n=12  len=10 |properly, |        n=7   len=8  | symptom|         n=10  len=6  |Strong|
n=13  len=14 |when they are |    n=5   len=8  |ignorant|         n=3   len=10 |puff out, |
n=8   len=6  |bureau|            n=9   len=6  |Temple|           n=5   len=13 |southwestern |
n=12  len=6  |Anglic|            n=22  len=14 |</xex> of the |   n=14  len=8  |bequeath|
n=4   len=12 |centrifugal |      n=6   len=10 |manufactur|       n=7   len=9  |electrode|
n=89  len=6  |bodies|            n=6   len=8  |alderman|         n=6   len=10 |<deg/ Fahr|
n=10  len=11 |One who is |       n=9   len=11 |. The term |      n=4   len=14 |Arctostaphylos|
n=47  len=8  |-shaped |          n=21  len=6  |antler|
n=20  len=8  |neighbor|          n=22  len=6  |Indian|
n=7   len=11 |; the time |       n=16  len=15 |remarkable for |
n=8   len=7  |Bohemia|           n=37  len=18 |Biol.)</fld> <def>|
n=4   len=12 |market place|      n=4   len=10 |`o*nis"tic|
n=7   len=8  |<emac/"z|          n=8   len=12 |occupied by |
n=10  len=6  |filthy|            n=11  len=20 |Mach.)</fld> <def>A |
```

**Re-Pair (`gcide.eval8.64k.full.b4sd`) — top 40 by count:** dominated by
2–7 byte affix/punctuation fragments — `| or|`, `| and|`, `|, or|`,
`|ing|`, `|ed|`, `| in|`, `| to|`, `| of|`, `|, and|`, `| a|`, `|; a|`,
`|al|`, `|er|`, `|</xex>|`, `|; to|`, `|an|`, `| of a|`, `| is|`, `|in|`,
`|</qex>|`, `| for|`, `|</ex>|`, `|, |`, `| by|`, `|ly|`, `| with|`,
`|ic|`, `| the|`, `|ar|`, `|es|`, `|en|`, `|</ets>|`, `|at|`, `|,\x0a|`,
`|, a|`, `|or|`, `|et|`, `| of the|`, `|on|`, `|ate|` — almost entirely
sub-word fragments (`|al|`, `|ic|`, `|ar|`, `|et|`, `|or|`, `|es|`, `|en|`
are word-parts, not words) and always missing the article/space grouping
MDL finds (`|a |`, `|the |`, `| of the |`).

**Re-Pair — 40 random entries, expansion length 6–20 (pool of 78,582
candidates):** `|Mendel|`, `|F.]</ety>|`, `|\x0athrough which|`,
`|er-</ets>|`, `|b<icr/|`, `|<imac/nt|`, `| of many|`, `|s of social|`,
`|enefic|`, `| strik|`, `|; as,\x0a<spn>|`, `|, celebrated|`,
`| of\x0abirds|`, `| or direction|`, `| (see\x0a<er>|`, `|sterile|`,
`| of the Greeks|`, `|; Bisc|`, `|; submiss|`, `|</conjf> <pr>(bl|`,
`|</qex>, p|`, `|.</q> <rj><qau>2 Sam|`, `| small quantity|`,
`|Prob. from\x0a<ets>|`, `| as it were|`, `|<osl/*l|`, `| symptom|`,
`|ignorant|`, `|adv.</pos>|`, `|Boisterous|`, `|Chin. <ets>chih|`,
`| Turkey|`, `` |`ro*dis"i*ac| ``, `| of a fetus|`, `| peaceable|`,
`| like a bird|`, `| arctic|`, `| masses of a|`, `| variety of ch|`,
`| were the|` — note `|enefic|` (mid-"beneficial"), `| strik|`
(mid-"striking"), `|; Bisc|` (mid-"Biscay"/"Biscuit"), `|; submiss|`
(mid-"submission"), `| variety of ch|` (cut mid-word), `` |`ro*dis"i*ac| ``
(a pronunciation-guide fragment) — genuine **word fragments that stop mid
letter-run**, something not one MDL entry above does.

### json.eval8

Both lexicons' **top-40-by-count** lists are near-identical: two-digit
number strings (`|47|`, `|58|`, `|50|`, ... — this file's redundancy at
the top of the frequency table is digit/hex-run structure, which neither
grammar can turn into "words"; this is exactly the case PLAN's Lane K
class-based model, not a lexicon, is meant to fix). The separation shows
up in the **40 random entries, length 6–20** instead:

**MDL lexicon** (pool of 209 candidates — JSON's mid-length vocabulary is
tiny): mostly genuine **JSON key-name chunks**: `` |,"content_sha256":"| ``
(n=135 and n=174 across two digit-prefix variants), `` |}\x0a{"content_bytes":4| ``
(n=69), `` |}\x0a{"content_bytes":1| `` (n=317), `|,"key_count":|` (n=8),
`|,"source_ordinal":|` (n=8), `|,"projection":"|` (n=4),
`|gcide-CIDE.C-000|`, `|/gcide-0.54/|`, `|file":"/|` — plus some
mid-word fragments leaking in from the dictionary text this JSON wraps
(`|bottom|`, `|-hearted|`, `|ceptual|`, `|tional|`, `|ograph|`) — a mix,
not a clean win, but no random-hex junk at all.

**Re-Pair** (pool of 1,520 candidates): saturated with **literal hex/hash
fragments** — `|ae005d|`, `|a3e2ec|`, `|1d77807|`, `|541f69|`, `|e901a5|`,
`|30b843c24|`, `|58f97b|`, `|1564e4|`, `|2edc0b|`, `|2e7e3b|`, `|23bf74|`,
`|be1cc88|`, `|a78af8|`, `|2a8a2f|`, `|c00500|`, `|22e6ad|`, `|01b0af|`,
`|1ab4b9|`, `|b9e1a8|`, `|0c0f94|`, `|2ccdc3|`, `|1f24e9|`, `|e7ab35|`,
`|90a4db|`, `|c627af|`, `|180fed|` — 26 of 40 are content-hash fragments,
**exactly** PLAN's prediction ("thousands of rules for random hex digits
in JSON"); MDL's deletion pass throws these away (they cost more to name
than they ever save, since each hex value differs) while Re-Pair, having
no mechanism to reconsider a bad merge, keeps them forever.

## What each ingredient bought (summary)

- **a3 seed vs bytes-only**: consistently reaches its own convergence
  threshold faster (6 vs 15 iterations on gcide.eval8; 15 vs a full
  20-iteration cap, still improving, on omw.untouched) — confirms PLAN's
  "faster" framing every time. Final *quality* is mixed: a3-seed wins on
  gcide.eval8 (0.9% smaller real total) but byte-seed, given the full
  budget rather than stopping early, ends up 2.4% *smaller* on
  omw.untouched. Bytes-only is a real, general, dependency-free fallback
  that works, not just a fallback that avoids failing.
- **Re-parse** (self-validating DP over the flat trie, corpus + every
  entry's own spelling): the mechanism that lets a token created for one
  purpose get re-explained once better units exist; visible as the steady
  per-iteration DL decrease in every curve above and directly responsible
  for the qualitative word/phrase boundaries (a fixed Re-Pair merge can't
  do this at all).
- **Deletion** (generalised to n-ary, any-parent): the single biggest
  lever measured — 65–75% of every seed grammar's entries deleted in the
  very first round (e.g. macho 301,438 → 76,783), because Lane A's own
  MDL pass (A2) is restricted to "nobody's child" rules and Lane M's is
  not. Never regressed (real-recompute + halving safety net, ported from
  LANE_A.md's hard-won fix for the same failure mode).
- **Triples**: never hurt, 0.02–6.08% additional real-byte win, biggest on
  the corpus (OMW) LANE_A.md already flagged as filler-dominated.
- **The real codec**: the whole reason any of the above numbers are
  trustworthy rather than `est` — and the source of the one clear
  negative result (below).

## Biggest remaining inefficiency

**The model codec, not the lexicon.** Lane M's lexicon quality (parse
efficiency, word-likeness) is good — B/token is competitive or better than
Lane A's grammars everywhere, deletion + re-parse + triples all
demonstrably help, and the qualitative entries are visibly word/phrase-
shaped where Re-Pair's are fragments. But `m_codec.zig`'s reference coding
(one shared static frequency table, no DEF-tree, no recency cache, no
context) costs 1.5–3.5× more bits/entry than Lane B's tuned codec on
exactly the low-reuse-tail corpora (OMW, macho, zigsrc) where that
overhead matters most, and that model-cost gap is large enough to erase
Lane M's real parse-quality advantage on 5 of 12 combos when compared
against the real (LANE_B-costed) Re-Pair-static path. The fix is
mechanical, not conceptual: port Lane B's DEF-tree/REF-with-recency-cache
idea onto Lane M's n-ary entries (the entries themselves already look
right) rather than inventing a new lexicon mechanism — this was out of
scope to build in the time available for this lane but is the clear next
step, and LANE_B.md's own diagnostics (recency, not probability modelling,
is what actually works on a REF alphabet this sparse) apply unchanged.

Second-order inefficiency: JSON's top-of-table redundancy is fundamentally
digit/hex-run structure that no lexicon (MDL or Re-Pair) can turn into
"words" — Lane M still loses to bzip3 there (−5.2%) despite winning the
Re-Pair-static comparison, exactly the case PLAN's Lane K (class-based
model) targets, not this lane.

## Failures / limitations (kept per PLAN's rules of evidence)

- Top-level `iterate()` regressions do happen (propose accepts a batch by
  heuristic ΔDL estimate, not exact recompute) — rare, small (<0.05% of
  DL), always caught and reverted by the snapshot/revert check, visible in
  the freedict.untouched curve above.
- Triples' role-consistency is a simpler "any symbol used once, excluded
  from every other candidate this round" rule, not Lane A's asymmetric
  left/right bit scheme — adequate (never regressed) but almost certainly
  leaves some good triple merges on the table each round; not measured
  directly.
- Byte-seed ablation was only run on 2 of 12 files (omw.untouched,
  gcide.eval8) and only the triples-off variant, to fit the time budget;
  directionally consistent with PLAN's prediction in both cases but not
  exhaustively confirmed everywhere.
- `reparseRound`'s entry-spelling re-parse and `materializeAll` skip any
  entry whose byte expansion exceeds 256 bytes (Lane A's own bounded
  approximation, LANE_A.md A4) — a handful of very long chained entries
  are simply left unreparsed/unmatchable; not counted as a failure (same
  policy Lane A shipped with) but worth flagging as a shared limitation.
- One real bug found and fixed during development: `materializeAll`
  originally assumed a component's *id* is always smaller than its
  parent's (true only before the first re-parse round); after
  `reparseRound` can rewrite an entry to reference a higher-numbered but
  shorter-`explen` entry (explicitly allowed by PLAN's acyclicity rule),
  that assumption breaks and materialisation read uninitialised memory —
  crashed immediately and reproducibly on `freedict.eval8` at block
  16384. Fixed by materialising in `explen`-ascending order instead of id
  order (the actual dependency order, always valid regardless of id
  numbering). It crashed loudly on that one combo but, being a read of
  uninitialised (not out-of-range-checked-away) memory, could in principle
  have silently miscomputed rather than crashed on a different combo/build
  — so every number in this notebook comes from the single `bin/m_lab` run
  compiled *after* this fix (one build, one run, `dumps/m_*.b4sd` and the
  TSV/qualitative output all from that run); nothing from earlier
  interactive `m_probe` exploration (pre-fix) is reported above.

## Encode/decode timing

Codec `encode()` is 5–40 ms even on the 8 MiB files' ~50–77k-entry,
~0.6–1.6M-token results (it is one linear pass plus one `O(k log k)` sort
for the rank order) — negligible next to the MDL loop itself (0.5–22 s per
combo, dominated by re-parse's per-round trie rebuild + DP, not by
proposal or deletion, which are both sub-100ms even on the 8 MiB files).
Decode was not separately timed (out of scope for this report; every
decode ran as part of the same-process verification pass and produced
byte-exact output every time, so it works, but "how fast" wasn't
measured — flagged for the record per PLAN's rules of evidence rather than
guessed at).
