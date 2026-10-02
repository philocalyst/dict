# Joint lexical PPM development screen

The fixed causal diagnostic in [PROTOCOL.md](PROTOCOL.md) ran on all six
pinned at-most-1 MiB development book sources. Both tokenizers reconstructed
every source byte exactly, including the tests for zero and invalid UTF-8.
All 12 rows remained below the 512 MiB process address-space cap. The model
keeps complete successor distributions in each retained row and uses PPM-D
exclusion and an explicit-END byte PPM for first-use spellings.

These figures are **optimistic ideal code lengths**, with one mode bit and a
24-byte provisional framing reserve. They are not archive bytes or a universal
lower bound. Actual arithmetic coding, a decoder and its work bound would add
cost. Whole-file bzip3 values are complete, independently exact-decoded frames
of the same sources.

| Development book | Whole bzip3 B | Byte events ideal B | Scalar CJK ideal B | Better mode | Better vs bzip3 |
|---|---:|---:|---:|---|---:|
| Pride and Prejudice (en) | 161,119 | 177,750 | 177,195 | scalar | +9.98% |
| War and Peace prefix (en) | 247,364 | 276,976 | 273,866 | scalar | +10.71% |
| Don Quijote prefix (es) | 252,940 | 287,849 | 287,569 | scalar | +13.69% |
| Madame Bovary (fr) | 179,597 | 205,747 | 205,566 | scalar | +14.46% |
| Die Verwandlung (de) | 35,251 | 40,824 | 40,739 | scalar | +15.57% |
| Kokoro (ja) | 97,505 | 112,312 | 101,589 | scalar | +4.19% |
| **Sum** | **973,776** | **1,101,458** | **1,086,524** | scalar | **+11.58%** |

For the selected modes, the 1,086,524-byte ideal cost contains approximately
676,969 bytes for known word choices, 137,936 for known separator choices,
71,419 for first-use escapes, 196,901 for new word spellings including END,
and 3,152 for new separator spellings. The mode bit, ceiling to bytes and
24-byte reserve account for the small remainder. First-use spelling is a
material cost; eliminating it hypothetically would be invalid because the
decoder needs every new surface form. Known word choice is the largest cost.

The lexical row cap reached 80,000 on five books, with 1,470,985 whole-row
replacements across the selected six rows. The peak retained lexical edge
count was 233,567 of a 400,000 cap. The spelling model needed no replacement;
its largest row and edge counts were 19,181 and 44,405. Peak observed process
RSS among all 12 diagnostic processes was 83,720 KiB. These data establish
admission for these sources, not a fixed-cost decoder: exclusion currently
scans all successors of an escaped row and can require quadratic cumulative
work in a constructed 1 MiB input. The subprocess timeout is a diagnostic
failure bound only.

The result fails the preregistered native-wire gate on every book. It closes
this exact PPM model and tokenizer pair, without a post-result order/capacity
grid. It does not rule out a stronger jointly coded morphology/word grammar,
or a different bounded-work causal predictor. The scalar policy gives the
largest relative gain over byte tokens on Japanese, but still exceeds native
whole-file bzip3 there.

## Evidence and reproduction

```
cd src6/experiments/lexical_ppm
python3 test_ppm.py
python3 screen.py --output /workspace/scratch/lexical-ppm-dev6-r0
```

The byte-for-byte preregistered protocol is in
[preregistered-PROTOCOL.md](evidence/preregistered-PROTOCOL.md). Its source
hash and the unchanged scorer/script hashes are in [pins.json](evidence/pins.json).
The full 12-row source identities, six-way attribution, state counts,
replacement counts, ideal bits and diagnostic clocks are in
[results.jsonl](evidence/results.jsonl). The original result artifacts are
also under `/workspace/scratch/lexical-ppm-dev6-r0/`. The scalar-mode Python
and Unicode versions are in [runtime.json](evidence/runtime.json). The protocol's later
wording correction lists the exact Unicode scalar ranges already used by the
pinned code; no model or acceptance policy changed.
