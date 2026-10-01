# bz4 v2 — words + syntax

A from-scratch Zig 0.16 package (no C, std only) that puts Lane M's
compositional MDL lexicon ("words") under Lane K's induced class-transition
model ("learned syntax"), then jointly refines the two: after classes are
learned, every lexicon entry's benefit is recomputed under the
class-conditional code, entries that stop paying are deleted, the corpus is
re-parsed, classes are re-fit, and the loop repeats for a few rounds,
keeping whichever real, byte-exact frame — order-0 M alone, M + classes with
no refinement, or M + classes + joint refinement — is smallest. See
`../PLAN.md` ("Round 3 — structural rethink") for the thesis and
`../LANE_M.md`/`../LANE_K.md` for the two engines this package recombines,
and `../LANE_Z1.md` for this lane's own notebook (results, ablation,
failures).

## Layout

- `src/range_coder.zig` — the shared 64-bit carryless range coder.
- `src/coding.zig` — adaptive integer/gamma codes, Fenwick trees, the
  bucket-by-class symbol table.
- `src/ids.zig` — `TokenId`/`EntryId`/`ClassId`, distinct id types so the
  package's several numbering spaces (a `Lexicon`'s own ids, the model
  codec's rank-renumbered ids, class ids) cannot be mixed up at a boundary.
- `src/lexicon.zig` — the n-ary `Lexicon` + `Corpus` storage and the
  shared-population counting/cost functions.
- `src/propose.zig`, `src/parse.zig`, `src/delete.zig`, `src/learn.zig` —
  Lane M's propose/re-parse/delete engine and its `iterate()` driver.
- `src/topology.zig` — a real topological order + first/last-byte table
  over a `Lexicon`'s entry DAG (ids are not guaranteed topologically
  ordered: re-parsing allows forward references, and the model codec
  renumbers by count).
- `src/classes.zig` — Lane K's induced class-transition model (DAG
  inheritance, cost-pruned overrides), narrowed to its own recommended
  "one map, inherit on" safe default.
- `src/model_codec.zig` — the lexicon's own wire codec, behind a narrow
  `encode(lex, counts, g) -> bytes + id map` / `decode(bytes) -> entries +
  counts` interface (PLAN's brief: swappable for a smaller lexicon codec
  later).
- `src/class_codec.zig` — the class model's wire codec (byte classes,
  overrides, transition table).
- `src/block_coder.zig` — the class-conditional block coder, behind a
  narrow `encodeBlock(tokens) -> bytes` / `decodeBlock(bytes, out) -> void`
  interface (PLAN's brief: swappable for table-driven ANS later);
  `decodeBlock` is allocation-free.
- `src/frame.zig` — the v2 frame format (header, two-part model segment,
  directory, blocks), `Frame.open`/`decodeBlock`/`decodeAll`.
- `src/joint.zig` — the joint-refinement tournament described above.
- `src/root.zig` — the public API (`compress`, `open`, and every module
  re-exported for direct use).
- `src/bench.zig` — the measurement harness (`zig build bench -- FILE
  BLOCK`, plus `ablation`/`csweep` subcommands).
- `src/cli.zig` — `zig build cli -- compress|decompress IN OUT`.

Every `.zig` file above carries its own `test` blocks (`zig build test`,
Debug and ReleaseSafe both pass, 29 tests).

## Design notes worth flagging

- **Degenerate cases are not special-cased.** `classes.Params{.C = 1}` IS
  order-0 coding (a single class has one possible transition and nothing
  to pick), exercised as the "M tokens + order-0" ablation stage by running
  the *same* class-model code path, not a separate order-0 codec. An empty
  lexicon is a `Lexicon` with zero entries; a single block is a `Corpus`
  with one `block_end` entry. None of these are `if` branches anywhere in
  this package.
- **Two id spaces, on purpose, kept from colliding.** `model_codec.encode`
  renumbers entries by descending population and returns the map; every
  downstream stage (`classes.zig`, `block_coder.zig`) is run against the
  *renumbered* lexicon and a corpus remapped through that same map — see
  `../LANE_V.md`'s "the one non-obvious integration bug: two id spaces" for
  why this discipline exists.
- **The lexicon's own reference code and the corpus's block code are two
  different populations.** `model_codec`'s population is spelling-internal
  usage only (`lexicon.recountSpellingOnly`); corpus/root occurrence counts
  (`lexicon.recountRootsOnly`) are a second, separately-transmitted array
  that only the class-conditional block coder needs.
- **Joint refinement's inner search is a documented simplification.**
  Lane M's own `deletePass` gates its batch size with a cheap *exact*
  order-0 recount per halving trial; a class-conditional exact recount
  would need a full re-fit per trial, so `joint.zig` instead ranks
  candidates with an independent-estimate heuristic and gates the whole
  batch with one real end-to-end re-encode per round, reverting the round
  if it doesn't actually shrink the frame. See `src/joint.zig`'s doc
  comment and `../LANE_Z1.md` for the trade-off stated plainly.
