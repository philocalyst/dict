# SED2: sentence-boundary correction result

SED2 keeps single LF/CRLF hardwraps inside a clause and cuts at punctuation,
exact blank lines, the original 1024-byte limit and original 64 KiB pages.
This is the one fixed segmentation-only correction to SED1. It increases
clause lengths and improves the free-information residual proxy on five
books. **The fully paid transform still loses whole-file bzip3 on all six**,
so the fixed promotion gate fails and no new native wire was built.

| UTF-8 DEV book | Source B | Whole bzip3 B | Free-donor residual frame B | Paid route frame B | Paid literal frame B | Paid diagnostic B | Exact original pages |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pride and Prejudice (en) | 705,012 | 161,119 | 150,165 | 23,732 | 160,880 | 184,676 | 11 |
| War and Peace (en), prefix | 1,048,576 | 247,364 | 223,339 | 42,533 | 245,018 | 287,615 | 16 |
| Don Quijote (es), prefix | 1,048,576 | 252,940 | 220,574 | 27,357 | 251,706 | 279,127 | 16 |
| Madame Bovary (fr) | 716,472 | 179,597 | 149,634 | 20,360 | 179,314 | 199,738 | 11 |
| Die Verwandlung (de) | 126,200 | 35,251 | 29,351 | 3,619 | 34,980 | 38,663 | 2 |
| Kokoro (ja) | 486,098 | 97,505 | 110,369 | 27,761 | 95,353 | 123,178 | 8 |

The paid diagnostic size is the two complete bzip3 backend frames plus its
64-byte envelope. It is a byte-exact routed transform, but still uses bzip3
for both entropy streams and has no fast independent selected-page decoder.
The free-donor residual is **not** a lower bound on every possible sentence
codec: it ignores donor and edit descriptions, fixes an eight-donor search,
and changes the byte order and probability context of the residual before
bzip3 compression. It is an unattainable, segmentation-sensitive proxy.
Its best improvement over whole bzip3 is 16.7% on Bovary/Kafka, far from
the user's 35% stretch target; it is 13.2% larger on Kokoro.

## Sentence and donor lengths, paid coverage

| Book | SED1 clauses | SED2 clauses | SED2 clause p50/p90 B | Paid donor p50/p90 B | Free LCS bytes | Paid KEEP bytes | Paid KEEP segments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Austen | 20,197 | 9,345 | 50 / 185 | 174 / 336 | 433,839 | 32,063 | 3,109 |
| War | 34,549 | 17,552 | 29 / 162 | 145 / 296 | 641,329 | 75,843 | 6,308 |
| Quijote | 22,036 | 6,792 | 115 / 369 | 310 / 636 | 644,183 | 49,705 | 4,274 |
| Bovary | 23,512 | 11,335 | 27 / 182 | 201 / 365 | 453,005 | 21,281 | 2,092 |
| Kafka | 2,674 | 855 | 119 / 319 | 274 / 521 | 75,404 | 5,642 | 519 |
| Kokoro | 6,240 | 4,900 | 90 / 173 | 102 / 189 | 292,108 | 92,422 | 6,716 |

The evidence also stores min/max and fixed size bins for each clause, all
searched donors and selected paid donors. Hardwrap correction roughly halves
the Austen/War/Bovary unit counts and divides Quijote/Kafka by about three.
Yet paid KEEP coverage remains only 3.0–19.0% of source bytes. The
improvement in the free proxy is mostly short scattered character matches;
the fixed eight-byte minimum and fully encoded positions reject most of
those matches. The paid literal frames remain close to whole-file bzip3
size, while route frames add 3.6–42.5 kB. SED2's paid size improves SED1
by 40–8,740 B depending on book, without reversing any result.

## Exactness and provenance

The frozen command was:

```sh
python3 src6/experiments/grammar_automaton/clause_alignment/segmentation_v2/run_six.py \
  /workspace/scratch/books2026-dev/manifest.json \
  /workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json \
  /workspace/scratch/bzip3 \
  /workspace/scratch/grammar_automaton/clause_alignment/sed2-dev6 \
  src6/experiments/grammar_automaton/clause_alignment/segmentation_v2/evidence/sed2-dev6.json
```

The modules compiled before first book scoring. Tiny byte-exact cases
covered single LF, CRLF, all four blank-line patterns, Japanese punctuation,
a length-cut boundary and arbitrary source bytes. On all six books the
route/literal transform reconstructed the original source, and fresh
bzip3 decodes of all three diagnostic streams matched their uncompressed
bytes. Every original 64 KiB page matched. These tests do not supply an
independent native entropy decoder; no new native wire was promoted.

| Fixed artifact | SHA-256 |
| --- | --- |
| `PROTOCOL.md` | `713a874848ddc216c5b6240fe3d36b2c42dddd986366cd2c57deadb1941f1bb3` |
| `sed2_screen.py` | `ec2f3259f373b60ec6bfbf607ae470f8a34da00c451d6186622ec3d4d02dd3c8` |
| `run_six.py` | `244ec2770d333be965bf797bf694cdc2bcff78438db21f9408c653eaba591869` |
| Six-book development manifest | `ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d` |
| Matched bzip3 controls | `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f` |
| Pinned bzip3 executable | `96d0e3d36f531bf4e255b43c9617ac8e6a4b2d23289647c147946761f2d6ce44` |
| Full six-case evidence | `5fd28c270934fe6f4e4aead9140dc9c8bfa67398bd71599805e43cd169ef4451` |

No reserved validation or sealed final corpus was used. This result closes
the fixed clause-edit alignment family tested here; it does not rule out
sentence models with different search, grammar or probability mechanisms.
