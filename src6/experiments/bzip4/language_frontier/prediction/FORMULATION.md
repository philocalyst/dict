# Selected frontier formulation: a charged spelling probabilistic circuit

The type-weighted factorized spelling screen in `spelling_model.py` is a
complete, lossless control.  It is useful, but its static event stream is a
poor replacement for v4's recency/class payload model.  The next (and more
exotic) formulation is therefore a *spelling-only* probabilistic circuit,
with the existing v4 token stream retained for occurrences.  The cheap
`circuit_probe.py` screen below is deliberately diagnostic; it prevents an
expensive arithmetic-coder implementation when the charged lower bound has
already lost.  No unmeasured circuit bytes are claimed as a win.

## Mechanism

For every first-use type (w=b_0\ldots b_{n-1}\), train a small mixture of
products:

\[
 P(w)=\sum_{z=0}^{K-1} P(z)\left(\prod_{i=0}^{n-1}
 P_z(b_i\mid q(i))\right)P_z(\mathrm{END}\mid q(n)),
\]

where `q(0)=start`, `q(i)=interior` for i>0, and q(n) is `start` for an
empty word and `interior` otherwise.

Here `z` is latent (it can represent script, morphology, and paradigm
families).  Each (P_z) is a smoothed static table over the 256 byte values
plus END.  Parameters are trained from distinct types only, so repeated
prose/function-word frequency cannot overwhelm the spelling population.  Both
rows include END:
a nonempty word is `start(byte)`, zero or more `interior(byte)`, then
`interior(END)`; the empty word is `start(END)`.  Thus the model is a
normalized unknown-length generator and never receives a final-position
oracle.

The encoder and decoder maintain the exact posterior mixture weights for the
current type as bytes are coded.  At each byte they arithmetic-code the
mixture marginal; after END they reset the posterior and start the next type.
No probability table changes.  A fixed-point/integer implementation stores
all counts and rounds the same way on both sides.  The component table,
priors, arithmetic precision, and type-boundary markers are all in the frame.
No script class, length bucket, or final-position signal is read from the
unencoded source.  If a richer route is useful, script/length must be latent
nodes in the circuit and therefore be marginalized or explicitly coded.  A
final-position row is illegal unless the type length is sent first; the
bounded prototype therefore uses only start/interior rows whose alphabets
include END.  If posterior
arithmetic is too expensive for
the native decoder, the same circuit can transmit a component ID first and
use a static product row as a bounded fallback; that ablation must be
reported separately.

This is a product/sum probabilistic circuit, not a neural network or an
uncharged language model.  It differs structurally from v4's `aliasBytes` and
class rows: v4 pools byte frequencies over all event occurrences; this model
uses a latent component and exact posterior mixture *only while spelling a
new type*, and its sufficient statistics are type-weighted.  It also differs
from greedy BPE/W2: there is no lexicon of learned pair entries and no
per-entry ARITY/NAME path.  The circuit emits bytes directly until END.

## Cheap screen and falsification

1. Train on each fixed 1 MiB `*.train.bin` prefix; freeze all integer counts.
2. Encode `*.eval8.bin`, `*.untouched.bin`, and synthetic invalid UTF-8 /
   combining/mixed-script/NUL fixtures.  Decode independently and compare
   hashes.
3. First compare spelling-stream bits and charged model bytes against the
   *isolated type-spelling* component of v4.  `Stats.delta` is not itself a
   novel-word spelling total: it includes nested definitions, ARITY/NAME/CUT,
   and phrase definitions.  A complete splice must account for those events
   explicitly.  Then put the circuit spelling stream in a complete frame with
   the unchanged v4 occurrence stream.  Report header, circuit, type
   boundaries, spelling, occurrence, and padding bytes.
4. Reject if the circuit does not save at least 10% of the v4 first-use
   spelling bytes *and* 5% of the complete frame on at least two of the three
   primary eval slices.  A cross-entropy win without a complete-frame win is
   diagnostic only.

The most likely disproof is that the latent component ID and charged tables
consume the gain, or that type spellings are too heterogeneous for a tiny
mixture.  That is a useful result: it identifies a real model-cost boundary,
not a tuning failure.  A richer next lane is a sparse Markov/HMM circuit with
shared transitions across positions, but its transition table must also be
charged; this probe intentionally does not claim that unimplemented win.

## Sources and limits

Liu, Mandt, and Van den Broeck show that probabilistic circuits support exact
marginalization and practical arithmetic coding for lossless compression:
[Lossless Compression with Probabilistic Circuits (2021)](https://arxiv.org/abs/2111.11632).
The proposed circuit is a much smaller, symbolic mixture-of-products model;
the paper's image experiments do not establish a text result.

Nardone and Ferragina's recent diffusion-compression paper demonstrates a
different route to parallel neural prediction but still relies on a large
model and reports an enwik8 setting:
[Diffuse to Compress (2026)](https://arxiv.org/abs/2608.11249).
It is a frontier reference, not an implementation dependency or a free model
for this lane.

Liu, Zhang, and Van den Broeck show how latent-variable distillation can
train tractable PCs, including an HMM language-model example on WikiText-2.
Their teacher-derived assignments are useful as a *training* idea, but a
teacher is not shipped or queried by this codec; only the resulting finite
tables could be charged.  Their HMM example also makes the distinction clear:
an oracle final-position or script label would be extra observed information,
whereas a latent state is marginalized.
[Scaling Up Probabilistic Circuits by Latent Variable Distillation (2024)](https://arxiv.org/html/2210.04398v2).

Chiu and Rush's sparse/block HMM work demonstrates exact forward inference
with restricted emissions and compact sharing, but its language-model setting
uses much larger neural/state parameterizations than this lane can afford.
It motivates a future shared-transition spelling state machine, not a free
claim for the two-row probe.
[Scaling Hidden Markov Language Models (2020)](https://arxiv.org/pdf/2011.04640).
