# Exact phrase skeletons: next private structural experiment

The current first-use word-form constructors lose to the native M frame on
the completed 1 MiB development gates. Mandarin OMW's forced short-span
constructor cost 89,914 B versus M's 86,824 B and selected **zero** shared
surface templates. This is evidence against more operand-only tuning on that
parse, not evidence against reusable sentence structure. The next source
change should act on ordered words and separators, including variable slots,
rather than on the spelling of one word at a time.

## Reversible source representation

Partition each original 64 KiB page into exact UTF-8 scalars. In a word-run
mode, valid Unicode letters, numbers, and marks form a maximal word token,
capped at 96 bytes. In a scalar-word mode they remain separate exact scalar
tokens, allowing unspaced scripts to expose structure without a script table.
Whitespace runs are exact separator tokens in both modes; each remaining
scalar is a token. A malformed UTF-8 byte is an independent literal token.
The frame pays a mode selector. Token records store original bytes, with no
case folding, normalization, stemming, language tables, or discarded
whitespace. A phrase cannot cross a page boundary. The byte fallback makes
the map bijective for arbitrary input.

Candidate skeletons are ordered token sequences with one or two *whole-word*
slots and at least two fixed non-slot anchors. For example, repeated exact
surfaces `... the river of Nile ...` and `... the river of Thames ...` can
share the fixed `the river of` bytes while each occurrence carries its exact
slot value. This is only an illustration, not an English-specific rule.
Punctuation, whitespace, CJK words, Arabic clitics, and invalid bytes retain
their exact positions. A skeleton can be used only when every fixed anchor
and separator matches; the decoder performs no analysis or inference.

The discovery pass indexes bounded left/right exact contexts around eligible
word positions, then greedily extends common fixed anchors. Two-slot
proposals arise from repeated ordered anchor triples, not a combinatorial
enumeration of every pair of positions. Bound the candidate inventory,
template span (24 tokens / 512 bytes), number of slots (2), slot bytes (96),
and expansion work. Group by source identity before pricing, and reject a
candidate unless it has at least two nonoverlapping uses.

## Native wire and paid search

Give the private native grammar a first-class `SKEL` event. A skeleton table
stores the exact fixed token IDs, slot positions, slot count, and expanded
byte/work bounds. The payload event codes a skeleton ID in its native
context row, then codes each slot as an ordinary native token event in a
slot-specific row (including its DEF/PAST/GEN consequences). After each
constituent, both encoder and decoder update the ordinary PAST window and
native successor state deterministically; the fixed anchors have no hidden
source events. A later use can therefore take the normal distance options.
The whole expanded occurrence may also enter a bounded phrase PAST if that
option pays; its table and distance costs are explicit. The decoder emits
fixed anchors and decoded slots in order and restarts from the transmitted
page state. A literal/native-root event remains available
for every position, so a skeleton is never required for exactness.

Train by alternating: (1) a page-local DP that considers literal/native
roots and nonoverlapping skeleton occurrences at the current *measured*
event prices; (2) refitting the native rows and slot distributions from that
parse; (3) pruning candidates whose complete-frame marginal saving is
negative. Compare the **whole frame** against unchanged M and whole-file
bzip3 on the same exact source. Charge lexicon/rule definitions, template
table, slot selectors/rows, event stream, page directory and checksums,
rejected policy fits, and decoder memory/work. If a frame has no profitable
skeletons, select the unchanged M archive rather than counting an unchosen
experimental wire as a win.

The first gate is development prose and old multilingual material, not a
fresh holdout: one natural book/prose sample, plus Finnish, Turkish, and
Arabic or CJK, with byte-exact full decode and every original page. The
primary score is complete frame bytes versus **whole-file** bzip3; M is the
internal structural control. A source-only discovery probe can first reject
the idea if anchors have insufficient repeated fixed material even under an
optimistic zero-cost slot coder. That bound must include template
serialization and cannot be promoted to a compression result.

Potential failure modes: the existing M grammar may already code fixed
anchors cheaply; per-template event IDs and slot contexts may outweigh
remaining savings; arbitrary-book prose may have too few repeated long
phrases; and a broad search may make encoding too expensive. These are
measured questions, not reasons to silently omit a cost or use a hidden
dictionary.

## Development screen outcome

Six complete hash-pinned prose books, including English, Spanish, French,
German and Japanese, were screened as source-only diagnostics. Whole-word
one-slot skeletons with asymmetric fixed anchors reached only 2.74% to
5.37% of whole-file bzip3 bytes on the four larger spaced-script books under
a favorable static-unigram token proxy. The shorter German book and
Japanese word-run mode had negative proxy gains. Two independently varying
whole-word slots reached at most 1.42% on any book. The proxy assumes slot
costs cancel and charges only a fixed model-row allowance; it is optimistic
relative to an exact native M frame. The scalar mode's larger scores on
spaced-script books are mostly letter holes inside words, outside this
sentence-level architecture. Its Japanese patterns are one-character
inflectional forms rather than two whole-word slots. Complete evidence and
the earlier symmetric-anchor ablation are described in `README.md`.

This specific exact-anchor SKEL candidate is stopped before a native wire:
the observed reusable anchor entropy is too small for the requested
whole-file gain, even before a real model and decoder table are paid. A
broader language model or variable lexical classes would be a new source
architecture with a new budget, not an extrapolation of these scores.
