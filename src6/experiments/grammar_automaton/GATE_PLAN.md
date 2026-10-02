# Paid hot-symbol gates on native grammar events

## Hypothesis

WGJ clones an entire native tANS row for each useful causal context. The
Japanese 8 MiB M frame has about 160 KiB of model and grammar definitions.
Even when a context strongly favors one first event, a cloned row repeats a
full alphabet's occupancy, frequencies, and successor metadata. A binary gate
can describe the single favored event and fall back to the unchanged row.

For a selector `(base row, causal key)`, store a `hot` native first symbol and
a two-symbol gate table. At a token start the decoder reads `hot/fallback`.
Fallback decodes the original first event from the base row. Hot synthesizes
that event with the base row's successor and raw operand width. Silent class
events continue through their original next row. A gate can operate in the
recursive grammar-definition stream or the page-reset payload stream. It does
not change the grammar parse, token identity, first-use definitions, PAST
ring, or CUT behavior.

## Causal and exact semantics

The gate is selected before the token, from the same bounded causal features
as WGJ. Encoder and decoder update those features only after resolving the
whole token. A nested definition updates the persistent definition context
at the same point on both sides. CUT resets it. Every original source page
resets payload context and PAST. On the hot branch, the gate event carries
the original first event's raw operand bits; on fallback, the base event
carries them. Exactly one branch consumes them. The hot symbol's successor
and semantic kind are taken from the original base row, never learned as an
independent rule. Invalid UTF-8 remains an ordinary byte sequence.

## Paid model and candidate policy

The new wire must serialize selector keys, targets, hot symbols, two-symbol
normalized tables, row successors, and every grammar/payload event. Gate
rows use the same deterministic integer tANS primitive as the existing
native wire. The encoder evaluates the same causal feature menu and bounded
selector caps as WGJ, with shared gate rows only when their base row and hot
symbol match. It chooses a complete-frame minimum, comparing the unchanged
WGJ candidate and the new gate wire by actual byte lengths; distinct magic
bytes provide decoder dispatch without an uncharged selector.

An optimistic WGT4 trace screen computes each key's potential saving as the
hot-symbol base cost minus binary gate entropy and a metadata floor. This
screen can reject the idea cheaply. It is not a storage result. The decisive
gate is full-frame exact decoding, all original 64 KiB pages, and a ledger
whose header, directory, model, grammar definitions, and payload sum to the
file length. A losing gate candidate remains a documented negative.

## Failure modes to test

* First symbol is a silent class transition; hot must continue decoding from
  the base successor and preserve the original first-symbol context feature.
* First symbol is PAST, DEF, byte bucket, or a dictionary bucket; the hot
  branch must consume the correct operand bits exactly once.
* Nested definitions and CUT interleave with page payloads; definition state
  must persist and reset at precisely the native events.
* Selectors sharing a gate row must agree on base row and hot symbol, and the
  decoder must reject malformed mappings, row cycles, and out-of-range widths.
* Hostile frame lengths and model dimensions need bounded native preparation
  before allocation; all-page exactness by itself is not a resource bound.
