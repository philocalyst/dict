# SED1: causal sentence edit grammar, fixed development screen

This is a separate structural test of whole-clause reuse, not another
context-row adjustment. A previous clause supplies exact source bytes to a
new clause through ordered KEEP segments, while unmatched bytes stay in a
literal stream. It may capture recurring propositions with changed names or
details even when no complete sentence repeats. The transform reconstructs
the original bytes, including spaces, punctuation, UTF-8, and malformed byte
sequences. It uses no language dictionary or pretrained model.

## Corpus, comparator and stop rule

Use the six fixed UTF-8 book-body development prefixes in
`/workspace/scratch/books2026-dev/manifest.json` (SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`),
and the six exact same-source complete bzip3 frames in
`/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json`
(SHA-256 `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`).
No reserved validation or final source may be read. The initial fixed matrix
is all six prefixes, once. Report individual and aggregate values; do not
choose a policy per book or language.

A **source-only diagnostic** must include the route stream, donor IDs,
segment counts, positions, lengths, literal boundaries and literal bytes.
Report exact donor-covered bytes and exact total sidecar bytes. Compress the
sidecar and literal streams with the pinned bzip3 implementation as an
optimistic backend check, charging both complete frames and the outer
envelope/index/CRC if a decodable archive is made. If this complete
diagnostic is not under 90% of bzip3 on at least three books, stop without
a new entropy wire. For the user's stretch goal, mark how far it is from a
complete frame at most 65% of bzip3. bzip3 inside a diagnostic is never
called an independent alternative codec.

## Two independent estimates

First, for each searched prior clause, compute the exact byte longest common
subsequence (LCS). The best donor supplies those bytes at **zero** donor,
position, operation and length cost. Retain the unmatched target bytes in
source order and compress this residual with one complete pinned bzip3 frame.
This is an intentionally unattainable optimistic check: an LCS may have one
KEEP operation per byte, and a decoder could not identify the donor or
positions for free. It must never be called a frame, compression ratio or
decodable transform. Report maximum donor-covered bytes, LCS segment count,
literal residual size, complete compressed residual bytes, and its gap from
the 65% target. If even the free-side-information residual cannot reach
65% of bzip3 on several books, the whole-clause route lacks the needed
headroom and the paid diagnostic can stop.

Second, construct an exact decodable COPY/INSERT route, charge every selected
donor and segment, and compare the complete compressed literal *and* route
streams including both backend headers. A literal-only clause is always an
available choice. The optimistic and paid estimates must use their own
literal streams; do not cancel residual or literal context costs by assuming
the baseline's original byte probabilities stay unchanged.

## Exact transform and fixed search

Split raw bytes *after* each ASCII `.`, `!`, `?` or LF, and after exact UTF-8
sequences for `。`, `！` and `？`; force a cut at 1024 bytes if none occurs.
Only correctly formed complete multi-byte delimiters cut; invalid UTF-8 and
other Unicode bytes pass through unchanged. Every byte belongs to one
clause. The unit is a byte clause, not a normalized text sentence. Decoder
clauses are materialized in order and only prior
clauses can be donors. One clause may be at most 1026 bytes when a three-byte
delimiter ends at the length cut. Retain at most 4096 clauses as donors; if
that count is reached within a page, clear the ring before the next clause.
The ring also resets at every original 64 KiB
source page so any page is independently decodable with its own paid
model/header/index. If a boundary cuts a sentence, each page still has a
complete byte partition.

Index exact 12-byte shingles at 4-byte strides and exact punctuation/space
shape shingles; these are source-derived and use no English word list.
Retain at most 64 recent donor IDs per shingle. Count current-clause hits,
choose eight prior donors with most hits (ties: newest first), and evaluate
a no-donor literal choice too. LCS runs are exact ordered byte matches. For
the paid route, retain runs of at least eight bytes, joining directly
adjacent runs, and put all other source bytes in literal gaps. This produces
ordered KEEP operations without unseen substitutions. Positions and lengths
are always written to the route stream, even for a whole-clause match.

Route metadata uses unsigned LEB128 with a literal or donor flag per clause;
record donor distance, segment count, each donor offset and length, each
literal-gap length, and each clause length. Charge page resets and a page
directory in the diagnostic. Choose the smallest uncompressed
`route_bytes + literal_bytes` candidate, with literal on ties. All choices
and ordering are fixed before corpus scoring. Decoder can verify exact
source SHA-256, every original 64 KiB page, and CRCs if a wire is promoted.
The diagnostic records per-clause segments, covered bytes, lengths and
search work, including empty clauses. The page-level donor reset and both
backend frames are included in cost; no free persistent sentence table.
The diagnostic may use global compressed streams and therefore makes no
independent-page access claim; page-independent frames are a later wire gate.

The source-only transform alone is not a storage result. Promotion requires
a fully decodable new native frame with precise model, routing, index,
reset, header, checksum and work bounds, followed by full decode and every
page. If the fixed screen fails, preserve its negative ledger and stop.
