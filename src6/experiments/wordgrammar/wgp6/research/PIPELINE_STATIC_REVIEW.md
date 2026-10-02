# WGP6 pipeline static review

Scope: text-only review of `../native.zig`, `../encode.py`,
`../test_pipeline.py`, and README claims. No builds, runs, or performance
diagnostics were performed.

## Findings

**The advertised price-matrix resource cap is not enforced in the native
writer.** README says priced matrices are limited to 20 million cells / 192
MiB. `native.zig:priceFile` loops over `(256 + input.entries()) *
(classes + 1)` cells and appends 8 bytes per cell (a float price and a
successor row) without a checked product or limit. The frozen Python policy
sets proposal capacity to 200,000; at 128 classes that permits 25,833,024
cells, or about 197 MiB, before ArrayList growth overhead. Private parse
input can also be supplied directly to `native compile`, so the fixed
pipeline policy alone does not establish the README limit. Add checked
multiplication and reject over either cap before constructing the matrix;
test that the private `prices` path refuses an over-cap graph. This is a
concrete README/resource-bound mismatch, not evidence of a decoder issue.

## Checks that look sound by inspection

`encode.py` keeps the original frame as the initial candidate, evaluates all
five reparse candidates, and changes the winner only on a strictly smaller
complete frame. Thus ties resolve to the earliest candidate (the original
frame if tied), matching the README's first-tie argmin. Its reported search
codec time sums the baseline stage and every preparation/compile stage; the
test checks that sum against the trial ledger. The complete-frame length is
the selection objective, so no price surrogate selects the winner.

The private parse reader checks the `P6P1` marker, truncation and trailing
bytes, array bounds, offset endpoints/order, backward-only entry references,
nonempty entry bodies, child-length expansion, and a 64 MiB expanded-source
ceiling. CUT operands must follow a child, cannot be zero, cannot exceed the
preceding child's expansion, and cannot be adjacent to another CUT. Top-level
tokens must name bytes or existing entries. These checks prevent forward
references/cycles before fitting. The tests cover self and forward cycles,
bad top-level IDs, malformed offsets, invalid CUT values, trailing data, and
one valid nested expansion.

The restart test launches a new `native extract` subprocess for every
nonempty block, checks each extracted byte span and length in stream order,
and confirms their concatenation covers the source. It also compares two
complete encoded frames byte-for-byte. The existing README is careful to
state that this exercises old-decoder behavior and does not establish WGP5's
hostile-input/resource guarantees.

No definite Zig 0.16 source-interface error was identifiable from static
inspection: the adapter uses the new `std.process.Init` / `std.Io` style
consistently. Since the requested quiet window excludes compilation, API
compatibility remains unverified rather than cleared by a successful build.
