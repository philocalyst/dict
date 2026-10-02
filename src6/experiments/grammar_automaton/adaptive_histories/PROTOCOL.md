# AH1: bounded nonstationary bit-history model

This is one fixed source-only development experiment motivated by the
mechanism, not the code, of PAQ8 `ContextMap2`, `StateMap` and conditional
`Mixer`. The inspected CMIX v21 PAQ8 source is pinned at commit
`194af9cd133b8b741d2a53afca13ed0ca453c276` (source SHA-256
`8d902a7f07b817b3940597d33c807636ca55debbfe9e05b9351defb138e7ba95`).
No GPL source or pretrained table is imported. Our Q15 stretch/squash
constants were independently Decimal-generated in the prior CCM1 round;
the exact `squash_table.h` bytes must be hashed. Its predictions and all
state updates are integer. Floating `log2` is only the source-only reporting
of ideal bits and cannot influence any subsequent prediction.

## One state-model architecture, two fixed outputs

Process source bytes MSB first. For each bit, derive six exact bounded
completed-byte histories of orders 1, 2, 3, 4, 6 and 8. The row key
contains this history, family ID, one of three bit phases, and the phase's
already-decoded high bits. Phase 0 groups byte bits 0–2; phase 1 groups bits
3–5 and keys the first three bit values; phase 2 groups bits 6–7 and keys
the first six. Each tagged row has seven finite bit-history slots: one for
the group's first bit, two for its second bit, and four for its third bit.
Phase 2 uses only three slots. These are not independent full-prefix maps.
The key is compared exactly after bucket selection, so a hash collision
changes eviction pressure but never presents a different history as equal.
Four-way oldest-use replacement resets all seven cells and the previous
byte run for the replaced row. No state survives an explicit page reset.

Each cell stores Q15 local probability, eight most recent bit outcomes with
an initial sentinel, and a count capped at 255. Prediction blends that
local EWMA and a shared causal state-to-probability table in the ratio
`count:8`. The state table starts at Q15 half and updates after observing
each bit by signed division toward the target by 128. The local EWMA uses
signed division by `2^shift` with `shift=2/3/4/5` for counts `<4/<16/<64`
and otherwise; surprising a four-identical-bit run forces shift 2. Every
nonzero difference advances at least one Q15 unit. All probabilities clamp
to `[1,32767]`. A previous-byte run expert checks whether the current
partial prefix matches the last byte observed in the exact order-2 context
and proposes its next bit with confidence `(run+1)/(run+2)`; otherwise it
proposes half. Runs cap at 255. This couples recency and repetition without
transmitting a corpus-fitted model.

One first-layer context-selected integer logit mixer combines the partial
byte prior, six row predictions and the run expert. It has 64 rows indexed
by bit position and previous completed Unicode script class. One second
layer mixer has 128 rows selected by bit position, prior boundary type and
match tier; it combines layer one, exact causal byte-match, and two optional
word/scalar-context row predictions. Its weights, residual-gradient update,
signed division, clipping and table lookup are fixed in source. The exact
1 MiB causal byte-match index has four-way tagged rows; only previously
decoded bytes can be read. Byte-only and word-conditioned second-layer
models run side by side on **the same** byte, history, match and word state:

1. `byte_only`: second-layer word/scalar inputs equal its layer-one input.
2. `word_scalar`: previous token's last four exact bytes × current token's
   already-seen last four exact bytes, and previous valid Unicode scalar's
   up-to-four bytes × current token's last four bytes, are each packed into
   an exact 64-bit key. Length classes saturate at 15. ASCII punctuation and
   whitespace end a token; valid UTF-8 `。！？` also ends a token. Long tokens
   keep their exact suffix and saturated length class. Invalid UTF-8 bytes
   remain literal and update a separate invalid script class. No English
   word list, spelling normalization or external property table is used.

Both ablations deliberately share word/scalar map allocation, state updates
and eviction pressure. `byte_only` measures those features' contribution
to the output mixer, not a memory saving from omitting them. A valid
multi-byte whitespace or punctuation scalar flushes the token that
preceded its UTF-8 bytes. All mixer predictions are captured before the
observed bit is supplied; then mixer weights, state maps, local cells and
match confidence update in source-defined order. The match index inserts
only after eight completed bytes, so padded initial histories cannot
impersonate a complete eight-byte history. The fixed integer Q15 table is
SHA-256 `82e8ea89e8116a4ec34b6ad77ab39523109c64d79cde563468a083d98d3d0da7`.

Each model starts identically on every source; the decoder would perform
the same updates from emitted bytes. The source-only scorer trains
continuously across each prefix and claims no independent page access;
a promoted wire must pay for page resets or serialized state snapshots.
Every table entry is determined from source seen so far. The source
scorer has a 16 MiB input limit. The four-way bit-history table has
`2^18` rows, at most 48 bytes each (12 MiB); the exact match table is at
most 2 MiB, a future decoder history ring at most 1 MiB, and both mixers,
state maps and parser state under 0.5 MiB. The fixed decoder state must
remain below 16 MiB, independent of input length. Row replacement counts,
map occupancy, match work and exact model byte budget are reported. Work is
bounded by at most eight tagged contexts and two short mixer dot products
per source bit, with no O(vocabulary) lookup.

## Fixed development gate

Run exactly once on the six UTF-8 book-body development prefixes (up to
1 MiB) in manifest SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`,
and matched complete bzip3 controls SHA-256
`640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`.
There is no per-book or per-language selection and no parameter grid.
Report each model's full and four-quarter ideal bits, input hash, byte
work, state replacement and memory budget, and ratio to the whole bzip3
frame. Q15 ideal bytes are **not** compressed sizes: they omit range-coder
rounding, frame header, source integrity and page index. Build a native
complete range-coded wire with independent fresh decoder and every
original 64 KiB page gate only if a fixed model has at least roughly 10%
ideal headroom on **each** of the six books; otherwise preserve its negative
result and stop. No reserved validation or sealed final source is read.
