# Retained `bzip4` experiment results

Status: bounded experimental evidence, not a production benchmark or a claim
of superiority. All successful rows roundtripped exactly.

## Round two: BWT/MTF/zero-run/rANS

The second candidate uses independently invertible cyclic-BWT blocks, MTF,
canonical zero runs, and static byte rANS. A 512-byte model trained only from
the fixed first 1 MiB is embedded and charged once. Raw fallback, 40-byte
header, and every 16-byte restart record are included. The same next 8 MiB is
held out. There are no pretrained weights or corpus-specific schemas.

The initial matrix's manual transcription is in
[`round2-transcription.tsv`](round2-transcription.tsv); hashes are in
[`round2-hashes.tsv`](round2-hashes.tsv); exact command, order, environment,
and the one shell-wrapper incident are in
[`round2-protocol.txt`](round2-protocol.txt). All 18 intended runner processes
printed `roundtrip ok`. Samples 2–18 returned zero. Sample 1's runner status
was not captured because the wrapper failed after stdout on a reserved zsh
variable; it was not rerun and is explicitly `unavailable`.

Important provenance limitation: the initial wrapper did not directly save
original stdout/stderr artifacts. The TSV was manually transcribed from the
tool-visible chunks and has not been byte-compared to an original capture. It
is therefore provisional transcription, not raw or lossless evidence. An
independently captured replication is required before treating these clocks
as final benchmark evidence.

### Complete bytes

| corpus | boundary | BWT candidate | matched bzip3 | size delta | raw framed |
| --- | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 16 KiB | 1,195,903 | 1,189,002 | +0.580% | 8,397,864 |
| FreeDict | 64 KiB | 940,246 | 899,408 | +4.541% | 8,391,336 |
| GCIDE | 16 KiB | 2,490,928 | 2,362,319 | +5.444% | 8,397,864 |
| GCIDE | 64 KiB | 2,087,612 | 1,905,560 | +9.554% | 8,391,336 |
| OMW Japanese | 16 KiB | 1,194,897 | 1,124,142 | +6.294% | 8,397,864 |
| OMW Japanese | 64 KiB | 825,074 | 674,384 | +22.345% | 8,391,336 |

Totals decompose as 40-byte header + 512-byte model + 16 bytes per block +
payload. The directory is 8,192 B for 16 KiB blocks and 2,048 B for 64 KiB
blocks. Thus the candidate narrowly approaches matched bzip3 only for
FreeDict/16 KiB; bzip3 remains smaller in every row.

### Median timing, three fixed serial samples

Times are milliseconds. `ret bz3 dec` is the comparison-only matched-boundary
bzip3 lane with encoder/decoder state and work buffer retained across blocks.
Model training includes BWT/MTF/token preparation over the 1 MiB training
partition. OS caches were not reset, so these are bounded provisional results.

| corpus | boundary | train | BWT encode | BWT decode | retained bzip3 encode | retained bzip3 decode | decode speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 16 KiB | 65.195 | 543.887 | 98.354 | 359.213 | 204.133 | 2.076x |
| FreeDict | 64 KiB | 91.710 | 760.792 | 112.092 | 348.391 | 169.733 | 1.514x |
| GCIDE | 16 KiB | 65.449 | 570.287 | 133.072 | 695.811 | 346.468 | 2.604x |
| GCIDE | 64 KiB | 93.844 | 795.546 | 149.555 | 734.045 | 310.980 | 2.079x |
| OMW Japanese | 16 KiB | 62.890 | 535.179 | 99.201 | 518.230 | 241.934 | 2.439x |
| OMW Japanese | 64 KiB | 90.194 | 746.925 | 111.625 | 374.217 | 172.158 | 1.542x |

The candidate decoder is materially faster in all six comparisons, while its
encoder ranges from 18% faster (GCIDE/16 KiB) to 2.18x slower
(FreeDict/64 KiB). Combined with the size losses, this is a measured Pareto
tradeoff—not a bzip3 replacement and not an end-to-end query result.

Cold independently decoded-block accounting is 143,110 B at 16 KiB and
536,326 B at 64 KiB, including the 512-byte resident model, output,
worst-case tokens, in-place MTF/BWT-last buffer, LF map, and fixed prepared
tables. Whole-8-MiB decode accounting is 8,514,822 B and 8,858,886 B.
These are conservative logical byte charges, not physical RSS. The dominant
construction temporary bound on this 64-bit host is 25 times block size,
excluding the growing output frame and allocator capacity.

### Correctness and acceptance

The pure experiment build ran 26 test executions in each of Debug,
ReleaseSafe, and ReleaseFast (17 distinct tests because the second suite
imports the nine first-round tests). This includes deterministic endian-stable
wire, exact all/block roundtrips, raw fallback, model/metadata/length/index/
tail/budget rejection, noncanonical and overflowing ULEB aliases, nonuniform
rANS differential decoding, strict rANS termination, and forced-BWT exhaustive
allocation failures. A separately authored public-API audit adds 12 patterned
inputs, three boundaries, every independent block, and 64 mutations per
frame. Compile-only full-path probes pass for wasm32-freestanding and
x86_64-linux without libc; these are portability compile checks, not runtime
proof on those targets.

Acceptance decision: retain the BWT candidate as experimental evidence. It is
a substantially better decode/storage point than round one's shared-LZ
candidate, but bzip3 is smaller for every measured boundary/corpus, encode and
training costs remain material, and no complete LEX6 archive/query benefit has
been measured. Production adoption is rejected pending separate review.

## Round one: fixed protocol

- Host: Darwin 24.6.0, arm64 T6030; Zig 0.16.0; `ReleaseFast` runner.
- Corpus inputs: the retained `projection.tsv` files in
  `src6/bench/real-world/evidence/corpora`; the runner decodes and concatenates
  only the third normalized-content hex field.
- Partition: first 1,048,576 decoded bytes train the dictionary; the next
  8,388,608 bytes are held out and compressed. No held-out byte can enter the
  dictionary.
- Candidate boundary: independent 16,384-byte microblocks.
- Candidate main: 32,768-byte dictionary, online arithmetic predictor enabled.
- Storage ablations: dictionary 0/8,192/32,768 bytes; one 32,768-byte run with
  the predictor disabled. Clocks were disabled for dictionary-size ablations.
- Controls: bzip3 at the same 16 KiB boundary, bzip3 at the current 64 KiB page
  boundary, and a comparison-only 16 KiB bzip3 lane retaining one encoder
  state, one decoder state, and one buffer. Complete control totals add the
  same 32-byte frame and 16-byte record per block.
- Main timing: three serial, fixed-order process runs per corpus under the
  explicit quiet gate. OS cache state was not reset; values are provisional
  and descriptive. No retry was selected for appearance.
- Source commit at measurement: `a3eae58f61196715f13c92ab50baa05812f10ec3`
  plus the uncommitted isolated experiment directory.

The complete input byte counts decoded by the owned extractor were
43,700,255 (FreeDict), 58,808,436 (GCIDE), and 112,147,272 (OMW Japanese),
matching the retained report's normalized-content totals (GCIDE's report uses
58,808,436 B). Source projection sizes were 90,123,314, 123,479,075, and
229,392,768 bytes respectively.

## Complete storage results

Every total includes 32-byte frame header, 8,192-byte block directory for 512
microblocks, payload, and the dictionary/model bytes shown. The online model
has zero stored bytes; its mode bytes are in payload. Raw framed size is
8,396,832 B.

| corpus | lane | dictionary | predictor | complete bytes | input ratio |
| --- | --- | ---: | --- | ---: | ---: |
| FreeDict | candidate | 0 | on | 1,915,589 | 22.836% |
| FreeDict | candidate | 8,192 | on | **1,716,235** | **20.459%** |
| FreeDict | candidate main | 32,768 | on | 1,783,020 | 21.255% |
| FreeDict | plain shared LZ | 32,768 | off | 2,000,000 | 23.842% |
| FreeDict | bzip3 matched 16 KiB | 0 | n/a | 1,189,002 | 14.174% |
| FreeDict | bzip3 current 64 KiB | 0 | n/a | 899,408 | 10.722% |
| GCIDE | candidate | 0 | on | 3,655,187 | 43.573% |
| GCIDE | candidate | 8,192 | on | 3,491,766 | 41.625% |
| GCIDE | candidate main | 32,768 | on | **3,472,196** | **41.392%** |
| GCIDE | plain shared LZ | 32,768 | off | 3,719,052 | 44.335% |
| GCIDE | bzip3 matched 16 KiB | 0 | n/a | 2,362,319 | 28.161% |
| GCIDE | bzip3 current 64 KiB | 0 | n/a | 1,905,560 | 22.716% |
| OMW Japanese | candidate | 0 | on | 1,662,538 | 19.819% |
| OMW Japanese | candidate | 8,192 | on | **1,556,273** | **18.552%** |
| OMW Japanese | candidate main | 32,768 | on | 1,592,244 | 18.981% |
| OMW Japanese | plain shared LZ | 32,768 | off | 1,740,642 | 20.750% |
| OMW Japanese | bzip3 matched 16 KiB | 0 | n/a | 1,124,142 | 13.401% |
| OMW Japanese | bzip3 current 64 KiB | 0 | n/a | 674,384 | 8.039% |

The arithmetic iteration is real but insufficient: against the same 32 KiB
dictionary/plain-LZ frame it saves 216,980 B (FreeDict), 246,856 B (GCIDE),
and 148,398 B (OMW), or 6.6–10.8% of that baseline. Yet the best dictionary
size is not consistently 32 KiB once dictionary bytes are charged. The 8 KiB
dictionary wins on FreeDict and OMW; 32 KiB wins GCIDE by only 19,570 B.

Most importantly, every candidate loses storage decisively to the matched
16 KiB bzip3 control, by 527,233 B on the best FreeDict lane, 1,109,447 B on
GCIDE, and 432,131 B on OMW. The 64 KiB control is smaller again, but has a
four-times-larger access boundary.

## All accepted main timing samples (nanoseconds)

`prod16` is the production wrapper and creates/frees native bzip3 state per
block. `ret16` retains state/buffer across blocks. `bz3-64` is the current-page
control. Retained setup is listed separately and is one-time per process.

| corpus | sample | train | candidate enc | candidate dec | prod16 enc | prod16 dec | ret setup | ret16 enc | ret16 dec | bz3-64 enc | bz3-64 dec |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 1 | 2,533,750 | 309,885,666 | 511,648,417 | 410,464,291 | 230,608,917 | 55,708 | 395,805,666 | 217,743,250 | 389,357,542 | 181,575,917 |
| FreeDict | 2 | 2,430,042 | 296,381,917 | 498,405,084 | 398,614,625 | 225,071,583 | 68,167 | 392,229,416 | 215,624,875 | 389,443,500 | 180,644,209 |
| FreeDict | 3 | 2,375,000 | 304,411,708 | 501,688,167 | 403,380,959 | 225,159,750 | 108,167 | 398,356,208 | 216,999,416 | 387,604,333 | 181,289,834 |
| GCIDE | 1 | 3,138,875 | 545,563,375 | 929,983,000 | 754,776,709 | 372,928,875 | 55,209 | 749,525,334 | 364,306,625 | 793,038,292 | 331,724,167 |
| GCIDE | 2 | 3,034,875 | 598,150,917 | 929,313,417 | 765,028,583 | 384,417,750 | 83,333 | 754,921,542 | 365,337,250 | 806,357,000 | 332,689,667 |
| GCIDE | 3 | 3,136,916 | 549,530,583 | 939,447,833 | 769,046,875 | 385,594,542 | 115,209 | 762,203,542 | 367,702,958 | 806,308,542 | 345,514,000 |
| OMW Japanese | 1 | 3,126,417 | 269,238,875 | 447,502,209 | 572,841,708 | 272,085,083 | 83,958 | 570,408,166 | 254,599,208 | 411,413,875 | 183,599,875 |
| OMW Japanese | 2 | 3,003,792 | 268,306,583 | 445,709,167 | 579,511,292 | 263,744,791 | 85,125 | 567,281,500 | 257,548,334 | 408,379,375 | 184,397,666 |
| OMW Japanese | 3 | 3,000,834 | 269,445,709 | 453,723,083 | 579,340,833 | 271,114,250 | 135,542 | 569,331,416 | 261,199,417 | 420,282,292 | 193,523,792 |

### Medians

| corpus | candidate enc | candidate dec | prod16 enc | prod16 dec | ret16 enc | ret16 dec | bz3-64 enc | bz3-64 dec |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 304.412 ms | 501.688 ms | 403.381 ms | 225.160 ms | 395.806 ms | 216.999 ms | 389.358 ms | 181.290 ms |
| GCIDE | 549.531 ms | 929.983 ms | 765.029 ms | 384.418 ms | 754.922 ms | 365.337 ms | 806.309 ms | 332.690 ms |
| OMW Japanese | 269.239 ms | 447.502 ms | 579.341 ms | 271.114 ms | 569.332 ms | 257.548 ms | 411.414 ms | 184.398 ms |

The candidate encoder is faster in this bounded runner. Its decoder is
1.6–2.6x slower than the retained-state matched bzip3 decoder because the
strict arithmetic path decodes and canonically re-encodes the token stream.
The production-vs-retained bzip3 difference is modest relative to that loss,
so per-block state setup does not explain the candidate's slow decode.

## Access and memory accounting

For the first 16 KiB block in the main 32 KiB-dictionary lane:

| corpus | encoded block | warm bytes/raw | cold dictionary+block/raw | conservative random-access logical byte charge |
| --- | ---: | ---: | ---: | ---: |
| FreeDict | 3,211 | 0.195x | 2.195x | 80,263 |
| GCIDE | 5,580 | 0.340x | 2.340x | 83,854 |
| OMW Japanese | 2,158 | 0.131x | 2.131x | 80,774 |

The conservative candidate charge includes resident dictionary, 16 KiB
output, worst-case LZ-token bytes, the largest selected encoded block for
canonical validation, and 8,192 bytes of fixed predictor counts. It is an
accounted byte bound, not proof of physical peak RSS or allocator retained
capacity. Production bzip3's corresponding explicit
admission accounting is 2,603,094 B (native state + work bound + conservative
1 MiB libsais allowance).

Cold amplification above assumes a cold reader must fetch the entire
dictionary. Once resident, only the encoded microblock is required. The frame
directory itself is 8,192 B for the whole 8 MiB lane and can be separately
resident; it is included in complete storage totals.

## Rejected timing observations retained

After the accepted matrix, three predictor-disabled timing commands were
mistakenly launched concurrently. Their storage totals are deterministic and
already reported above, but their clocks are rejected because the processes
contended with one another. For completeness, the rejected candidate
encode/decode observations were:

| corpus | rejected encode | rejected decode |
| --- | ---: | ---: |
| FreeDict | 137,406,458 ns | 45,133,334 ns |
| GCIDE | 162,348,958 ns | 73,551,417 ns |
| OMW Japanese | 86,049,042 ns | 67,131,042 ns |

They are not used in any performance conclusion and were not rerun.

## Decision

Keep the candidate isolated. The shared reference proves that a compression
horizon can be separated from a 16 KiB decode horizon, and the small online
predictor improves the plain token stream, but this implementation is not on
the storage/decode Pareto frontier. It loses compression to bzip3 at the same
random-access boundary and loses decode time despite using much less admitted
scratch. There is no basis for production adoption or for the name `bzip4` to
imply succession.

The stronger BWT/self-index direction in the parent README remains a future
cost-estimation exercise. These losses argue against adding more ad-hoc LZ
complexity before measuring BWT run counts plus rank/sample overhead.
