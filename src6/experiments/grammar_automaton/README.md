# Grammar automaton experiment

This research codec tests a model-paid causal automaton on the *native lexical
event stream*. It is separate from the frozen WPG2 constructor and original
native-v4 backend. The `wga\x01` archive contains the complete grammar,
selector map, entropy tables, operands, and payloads needed to decode exact
source bytes. Invalid UTF-8 is treated as ordinary bytes.

Build with `./build.sh /path/to/output ReleaseSafe` or `ReleaseFast`. The
output directory receives five programs:

* `native_forward_trace trace INPUT.forward TRACE.wgt3 0 BASE.frame` traces a
  private byte-identical native-v4 fit and checks its full frame against an
  untraced fit. `event_screen.py TRACE.wgt3` reports optimistic diagnostics.
* `context_forward auto INPUT.forward OUTPUT.wga 0` fits the complete context
  frame; `decode FRAME RAW`, `extract FRAME PAGE INDEX`, and `inspect FRAME
  JSON` read it independently. The feature family and all selector rows are
  stored in the frame. Original 64 KiB payload blocks are independent after
  grammar preparation.
* `raw_codec RAW OUTPUT.wga OUTPUT.forward 65536 20 a-best 1 0` starts with raw
  bytes, learns the exact LaneA/M grammar, fits the context wire, and writes a
  complete archive. `OUTPUT.forward` is only a reproducibility artifact and
  is not consulted by the decoder. The final `0` chooses the interleaved
  quality profile; `1` hoists definitions for shared-model access.
* `joint_forward auto INPUT.forward OUTPUT.wgj 0` fits the WGJ wire, which
  also models the persistent grammar-definition event stream. Its `trace`
  command emits WGT4 with exact native table frequencies and separate delta
  and payload event records. `gate_screen.py TRACE.wgt4` provides a strictly
  optimistic, model-charged screen for the next binary gate experiment.
* `raw_codec_joint` provides the same raw-byte LaneA/M front end for WGJ.

WGJ's `auto` JSON reports every complete candidate frame's feature, selector
count, merge choice, and byte length. `GATE_PLAN.md` describes the planned
hot-symbol gate wire and its exact fallback semantics. Prior WGA1 diagnostic
auto runs recorded complete trial counts and selected frames, but did not
retain individual losing-trial sizes.

Each candidate's model, grammar, payload, and frame bytes are counted. The
encoder time includes grammar learning, native class fitting, selector
screening, and every complete candidate fit. `RESULTS.md` distinguishes ideal
screens from complete decoded frames. This is ongoing development; the new
decoder and complete size comparisons must pass before any frontier claim.
