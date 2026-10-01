# Results (2026-09-20, format v4)

Real round trips, every byte charged, one setting (`plan.fit` picks the
class count itself). Machine: Apple Silicon laptop that was **busy with other
work** during the runs; decode speed is the best of 7, single thread, and
is conservative. bzip3 columns are `../baselines.tsv` (same machine, idle).
Raw output: `results_v4.tsv`.

## Word corpora, old byte-level parses (`dumps/m_*`), our blocks independent

| input, block | bzip3 same block | bzip3 whole file | v3 | **v4** | v4 vs v3 | vs bzip3 block | vs bzip3 whole | decode MB/s (×8 threads) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict 8M, 16K | 1,189,002 | 554,003 | 592,986 | **573,985** | −3.2 % | −51.7 % | +3.6 % | 539 (1100) |
| gcide 8M, 16K | 2,362,319 | 1,243,221 | 1,324,180 | **1,286,217** | −2.9 % | −45.6 % | +3.5 % | 224 (469) |
| omw 8M, 16K | 1,124,142 | 332,331 | 383,822 | **340,823** | −11.2 % | −69.7 % | +2.6 % | 687 (989) |
| freedict 8M, 64K | 899,408 | 554,003 | 583,010 | **564,416** | −3.2 % | −37.2 % | +1.9 % | 587 (1314) |
| gcide 8M, 64K | 1,905,560 | 1,243,221 | 1,324,351 | **1,276,838** | −3.6 % | −33.0 % | +2.7 % | 242 (512) |
| omw 8M, 64K | 674,384 | 332,331 | 380,070 | **330,148** | −13.1 % | −51.0 % | −0.7 % | 787 (1199) |
| freedict 1M, 64K | 115,160 | 84,072 | 91,934 | **88,811** | −3.4 % | −22.9 % | +5.6 % | 771 |
| gcide 1M, 64K | 235,103 | 174,685 | 196,758 | **192,005** | −2.4 % | −18.3 % | +9.9 % | 289 |
| omw 1M, 64K | 95,276 | 57,862 | 70,241 | **63,575** | −9.5 % | −33.3 % | +9.9 % | 838 |

bzip3 decodes these at 25–65 MB/s. Joining our 64 KiB blocks into one
changes our size by less than 1 % (`lab --merge 128`: 562,084 / 1,281,773 /
326,782): the format does not need big blocks, bzip3 does.

## A corpus that is nothing but words

`/usr/share/dict/words` (web2, 2,493,885 bytes, 235,976 sorted words), end
to end through `bz4 c` (learner included):

| bz4 | xz −9e | brotli −q11 | zstd −19 | bzip3 | bzip2 −9 |
|---:|---:|---:|---:|---:|---:|
| **536,789** | 637,488 | 649,943 | 661,927 | 806,792 | 857,578 |

−16 % against the best LZ, −33 % against bzip3. Every word is a definition
here (`[previous word, CUT k, suffix morphs]`), so decoding runs entirely in
the serial definition loop: ~85 MB/s on the busy machine, the slowest case
we have and still 3× bzip3.

## End to end (`bz4 c`, the in-tree learner, 64 KiB blocks, decoded on 8 threads and compared)

| input | bzip3 whole file | old parse + v4 | Lane W2's learner | **`bz4 c`** | compress |
|---|---:|---:|---:|---:|---:|
| freedict 8M | 554,003 | 564,416 | 579,677 | 579,202 | 8.6 s |
| gcide 8M | 1,243,221 | 1,276,838 | 1,333,115 | 1,324,034 | 31.8 s |
| omw 8M | 332,331 | 330,148 | 367,391 | 374,217 | 9.0 s |
| web2 2.5M | 806,792 | — | 626,490 | **539,369** | 6.7 s |
| freedict 1M | 84,072 | 88,811 | — | 92,964 | 0.9 s |
| freedict 64 KiB | 7,239 | — | — | 8,254 | — |
| freedict 4 KiB | 800 | — | — | 995 | — |

`compress` learns twice (once-seen words spelled in place, or defined) and
fits class counts by trial, which is why it is slow. Both word-aligned
learners merge by count thresholds; the old byte-level parses were chosen by
an MDL criterion and are still 3–13 % better on the dictionaries. Lane W2
(`lab/LANE_W2.md`) found that pruning at real prices does not close that gap
and that the greedy pair-merging itself is what has to go.

## Other data (secondary)

| input | bzip3 64K | bzip3 whole | v3 | **v4** |
|---|---:|---:|---:|---:|
| json 8M | 1,028,983 | 884,918 | 956,389 | 961,555 |
| Mach-O 8M | 3,259,348 | 2,493,160 | 2,759,944 | **2,597,654** |
| Zig source 8M | 1,454,997 | 1,037,980 | 1,212,378 | **1,093,818** |

## Small standalone inputs (first N bytes of the untouched files; `w_parse` + `lab`)

| input | xz −9e | bzip2 −9 | zstd −19 | bzip3 | **bz4** |
|---|---:|---:|---:|---:|---:|
| freedict 4 KiB | 772 | 802 | 704 | 800 | 1,013 |
| freedict 64 KiB | 7,892 | 7,279 | 7,920 | 7,239 | 8,570 |
| freedict 256 KiB | 28,176 | 24,651 | 28,820 | 24,439 | 27,725 |
| gcide 4 KiB | 1,596 | 1,558 | 1,495 | 1,544 | 2,003 |
| gcide 64 KiB | 15,916 | 14,539 | 16,012 | 14,366 | 17,930 |
| gcide 256 KiB | 58,496 | 51,718 | 59,383 | 49,869 | 59,205 |
| omw 4 KiB | 1,072 | 1,077 | 1,046 | 1,189 | 1,250 |
| omw 64 KiB | 4,852 | 5,186 | 4,831 | 4,604 | 5,937 |
| omw 256 KiB | 16,616 | 17,746 | 17,079 | 14,859 | 19,011 |

Still behind everywhere below 1 MiB: 22 % of a 4 KiB frame is ARITY / NAME
/ DEF overhead of a grammar with far too many entries, and letters are
mostly spelled as raw bytes. This is a learner problem (Lane W2).

## Where the remaining bits are (freedict 8M, real prices, by XML element)

| part | bytes in | bzip3 alone on that part | bz4 v3 (in context) |
|---|---:|---:|---:|
| definitions (English prose) | 1.32 MB | 308 KB | 304 KB |
| translations | 222 KB | 87 KB | 72 KB |
| pronunciations | 253 KB | 65 KB | 56 KB |
| headwords | 130 KB | 55 KB | 43 KB |
| tag skeleton | 6.44 MB | **30 KB** | **93 KB** |

v4's past buckets took back part of the skeleton; the rest needs tokens that
are whole words (the old parses glue `o</ns0:quote>…`), which is what the
word-aligned learner is for. In gcide, 41 KB (3.2 %) is the space-or-newline
choice of hard-wrapped lines, which a greedy-wrap rule predicts 93 % of the
time; nobody's model, ours or bzip3's, knows the column.
