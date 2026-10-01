# Adversarial review of `symbol_bwt/codec.py`

This is a bounded, read-only review of the plausible symbol-BWT candidate.  It
does not modify `symbol_bwt`, grammar, or protocol files, and it does not run a
corpus timing or final-lane measurement.  The current source under review is
`codec.py` SHA-256
`7fd9c43f1f291522a0e23a2c807888c5fd8639e05249c0874442eed74bdff638`.

## Previous finding — resolved

### P2 — encoder/parser `MAX_BLOCKS` mismatch (fixed)

`_parse_frame()` rejects `block_count > MAX_BLOCKS`, and the raw-size/block-size
bounds make more than one million one-byte blocks reachable under the 512 MiB
raw limit.  The current `encode()` computes the block count immediately after
its input/block-size checks and rejects counts above `MAX_BLOCKS` with
`FrameError`, before serializing the grammar/event model or entering the
per-block `_encoded_block()` loop.  The parser and encoder now share the same
block-count contract.

`test_encoder_rejects_block_count_before_record_work` scales `MAX_BLOCKS` to
one, monkeypatches `_encoded_block()` to fail if called, and requires
`FrameError` for two one-byte records.  Thus the test proves the guard occurs
before model serialization and per-record work rather than merely checking a
bad frame after construction.

No open P2 was found in this refreshed bounded pass.

## Checks that passed

### Integer-alphabet BWT and MTF boundaries

An independent naive rotation-sort oracle matched `_bwt_transform()` and
`_inverse_bwt()` for every ternary sequence of lengths 1--7 and deterministic
random sequences using negative, large, and adjacent integer IDs.  The
implementation's dense initial ranking is decoder-local scratch and does not
assume byte values.  MTF ranks are bounded to the complete grammar root
alphabet, and RUNA/RUNB conversion rejects rank/run counts that cannot produce
the declared root-token count.

The focused review also exercised a grammar rule root (`ab`) alongside literal
IDs and checked that the frame round-trips with its complete event model.

### Complete model and accounting state

The frame carries the serialized fixed grammar DAG, a separate `EHD1` event
model containing every event code length, the header's grammar symbol count,
and a directory record for each independent block.  The event alphabet has
`symbol_count + 1` entries: RUNA, RUNB, and nonzero MTF ranks.  `Model` rejects
absent, oversized, or wrong-length event tables; `Model.from_blobs()` checks
the event magic/count/length and canonical code set.  The grammar model's
rules, scope, training byte count, and any grammar Huffman lengths (if a
non-default grammar model is supplied) remain in the grammar blob; fixed
grammar models legitimately have no redundant grammar entropy table.

`frame_metrics()` reports grammar-model bytes, event-model bytes, directory,
payload, entropy bits/padding, root/event counts, and complete bytes.  The
metadata CRC covers the zeroed-CRC header, grammar blob, event blob, and full
directory.  Block mode, raw length, token/event counts, BWT primary, block CRC,
and exact valid Huffman bits are all charged directory state.  I found no old
Huffman table silently omitted from the current wire accounting.

### Resealed hostile wires

The focused tests construct frames with valid outer metadata checksums and then
exercise:

- grammar rule-zero forward references, 513-child arity, a 512-byte child
  doubled past the expansion bound, excessive training bytes, and a rule count
  above `MAX_RULES`;
- zero/oversubscribed event code lengths and a header grammar-alphabet mismatch;
- root-token overflow, BWT primary overflow, event-count overflow, exact
  coded-body/valid-bit mismatch, nonzero Huffman padding, and payload bit
  corruption; and
- empty frames, raw fallback blocks, selected-block index bounds, and ordinary
  coded round trips.

`Model.from_blobs()` normalizes malformed grammar/model exceptions to
`FrameError` at the wire boundary.  Direct invalid public model construction
continues to raise `ModelError`, which is the appropriate encoder-side API
error.  `Prepared.decode_block(i)` parses the full frame/model but validates
only block `i`; unselected payload corruption is not detected until those
blocks are decoded, as required for independent access.

### Huffman tail and decoder bounds

`_huffman_decode()` requires positive valid bits, exact
`ceil(valid_bits/8)` body length, a zero padding suffix, a terminating tree
node, and exactly the directory's event count.  After entropy decoding,
`_events_to_ranks()` requires exactly the directory token count, `_mtf_decode()`
checks every rank against the full root alphabet, inverse BWT checks the
primary, and root expansion checks the declared raw length before the per-block
CRC.  Parser limits cover 512 MiB frames/raw input, 4 MiB blocks, one million
records, 16 MiB grammar models, bounded event-model bytes, bounded coded bits,
and grammar expansion limits inherited from the grammar model.

## Complexity and startup

The Python cyclic prefix-doubling sort performs comparison sorting over integer
IDs at each round, approximately `O(n log^2 n)` comparisons in this reference
implementation; this is not a native linear-sort claim.  MTF updates are
`O(alphabet_size)` per rank, inverse BWT is linear in the token count using
counter/dictionary scratch, and Huffman/event/rule expansion work is linear in
the decoded stream after preparation.  Grammar expansions are precomputed once
and copied in bulk.  `frame_metrics()` exposes logical Huffman-tree, MTF
scratch, and preexpanded grammar estimates; Python object RSS is not disguised
as a portable native allocation figure.

## Reproducible current evidence

The focused review test source is SHA-256
`b4af7f2f126f43622b6472d278c39fe2a3e691536e96a0c40a18f84049fe6e88` and has
seven tests:

```text
PYTHONPATH=src6/experiments/bzip4/frontier_python \
  python3 -m unittest discover \
  -s src6/experiments/bzip4/frontier_python/structure \
  -p test_symbol_bwt_review.py -v
```

The refreshed subprocess was captured before parsing and returned status 0
with empty stdout (SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) and
1245-byte stderr (SHA-256
`9480be04b376ff959d08b660862b3daa6e13d32750abaec49180f9b70e0a206d`).  Raw
streams and the status record are retained at:

`structure/evidence/symbol-bwt-review/symbol-bwt-review-fixed-v2.{stdout.bin,stderr.bin,status.json}`

The candidate's existing five-test codec suite also passed with status 0.  Its
refreshed process has empty stdout (same SHA-256 above) and 779-byte stderr
(SHA-256
`fc858696d02e6057a261515d7ef5a3da7eaa66d5b939b3e65c62a5bb7b7d8ae2`):

`structure/evidence/symbol-bwt-review/symbol-bwt-tests-fixed-v2.{stdout.bin,stderr.bin,status.json}`

## Historical pre-fix evidence (preserved)

The original finding was observed against codec SHA-256
`cf1cdb085b198bec46f668665a310ec1925b1b7f3fe5f21f7fbfeb85d6a7aeb2` and
focused-test SHA-256
`539f7cc9181e98bcaf4f3cd026fec28844e81dec3c3aeee29875403c4ffab59f`.  The
pre-fix raw captures remain under the v1 stems and are not overwritten:

- `symbol-bwt-review-fixed-v1`: status 0; empty stdout SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
  stderr 1243 bytes, SHA-256
  `3ff6df604d616b3774faa147ebc14526d4b1cf4d3e74c50df77dd4f40abfb221`.
- `symbol-bwt-tests-fixed-v1`: status 0; empty stdout SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
  stderr 507 bytes, SHA-256
  `1cc21305d102a58d56d1de89bc7f4d21bc9e69cc3e2b86ba3cc651f07c8ffd2c`.

No symbol-BWT corpus screen or long timing was run for this review.
