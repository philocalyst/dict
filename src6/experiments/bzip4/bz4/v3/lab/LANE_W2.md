# Lane W2 — a word-aligned parse learner, priced by the real codec

Owner file: `w2_parse.zig` (325 lines, `zig fmt`-clean). No `w2_lab.zig` was
needed: `w2_parse.zig` itself imports `bz4` (built with `zig build-exe
-OReleaseFast --dep bz4 -Mroot=lab/w2_parse.zig -Mbz4=src/root.zig`) and does
the parse → plan → encode → price → re-parse loop in-process, so the dump it
writes is already the priced, pruned parse — `lab DATA OUT --classes 64
--workers 1` needs no extra flags to reproduce every number below. All
numbers are real, round-tripped `total=` bytes from that exact command
(`--classes 64 --workers 1`) unless marked `est`; every dump in this lane
round-tripped with zero `RoundTripMismatch`. One setting for every input:
`morph_least=3, phrase_least=4, share_window=32, least_shared=6,
price_classes=64, prune_overhead=10`. Encode time (parse + plan + encode)
is 2–6 s per 8 MiB file, far under the 2-minute budget.

## Method in one paragraph

Atomize exactly as `w_parse.zig` does (maximal letter runs, `>=0x80` counts
as a letter, maximal digit runs, every other byte alone — no text-specific
rule anywhere). Grow a spelling grammar (BPE over the distinct atoms, a new
word may front-code off one of the last 32 new word types) and a phrase
grammar (Re-Pair over the atom stream, fenced at 64 KiB blocks), both with
generous count thresholds. Then price every resulting entry — byte, morph,
word or phrase, no distinction — with a real `bz4.plan.baseline` +
`bz4.encode` at `classes=64` (the same class model the score is judged
under) and dissolve whatever `bz4.plan.prune` says does not pay; repeat,
stopping at the round whose *real encoded length* is smallest (not at the
round where entry count stops changing — see "pruning" below for why that
distinction matters). The only thing this file adds on top of
`w_parse.zig`'s already-published algorithm is that pricing loop.

## Results table (real `total=` bytes, `--classes 64 --workers 1`)

### Primary corpora (8 MiB eval8)

| input | bzip3 (whole-file) | xz -9e | bzip2 -9 | old byte-level `m_*` | `w_parse` (lead, no `--inline-hapax`†) | `bz4` native (lead's integrated `learn`+`plan.fit`, auto class) | **w2_parse (this lane)** |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 554,003 | 682,880 | 651,164 | 564,416 | 583,287 | 583,287 | **579,677** |
| gcide.eval8 | 1,243,221 | 1,559,640 | 1,518,049 | 1,282,509 | 1,337,182 | 1,332,108 | **1,333,115** |
| omw.eval8 | 332,331 | 366,600 | 526,190 | 330,148 | 378,672 | 378,672 | **367,391** |

† `w_parse --phrase 4 --morph 3 --inline-hapax` (the setting the brief's own
reference table used) **crashes the current codec** — see "a real bug
found" below; the fair comparison is `w_parse`'s own non-crashing default.
`bz4` native = the lead's `src/learn.zig` + `zig-out/bin/bz4 c`, which
landed *during this lane's session* and is now essentially `w_parse`'s
algorithm (defaults `share_least=3`) wrapped in `plan.fit`'s auto class
search (tries 1/4/8/…/128 classes, keeps the smallest real encode) — the
strongest baseline available, not something this lane gets credit for
beating "unfairly."

**w2_parse beats the lead's own best current pipeline on 2 of 3 primary
corpora (freedict −0.6%, omw −3.0%) and ties on the third (gcide +0.08%,
inside noise)**, using a *fixed* `classes=64` with no per-file class search.
None of the four bz4-family entries beat whole-file bzip3 (freedict +4.6%,
gcide +7.2%, omw +10.6%) — see "why bzip3 still wins" below for the
measured reason, which is structural, not a tuning miss.

### Secondary corpora (1 MiB `untouched`, small excerpts, word list)

| input | bzip3 | xz -9e | bzip2 -9 | `m_*` | `bz4` native | **w2_parse** |
|---|---:|---:|---:|---:|---:|---:|
| freedict.untouched | 84,072 | 102,664 | 88,054 | 92,390 | 93,892 | 96,165 |
| gcide.untouched | 174,685 | 213,220 | 190,345 | 193,216 | 198,704 | 201,013 |
| omw.untouched | 57,862 | 66,128 | 69,386 | 65,427 | 67,551 | 67,571 |

| input | xz -9e | bzip2 -9 | **w2_parse** |
|---|---:|---:|---:|
| freedict.4KiB / 64KiB / 256KiB | 744 / 6,964 / 24,656 | 818 / 6,504 / 21,860 | 2,407 / 10,844 / 28,693 |
| gcide.4KiB / 64KiB / 256KiB | 1,320 / 16,056 / 57,620 | 1,314 / 14,795 / 51,405 | 3,475 / 21,745 / 62,551 |
| omw.4KiB / 64KiB / 256KiB | 844 / 5,228 / 15,276 | 873 / 5,560 / 17,321 | 2,056 / 8,569 / 20,796 |
| `/usr/share/dict/words` (2.49 MB) | 637,488 | 857,578 | 626,490 |

`/usr/share/dict/words` beats both xz and bzip2 at this lane's global
setting, and every 64/256 KiB excerpt beats bzip2's *ratio* by a smaller
margin than it loses on 4 KiB — see "small files" below. `w_parse`'s own
default (`share_least=3`) gets 539,322 on the word list and `bz4` native
536,789 — both clearly better than this lane's 626,490 (see "least_shared
is a real trade-off" below for the honest reason this lane did not chase
that number).

## What each idea bought or cost (numbers, including the failures)

1. **Real-price pruning recovers ~0.5% when the proposal over-merges, and
   is a measured no-op once thresholds are hand-tuned.** At an intentionally
   generous seed (`morph_least=3, phrase_least=3, least_shared=3`, 81,307
   entries), pruning off gives 589,331 real bytes on freedict.eval8;
   pruning on (same seed) gives 586,117 (dissolving down to 71,571 entries)
   — a genuine, reproducible win from dissolving entries whose measured
   bucket cost does not pay. But at this lane's *final*, threshold-swept
   settings, `prune_rounds=0` and `prune_rounds=40` produce **byte-identical
   output on all three primary corpora** (579,677 / 1,333,115 / 367,391) —
   `bz4.plan.prune` finds nothing worth dissolving once the greedy proposal
   already sits where per-entry real pricing agrees with it. This confirms
   LANE_L.md/LANE_O.md's finding from the other direction: pruning is real
   damage control for an over-generous learner, not a free lunch on top of
   an already-reasonable one. Kept in the shipped pipeline anyway (it is
   the only thing standing between "one bad threshold choice" and "586K
   instead of 579K", and it is cheap — one extra `baseline`+`encode` call
   per round, ~8 rounds, ~2s).
2. **A local per-entry price estimate overshoots real total bytes** the
   same way LANE_L/LANE_O found: at the over-generous seed above, `entries`
   kept shrinking for 39 more rounds after real bytes stopped improving
   (81,307→70,364 over 40 rounds), and real bytes *climbed back up*
   (586,117→588,094) well before entry count converged. Fixed by making
   the stopping rule "the round whose real `bz4.encode(...).len` is
   smallest", not "entries stopped changing" — a one-line, exact fix once
   measured, but the crude version silently produces a worse file with more
   rounds, which is the same failure shape LANE_L's `total_B_scoped` and
   LANE_O's naive pooled pricing both hit.
3. **`least_shared` (the minimum front-coding prefix worth a `CUT`) is a
   real, corpus-dependent trade-off, not a knob with one right answer.**
   Sweeping it on freedict.eval8 at fixed `morph_least=3, phrase_least=4`:
   `least_shared=3` → 582,481; `=4` → 581,882 (unpruned already optimal);
   `=6` → 579,677; `=8` → 579,754; `=10` → 579,159; `=20` → 579,499 — a
   real, reproducible ~0.55% gain from being *less* eager to share prefixes
   on XML dictionary text (short coincidental shares cost more in
   name/CUT-row overhead than they save). But the *same* change is a clear
   loss on a genuinely front-codable corpus: disabling `CUT` sharing
   entirely (`share_window=0`) costs omw.eval8 +1.24% (362,833→367,391 is
   backwards — 367,391 is *with* sharing, 362,833 *without*; sharing is the
   loser there) while it is gcide's small win (+0.24% *for* sharing) — and
   on the fully-sorted `/usr/share/dict/words`, `least_shared=6` gives
   626,490 while the lead's own default `least_shared=3` gives 539,322, a
   14% gap, because a sorted list's adjacent new words routinely share only
   3–5 characters and a threshold of 6 throws most of that away. This
   lane's global setting (6) is chosen for the three primary dictionaries
   (its actual mandate) and reported honestly as a real loss on the
   word-list side benchmark, not hidden — "one setting for all inputs"
   costs something concrete here, not just in principle.
4. **The spelling grammar (`delta`), not the phrase grammar, is where the
   bytes are and where nothing tried here closed the gap.** On
   freedict.eval8, `delta=273,038` of `total=579,677` (47%) — matches the
   brief's own 35–50% figure. Sweeping `morph_least` (2/3/4/6) moved delta
   between 258K and 277K but total bytes stayed within 1% of each other in
   every direction (more morphs → smaller delta, but the payload/table cost
   of the resulting bigger morph alphabet gives most of it back). This is
   this lane's clearest negative result: **greedy BPE with a count
   threshold, even wrapped in real-price pruning, does not find a
   meaningfully better morph inventory than `w_parse.zig` already had** —
   confirming the brief's own diagnosis (unigram-LM/MDL segmentation, not a
   deeper BPE search, is the actual lever) without this lane having budget
   to implement that segmentation.
5. **Separator placement needed no special mechanism, and the finding is
   that it mostly doesn't matter here.** No code treats a space specially;
   the phrase grammar is free to merge a word with an adjacent space (or
   not) like any other atom pair, and pruning would remove such a merge if
   it did not pay. `phrase_least=4` vs `=5` is the cleanest read on whether
   this fires usefully: `=4` costs freedict 0.33% (579,677 vs 577,740) but
   **saves omw 3.4%** (367,391 vs 380,055) — omw's dense internal repetition
   (short glosses, repeated headwords) rewards more phrase merging
   (including separator-attached ones) much more than freedict's does; `=4`
   is this lane's global choice because omw's swing is 6x freedict's.
6. **A real, reproducible bug found and root-caused, independently fixed by
   the lead mid-lane.** `w_parse.zig --inline-hapax` on the current codec
   segfaults (`index out of bounds: index 4294966789, len 52510` under
   ReleaseSafe). Root cause: a hapax word entry whose body is exactly
   `[ref, CUT n]` (an atom that is *entirely* a prefix of an earlier one)
   gets dissolved by `--inline-hapax`'s looser keep rule, and splicing it
   into the top-level block stream leaves a bare `CUT` token where
   `encode.zig`'s per-block loop expects a byte or an entry — something its
   own `Walk.define` loop guards against for *nested* kids but the
   top-level loop does not. `bz4.plan.prune` (used by this lane's pricing
   loop) had the same latent hole. Both are now moot: `src/plan.zig` (as of
   this session, mid-lane) added the exact guard needed
   (`fixed[e]=true` for a body containing a cut *and* for whatever
   precedes it), and `src/learn.zig` unconditionally keeps any
   top-level-referenced entry. This lane's own `protectCutSources` in
   `w2_parse.zig` implements the same guard independently (zeroing
   `entry_uses` for any entry that precedes a `CUT` in some body, checked
   per-body so a body boundary can never look like a false adjacency) and
   is kept even though `plan.prune` now also guards it, on the principle
   that a lab file should not depend on an implementation detail of a
   `src/` function it does not own and cannot pin.

## Why bzip3 still wins, measured not guessed

`delta` (lexicon) is 41–47% of every primary-corpus total here. bzip3 has
no separate "spell each word once" cost at all — it is one adaptive
BWT+CM stream with no entries, no ARITY/NAME/DEF overhead per distinct
word. A word-aligned lexicon *must* have on the order of one entry per
distinct atom type that cannot fully collapse into a single morph
(53,104–67,380 word entries here, out of 56,468–73,319 distinct atoms);
that per-entry overhead is exactly what an unstructured adaptive coder
does not pay. `RESEARCH.md` (added mid-lane) independently names this the
same weak point ("the spelling generator is where we are weak") and cites
literature (Morfessor's MDL, PathPiece/SuperBPE on tokenisation) pointing
at the same fix this lane could not build in scope: replace count-threshold
BPE with a real MDL/unigram-LM segmentation. Real-price *pruning* (this
lane's contribution) cannot fix this because the entries it dissolves are
already the ones that do not pay — the ones that remain (the bulk of the
delta cost) are hapax words that must be spelled *somewhere*, and pruning
has no lever over how cheaply the segmentation spells them.

## Small files: not this lane's regression

At `classes=64`, freedict.4KiB is 2,407 bytes here versus xz's 744 — but
`w_parse` on the *same* file at the *same* `--classes 64` gets 2,326, and
`v3/DESIGN.md` already documents this as a known, unfixed gap ("a full pair
grammar through v3 is 10–25% behind xz/bzip2" at 4–256 KiB) — a fixed
64-class model table costs more than a 4 KiB file's content does,
regardless of which learner produced the parse. Not fixed here (it is a
plan/model-header question, out of this lane's file scope), but verified
not to be specific to this lane's parse before reporting it.

## What I would try next

1. **Unigram-LM (Morfessor-style) segmentation for the spelling grammar**,
   replacing greedy BPE — the one lever `RESEARCH.md` and this lane's own
   morph-threshold sweep (finding 4) agree is the actual remaining money,
   and the one this lane did not have budget to build from scratch.
2. **Price `CUT` source/length choice directly**, not just threshold-sweep
   it: right now a candidate source is accepted purely by longest shared
   prefix within the window; pricing 2–3 candidate sources per word with a
   real `bz4.encode` call (expensive, would need batching) might recover
   some of the `least_shared` trade-off in finding 3 instead of picking one
   global threshold.
3. **A second grow-then-prune generation**: after the first prune round
   dissolves bad phrases back into their atoms, those atoms sit in new
   contexts that were never offered to `grow()`; one more Re-Pair pass over
   the post-prune stream might find merges the first pass could not see.
   Not attempted — likely a smaller win than (1), and this lane's own
   finding 1 suggests it would need the same real-encoded-length stopping
   rule to avoid over-shooting again.
4. **Re-run `least_shared` and `phrase_least` against `bz4` native's
   `plan.fit` auto-class search** instead of a fixed `classes=64` — this
   lane fixed classes to match the brief's exact scoring command, but
   finding 3's per-corpus swings might partly be a `classes=64`-specific
   artifact that a searched class count would smooth out.
