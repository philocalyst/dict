# Native GEN experiment: paid structural hypothesis

The initial payload-only two-piece wire was a private `sgn\x01` sketch. The
current three-piece delta+payload wire is `sgn\x02`; the decoder rejects the
older private sketch and the unchanged `bz4\x03` frames.

The existing M parse often has a useful token for a word form, but its first
use either defines and names that token globally or spells children in place.
GEN is a third choice: construct the exact surface from a recent token's
contiguous byte span with literal bytes before and after it, then insert the
result in the ordinary per-stream PAST window. An immediate recurrence can
use the existing distance tiers. A form that is not reused never needs its
own permanent name solely because it was constructed once.

The construction is `lead || donor[start : start + copy_len] || tail`. The
encoder considers at most 16 recent tokens, rejects candidates whose UTF-8
valid byte spans split a continuation sequence, and otherwise preserves any
invalid bytes exactly. Its metadata has a GEN event in the native finite
state source plus separate native adaptive binary operands: donor distance,
start, copy length, lead length, tail length, and each literal byte. Definitions
and payloads have independent operand streams. Every stream length and block
record appears in the private `sgn\x02` frame; the byte ledger is computed by
`inspect_gen.py`. No external vocabulary or codec is needed for decoding.

The initial form proposal uses an exact shared span of at least 12, 16, or 24
bytes, with no more than 24 remaining literal bytes. This is a *proposal
filter*, not the claimed compressed cost. The corrected `private_fit.zig`
learns native rows for each threshold and tests every declared class count,
plus a no-GEN control, choosing the smallest **complete** frame. The earlier
linked wrapper bypassed this fit: its 14-lane 1 MiB screen is a threshold-12,
early-stop diagnostic despite exact full and page parity. It must not be
presented as the corrected policy. Once rerun, the final choice pays every new
event, operand, probability table, definition, cache insertion, and rejected
candidate's encoder time. A separate comparison
against the unchanged M backend is still needed because the private wire adds
directory fields even when GEN is unused.

The first payload-only cut on a 1 MiB Japanese OMW development prefix found
25 GEN events. At a fixed 16 classes its frame was 51,580 bytes against
51,272 bytes for unchanged M: a 308-byte loss. The extra paid GEN operand
stream was 262 bytes, and payload entropy improved by only 10 bytes. The
original early-stop class policy picked one class for GEN and thereby missed
the better 16-class frame. These are development observations, not final
results. The three-piece delta+payload wrapper's first 14-lane diagnostic
ran after the quiet window; the corrected exhaustive search later selected
no GEN on the same 1 MiB Japanese development source, 51,336 bytes versus
51,272 for unchanged M. A typed donor-span wire saved only 15 bytes across
25 forced GEN events and still lost. Even zero-cost operands would leave its
forced frame 7 bytes above M, proving that an operand-only change cannot win
that fixed parse. Full ledgers are retained under `evidence/`.

The next construction-family variant stores shared exact surface edits once,
with each binding entering PAST. Its source and grammar decisions must pay
the complete model, template, binding, donor, fallback and native entropy
costs. A useful result must beat strongest M and whole bzip3 on pinned
development inputs with fresh full and every-page parity. The immediate gate
is 1 MiB Mandarin OMW; old Finnish, Turkish and Arabic form sources are
available if a complete-frame gain survives. No final split is used.

The current per-form proposal does not yet use full native event price. A
follow-up can export the prior pass's `row, DEF/GEN/PAST` cell cost and price
the sidecar with its adaptive state at each proposed occurrence. Even then,
the actual acceptance rule remains complete-frame comparison, because GEN
changes future PAST reach, row contexts, definition placement, and class
tables. A broader template inventory or multiple donor spans would require
their own transmitted operands and support, not an uncharged oracle.
