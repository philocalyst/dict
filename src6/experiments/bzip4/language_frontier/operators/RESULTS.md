# Bounded operator-reset screen

Run date: 2026-09-26.  This is a development screen only: three 65,536-byte
train/target slices, stored HMM teachers, no retraining, no untouched files,
and no timing measurement.  The authoritative machine-readable output is
[`results.json`](results.json).

Command:

```text
python3 src6/experiments/bzip4/language_frontier/operators/operator_probe.py --out src6/experiments/bzip4/language_frontier/operators/results.json
```

The fixed reset sweep was `0`, `1e-4`, `1e-3`, `1e-2` in maximum row total
variation.  The complete prefix code used eight frequent training spans,
expanded with fallback siblings and internal `prefix+EOS` leaves.  Its row
mass error was at most `2.22e-16` in all three cases; CDF binary-search checks
passed, the reconstructed surface matched each target, and the exact phrase
NLL agreed with direct teacher-byte NLL within `3.3e-9` bits.

| case | exact teacher bits | reset threshold | resets / phrases | closed NLL excess bits | serialized diagnostic model | v4 frame | bzip3 frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 236,886.2881 | 0 | 0 / 44,547 | 0 | 6,786,171 B | 7,588 B | 6,674 B |
| FreeDict | 236,886.2881 | 1e-4 | 702 / 44,547 | +0.0126 | 5,721,339 B | 7,588 B | 6,674 B |
| FreeDict | 236,886.2881 | 1e-3 | 1,610 / 44,547 | −0.0286 | 4,444,155 B | 7,588 B | 6,674 B |
| FreeDict | 236,886.2881 | 1e-2 | 2,423 / 44,547 | +0.1497 | 3,366,651 B | 7,588 B | 6,674 B |
| GCIDE | 308,598.3878 | 0 | 0 / 52,169 | 0 | 3,909,457 B | 17,417 B | 14,613 B |
| GCIDE | 308,598.3878 | 1e-4 | 29 / 52,169 | +5.6e-8 | 3,808,081 B | 17,417 B | 14,613 B |
| GCIDE | 308,598.3878 | 1e-3 | 29 / 52,169 | +5.6e-8 | 3,687,121 B | 17,417 B | 14,613 B |
| GCIDE | 308,598.3878 | 1e-2 | 72 / 52,169 | −0.0036 | 3,354,193 B | 17,417 B | 14,613 B |
| OMW | 299,575.0188 | 0 | 2 / 62,900 | 0 | 5,404,007 B | 6,493 B | 5,032 B |
| OMW | 299,575.0188 | 1e-4 | 179 / 62,900 | −1.1e-6 | 3,454,823 B | 6,493 B | 5,032 B |
| OMW | 299,575.0188 | 1e-3 | 341 / 62,900 | −6.0e-4 | 3,075,815 B | 6,493 B | 5,032 B |
| OMW | 299,575.0188 | 1e-2 | 341 / 62,900 | −6.0e-4 | 2,894,567 B | 6,493 B | 5,032 B |

The negative NLL deltas are not compression savings: this is one deterministic
target, and the reset model can assign it slightly more probability.  The
diagnostic model blob is still megabytes larger than the retained v4/bzip3
frames and there is no payload coder or independent decoder.  These numbers
therefore disprove a claimed practical win for this tiny teacher/phrase
construction, not for all latent sources or all operator topologies.

Input/teacher SHA-256 evidence (also repeated in `results.json`):

```text
freedict train 378a174c295bf7084c98832aed5b1f5e31a9ab7fa174800eb25e5372d932 target d3bae0c328de1d07a3fde062f4cd68a6b72b828d6098f37aea4c73effae55b63 teacher b8e84fafd625b96eb07fc673264427a8db154f742f0a30d80e9a7b4054217e25
gcide    train 042b063b4352b821de0c64b4b1e3ffe25513dfbbf7d176f9b3e1ebc05ba65008 target 8719c720994d16f2276bbccf0fc315e7c950a77fc426814924ed9b4f1d1e223b teacher 504ec0e8fe6f90dd1c03409e3973eb3be47738879b24c00c861265e3f685db82
omw      train d95b6d8339f1fe12652afc461624423278dba2b35271b66c32893a23b186f219 target 7b8124b6cde70665409887bdb03f88af9873d0490272cdbe97cc2af752007283 teacher e237006598b2d361c810c7b15470f85cb93a354bcc5065972f9eb03f1a1dcf53
```

## What the rows say

The normalized complete-code row-dispersion summaries are broad rather than
uniformly forgetful.  FreeDict's median was `1.23e-3` and p95 `0.906`; GCIDE
median `0.277` and p95 `0.851`; OMW median `1.13e-4` and p95 `0.941`.  OMW had
many low-dispersion fallback phrases, but the long-tail rows still had
operator ranks through 8.  The word and byte-substring proxy inventories are
not normalized codebooks; their row statistics are diagnostics only.

All positive real-data products had finite Birkhoff cross-ratio values, but
the resulting contraction bounds were often weak: complete-code p95 `tau` was
`0.983` (FreeDict), `0.959` (GCIDE), and `0.995` (OMW).  A finite Birkhoff
bound is therefore not evidence that a reset is cheap enough; the rollout and
charged table must still be measured.

## Checks

```text
python3 -m unittest discover -s src6/experiments/bzip4/language_frontier/operators -p 'test_*.py'
......
Ran 6 tests in 0.092s
OK
```

The exact tests cover composition, probability-preserving rank-one resets,
posterior normalization/bounds, impossible and negative models, complete-code
terminal handling, and cumulative-CDF/binary-search equivalence.
