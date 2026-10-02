# Integer bitwise context mixing for whole-book prose

The Unicode word-ID and bounded byte-PPM experiments have a complete
development falsifier: all four ≤1 MiB complete books have ideal costs above
the exact same-source whole-file bzip3 frames. Simple exact-match prediction
also loses to PPM on the fixed books. The next structurally different bet is
a **bitwise online context model**, akin to the useful part of PAQ/neuralzip
without a floating neural network, shared checkpoint, or external lexicon.

## Model

Encode each source byte as eight bits, MSB first, with a range coder. Before
each bit, several exact integer experts predict `P(bit=1)` from states
reconstructed solely from earlier decoded bits:

1. Partial-byte prefix plus last 0/1/2/4/8 complete bytes. A context row
   keeps two counts, capped and deterministically rescaled. Fixed maximum
   row counts and deterministic LRU eviction bound memory.
2. A word-boundary signature from a capped recent UTF-8 byte run; it may use
   literal byte categories but never an external Unicode table or language
   lexicon. This expert is a fixed alternative, not free training material.
3. A causal long exact match expert that tracks match *continuation length*,
   not merely the last successor of an 8-byte context. Its donor is verified
   against already decoded bytes and its table/window is bounded.

A mixer keeps deterministic integer weights by bit position and coarse
context class. One ablation is fixed-prior Bayes; another is bounded
discounted online weights. Every update is after coding the current bit,
using the bit and the exact quantized expert probabilities. The full
quantized mixture has a frequency of at least 1 for each bit. Fixed integer
tables, scales, tie rules, and update order are part of the source/wire
version; no model bytes are assumed. The decoder's work is `O(N * 8 * E)`
with fixed `E`, bounded state and no source-dependent training phase.

## Falsifier before wire

Build one C++ source-only scorer that records prequential integer CDF log
loss with exactly the same model class intended for the coder. Freeze
contexts, caps, updates, and two mixer modes before inspecting book scores.
Evaluate the six frozen development-book 1 MiB prefixes, the four complete
short books with exact bzip3 controls, and whole War/Quijote only if a
substantial margin remains. Report separate expert and mixer losses, full
source hashes, peak rows/memory and byte work. Existing byte-PPM loss is the
counterfactual. A positive ideal margin must clear bzip3 by enough to pay
CDF quantization, frame and decoder complexity; a few hundred bytes are not
a reason to write a new format.

## Complete archive gate

If the scorer survives, add a self-contained range-coded frame with exact
length/CRC/mode and bounded decoder. Fresh decode every complete frame and
compare full source hashes; reject truncated, extra-suffix and malformed
frames. Compare complete frame bytes against the exact same-source whole
bzip3, bzip2, xz and zstd controls, with all negative trials retained. Any
page-access claim requires a separate paid reset/index profile. Decoder
throughput and memory are part of the result, because an extravagant
causal model can win bytes while being unusably slow.
