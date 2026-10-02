# CCW1 development result

The fixed six-book screen in [PROTOCOL.md](PROTOCOL.md) is complete. Its best
causal Q15 **ideal** score exceeds the complete, same-source bzip3 frame on
every book. It is also worse than the prior CCM1 score on five of six books.
The preregistered complete-frame gate was therefore not met, and no CCW1
archive or decoder was built. These ideal scores omit range-coder rounding,
frame bytes and integrity fields, so they are optimistic estimates rather
than compressed sizes.

| UTF-8 DEV book | Source B | bzip3 frame B | Packed orders B | + previous 1 B | + previous 2 B | + scalar segments B | Best over bzip3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pride and Prejudice (en) | 705,012 | 161,119 | 170,240.51 | 169,423.07 | 169,088.11 | 169,087.29 | +4.94% |
| War and Peace (en), prefix | 1,048,576 | 247,364 | 260,345.51 | 259,193.01 | 258,734.88 | 258,731.22 | +4.59% |
| Don Quijote (es), prefix | 1,048,576 | 252,940 | 267,367.96 | 266,084.44 | 265,619.37 | 265,619.49 | +5.01% |
| Madame Bovary (fr) | 716,472 | 179,597 | 192,629.82 | 191,693.98 | 191,292.44 | 191,283.98 | +6.51% |
| Die Verwandlung (de) | 126,200 | 35,251 | 37,093.33 | 36,997.01 | 36,935.89 | 36,936.35 | +4.78% |
| Kokoro (ja) | 486,098 | 97,505 | 107,929.73 | 107,686.48 | 107,566.41 | 106,147.59 | +8.86% |

The previous-token construction improves the packed baseline on all six:
previous two tokens save 1,152 B on Austen, 1,611 B on War, 1,749 B on
Quijote, 1,337 B on Bovary, 157 B on Kafka and 363 B on Kokoro. Scalar
segmentation saves a further 1,419 B on Kokoro but nearly nothing on the
other texts. This is evidence for the specific joint predictor, not for a
whole-frame compression gain. The frozen CCM1 best scores were 168,763,
260,146, 263,843, 187,541, 36,453 and 102,973 ideal bytes in this order;
CCW1 improves only War by about 1,415 B against that earlier model.

## State and work ledger

The packed representation did address CCM1's frequent replacement of
per-prefix byte rows. Exact byte-order-8 outer-row replacements and
within-row partial-prefix evictions are separate counts:

| Book | Byte-8 row replacements | Byte-8 prefix evictions | Joint prior-2 row replacements | Joint prior-2 prefix evictions |
| --- | ---: | ---: | ---: | ---: |
| Austen | 107,087 | 97,907 | 426,628 | 121,250 |
| War | 262,524 | 154,271 | 701,768 | 175,515 |
| Quijote | 268,568 | 154,411 | 698,149 | 174,092 |
| Bovary | 145,100 | 89,805 | 454,692 | 108,044 |
| Kafka | 973 | 9,509 | 16,299 | 9,184 |
| Kokoro | 13,855 | 59,096 | 353,118 | 239 |

The scalar-segmented prior-2 table on Kokoro has 21,440 outer-row
replacements and 66,383 inner-prefix evictions. Thus its gain comes with a
different state-sharing tradeoff, not a free extra model. The largest
reported fixed state plus source capacity is 371,534,160 B, under the
512 MiB design cap. It includes the scorer's vector capacities and retained
source, but excludes allocator bookkeeping and should not be called peak RSS.
The full JSON retains every expert, source quarter, table capacity,
occupancy, replacement count, match count and memory report for all six.

## Reproduction and provenance

The exact command is:

```sh
python3 src6/experiments/grammar_automaton/context_mixer/word_context/run_six.py \
  /workspace/scratch/grammar_automaton/word_context/ccw_score \
  /workspace/scratch/books2026-dev/manifest.json \
  /workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json \
  src6/experiments/grammar_automaton/context_mixer/word_context/evidence/ccw1-six-prefix.json
```

The runner verifies source and control hashes and records identities per
case. The source was fixed before scoring any of these books. Tiny ASan and
UBSan cases covering arbitrary bytes, invalid UTF-8 and repeated Japanese
text passed before the six-book run; the score itself has no decoding gate
because it produces no wire.

| Artifact | SHA-256 |
| --- | --- |
| `ccw_score.cpp` | `2b70c63398661aa3c828964d27b15c58df8e76ec524ba9ec7c306f6d6e07f05f` |
| `run_six.py` | `9f8209d7cb5c1f66ae7817f4740c38beae808ac68bc2b6e4b3c825ef18d3acf4` |
| Scorer binary | `4ef6088a17c7e805ba9baff481b36b31b0e9560da4306eedd705a0591ea7c3fa` |
| Frozen integer squash table | `82e8ea89e8116a4ec34b6ad77ab39523109c64d79cde563468a083d98d3d0da7` |
| Six-book manifest | `ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d` |
| Matched bzip3 controls | `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f` |
| Complete CCW1 evidence | `6f4622cb2b07dac442c323acc703c4a151a687fbe855082afaae326463f5fb7f` |

No reserved validation or sealed final source was read for this round. The
result rules out this bounded joint-token/prefix predictor at these fixed
settings as the requested large bzip3 improvement; it does not rule out
other causal context models or phrase representations.
