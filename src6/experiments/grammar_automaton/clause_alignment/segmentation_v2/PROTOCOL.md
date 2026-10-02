# SED2: one fixed sentence-boundary correction

SED1's split after every LF turned hardwrapped book prose into 30–50-byte
lines. SED2 tests that specific segmentation flaw once on the same six
frozen UTF-8 development prefixes. SED1 code, frames and evidence remain
unchanged. The only transform-code difference is `clauses()`:

- Split after ASCII `.`, `!`, `?` or exact UTF-8 `。`, `！`, `？`.
- Split after exact blank-line byte sequences LF LF, CRLF CRLF, CRLF LF or
  LF CRLF. A single LF or CRLF inside a nonempty paragraph stays in its
  clause as literal source bytes.
- Force a cut at 1024 bytes; a complete three-byte UTF-8 delimiter may
  extend a clause to 1026 bytes. If a four-byte blank-line marker would
  exceed that bound, cut before the marker. Original 64 KiB page cuts still
  reset the donor ring, including when they split a sentence or UTF-8 scalar.

All byte sequences are kept exactly; invalid UTF-8 is never normalized or
discarded. This handles Japanese sentence punctuation and CRLF hardwraps
without a language dictionary. Empty paragraphs and the fixed maximum
length are admitted. The byte shingle and punctuation/space shingle search,
eight causal donor candidates, 4096-clause bound, exact LCS, minimum
eight-byte paid KEEP, ULEB128 fields, literal fallback, page index and CRC,
64-byte outer envelope, and two complete bzip3 backend frames are copied
without changing the selection or coding policy. The SED2 code diff against
SED1 must show only this scanner change, module names and read-only length
distribution telemetry.

## Fixed evidence and interpretation

Run SED2 once on all six prefixes in the frozen manifest SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`,
against same-source bzip3 controls manifest SHA-256
`640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`.
The first diagnostic gives the best shortlisted causal donor's exact byte
LCS for **free**: no donor, operation or position bits. Compress only the
unmatched bytes with one whole-stream bzip3 frame. This is a
segmentation-sensitive, unattainable **proxy**, not a universal lower bound
or an archive size: changing residual byte order changes the entropy model,
and an unsearched alignment could differ.

The second diagnostic pays the route stream and changed literals through
their own complete bzip3 frames plus the 64-byte envelope. Report source,
clause and donor-length distributions, optimistic and paid copy coverage,
segment count, both raw and compressed streams, exact whole-source and every
64 KiB page inverse, and all source/frame hashes. Costs of unseen literal
contexts must not be canceled against the whole-source bzip3 frame.
No reserved validation or sealed final source may be inspected.

The same SED1 promotion threshold applies: only material paid bytes under
90% of whole bzip3 on at least three books justify a native codec wire.
Independently report distance from the user's stretch goal of 65% of
whole-file bzip3. Stop after this fixed six-case result if weak; a bzip3
diagnostic cannot be called a new independent word codec or a fast
selected-page reader.
