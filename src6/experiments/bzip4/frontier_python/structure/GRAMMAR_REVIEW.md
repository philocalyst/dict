# Adversarial review of `grammar/grammar.py`

This is a bounded, read-only review of the current grammar wire format and
decoder.  It does not modify `grammar` or protocol files and does not run a
corpus timing or final-lane measurement.  The review targets resealed
metadata, ULEB canonicality, topological references, stored fan-inverse
accounting, and model/expansion capacity.  The current source under review is
grammar SHA-256
`871efc235a9726aadf6730733c4459b8930dad9acd0896610d0cd0725746ccdc`.

## Current verdict

No open P2 was found in this bounded pass.  The previously reported grammar
issues are repaired in the current source:

- model construction now rejects zero literal Huffman frequencies, so a public
  model cannot serialize a frame whose literal escape alphabet is absent;
- `Model.from_bytes()` translates semantic expansion/training-bound failures
  into `FrameError` at the hostile-wire boundary;
- frequencies are encoder-only diagnostics and are no longer redundant wire
  state;
- pruning counts root occurrences plus direct stored definition sites, not
  runtime expansion multiplicity; and
- the trie does not expose an uncoded internal DAG node as a frozen-model
  terminal.

The decoder still intentionally accepts more than one tokenization when two
valid token streams expand to the same bytes.  That is an informational format
policy observation, not a corruption or accounting bypass.

## Adversarial checks

The focused tests rebuild the metadata CRC after every header, directory, or
model mutation.  Therefore the malformed-wire results below are not merely
stale-checksum failures.

- Header flags/size/reserved fields, zero block size, raw-length and
  block-count mismatches, model/directory length shifts, valid-bit changes,
  directory offsets, payload trailers, and truncation are rejected.
- A rule-zero forward reference, oversized arity (513), rule count above
  `MAX_RULES`, a backward-reference expansion over 512 bytes, and a training
  byte count above `MAX_RAW_BYTES` are rejected after a valid metadata reseal.
  Semantic model failures now surface as `FrameError`, not an internal
  `ModelError` leak.
- Noncanonical zero ULEB encodings for both a rule arity and a child reference
  are rejected by `_read_uleb()` after resealing.  Its ten-byte cap, terminal
  zero rule, overflow-byte check, and per-field limits bound malformed input.
- An in-memory model with an uncoded internal child does not freeze that child
  as a terminal: literal `ab` tokenizes as literals while coded parent `abab`
  remains selectable.  Serialized Huffman models require every literal to
  have a positive code length, while internal zero lengths are allowed only
  for such uncoded DAG nodes.
- A valid frame with its first literal Huffman length resealed to zero is
  rejected.  The public constructor independently rejects a zero literal
  frequency before a frame can be emitted.

## Informational canonicality observation

The encoder's trie chooses a longest match.  The decoder expands decoded
symbols and checks the resulting raw CRC; it does not re-tokenize the output to
prove that the longest-match stream was used.  With `ab` as a child and `abab`
as a parent, both `[parent]` and `[child, child]` can be encoded with valid
canonical Huffman bits and the same block checksum.  Enforcing a unique
longest-match wire would require a second tokenizer pass during decode and is
not needed for lossless reconstruction.

## Wire, capacity, and accounting review

`_derive_expansions()` validates earlier-reference order, rule arity, each
expanded rule length, and the aggregate pre-expanded table before a decoder
table is retained.  The model and frame bounds are finite: 8192 rules, arity
512, 512-byte individual expansions, 8 MiB aggregate pre-expansions, 32-bit
bounded code lengths, one-million directory entries, 4 MiB block targets, and
512 MiB frame/raw limits.  Directory offsets are contiguous and totals are
cross-checked against the header before block decode.

The metadata CRC covers the zeroed-CRC header, complete model, and complete
restart directory.  Payload bytes are outside that CRC by design, but every
block has an exact directory length, raw length, CRC32, valid-bit count,
canonical Huffman/fixed padding check, and decoded-length check.  CRC32 is
adequate for accidental-corruption detection, not cryptographic
authentication.

The serialized model charges rule references, arities, scope/training-byte
metadata, and the dense Huffman code-length table.  Frequencies are not
serialized because they are not needed by the decoder; `frame_metrics()`
reports `frequency_records_encoder_only: None` for prepared frames.  Complete
frame totals include the 48-byte header, 24-byte directory records, model,
mode bytes, entropy bits, and explicit padding.

`prepare()` parses and bounds the entire frame without decoding every block.
`Prepared.decode_block(i)` validates only block `i`, preserving independent
access; full integrity requires decoding all blocks.  Entropy decoding is one
canonical bit walk per coded event, and flat rule expansion copies each
decoded symbol's pre-expanded bytes once.  `decode_symbol_ops` and
`decode_copy_bytes` expose those actual operations.  Raw fallback blocks are
bounded direct slices.  This is Python reference complexity, not a native
speed claim.

## Reproducible current evidence

The focused review test source is SHA-256
`227ea52c6011e9bac785cd891d7593f2b3d1db001c853544f3d2ee6fee4e22d9` and has
six tests:

```text
PYTHONPATH=src6/experiments/bzip4/frontier_python \
  python3 -m unittest discover \
  -s src6/experiments/bzip4/frontier_python/structure \
  -p test_grammar_review.py -v
```

The actual subprocess was captured before parsing and returned status 0 with
empty stdout (SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) and
1078-byte stderr (SHA-256
`31f62c876437436fb2159b5908709f803de92e7463556a04780ffa23140cc24d`).  The
raw streams and status record are retained at:

`structure/evidence/grammar-review/grammar-review-fixed-v1.{stdout.bin,stderr.bin,status.json}`

The existing grammar codec suite has nine tests and also passed with status 0.
Its captured process has empty stdout (same SHA-256 above) and 1332-byte
stderr (SHA-256
`b3743f508450605e72884453101154142d3424c1b4cfd781407c745ee39a9042`):

`structure/evidence/grammar-review/grammar-tests-fixed-v1.{stdout.bin,stderr.bin,status.json}`

No grammar corpus screen or long timing was run for this review.
