# AH1 nonstationary history model: fixed DEV result

AH1's six-book, source-only Q15 ideal score loses the matched complete
whole-file bzip3 frame on **every** development book. The word/scalar
features help the same small-memory state model consistently, but its best
score is still 1.1–14.0% above bzip3 and is worse than frozen CCM1 on five
books. The preregistered requirement of about 10% headroom **below** bzip3
on every book fails. No range-coded wire or compressed-size claim follows.

| UTF-8 DEV book | Source B | bzip3 complete frame B | AH1 byte-only ideal B | AH1 word/scalar ideal B | Word/scalar above bzip3 | Word/scalar gain over byte-only B |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pride and Prejudice (en) | 705,012 | 161,119 | 184,562.60 | 180,080.85 | +11.77% | 4,481.76 |
| War and Peace (en), prefix | 1,048,576 | 247,364 | 283,704.99 | 277,339.09 | +12.12% | 6,365.90 |
| Don Quijote (es), prefix | 1,048,576 | 252,940 | 288,363.83 | 282,859.39 | +11.83% | 5,504.44 |
| Madame Bovary (fr) | 716,472 | 179,597 | 208,887.60 | 204,710.51 | +13.98% | 4,177.10 |
| Die Verwandlung (de) | 126,200 | 35,251 | 36,336.31 | 35,637.93 | +1.10% | 698.38 |
| Kokoro (ja) | 486,098 | 97,505 | 107,111.02 | 106,491.45 | +9.22% | 619.57 |

The byte-only and word/scalar rows share the same history map, source-trained
state, memory and replacement pressure. Their difference measures the
word/scalar predictions' **output contribution**, not the benefit of
removing that state. The complete JSON preserves all four source-quarter
losses for both variants and 11 individual experts. The ideal calculation
uses floating `log2` only after each integer probability has been fixed;
floating arithmetic never feeds a later prediction. Ideal bytes omit range
coding, header, integrity, model reset/snapshot and index costs. Thus even
the optimistic number is already above bzip3.

## Resource and failure attribution

The exact model-state formula, including `sizeof(Model)`, all vector
capacities and a future 1 MiB decoder history ring, is **15,822,624 B**,
below the fixed 16 MiB cap. The 262,144 tagged bit-history rows occupy
12 MiB. They fill on all but Kafka, then incur heavy replacement:

| Book | Occupied rows | Row replacements | Row updates | Replacement share | Exact-match eligible B | Match continuation B |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Austen | 262,144 | 4,776,903 | 45,825,780 | 10.42% | 338,472 | 208,910 |
| War | 262,144 | 7,445,400 | 68,157,440 | 10.92% | 479,707 | 299,624 |
| Quijote | 262,144 | 7,376,414 | 68,157,440 | 10.82% | 467,642 | 276,877 |
| Bovary | 262,144 | 5,528,097 | 46,570,680 | 11.87% | 296,291 | 172,797 |
| Kafka | 262,006 | 758,849 | 8,203,000 | 9.25% | 38,973 | 23,364 |
| Kokoro | 262,144 | 2,390,516 | 31,596,370 | 7.57% | 312,511 | 216,701 |

Every input bit queries eight shared context families and a separate run
lookup, followed by causal updates;
`row_updates = 8 × source_bits + source_bytes` on all six. The preregistered
protocol's eight-context work description omits that extra run lookup.
This clarifies the measured fixed work; no source or prediction changed.
The 7-slot packed state does save memory, yet sharing 12 MiB among six byte
orders, joint word, and prior-scalar contexts causes 7.6–11.9% of row
updates to reset a row. This measured churn and the modest 16 MiB state
budget distinguish AH1 from a full PAQ model. It is evidence for *this*
bounded design's failure, not a limit on larger adaptive models. The
source-only scorer runs continuously across each prefix; a selected-page
wire would need to pay for state resets or snapshots and was not built.

## Tests and provenance

The exact fixed screen command was:

```sh
python3 src6/experiments/grammar_automaton/adaptive_histories/run_six.py \
  /workspace/scratch/grammar_automaton/ah_score \
  /workspace/scratch/books2026-dev/manifest.json \
  /workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json \
  src6/experiments/grammar_automaton/adaptive_histories/evidence/ah1-six-prefix.json
```

Before any book outcome, `-Wall -Wextra -Werror` compiled the fixed scorer;
ASan/UBSan tiny cases with invalid UTF-8 and repeated source passed.
Independent source review found and closed three pre-score issues:
Unicode punctuation/ideographic space now preserve the preceding token,
the resource ledger includes all static arrays, and each mixer computes
both output probabilities before consuming the observed bit. A tiny
sanitized self-test also proves that incomplete initial eight-byte match
histories cannot alias a complete zero-byte history. No source policy was
altered after the six-book screen.

| Frozen artifact | SHA-256 |
| --- | --- |
| [Protocol](PROTOCOL.md) | `4568fbb36f4b34c38d91083eebc3bed98609d5fd3fae5cc7df95175368a7e0d8` |
| `ah_score.cpp` | `8f14e5dd914bdba6ef38ba2381c0a114bbb5bb517e795b3192bf9df3de1c59b9` |
| `run_six.py` | `a1452f26d39b7bc969f073d7a94191a1bc3ca8a2b011c5298ad69aebab77d765` |
| Scorer binary | `f0cf06270602766e09f64efa43cf62361ee9518da72a9d568e8f234a62cebef4` |
| Integer squash table | `82e8ea89e8116a4ec34b6ad77ab39523109c64d79cde563468a083d98d3d0da7` |
| Six-book manifest | `ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d` |
| Matched bzip3 controls | `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f` |
| [Full AH1 evidence](evidence/ah1-six-prefix.json) | `83b24b3d67d240fa91025f6eff580d852ca7daf918242b3d35db1df14b8369f9` |

No reserved validation or sealed final book was used. This is a negative
source-only model test, not a decompression or archive result. This fixed
small-memory architecture fails to reproduce mature PAQ's observed advantage.
The replacement counts show capacity pressure; they do not establish that
larger tables alone would fix prediction loss.
