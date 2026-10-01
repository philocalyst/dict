# Adversarial review of `bwt_context/codec.py`

This is a bounded, read-only review of the isolated BWT reference codec and
its A--F frame families.  It did not change `bwt_context`, the protocol
helpers, or any production integration, and it did not run a corpus screen or
long timing.  The current verdict below is against `codec.py` SHA-256
`ad20998c88df51a42b17ca1f1a9f587cc1f6bee6aae3efa352047c3ebd64addd` and the
focused review test SHA-256
`59ebb46effecf23c19377a94ffb51dfa5f601003bf929109ce9d8d98cc5fa6be`.

## Current verdict

The three P2 wire/canonicality issues recorded by the earlier review are
resolved in this source revision:

| historical issue | current behavior | focused regression |
| --- | --- | --- |
| C zero `factor_window` or `factor_min_match` silently expanded to defaults | C wire fields must be in their serialized ranges; zero is rejected | `test_resealed_c_zero_factor_fields_are_rejected_after_repair` |
| a resealed MTF mask could contain an unused byte | decoded BWT symbols must have exactly the serialized mask set | `test_resealed_mask_with_unused_symbol_is_rejected_after_repair` |
| public C/D model values exceeded their u8/u16 wire fields and leaked `struct.error`/`ValueError` | constructor bounds match the wire widths and raise `CodecError` | `test_model_constructor_rejects_values_that_wire_cannot_pack` |

The F conditioning arithmetic is also now exact for the full 256-byte
alphabet: `_conditioned_frequencies(base, 256) == base`.  It performs one
largest-remainder normalization and does not add a second unit prior.

No open P2 was found in this bounded pass.  This is a correctness and format
review, not a claim of native speed, cryptographic authenticity, or corpus
compression quality.

## Repaired historical findings

### C factor fields are strict

Earlier `Model.from_wire()` used `factor_window or FACTOR_WINDOW` and
`factor_min_match or FACTOR_MIN_MATCH`, so a correctly resealed C model with a
zero field decoded under an implicit default.  The current parser rejects both
zero and out-of-range values before constructing the model.  The constructor
also enforces the actual u16 window and u8 minimum widths.  The test mutates a
valid frame, recomputes the metadata checksum, and requires `CodecError`; it
does not rely on a random payload bit or the raw block CRC.

### MTF mask membership is strict at the frame boundary

`_alphabet_from_mask()` still parses a nonempty 32-byte mask, but the coded
block decoder now compares the reconstructed BWT last-column byte set with the
mask set.  Adding an unused byte and shifting only EOB therefore fails after
valid rANS decoding.  This closes the earlier alternate-wire representation
while retaining the mask as an explicit, charged block field.

### Public model bounds match serialization

The current `Model.__post_init__()` rejects D `segment_bytes=65536`, C
`factor_window=65536`, and C `factor_min_match=256` with `CodecError`; these
values cannot be represented by the u16/u8 model fields.  The focused test
constructs each invalid model directly, so it checks the public constructor
boundary rather than only `wire()` failure.

## Checks that passed

- An independent rotation-sort BWT oracle covered every binary string of
  lengths 1--9 and deterministic random byte strings of lengths 1--79.  The
  transform's last column and primary index matched, and inverse BWT restored
  every source.
- Direct entropy-state corruption (initial rANS state below the lower bound),
  token-length overflow, primary-index overflow, an empty mask, and malformed
  factor marker/reference streams were rejected through their own parser
  bounds.  The minimal malformed frames were correctly resealed and carried a
  valid directory checksum, so those failures are not merely metadata/raw-CRC
  gates.
- RUNA/RUNB run termination and overflow, EOB/trailing-token handling, MTF
  rank bounds, BWT primary bounds, D selector count/range checks, block mode and
  flag checks, directory contiguity/totals, frame length/truncation, and model
  header bounds are covered by the focused tests and the existing codec suite.
- Full-alphabet F conditioning is identical to the stored A table.  Sparse
  derived tables have zeroes only outside the reachable event support, sum to
  `PROB_TOTAL`, and remain non-serializable.  The decoder's derived-table
  cache is bounded to all 256 cardinalities and its complete logical capacity
  is charged in `Prepared.initialization_bytes`.

## E representation and accounting review

E serializes two complete 258-symbol tables: its model wire is 1044 bytes,
including the model head.  Each coded block stores the representation flag in
its charged block header; flag 0 selects raw-BWT entropy and flag 1 selects
factorized-BWT entropy.  The corresponding table, factor candidate policy,
mask, primary index, entropy tail, directory record, and selector/length bytes
are all included in the complete frame.  Ties select raw deterministically.

The current model rejects noncanonical custom factor parameters for E, so the
fixed E wire does not silently omit a user-selected factor policy.  Training
counts raw-BWT tokens for every training block and factorized-BWT tokens only
for blocks whose bounded candidate is selected; the held-out block choice is
made with the two stored tables.  I found no new E metadata omission in this
revision.  `frame_metrics()` does not separately expose raw-vs-factorized
counts, selector count, token count, or entropy bytes; those values are still
inside the charged payload and can be recovered by parsing it.

## Metadata checksum, payload integrity, and access boundary

The metadata CRC covers the first 36 header bytes, the complete model, and the
complete directory, but deliberately excludes payload bytes.  Payload
corruption is still constrained by directory lengths, exact rANS tail
consumption, block reconstruction, and per-block raw CRC.  This is sufficient
for accidental-corruption checks but is not a cryptographic authentication
tag.  `decode_block(frame, index)` parses the full frame and validates the
selected block only; full-frame integrity requires decoding every block.

`Prepared.decode_block(index)` reuses base rANS state and the F cardinality
cache, while each public `decode_block(bytes, index)` first prepares the frame.
Blocks are independently length-delimited, but there is no sub-block
extraction.  Bounds checked before allocation or entropy traversal include
512 MiB maximum frames/raw input, 64 KiB transformed blocks, token length at
most `2 * transformed_length + 16`, model size, selector count, factor window,
factor output length, and exact directory totals.

## Decode/encode complexity

The Python encoder's cyclic suffix construction uses comparison sorting at each
prefix-doubling round, approximately `O(n log^2 n)` comparisons here; this is
not a native linear-sort claim.  MTF list lookup/pop/insert is `O(256n)` in the
worst case.  Inverse BWT, factor expansion, and rANS symbol work are linear in
the transformed/output block after table preparation.  `_copy_match()` builds
one distance-sized period and extends it in bulk, keeping expansion work
proportional to output length.  Logical initialization accounting uses native
u16 CDF/slot widths and explicitly excludes Python object overhead.

## Reproducible current evidence

The focused review has eight tests:

```text
PYTHONPATH=src6/experiments/bzip4/frontier_python \
  python3 -m unittest discover \
  -s src6/experiments/bzip4/frontier_python/structure \
  -p test_bwt_review.py -v
```

The actual subprocess was captured before any parsing.  The current capture
returned status 0 with empty stdout (SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) and
1296-byte stderr (SHA-256
`727482ca52d7b82bc80653678a713d3b47ac5c3db8f2754af4c300c76ddbf601`).  Raw
streams and the process record are retained at:

`structure/evidence/bwt-review/bwt-review-fixed-v1.{stdout.bin,stderr.bin,status.json}`

The existing codec suite now has 12 tests, including A--F round trips,
independent blocks, wire/model/directory/entropy/factor rejection, strict
widths and masks, F cardinalities/unseen bytes, and the near-full expanding C
fallback.  Its current captured subprocess also returned status 0 with empty
stdout (SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) and
1589-byte stderr (SHA-256
`f0a1852ed4d2896933d0f23fb089e514c045366e2862c987e5c044eb53d0ea3f`):

`structure/evidence/bwt-review/bwt-codec-tests-fixed-v1.{stdout.bin,stderr.bin,status.json}`

## Historical pre-fix evidence (preserved)

The earlier review was run against codec SHA-256
`f0036bf0d5fd2f1b55d25fb139ff85b99faae49aed7a7d5823c72af7c9edec67` and
focused-test SHA-256
`31275271109a8f6af9f0587631152395821a18a5708ab10a514a665ed2a94b90b`.  It
reported the three P2 issues above as accepted alternate/malformed wires.  The
old raw subprocess records were not overwritten:

- `bwt-review-tests-v2`: status 0; empty stdout SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
  stderr 1278 bytes, SHA-256
  `8a5446527845c5161e8fb3c17d9236f57759dc8a299d3ab505b70e22f971414b`.
- `bwt-codec-tests-v2`: status 0; empty stdout SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
  stderr 98 bytes, SHA-256
  `3d2bd0a2599088d8ad7c741be14c22f39bc228900a413923ec2f3b2f00f1a04b`.

No corpus screen or long timing was run for this review.
