# Minimal acyclic word graph inventory probe

**Result: reject this inventory source for WGP6.** The exact finite set
round-trips by sorted rank, but both the uncompacted and path-compacted graph
cost more than a front-coded type table on the same sample rows. A first-use
bridge needed by the old v4 naming order adds tens to hundreds of kilobytes.
This is a table diagnostic, not a native frame or decode-speed result.

## Accounting

[`dawg_inventory_probe.py`](dawg_inventory_probe.py) reads only the retained
1 MiB and 8 MiB development prefixes. It extracts the byte-exact WGP letter
runs, counts occurrences, sorts distinct strings by raw bytes, builds the
minimal acyclic automaton incrementally, and verifies every sorted-rank
unranking against the source type list. The primary graph removes nonfinal
unary states by concatenating their byte labels and numbers states in
child-before-parent order; arc targets are positive topological deltas.
The uncompacted graph is also retained as an audit.

Both sides use the same first-use-order Huffman word-ID source, including its
complete one-byte-per-ID code-length vector and payload. “Raw model” counts
every front-code/graph header and operand. “Packed model” runs each serialized
inventory byte stream through the same optimal static byte-Huffman coder and
charges a 256-byte canonical code-length vector plus raw size. All integer
operands are ULEB. Rank-path counts are derived by a topological pass and are
not serialized. The comparison excludes all common XML and non-letter data.

| Sample | Types | Compacted states / arcs | Front-coded raw | Graph raw | Raw delta | Front-coded packed | Graph packed | Packed delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| FreeDict 1 MiB | 9,843 | 3,997 / 11,983 | 58,157 | 72,553 | +14,396 | 38,358 | 55,741 | +17,383 |
| FreeDict 8 MiB | 55,856 | 20,569 / 62,565 | 313,231 | 377,823 | +64,592 | 210,027 | 298,162 | +88,135 |
| GCIDE 1 MiB | 16,960 | 5,940 / 17,907 | 83,126 | 97,228 | +14,102 | 48,724 | 72,378 | +23,654 |
| GCIDE 8 MiB | 72,676 | 22,450 / 70,845 | 339,978 | 388,543 | +48,565 | 199,003 | 291,231 | +92,228 |
| OMW 1 MiB | 3,136 | 1,640 / 4,439 | 51,961 | 58,346 | +6,385 | 35,284 | 41,638 | +6,354 |
| OMW 8 MiB | 22,428 | 11,317 / 30,702 | 418,625 | 462,804 | +44,179 | 285,792 | 337,218 | +51,426 |

Positive deltas mean the graph is larger. The uncompacted graph only beats
front coding in raw GCIDE bytes (−7,802 at 1 MiB and −39,690 at 8 MiB); after
the same byte-Huffman backend those rows are +10,409 and +32,779 bytes.
Path compaction reduces state/arc counts but makes raw and packed model size
worse than front coding on all six rows. This rejects the expected
right-language sharing headroom for this serialization.

## First-use and native integration cost

Sorted graph ranks do not match old v4's first-use names. For a decoder to map
those existing IDs into graph ranks, the exact first-use-rank → sorted-rank
permutation requires:

| Sample | Raw ULEB map | Packed static-Huffman map |
|---|---:|---:|
| FreeDict 1 MiB | 19,558 | 19,033 |
| FreeDict 8 MiB | 151,056 | 129,532 |
| GCIDE 1 MiB | 34,368 | 34,532 |
| GCIDE 8 MiB | 201,516 | 172,618 |
| OMW 1 MiB | 6,144 | 5,595 |
| OMW 8 MiB | 50,772 | 47,973 |

Against the sorted-rank front-coded control with no bridge, adding that map
alone makes the compacted graph +11,949 to +264,846 bytes under the packed
ledger. The old codec's class/bucket placement also has to be represented or
recomputed by a real planner; this probe does not price that mapping. These
omissions cannot turn the result into an integration win because the core
inventory graph already loses under the like-for-like table comparison.

Machine-readable output preserves every row, model component, and input hash
in [`dawg-results.json`](dawg-results.json). The earlier uncompacted-only
screen is retained in [`dawg-results-uncompacted.json`](dawg-results-uncompacted.json).
