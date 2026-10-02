# Sparse causal native event automaton

The input is an exact P6F1 grammar parse learned from bytes. The learner and
the original native-v4 class/bucket planner are unchanged controls. The new
`wga\x01` wire uses the same exact grammar definitions, first-use NAME and
DEF events, PAST ring, CUT and ARITY events, bit-stack integer operands, and
per-block tANS payloads. The archive directly carries all event tables and
rules; it has no external word list, pretrained weights, or old-frame payload.
`raw_codec.zig` runs the exact byte-to-LaneM learner and writes a complete
archive directly. Its optional P6F1 graph output is only a reproducibility
artifact; the decoder reads the archive alone.

Each payload token begins in the original predecessor class row. A sparse
selector optionally sends its *first* symbol through a clone row whose
frequency table is separately fitted. Silent class symbols in a clone rejoin
the original tier rows. A token's remaining events and all dictionary delta
events retain the original model. This makes first-use, reference, PAST, and
class decisions eligible for a higher-order predictor while preserving exact
transducer semantics. Clone rows add real header bytes even if their symbols
are strongly predictable.

The context is causal: the previous four decoded bytes, previous native event
family (byte, known reference, PAST, or DEF), previous token length bucket,
previous first symbol, and preceding base class rows. Its state resets for
each independently decoded payload block. The grammar definition stream uses
the original model and retains its sequential dictionary construction.
Selected feature family, sorted `(base row, key)` map, each clone table, row
links, and all grammar material are serialized and bounded. The decoder
rebuilds state only from already decoded tokens. It can decode a selected
payload after model/dictionary preparation without reading earlier payloads.

The encoder traces an original full frame, scores twelve causal feature
families by ideal bits with an intentionally cheap metadata charge, and
fully refits bounded maps of 1, 4, 16, or 64 keys per family. The archive
minimum is taken over *complete* candidate frames plus the no-selector
control, not over ideal entropy. The development screen also uses alternating
original pages as a generalization check, but no screen estimate is used as a
compressed-size claim. All candidate fitting time is encoding time.

If individual contexts cannot pay for separate tables, the next version will
merge selectors that share a predictive distribution into one serialized row.
That merge must use pooled native event counts, pay every selector key and the
shared table, and pass the same exact-frame comparison. The current wire has
one clone per selector; no merged-row gain is claimed yet.

Limits: the prototype currently uses an unhoisted quality profile. Grammar
definitions are prepared sequentially; payload contexts and PAST reset at
original 64 KiB block boundaries. Decoder resource hardening and page/whole
fidelity are required before the format is considered complete.
