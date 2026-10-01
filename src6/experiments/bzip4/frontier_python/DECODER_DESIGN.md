# Decoder specification for the strongest structural candidate

This specifies the isolated `symbol_bwt` Python reference, not a production
format or an approved Bzip3 replacement. It is deliberately independent of
how an encoder discovers phrases. The actual implementation and exact numeric
limits are in `symbol_bwt/codec.py` and `grammar/grammar.py`.

## A small stored program over byte strings

There are three different integer domains:

1. A **definition ID** names a literal byte or a bounded grammar expansion.
2. A **root symbol** is a definition chosen to emit bytes in a block.
3. A **recency rank/event** codes where that root occurs in a moving ordering.

The current wire gives literals IDs 0–255 and then gives rules increasing IDs.
Each rule references only earlier definitions. This makes the grammar a DAG
without needing an expensive cycle search. Expansion length is a checked
measure: it is the sum of its referenced expansions, bounded both per rule and
over the complete model. The table is immutable after preparation.

Rule discovery is encoder-only. The frozen experiment uses a bounded
non-overlapping pair family to learn rules, removes stored-single-owner
definitions, then parses each block by longest matching finalized expansion.
The decoder repeats none of that work. It sees only the resulting model and
code stream.

## Complete wire accounting

| Region | Stored content |
|---|---|
| 56-byte frame header | Magic/version, boundary/count/raw size, model/directory/payload lengths, alphabet count, metadata CRC, reserved fields |
| Grammar model | Tagged/versioned bounded topological DAG, all literal/rule expansion information, scope metadata; no redundant root Huffman table for the fixed grammar mode |
| Event model | 9-byte tagged header followed by one canonical Huffman code length per recency event |
| 36-byte record per independent block | Payload offset and size, raw/root/event counts, cyclic-BWT primary, decoded CRC32, exact valid bit count |
| Block payload | One raw/coded mode byte followed by raw bytes or packed Huffman events, including charged final padding |

The metadata CRC covers the header with its CRC field zeroed, both models, and
the complete directory. Each block also checks its decoded CRC32. These are
accidental-corruption checks comparable in purpose to the control's checks;
they are not cryptographic authentication. An authenticated container must
charge its own digest/directory and supply stable verified bytes.

## Preparation

```text
read fixed header
reject unsupported tags, impossible sizes, excessive counts, nonzero reserves
prove exact region offsets and total length before slicing model regions
verify metadata CRC
read bounded topological grammar; compute checked expansion measures
read canonical event code lengths; reject missing, oversized, or oversubscribed codes
construct immutable expansion table and Huffman decode state
validate directory offsets, lengths, counts, primary indices, and bit bounds
publish Prepared(frame, model, directory)
```

The current reference eagerly expands the grammar. That makes retained decode
simple but costs startup and memory even for a single query. Its measured
startup is not free, and its first-block path reparses/prepares the model.

## Independent block decoding

```text
record = directory.checked(index)
if payload.mode == raw:
    require exact raw size and zero coded-bit count
    return checked_crc(payload.bytes)

events = huffman_decode_exact(payload, event_count, valid_bits)
require no extra code, partial code, extra byte, or nonzero padding
ranks = expand_zero_runs(events, exactly=root_count)
roots_in_bwt_order = inverse_mtf(ranks, initial_order=all_definition_ids)
roots = inverse_cyclic_bwt(roots_in_bwt_order, primary)

for root in roots:
    expansion = expansion_table.checked(root)
    require expansion fits remaining declared raw length
    copy expansion into caller-owned output
require exact final length and matching decoded CRC
```

RUNA/RUNB give zero runs a bijective binary representation; other events name
positive recency ranks. Every block starts from the same alphabet order, so no
preceding block must be decoded. The inverse BWT operates on root tokens, not
expanded bytes. That is the intended reduction in serial work.

The Python reference returns owned byte strings and uses Python integers,
lists, and dictionaries. A later Zig implementation could use bounded integer
lanes and caller-owned output/scratch, but this is a design possibility, not a
measured native result. Do not infer its speed from Python or from an older
different native BWT codec.

## Composition with the dictionary model

At the byte-codec layer, each independently addressable compressed block maps
to a raw interval. It can hold a canonical typed packet, a text page, or a
column page. A caller must still admit the decompressed packet before exposing
references. The codec neither weakens semantic validation nor resolves
forward references on its behalf.

`decodeInto` should write directly into its final bounded output allocation.
Admission may then build views whose pointers are stable for that allocation's
lifetime. Shared rule expansions are immutable internal storage; pointers into
temporary codec scratch must never escape as semantic string views. Resource
reference fixups belong to packet admission, not to compression.

Selective block decode survives, but selective fields within one compressed
block do not appear for free. Smaller pages increase restart/model/directory
cost; larger pages increase first-query work. Shared model scope and page
placement must be included in any outer-container benchmark. The experiment
does not count canonical packet reconstruction as exact reproduction of an
original TEI/LIFT XML serialization.

## Remaining risks before any Zig port

- Byte storage must pass on every required corpus; one large win is not a
  universal replacement.
- Full-alphabet MTF has an alphabet-sized worst-case update. A faster rank
  structure may improve native execution but adds state; measure the simplest
  flat implementation first.
- The reference cyclic sorter uses comparison sorting per doubling round,
  not a claimed linear-time suffix sorter. Encoding cost is explicit.
- Eager rule expansion and dense event lengths add startup and fixed bytes.
  Reducing either must retain exact bounds and an ordinary, inspectable reader.
- Parser/encoder count limits must be one contract. Distinct integer domains,
  checked constructors, and immutable admitted views should make mismatches
  difficult to express rather than relying on comments alone.
