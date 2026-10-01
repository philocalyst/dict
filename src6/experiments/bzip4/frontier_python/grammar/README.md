# Global batch grammar reference

This directory is a separate Python reference family.  It is not production
selection code and does not claim a new compression algorithm.  It tests one
specific hypothesis from the frontier plan: independently addressed blocks can
share a charged, recursively reusable grammar whose rules reduce both spelling
bytes and event count.

## Construction

`_build_grammar` starts with literal byte IDs `0..255` in each raw block.  A
pass aggregates packed adjacent-pair counts over every block, ranks pairs by a
deterministic saving estimate, then greedily replaces selected non-overlapping
pairs in one scan.  New rules are appended only after the pass, so references
always point backwards.  Rules whose expansion would exceed 512 bytes are
rejected.  The default cap is 4,096 rules and ten passes; the encoder is
allowed to inspect the complete input for the `input_*` variants because the
complete discovered model is written to the frame.

After substitution, reachability/use counts are propagated through the DAG.
Unused and one-use rules are inlined; only rules with at least two reachable
uses remain.  Inlining may make a retained rule n-ary, so each surviving rule
stores a bounded ULEB arity followed by packed ULEB references.  The decoder
validates topological ordering and expansion lengths, then pre-expands each
surviving rule once.  Its hot path is a canonical-code walk plus one flat-table
`bytearray.extend` per decoded symbol.

The `training_huff` screen variant calls `train(training)` and then encodes the
screen against that frozen grammar.  `input_huff` and `input_fixed` rebuild a
fresh grammar from the evaluation input; those are ordinary input-fit batch
compression diagnostics, not held-out predictive claims.  Literal bytes remain
available for arbitrary unseen or invalid UTF-8 input.

The nominated fixed screen configuration is `input_huff`, 8,192 maximum rules,
64 maximum passes, 16 KiB or 64 KiB raw blocks, and the `consistent` pair
policy.  This is one fixed algorithm/parameter budget across corpora; the
smaller 4,096-rule/10-pass overlap-greedy defaults remain useful for quick API
smoke tests and retained ablations.  Internal rules with no top-level event may
have zero Huffman length and are skipped during frozen-model tokenization;
literal code lengths and literal frequencies are always positive.

## Charged wire format

Every frame contains:

* a 48-byte header and 24-byte restart directory record per raw block;
* a complete model (`GMD1`) with coder/scope, rule count, source-byte count,
  symbol count, every rule's arity and references, and the dense canonical
  Huffman length table (or the corresponding fixed-width diagnostic model);
* each block's mode byte, event bits, valid-bit count, raw length and CRC-32;
* exact metadata CRC coverage over the zeroed-CRC header, model and directory;
* canonical zero padding checks and no trailing bytes.

Raw fallback is selected per block only when its complete mode-plus-literal
payload is no larger than the coded candidate.  Thus a high model cost or a
poor block is visible in `model_bytes`, `directory_bytes`, and `raw_blocks`.
`frame_metrics()` reports complete-byte accounting, rule expansion bytes,
serialized entropy-table bytes, entropy/padding bits, and decoder operation
counters.  The encoder retains raw frequencies only as diagnostic evidence;
they are not serialized redundantly because canonical lengths fully determine
the decodable Huffman table.

## Complexity and startup assessment

For a block sequence of `N` symbols and `P` passes, pair counting and replacement
are `O(PN)` plus sorting the bounded candidate map; the candidate map uses
packed integer keys and is encoder-only.  Model serialization is linear in rule
references and the canonical entropy table.  Preparation is `O(model bytes +
total rule expansion bytes)` and is bounded by `MAX_PREEXPANDED_BYTES` (8 MiB)
and 512 bytes per rule.  Each decoded coded symbol performs one entropy walk
and one bulk expansion copy; raw fallback is a bounded slice copy.

The eager flat table is a decoder baseline, not a claim that all deployments
should eagerly expand every rule.  A lazy alternative can retain the same
serialized topological refs and length checks, recursively expanding only rules
referenced by a requested block with memoized bounded results.  It would reduce
cold startup for sparse random access at the cost of branch/dependency work per
first use.  This prototype charges the eager table and reports its byte/time
cost explicitly; no hidden warm dictionary is assumed.

## API

```python
import grammar

frame = grammar.encode(data, block_bytes=16 * 1024, variant="input_huff")
prepared = grammar.prepare(frame)
assert prepared.decode_block(0) == data[:16 * 1024]
assert grammar.decode(frame) == data
print(grammar.frame_metrics(prepared))

frozen = grammar.train(training_prefix, block_bytes=16 * 1024)
heldout_frame = grammar.encode(heldout, 16 * 1024, model=frozen)
```

Run the local correctness suite with:

```text
python3 -m unittest discover -s src6/experiments/bzip4/frontier_python/grammar -p 'test_*.py'
```

The fixed 256 KiB screen uses `screen.py`.  It launches one worker per
corpus/variant, and each child is persisted through
`protocol.capture.run_and_save` before its JSON is parsed.  The resulting ledger
retains failed configurations and reasons as well as complete candidate and
native-control byte totals.

## Prior-art boundary

Pair substitution, RePair-style grammar induction, relative/LZ grammar
combinations, canonical Huffman coding, and flat phrase expansion are all
established ingredients.  The local research notes cite Stable Local
Consistency (SEA 2025), RLZ-RePair, and grammar random-access work.  Results
here are a storage/decoder-cost measurement of this charged block-addressable
combination, not a novelty assertion.
