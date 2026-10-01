# Prediction lane

This directory owns the charged, multilingual spelling-prediction experiments
for `language_frontier`.  It does not modify the native v4 codec.  The native
comparison is `src6/experiments/bzip4/bz4/v3/zig-out/bin/bz4` with block size
65536.

## What was tested

`spelling_model.py` is the complete bounded lossless control: distinct byte
atoms are segmented by a frozen MDL-like inventory, emitted through static
Huffman rows, and copied through a frozen event stream.  Its model, headers,
boundaries, padding, and CRC are charged.  It preserves arbitrary bytes and
has independent decode/hash checks.

`circuit_probe.py` is intentionally only a cheap diagnostic gate for the more
exotic H4 idea in `FORMULATION.md`.  It scores a type-weighted K=8
mixture-of-products with exact floating-point marginals, but does not claim a
compressed frame.  The corrected generator has two decoder-visible rows:
`start` and `interior`; each row contains 256 bytes plus END.  Therefore
unknown length is generated causally.  The component tables use a conservative
u32 charged-size lower bound.  `test_circuit_probe.py` checks this normalization
and the empty-word path.

The ANS/latent-state follow-up is in `ANS_LATENT.md`.  It reviews the oracle
fragment algebra, prefix-free macro/Tunstall coding, BB-ANS and the
state-space interleaving correction, and records exact operation/rank screens.

## Results (8 MiB eval8; one frozen 1 MiB train prefix)

| slice | native v4 bytes | H1 complete frame | H4 corrected marginal + model lower bound |
| --- | ---: | ---: | ---: |
| FreeDict | 579,202 | 3,775,691 | 321,680 B type-only |
| GCIDE | not rerun (long native command) | 4,413,406 | 354,328 B type-only |
| OMW Japanese | 374,217 | 2,286,351 | 373,449 B type-only |

The H1 frame is deliberately not presented as a v4 replacement: its simple
occurrence stream is much weaker than v4's class/recency payload model.  The
useful comparison for H4 is its isolated first-use type spelling stream:
285,230 B (FreeDict), 321,833 B (GCIDE), and 293,864 B (OMW), before any
complete splice costs.  The corrected H4 lower bound is already larger by
12.78%, 10.10%, and 27.08%, respectively, so no arithmetic-coder
implementation was justified.  Cross entropy is diagnostic only; no
uncharged model or tokenizer is used.

The first probe accidentally used an oracle-selected final-position row and a
u16 size estimate.  Those exact raw outputs remain in
`results/circuit_probe_{freedict,omw}.txt` with a rejection marker; corrected
outputs are in `*_corrected.txt`.  This makes the accounting correction
auditable rather than silently replacing a favorable number.

## Reproduction

```sh
python3 prediction/test_circuit_probe.py
python3 prediction/test_fragment_ans_probe.py
python3 prediction/fragment_ans_probe.py
python3 prediction/circuit_probe.py bz4/data/freedict.train.bin bz4/data/freedict.eval8.bin
python3 prediction/spelling_model.py bz4/data/freedict.train.bin bz4/data/freedict.eval8.bin /tmp/lpred.frame
```

Run commands from `src6/experiments/bzip4` or use the absolute paths recorded
in `results/`.  Keep corpus runs serial: the spelling control is intentionally
expensive and no concurrent long timing runs are part of the evidence.
