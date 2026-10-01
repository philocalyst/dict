# Structural/context separation

This isolated family tests reversible byte-class and descriptor-lane
transforms with a charged model and independent raw blocks.  It is not wired
into production.

* [`structure.py`](structure.py) exposes `train`, `encode`, `decode`,
  `decode_block`, and `frame_info`.
* [`HYPOTHESES.md`](HYPOTHESES.md) defines the four variants and the
  adversarial predictions.
* [`RESULTS.md`](RESULTS.md) is the retained 256 KiB screen and rejection
  ledger.  The raw subprocess capture and exact frames are under `evidence/`.
* [`test_structure.py`](test_structure.py) covers exact roundtrips,
  independent blocks, arbitrary bytes, corruption, truncation, and bounds.

The only entropy backend is the standard-library `zlib-diagnostic` bound.  No
timing claim is made here, and the parent serial gate intentionally stopped the
family before the final 8 MiB window.

The structural motivation follows established grammar/tokenization and
dictionary-compression work, including BPE with charged vocabulary, relative
LZ/grammar combinations, and block-local consistency.  The parent frontier
[`RESEARCH.md`](../RESEARCH.md) records the primary references and cautions;
this experiment makes no novelty claim.
