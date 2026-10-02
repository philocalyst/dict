# Structural reuse inside native grammar definitions

The exact OMW Japanese 8 MiB WGA1 frame has 11,285 bytes of entropy model
tables and 148,955 bytes of compressed grammar-definition deltas. Its
payloads take 168,702 bytes. A two-outcome context gate can only alter a
small part of those tables; a rule-construction code targets the dominant
definition component directly.

## Candidate instruction

`SPLICE(distance, offset, length)` appends a byte-exact contiguous span of
an already defined rule's expansion to the current definition. The donor is
selected from a bounded recent-rule ring; no future rule, external lexicon,
or implicit language model is available. One opcode replaces consecutive
definition child events. Distance, offset, length, row transition, opcode
probability, donor-ring policy, and any page/reset metadata are carried in
the native frame. All nonselected child events use the existing native code.
The encoder may search expensively, but the decoder's donor lookup and copy
have bounded work and memory. Copies must not overlap source or target in a
way that changes the advertised bytes.

This is confined to **grammar-definition** construction. The sibling GEN
codec separately works on productive first-use lexical forms and payload
PAST; this experiment does not alter that event family. P6F1 semantic IDs
and the source's exact arbitrary bytes remain unchanged.

## Early falsifier and accounting

`rule_splice_screen.py GRAPH.forward EXISTING_NATIVE.frame` uses a
first-demand postorder of the preserved graph and searches each expanded
rule for its best substring in the previous 1,024 definitions. It also
searches exact repeated sequences of grammar child IDs, since a surface
match composed of already cheap references may not buy anything. Both
diagnostics estimate operand costs with gamma codes and charge a three-bit
opcode floor. They compare matches against the frame's **average** compressed
native delta bits per expanded surface byte or child event. These averages
are not marginal event prices; native PAST, first-use names, and exact
definition scheduling differ.

An intermediate screen allows the donor to have different child segmentation,
but requires the copied span in the current definition to start and end at
whole-child boundaries. This keeps skipped child definitions already
demanded in the graph's postorder; a native encoder must separately check
that every skipped child has a live name slot. Its output explicitly
shows the optimistic margin after an extra 8 or 16 bytes per selected splice.
That reserve still omits any fixed new-wire model and framing cost.
The result is only a cheap upper-bound style diagnostic. A promising result
requires a native splice wire, exact model/header/operand/frame costs,
complete-frame comparison with untouched M and WGJ, and full plus every-page
byte identity. No final corpus may be used to choose the donor horizon or
opcode representation.

The main implementation risk is row/PAST state after a copied phrase. The
new opcode must define one deterministic successor and one explicit past
update, both mirrored by the decoder; it cannot silently pretend copied
children were coded individually. Nested rule definitions, CUT truncation,
and first-use name insertion need focused exactness tests. The decoder must
reject donor distances outside the retained ring, out-of-range spans,
excessive definition length, and malformed frame lengths before allocation.
