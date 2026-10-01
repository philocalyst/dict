# BWT context reference family

This directory is an isolated Python experiment. It does not alter the
production codecs or claim a native-decoder speed result. The decoder is pure
Python; only the encoder's bounded cyclic suffix ordering is used to construct
BWT blocks.

## Explicit ablations

| id | transform and event coding | charged state |
| --- | --- | --- |
| A | BWT, MTF, bijective BZip2 RUNA/RUNB zero runs, static rANS | one 258-symbol 12-bit table |
| B | A plus previous-event class (`start`, `run`, `non-zero/EOB`) | three complete 258-symbol tables |
| C | A plus bounded reversible LZ factorization before BWT | A tables, factor parameters in model |
| D | A plus local table clustering on 512-token segments | four complete tables and one selector byte per segment |
| E | per-block choice between raw-BWT and factorized-BWT representations | two complete global tables; the representation flag selects the table |
| F | A's table renormalized to reachable event IDs from each stored alphabet mask | one 528-byte table; bounded cardinality-keyed derived tables are charged |

RUNA/RUNB are integer events 0 and 1. Non-zero MTF ranks are symbols `rank +
1` (therefore 2 through 256), and EOB is `alphabet_size + 1` (up to 257).
The per-block
256-bit in-use map is stored in the block header; no alphabet is inferred from
an unstored training assumption. This is the structural change from the old
candidate's mixed byte stream of MTF ranks and ULEB run lengths.

The frame charges its 40-byte header, the complete serialized model, every
16-byte directory record (including decoded CRC), per-block BWT primary index,
in-use map, local selectors, rANS tail, and raw fallback bytes. `prepare()`
parses and validates these bytes once and retains CDF/table state for repeated
`decode_block()` calls. `frame_metrics()` reports the model, directory,
payload, and conservative initialization charge. There is no hidden external
dictionary or native entropy backend.

The decoder verifies that the reconstructed BWT last column uses exactly the
bytes named by each stored mask. C factor parameters and D segment sizes are
rejected when they exceed their serialized u8/u16 widths; zero C fields are
not treated as implicit defaults.

Variant F's per-block support is RUNA/RUNB, non-zero ranks through `k`, and
EOB `k+1` for a mask with `k` distinct bytes. The derived positive weights are
renormalized to the same 12-bit total; impossible higher ranks have zero
frequency. The prepared decoder cache is bounded to 256 cardinalities and its
full logical table capacity is charged in `frame_metrics()`.

## API

```python
from bwt_context import train, encode, prepare, decode

model = train(training_prefix, "B", block_bytes=16 * 1024)
frame = encode(held_out, model, block_bytes=16 * 1024)
assert decode(frame) == held_out
prepared = prepare(frame)
assert prepared.decode_block(0) == held_out[:16 * 1024]
```

Malformed headers, model totals, directory offsets, selectors, primary
indices, run lengths, rANS tails, factor references, and CRCs are rejected.
`test_codec.py` exercises zero-valued, raw-fallback, random, Unicode, repeated,
multi-block, malformed, and boundary inputs.

The optional `input_fit_screen.py` / `input_fit_worker.py` pair measures
ordinary input fitting on the fixed 256 KiB screen. It stores the fitted model
in each frame and labels the result `prediction_claim: false`; it is not part
of the frozen-prefix evidence.

## Primary references

The transform follows the original Burrows--Wheeler construction, not a new
algorithm: M. Burrows and D. Wheeler, *A Block-sorting Lossless Data
Compression Algorithm*, Digital SRC Research Report 124 (1994),
[DEC SRC-RR-124](https://www.hpl.hp.com/techreports/Compaq-DEC/SRC-RR-124.pdf).
For a formal analysis of the transform's compression behavior, see G. Manzini,
*An Analysis of the Burrows-Wheeler Transform*, Journal of the ACM 48(3),
2001, [ACM DOI](https://doi.org/10.1145/382780.382782).

The entropy coder is the range-normalized Asymmetric Numeral Systems variant
described in J. Duda, *Asymmetric Numeral Systems*, arXiv:1311.2540 (2013),
[arXiv](https://arxiv.org/abs/1311.2540). The RUNA/RUNB representation is the
established bzip2 run-length convention; the current bzip3 source is the local
control's primary implementation reference (`vendor/bzip3/src/libbz3.c`) and
performs LZP before BWT specifically to collapse long redundant data.

These sources establish prior art for the ingredients. The experiment only
tests whether the charged combinations improve the fixed corpus slices; it
does not treat the combination as novel.
