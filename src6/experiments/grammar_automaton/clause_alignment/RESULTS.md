# SED1: six-book clause alignment screen

The fixed [protocol](PROTOCOL.md) was screened once on all six frozen
UTF-8 development prefixes. Its free donor/position oracle is an
unattainable optimistic check: only Kafka beats whole-file bzip3, by 2.9%.
The exact COPY/INSERT transform, with every donor, segment, length, page
directory and literal byte charged through two complete bzip3 backend
frames and a 64-byte envelope, is larger on all six books. SED1 therefore
fails the preregistered three-book 90% promotion gate and is closed without
a native entropy wire. It is far from a complete frame at 65% of bzip3.

| Book | Source B | Whole bzip3 B | Free-position residual bzip3 B | Paid route frame B | Paid literal frame B | Paid two-frame diagnostic B | Exact original pages |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pride and Prejudice (en) | 705,012 | 161,119 | 177,325 | 27,739 | 160,956 | 188,759 | 11 |
| War and Peace (en), prefix | 1,048,576 | 247,364 | 259,040 | 48,942 | 244,630 | 293,636 | 16 |
| Don Quijote (es), prefix | 1,048,576 | 252,940 | 264,727 | 36,364 | 251,439 | 287,867 | 16 |
| Madame Bovary (fr) | 716,472 | 179,597 | 184,652 | 25,111 | 179,334 | 204,509 | 11 |
| Die Verwandlung (de) | 126,200 | 35,251 | 34,213 | 4,820 | 34,910 | 39,794 | 2 |
| Kokoro (ja) | 486,098 | 97,505 | 111,264 | 27,789 | 95,365 | 123,218 | 8 |

The 64-byte diagnostic envelope holds source length, both frame lengths and
the source digest. It is added to the two backend frame lengths in the table.
The transform independently reconstructs every original 64 KiB page and
the full source from its route/literal streams; all three backend stream
frames were freshly decoded and verified. This remains a bzip3-backed
diagnostic, not an independent alternative codec or a fast selected-page
reader.

## Why the apparent exact matches do not help

| Book | Clauses | Mean B/clause | Oracle LCS bytes | Paid KEEP bytes | Paid KEEP segments | Paid donor clauses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Austen | 20,197 | 34.9 | 366,256 | 31,895 | 3,049 | 2,982 |
| War | 34,549 | 30.4 | 553,212 | 78,510 | 6,502 | 6,290 |
| Quijote | 22,036 | 47.6 | 526,937 | 57,874 | 5,165 | 4,977 |
| Bovary | 23,512 | 30.5 | 367,824 | 22,178 | 2,159 | 2,135 |
| Kafka | 2,674 | 47.2 | 63,156 | 6,241 | 572 | 558 |
| Kokoro | 6,240 | 77.9 | 289,242 | 93,334 | 6,738 | 4,624 |

The free oracle finds approximately half the raw bytes in prior clauses,
but it needs hundreds of thousands of separate LCS runs. Those bytes are
mostly predictable character patterns already handled by bzip3: after
removing them **for free**, compressing the changed residual still fails
whole-file bzip3 on five books. The exact paid route keeps only 3–19% of
source bytes because short copied runs cost more than their literal bytes.
Route frames add 4,820–48,942 B, and the paid literals still take nearly a
complete whole-file bzip3 frame. No unpriced copy operation is credited.

The fixed clause split also cuts after every LF. Project Gutenberg's hard
line wraps therefore create many 30–50-byte units in the European books.
This is a real limitation of SED1's preregistered policy: it tests
line/clause alignment, rather than full semantic sentence alignment.
Kokoro's longer clauses are still a paid loss. A later paragraph/sentence
segmentation would be a separate versioned hypothesis, not a reinterpretation
of these results.

## Provenance and scope

The exact one-shot command was:

```sh
python3 src6/experiments/grammar_automaton/clause_alignment/run_six.py \
  /workspace/scratch/books2026-dev/manifest.json \
  /workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json \
  /workspace/scratch/bzip3 \
  /workspace/scratch/grammar_automaton/clause_alignment/ced1-dev6 \
  src6/experiments/grammar_automaton/clause_alignment/evidence/sed1-dev6.json
```

The evidence records every source/control/frame SHA-256, exact full/page
inverse, raw and compressed stream lengths, candidate counts and work
cells. Before the first book, 200 small random LCS cases matched a dynamic
programming oracle; three empty/arbitrary-byte/repeated-content sources
round-tripped, and both Python modules compiled. That validates the fixed
transform logic, not an independent new native decoder.

| Frozen item | SHA-256 |
| --- | --- |
| `PROTOCOL.md` | `94c47b1d36a21e3815feaee3952a8f431ad91b3c9415d8bf10ca2504dabca6c4` |
| `sed_screen.py` | `c92abb3c2b122d7a2f7a903403bc8a46d7f835be434b9b3c666584fe263699dd` |
| `run_six.py` | `16e70addd054898ec3c8fe1a22948a062432943e8bafe840c4139d911e7f0818` |
| Pinned bzip3 executable | `96d0e3d36f531bf4e255b43c9617ac8e6a4b2d23289647c147946761f2d6ce44` |
| Six-book manifest | `ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d` |
| Matched control manifest | `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f` |
| Complete six-case evidence | `20d44f2d1c2a1e10adda7a5e8c873d10f3f8b64d75a98b42201bf5a48e64212f` |

No reserved validation or sealed final source was read. SED1 only rules out
this fixed causal clause search and edit representation on the six stated
development inputs. It does not bound all sentence, grammar or neural models.
