# CCM1: context-conditioned integer mixer / APM development gate

This experiment is a source-only falsifier for a PAQ-style online compressor.
It is a new model, separate from `../bit_mix_score.cpp`'s global linear
mixture. Its inputs are the **six fixed UTF-8 book-body development prefixes**
from `/workspace/scratch/books2026-dev/manifest.json` (SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`).
The exact same-source whole-file bzip3 controls are in
`/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json`
(SHA-256 `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`).
No reserved validation or final corpus is read during design or tuning.

## Integer probability contract

Each MSB-first source bit is assigned a 15-bit integer `p1` in `[1,32767]`.
The squash table covers logit coordinates `z=-2048..2048`, meaning
`z/256` natural-log odds. A source-pinned generator uses Decimal precision
80 and ROUND_HALF_UP to create the table. At runtime the inverse stretch
table is constructed only by integer nearest lookup (ties select the lower
coordinate). No floating point affects model state; `log2` is used only to
report development entropy.

Nine causal experts supply logit inputs: partial-byte KT; preceding exact
1/2/4/8-byte contexts; exact previous bounded word and current word-prefix
byte strings; UTF-8 scalar script/boundary class; and exact prior-8-byte
match continuation with a bounded 1 MiB donor reach. Word-like byte runs
end at ASCII spaces/punctuation or after 16 bytes; malformed UTF-8 has an
explicit invalid class. This is a deterministic model feature, not an
external tokenizer or a transmitted vocabulary. Context rows use four-way
tag-checked sets and bounded replacement. Each row keeps two capped bit
counts, with a lower-context backoff mass of 16. All updates are after the
actual bit is available to both sides.

The conditional mixer selects one integer logit-weight vector using current
bit position (8), script class (8), boundary class (4), and match tier (4):
1024 rows. A separate global-row ablation is mandatory. The weighted sum is
shifted toward minus infinity with an explicit signed integer function.
Gradient updates likewise use specified signed floor division by powers of
two, bounded residuals, and saturated weights. APM uses 33 U16 knots per
context, selected by the stretched mixed prediction in 128-coordinate bins.
Adjacent knots are linearly interpolated and updated after each bit toward
0 or 32768 with integer rate 7. The generated squash constants, inverse
rule, initialization, bounds, and update order are source/wire material.

## Fixed ablations and stop rule

One scorer run per source reports these five models simultaneously, without
refitting static parameters from prior book outcomes:

1. One global logit mixer.
2. Conditional logit mixer without APM.
3. Conditional logit mixer plus 33-knot APM.
4. Conditional plus APM with word experts replaced by their causal backoff.
5. Conditional plus APM with match expert replaced by its causal backoff.

Report each expert's and candidate's loss by source quarter, plus table
occupancy/replacement, match work, peak fixed-memory budget, source and
binary hashes. These losses are source-only ideal bits **after Q15 model
quantization**; they omit arithmetic-coder rounding, archive header,
termination and checksum. A native wire is justified only if multiple books
show substantial headroom toward a **35% smaller** complete frame than
matched bzip3. Otherwise preserve negative evidence and stop this model.
If a wire is justified, it must have an independent fresh decoder, exact
source hash and malformed-input gates, full frame costs, bounded work/RAM,
and no external model weights.
