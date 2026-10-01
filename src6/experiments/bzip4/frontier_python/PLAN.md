# Language compression frontier: Python reference experiments

This is an isolated research program. The acceptance target is smaller complete
frames and faster decoding than matched bzip3 on FreeDict, GCIDE, and OMW
Japanese. Encoding may cost more. A Python storage result does not prove the
speed of a future native decoder. Nothing here changes production selection.

The previous shared-LZ experiment lost both size and speed. Its parser checked
only one local and one reference candidate per hash, stored three-byte matches,
then optionally predicted the serialized instruction bytes one bit at a time.
The second BWT/MTF/zero-run/rANS experiment reduced decode work but still lost
complete bytes by 0.58–22.35%. Its one global byte model mixes MTF events with
ULEB run-length bytes and cannot express BWT context changes. bzip3 also removes
long repeats before BWT, particularly useful on the repeated OMW projection.

Research waves:

1. Freeze a common input/control/framing protocol. Independently reproduce the
   prior BWT matrix with raw process capture when practical. Establish exact
   bzip3 sizes on deterministic smaller screens as well as the full 8 MiB lane.
2. Three independent Python families: reusable lexical/subword phrases with a
   cheap expansion decoder; lossless structural/column separation; BWT event
   coding with explicit contexts and long-repeat removal. Read primary research
   and implement the hypothesis, including rejected ablations.
3. Audit the strongest candidate for hidden model costs, leakage, framing,
   malformed input, memory/initialization and per-output work. Run fixed serial
   replication. Consolidate only if the evidence supports a coherent design.

Evidence-driven second wave:

* Reject byte-class/shape/template separation: its charged selectors and lost
  adjacency make every transformed screen worse than its own raw-zlib control.
* Refine flat phrases with minimum-bit parsing and residual-vocabulary
  replenishment. The first greedy parse discarded most candidate entries, so
  that screen alone cannot distinguish weak parsing from a weak representation.
* Test a bounded shared pair DAG. It can represent long cross-block fragments
  through reusable short rules rather than storing every overlapping phrase's
  full expansion. The grammar, entropy tables, expansion limits and restarts
  must all be charged; a plain input-trained grammar is ordinary compression,
  not an unseen-prediction result.
* Test raw/factorized BWT using two shared tables selected by the already
  required representation flag, then examine probability mass wasted on
  unreachable high ranks. These are bounded entropy-model experiments, not
  corpus-specific dispatch rules.

Final structural family:

* A consistent-pair grammar vocabulary with longest-match block parsing,
  integer-root BWT, full-alphabet MTF/RUNA-RUNB, and one canonical Huffman
  backend. All six full 8 MiB size-gate cells beat matched bzip3, including the
  complete stored DAG and entropy model. The settings are fixed at 8,192
  rules, 64 maximum passes, minimum count 4, and consistent pair selection.
* Freeze all candidate sources, then run exactly one serial final matrix over
  native bzip3, F, plain grammar, and symbol-BWT on both fixed evaluation
  lanes and both raw boundaries. Record three retained decode trials after a
  separately timed first decode, and three fresh first/middle-block restarts.
  Encoding includes model discovery/preparation. The native timing control
  retains one needed state per encode/decode phase, not an unused second state.
* Independently verify every persisted raw capture, source snapshot, full
  frame hash and independently decoded block after the final timing matrix.
  Distinguish Python execution results from any future native performance.

Fixed source: the complete existing projection.tsv for each corpus; decode and
concatenate only field three (normalized content bytes). Train on bytes [0,1MiB).
Initial development screen is bytes [1MiB,1.25MiB); final evaluation is the next
8 MiB [1MiB,9MiB), at both 16KiB and 64KiB raw boundaries. The final prefix
includes the development screen, so it is a benchmark, not untouched holdout.
A separate fixed linguistic holdout [9MiB,10MiB) must be evaluated for any
candidate selected from development data. Any additional training-derived data
is stored in the frame. Encoder-side discovery from the input is allowed as
ordinary compression only when the entire discovered model is serialized.

Each artifact records exact input/source hashes, command, environment, raw
stdout/stderr/status before parsing, deterministic fixed-order samples, model
and framing bytes, exact roundtrip, decode initialization, full and block decode,
and memory estimates. Native C controls may be called through a declared FFI;
candidate decoders are pure Python and expose all state. An external entropy
codec may be used only as a clearly labeled diagnostic bound, never as a claimed
new decoder. Final native speed acceptance remains unproven at Python stage.

No fixture-specific tags, token lists, omitted spelling/case/whitespace, external
dictionary, unstored weights, or selective result removal. Exact negative
results remain in the ledger. No claim that conventional ingredients or their
combination is novel without evidence. Decoder clarity and compact state matter
more than minimizing textual line count.
