# Development decisions and capture limits

These are experiments used to choose fixed policies before independent Luna
confirmation. They are not final held-out evidence. The JSON ledgers retain
actual child stdout/stderr strings and commands where captured. Early screens
did not serialize process exit statuses separately: their scripts asserted
zero status and byte-for-byte fresh decode before retaining each row. Some
early source revisions were not snapshotted. Do not replace these limitations
with reconstructed provenance or reuse concurrent development timings as a
clean speed ranking. The final Luna harness records sources, binaries, exact
commands, stdout, stderr, statuses, frame hashes, and restart checks directly.

## Ordering and segmentation

All figures below are complete frames over 1 MiB development inputs at 64 KiB
raw boundaries, with capacity 8,192. This first ordering screen predates
entropy-table packing; comparisons within each row use that same wire policy.

| Input | Creation order, greedy | Spelling order, greedy | Spelling order, 2 DP rounds | Reverse-spelling, 2 DP rounds |
| --- | ---: | ---: | ---: | ---: |
| GCIDE | 255,052 | 241,570 | 232,484 | 243,277 |
| Mixed UD prose | 321,414 | 300,265 | 279,547 | 296,544 |
| FreeDict English–French | 48,980 | 46,448 | 46,134 | 48,546 |
| OMW Japanese | 91,212 | 86,497 | 84,214 | 88,467 |

Spelling order plus price refitting consistently repaid its execution. Reverse
order and length-first order did not improve the chosen global policy. Ordering
is deterministic from delivered exact byte expansions; no language-specific
permutation or omitted sorting index is charged out of band.

Whole-word seeds were an earlier separate capacity-8,192 screen, before the
above improvements. They changed FreeDict 48,980→49,595; GCIDE 255,052→253,795;
OMW 91,212→103,784; and mixed prose 321,414→356,651. They were rejected as a
global policy. Treating every high UTF-8 byte as a word byte is not a linguistic
segmentation claim.

## Stored dictionary representation

With spelling order, two DP rounds, and compressed entropy models, direct
front-coded expansions compete with a shared grammatical DAG. Capacity is
8,192 and all model bytes count.

| 1 MiB input | DAG | Prefix-front-coded expansions | Reverse-front-coded expansions |
| --- | ---: | ---: | ---: |
| GCIDE | 223,163 | 225,742 | 223,272 |
| Mixed UD prose | 269,191 | 264,019 | 266,632 |
| FreeDict English–French | 43,591 | 50,967 | 52,276 |
| OMW Japanese | 77,438 | 98,801 | 100,817 |

The prose exception does not establish a universal better dictionary. The
frozen primary keeps the DAG representation.

## Extra event contexts

Conditioning shared event distributions on the preceding run/rank category
was tested with one, two, and four rows. Complete tables dominated the saved
payload. At capacity 16,384 on the prior fixed 8 MiB development streams:

| Input | 1 row | 2 rows | 4 rows |
| --- | ---: | ---: | ---: |
| FreeDict English–Spanish | 713,783 | 718,434 | 723,939 |
| GCIDE | 1,622,022 | 1,627,077 | 1,632,568 |
| OMW Japanese | 536,324 | 539,838 | 542,017 |

Two/four rows were rejected. Raw frequency tables also proved needlessly
expensive: compressing their delivered representation with its own charged
byte rANS model lowered table costs from tens of kilobytes to a few kilobytes.

## Productive exact-surface bindings

The binding parser considers a copy of prior decoded bytes at every byte
position, independent of root boundaries. It jointly chooses grammar roots and
bindings by dynamic programming. The candidate then BWT-codes command IDs and
codes length/distance arguments separately. At capacity 16,384:

| Prior 8 MiB input | Plain roots | Argument price 5 | Argument price 8 | Argument price 12 |
| --- | ---: | ---: | ---: | ---: |
| FreeDict English–Spanish | 713,783 | 737,374 | 720,823 | 715,010 |
| GCIDE | 1,622,022 | 1,686,762 | 1,641,115 | 1,625,757 |
| OMW Japanese | 536,324 | 540,206 | 527,431 | 520,345 |

This rejects automatic use of bindings on every input. It motivated the
separate frozen choice policy that pays both full encodes and selects the
smaller complete representation. It improves Japanese development storage
another 3% while selecting the simpler frame for FreeDict and GCIDE. It does
not claim that the same result holds on untouched inputs.

## Capacity as an actual objective

The fixed capacity search tries 0, 512, 2,048, 8,192, and 16,384 and compares
the entire delivered frame. No ratio proxy, omitted model cost, per-corpus
hand-tuned selector, or free search time enters its decision. On the 1 MiB
development inputs it selected 512 for FreeDict (40,530 B), 8,192 for GCIDE
(223,163 B) and OMW (77,438 B), and 2,048 for prose (267,217 B). The selected
frame has the normal decoder; all five encodes count in reported encode time.

## Correctness and scope

The frozen primary, capacity search, forced binding mode, and fixed binding
choice passed fresh-process tests for arbitrary bytes, multiple scripts,
periodic input, every restart, deterministic frames, all prefix truncations,
extra tails, 1,024 fixed mutations, resealed invalid directory fields, and a
sparse oversized-file rejection before allocation. This does not substitute
for an independent compiler/allocator/portability audit or full dictionary
integration. None of these experiments modifies production LEX6 compression.

## Valid Unicode scalar atoms

The isolated UTF-8 experiment validates scalar boundaries and seeds repeated
2/3/4-byte scalars before pair learning. Every seed's exact bytes are delivered;
invalid and rare spellings fall back to bytes. It compares capacities 0, 512,
2,048, and 8,192 on development data. Complete frame minima are:

| Development input | Byte grammar | Scalar-seeded grammar |
| --- | ---: | ---: |
| Russian prose, 1 MiB | 239,190 | 226,289 |
| Russian forms, 1 MiB | 234,308 | 220,601 |
| Chinese prose, 57,467 B | 26,569 | 26,689 |
| Chinese forms, 69,610 B | 29,323 | 29,323 |
| Japanese prose, 58,945 B | 22,472 | 22,472 |
| Japanese forms, 70,709 B | 24,168 | 24,168 |
| Arabic prose, 245,699 B | 56,851 | 56,851 |
| Arabic forms, 253,749 B | 56,040 | 56,041 |

Scalar atoms save 5.4–5.85% on the Russian development inputs. They do not
improve the globally best charged frame on the examined small Chinese,
Japanese, or Arabic inputs. Finnish and Turkish exploratory-training screens
are mixed or negative. These results reject universal scalar seeding and
motivate a fixed complete-frame choice between byte and scalar atoms. They do
not establish a win against bzip3 or general linguistic superiority.

Chinese/Japanese/Russian inputs are official UD development projections.
Arabic uses the complete official PADT development split (909 sentences), from
pinned commit `dfb6b4c547f1fe10f1857b39e44de3f86c47a2fe`, prepared by the
corpus agent with source/license metadata. No final/test Arabic input was read.
Finnish/Turkish use the older explicitly exploratory training projection, not
its separate confirmation portion. `unicode-screen.json` retains all rows;
the Arabic extension also records exit statuses and input/frame hashes
directly. Earlier rows retain the capture qualifications stated above.
