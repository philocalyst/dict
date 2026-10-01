# Structural/context separation hypotheses

This directory tests reversible transforms over arbitrary bytes.  The
transform is applied independently to each raw block; it never decodes XML,
Unicode, packet fields, or corpus-specific records.

## Candidates

1. `raw` is the matched backend baseline: the block is passed directly to
   zlib.  It has no learned model and is useful for separating a transform
   result from the entropy backend.
2. `shape` tokenizes bytes into maximal runs of a deterministic byte class
   (ASCII lower/upper/digit, whitespace, punctuation, control, UTF-8
   continuation, or high/unknown byte).  It stores compact `(class,length)`
   descriptors and puts the exact token bytes into class lanes.  Descriptors
   tell the inverse which lane to consume, so case, whitespace, invalid UTF-8,
   and order remain exact.
3. `byteclass` stores one three-bit byte-class selector per input byte and
   class-grouped value lanes.  It is intentionally less clever than `shape`:
   selector cost is explicit and tests whether run tokenization is actually
   earning its metadata.
4. `templates` uses the same class-lane payload as `shape`, but trains a
   bounded dictionary of repeated descriptor sequences from the first 1 MiB.
   A template event expands only to `(class,length)` descriptors; no source
   value bytes are copied into the model.  Literal events retain all unseen
   descriptor data.  This is a generic grammar-like structural code, not an
   XML rule set.

The values are grouped by class only after descriptors have been recorded.
Thus the transform changes locality without discarding source order.  The
decoder reconstructs the source by replaying descriptors and consuming the
corresponding lane.  Every dictionary byte, template event, selector bit,
restart record, checksum, and compressed/raw mode is in the frame accounting.

The implementation uses zlib as a clearly labelled diagnostic entropy bound.
It is not a claim of a novel entropy decoder or of native decoder speed.  A
future pure-Python or native entropy backend would have to reproduce the same
wire-visible transform and pass the same corruption/truncation tests.

## Adversarial predictions

* `shape` should help when repeated markup and prose classes have stable local
  forms, but its descriptor stream and lane boundaries can erase that gain on
  short blocks.
* `byteclass` should usually lose to `shape`: it spends three selector bits on
  every byte.  A win would indicate that exact class context matters more than
  run metadata.
* `templates` can remove repeated descriptor events, but only if its charged
  model survives the 256 KiB screen and the 8 MiB final window.  It must not be
  credited for any value bytes that came from held-out input.
* All candidates should lose on incompressible/random bytes and on class-random
  data; raw fallback is expected there.  A structural candidate that improves
  only the duplicated OMW projection is a repetition result, not a general
  language result.

The screen report therefore publishes fixed model bytes separately from
payload bytes and calculates the final-window break-even point.  No long final
timing run is started by this directory; timing remains gated by the parent
protocol.
