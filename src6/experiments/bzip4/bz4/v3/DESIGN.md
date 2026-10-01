# bz4 — the lexical automaton

One object, and every feature a compressor usually grows is a degenerate
case of it or a policy of the encoder. This is the fourth shape of the
format (the directory is still called `v3`); what changed and why is at the
end.

## The object

* A **token** is a byte slice. Nothing else. (`[]const u8`.)
* A **bucket** is an array of `2^w` tokens that the model treats as
  equiprobable. A token is addressed as *(bucket, w raw bits)*. Bucket 0 is
  the 256 single bytes (`w = 8`), present before anything is defined.
* **The past is a bucket too.** Each stream keeps its last 4096 tokens;
  past bucket `w` addresses the tokens `2^w - 1 … 2^(w+1) - 2` places back.
  It is never defined, named or reset by anyone: emitting a token is what
  puts it there. Recency, bursts, "the headword again", near-duplicate
  records and front coding all come from here.
* A **row** is one static tANS table over bucket symbols, `DEF`, `CUT`, and
  *silent* symbols that emit nothing and only change rows (so a token can
  be spelled class-then-tier where that is cheaper to describe). All rows
  share one `L`-bit state, yet each row has its own table size: a step uses
  the top bits of the state and carries the rest through untouched.
* A **cell** of a row is `{symbol, width, nbits, base, next_row}`.

Decoding one token is one table load and one bit extraction:

```
c     = cells[row.at + (state >> row.carry)]
v     = peek bits
state = (c.base + low(v, c.nbits)) << row.carry | low(state, row.carry)
index = low(v >> c.nbits, c.width)        // raw part: which slot
row   = c.next                            // the model's next state
out  += buckets[c.symbol][index]          // a memcpy
```

For a past bucket the slot is `past[pos - 1 - (2^w - 1 + index)]`, and the
next row is the row that followed that token the first time: a copy resumes
the automaton where the original left it.

The large alphabet (10^5..10^7 words) never touches the entropy coder; the
entropy coder sees a few hundred symbols. There is no arithmetic-decoder
division, no cumulative-frequency search, no per-token model update, no
inverse BWT, no MTF, no hash table.

`next_row` is stored per cell, so the static model is an arbitrary
**deterministic finite-state transducer** at zero decode cost. Finding a
good automaton is the encoder's problem, never the decoder's.

## The stream

A frame is a header (bucket widths, the rows) and a sequence of blocks. A
block is `delta` + `payload`, two independent tANS bitstreams.

```
payload := item*                   until the block's token count is reached
item    := USE(bucket) index       copy that token (a past bucket: from the past)
         | DEF                     copy the next top-level definition of this
                                   block's delta (its first use is free)
delta   := def*
def     := ARITY(n) child{n} NAME(bucket)
child   := USE(bucket) index | DEF def | CUT(k)
```

The delta is *text*: it is decoded by the same loop into an arena, and a
definition is the span its children just wrote. Nested definitions are
sub-spans of their parent, so they cost no bytes and no copy.

`CUT(k)` keeps only the first `k` bytes of the child before it. With the
past this is front coding as a property, not a mode: in a sorted word list
the previous word is the past at distance 0, so `abase` after `abandonment`
is `[past 0, CUT 3, "se"]`; `abandoned` after `abandon` is `[past 0, "ed"]`.
For the decoder a cut is `at = start_of_previous_child + k`.

The payload's past starts empty in every block, so payloads stay
independent of each other. The delta's past runs through the frame, like
the lexicon it belongs to.

Three rows are named by the header rather than by a cell: the arity row,
the cut row, and per row `name_row` (where a body that ends here is named)
and `first_row` (what follows a definition's first use in the payload; in a
body it is followed by the row its name led to).

## What falls out

| Mechanism elsewhere | Here |
|---|---|
| stored / incompressible mode | one bucket (bytes), one row: 0 entropy bits + 8 raw bits |
| shared dictionary | a block with a delta and an empty payload |
| random access | put every definition in a leading payload-less block |
| streaming | each definition sits in the block of its first use (the default) |
| parallel decode | run the deltas in order, then every payload independently |
| order-0 / class bigram / field state | automata with 1 / C / learned rows |
| MTF, recency cache, adaptive boost, block-local dictionaries | past buckets |
| LZ77 over words, rep-matches | past buckets; a copy resumes its row, so a run of copies stays cheap |
| front coding, stemming, prefix sharing | `CUT` of a token from the past |
| literal runs, hapax words | inline bytes, or a definition used once |
| Huffman vs range coder, big-alphabet tables | gone: tANS over a few hundred symbols + raw bits |

## Encoder contract

The encoder's only job is to choose tokens, buckets and an automaton that
minimise the bytes this exact code produces: **the cost model is the code.**

* `encode` walks the input several times. The first walk never looks back;
  each later walk takes a token from the past exactly when the previous
  walk's counts make that cheaper than its bucket.
* The planner (`plan.baseline`) clusters tokens into classes by exchange,
  buckets each class's entries by reuse count, and lays out the rows:
  class rows, a row that starts bodies, a row that follows a cut, one row
  per class for what follows a first use. Planned a second time with the
  bucket uses the first encode measured, entries the past always serves
  stop taking up classes and buckets.
* The learner (`src/learn.zig`) cuts the input
  into atoms the data delimits itself — letter runs, digit runs, single
  other bytes — and grows a spelling grammar over the distinct atoms and a
  phrase grammar over the atom stream. A payload token is always a whole
  number of words; sub-word structure lives only inside definitions.

## Status

See `RESULTS.md` for the tables. In short (real round trips, one setting):

* Same old byte-level parses as before, new format: 2–13 % smaller than the
  previous format on every word corpus (omw −13 %), −10 % on Zig source,
  with less code and no scope machinery. Decode 240–790 MB/s on one thread,
  0.5–1.3 GB/s on eight.
* `/usr/share/dict/words` (2.5 MB, sorted), end to end: **537 KB**; xz −9e
  637 KB, brotli 650 KB, zstd −19 662 KB, bzip3 807 KB, bzip2 858 KB.
* Against *whole-file* bzip3 with 64 KiB blocks of our own: omw −0.7 %,
  freedict +1.9 %, gcide +2.7 %. Not yet the 20–30 % the project wants.
* Small standalone inputs (4–256 KiB) are still 13–45 % behind xz/bzip3.
* `bz4 c IN OUT` / `bz4 d IN OUT` work end to end; the in-tree learner
  (`src/learn.zig`) is the weakest part: on omw it gives 374 KB where the
  old byte-level parse gives 330 KB. Lane W2's learner, priced and pruned
  at real costs, lands in the same place (`lab/LANE_W2.md`): the greedy
  pair-merging is what has to be replaced, not tuned.
* A decoder bug as old as v3 turned up when the end-to-end test decoded a
  multi-block frame with all deltas first: a job kept slices of buckets
  that later grew and moved. Buckets now grow into fresh memory.

## What this round found

* **Where bzip3 wins.** Splitting freedict by XML element and compressing
  the parts with bzip3: prose 308 KB (ours 304), headwords 55 (43),
  pronunciations 65 (56), translations 87 (72) — and the tag skeleton 30 KB
  against our 93. The old parses glue word endings to markup
  (`o</ns0:quote>…`), which fragments the structure into hundreds of
  7–10 bit variants. Tokens have to be whole words.
* **Exact contexts buy little** on top of a phrase grammar (3–5 % est):
  a merged phrase coded at order 0 *is* the chain rule over its parts.
  What the grammar cannot express is recency — hence the past buckets.
* **Spelling is a third to a half of all bits** on dictionaries: every
  distinct word is spelled once and 60 % of word types are hapax. bzip3
  spells freedict's 56 K word types in 205 KB; xz on the sorted list needs
  160 KB. Prefix sharing with recent definitions is what LZ has and we
  lacked — hence `CUT`.
* **Sticky field states and transparent separator classes**: nothing
  (−0.05 %), tried for real. Classes already carry the field.
* **Streams must not share a starting point.** One row starting both
  blocks and bodies, and the payload resuming in a row that bodies also
  use, cost 10 % on the word list.

## History

v3 had block lifetimes, families of tiers, per-block ranking and arity-1
cache aliases to turn recency into scope. Measured against the past
buckets they lose on every input, so they are gone, together with their
planner. What v2 had (model segment, class codec, overrides, tournament of
lexicon kinds, adaptive region) went the same way one round earlier.

## Files

`src/` is the codec (lead). `lab/` holds lane experiments; a lane owns only
its own files there. Rules of evidence are PLAN.md's: real round-trips,
everything charged, one setting for all inputs, estimates labelled `est`.
