# Prediction lane hypotheses (2026-09-26)

This lane owns only `language_frontier/prediction/**`.  The target is the
current lexical automaton (`bz4/v3`, wire v4), whose class-bigram rows already
predict token order reasonably well while first-use spelling is expensive.
The experiments below are deliberately different from byte aliases, greedy
pair merging, ordinary prefix `CUT`, and a generic previous-token context.

## H1 — type-weighted factorized spelling generator (selected)

Train a small static character/codepoint generator on *distinct types*, not on
all token occurrences.  A type is a deterministic maximal byte atom (the same
byte-preserving scanner used by the current learner); no UTF-8 validity,
normalization, case folding, or external tokenizer is assumed.  Use a bounded
unigram/MDL segmentation vocabulary and a low-order finite-state byte model
for the residual pieces.  A held-out type is encoded as a sequence of model
symbols plus an explicit end marker.  The model is frozen before held-out
encoding and its rows, symbol inventory, transitions, type boundaries, and
restart metadata are charged.

The structural difference is that every new type draws from one spelling
generator.  It does not pay a separate ARITY/NAME path through the ordinary
body/payload token-class model, and the training objective weights each type
once.  Repeated payload occurrences still use the existing-style static
recency/index stream in the prototype, so spelling and phrase selection can be
measured separately.  A decoder emits bytes only after checked model-symbol,
length, and end-marker validation.

Expected mechanism: type-weighting suppresses the huge frequency skew caused
by repeated function words and tags; shared stems/suffixes then become useful
across hapax types.  The expected saving is concentrated in `delta`/first-use
bytes (roughly 35--50% of v4 on the primary dictionaries), not in the already
good class bigram.  A reasonable target is 5% complete-frame savings, with a
model budget below the recovered spelling bytes.

Cheap disproof (before any long timing run): train on the fixed `*.train.bin`
prefix, freeze, and encode `*.eval8.bin` plus `*.untouched.bin` for FreeDict,
GCIDE, and OMW Japanese.  Compare complete bytes to the retained v4 frame and
to a no-generator byte baseline.  Require exact byte round trips, report
header/model/type-table/payload bytes separately, and test invalid UTF-8,
combining marks, mixed Latin/CJK, and NUL.  Reject H1 if its charged model
plus spelling stream does not beat the v4 spelling bytes by at least 5%, or if
the full frame is larger on all three primary eval slices.

## H2 — variable-order static context rows with state merging

Build an order-0/1/2/3 context tree for type residual symbols, smooth each
row, and merge contexts whose quantized continuation distributions are equal
or whose row replacement costs less than the saved model bytes.  The resulting
rows are serialized once and are deterministic finite-state transitions; the
decoder never updates counts.  This is a static analogue of a bounded context
tree, not the current class-bigram over lexical tokens.

Disproof: measure held-out cross entropy and complete bytes after charging row
tables and transition references.  If order 2/3 saves less than its table
cost, or if the merged model has no full-frame win over H1's order-1 rows,
retain the negative result and do not add rows to the production automaton.

## H3 — sparse sequence memoizer with dynamic-programming parse

Mine only repeated type sequences whose exact definition plus selector cost is
amortized by their occurrences, then choose a globally shortest parse with
dynamic programming.  This is not the prior greedy pair-merging learner: a
candidate can be a longer sequence, can overlap candidates, and is selected by
charged frame cost rather than pair count.  It targets phrase bytes only and
leaves H1's spelling model unchanged.

Disproof: evaluate shuffled/reordered records and mixed-script slices as well
as the primary corpora.  Reject if phrase savings do not survive definition,
selector, and restart costs, or if they leave first-use spelling as the
dominant v4 loss.  The previous W2 results make a large gain unlikely, so H3
is a control rather than the selected lane.

## H4 — charged mixture-of-products circuit (frontier follow-up)

This is the selected frontier formulation after the first complete control.
For each first-use type, a tiny latent component (z) chooses a static byte
product distribution.  The only observed position feature is `start` versus
`interior`; both rows include the 256 bytes *and* an END symbol, so length is
generated rather than supplied as an oracle.  Script, morphology, and
paradigm are latent component structure, not free side information.  The
encoder and decoder arithmetic-code exact mixture marginals by maintaining
only the posterior weights for the current type; counts never adapt.  The
circuit is serialized and charged.  It is not a neural model and does not
require a free tokenizer.  `FORMULATION.md` specifies the integer wire
contract and screen.

Cheap disproof: compare the spelling stream against v4's `Stats.delta` first-
use cost, then substitute it into a complete frame while retaining the v4
occurrence stream.  Reject unless at least two of three primary held-out
slices save 10% of first-use spelling and 5% of complete bytes after charging
component tables, priors, boundaries, arithmetic metadata, and padding.

## H5 — operator-cached macro ANS / state-space bits-back

The oracle algebra suggests a separate speed hypothesis: cache a complete
prefix-free phrase operator `M_w`, code one macro ID with ANS, append its
surface bytes, and advance the latent boundary by `qM_w`.  Tunstall trees and
state-space bits-back are relevant realizations.  The exact disproof is that
two reachable beliefs can require different CDFs for the same ID; a scalar ANS
state cannot select both without a finite compiled belief context, an explicit
latent sample, or posterior CDFs/seed bits.  The tiny probe in
`ANS_LATENT.md` records 0.267282 next-symbol predictive variation, 1.8125 mean
macro bytes, and the charged diagonal/low-rank rank growth.  H5 therefore
remains a bounded follow-up design (finite context rows plus prefix-free
surfaces), not an uncharged replacement or a complete-frame claim.

## Selection

H4 is selected as the bold mechanistic lane for the cheap disproof screen; the
corrected screen falsifies this two-row independent-product instance on the
three recorded held-out slices, so no expensive arithmetic implementation is
claimed.  H1 remains a complete lossless control and fallback artifact.  A
shared-transition HMM/Markov extension is documented as a future hypothesis,
not silently substituted after seeing the rejection.  The retained
measurements identify first-use spelling as the largest coherent loss and show
that more pair merging/pruning does not close it.  H2 and H3 remain documented
negative controls.  H5 is an algebraically validated speed follow-up, with no
compressed-frame evidence yet.  All experiments use one frozen policy per
candidate; no corpus-specific method is selected after seeing held-out totals.
