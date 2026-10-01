# Simplifying post-review real-world comparison

Status: `simplifying-post-review-timed-results`; correctness failures: **0**.

This is a separate targeted report. It does not overwrite or replace the full
format report at [`real-world-report-post-review.md`](real-world-report-post-review.md),
whose SHA-256 is `c704566eef94ca1e7e3d58ff150281db0d77545794d04657f473e1f90e4e09e2`. That retained report contains the complete
all-format native/sidecar storage table and the measured page-size/bzip3 horizon
analysis. This report adds only the matched production-simplification check.

## Paired scope and provenance

The run used the same retained 64 KiB raw and adaptive LEX6 artifacts, source
projections, and fixed query/row plans for FreeDict eng-spa, GNU GCIDE 0.54,
and OMW Japanese 2.0. For each lane and sample, the preserved post-review
binary ran first and the frozen-tree binary ran second. There were three
samples per side, 36 child processes total, and no retries. Fresh processes
were used without claiming cold OS cache; no cache eviction was attempted.

| item | value |
| --- | --- |
| preserved original binary | `b3287fda7127a58fe8b8f24cb0623f0b6c8875a1777f3ac892de36582680fe88` (951,768 B) |
| current binary | `35db09b6ffe5ced8e6a8dd822a17eaf646b2de80356502a107c33e80287becc0` (933,976 B) |
| paired ledger | [`simplifying-post-review-timing.json`](../runs/simplifying-post-review-timing.json), `d62b15e0a0e15c8a97bc49118ba0a508ea7a0475b6a8f73c6b87ddde600f2ea8` |
| baseline manifest | [`simplifying-post-review-baseline.json`](../runs/simplifying-post-review-baseline.json), `47096ea79382a59d32696a3e368218c7b74f11eea1b0a4029c995519fc7fb911` |
| fixed order | corpus → codec (`raw`, `adaptive`) → sample; original then current |
| operation schedule | runner internal warmup; fixed exact/prefix/render/snippet workloads; 256-operation batches; 3 prefix batches |
| verification control | `post_verify_all_ns`, after measured reads; not a cold verify measurement |

All 36 samples passed independent oracle validation. Digests, hit/key/output
counts, and cache counters matched between before and after for every lane.
The pair order is retained for auditability and is a possible cache-order
confound; the table is descriptive evidence, not a blanket speedup claim.

## Retained input artifacts

| corpus | codec | bytes | SHA-256 |
| --- | --- | ---: | --- |
| FreeDict eng-spa | raw | 48,271,065 | `755bd42c6ddf807ff4b8c21e0d085a11101dfff0bf00a6282084fa266e925104` |
| FreeDict eng-spa | adaptive | 6,406,243 | `2d1ef42083dde1ad23e37cdd4fb4b5b89c89b6d222d519fcda0c0b79eea29976` |
| GNU GCIDE 0.54 | raw | 67,821,905 | `6472b07554981d0ec099db4a4e04edce7089721aad39e8afd36a463ad60124aa` |
| GNU GCIDE 0.54 | adaptive | 16,274,792 | `a5e528964de6ba331bf33f86b13edd208db557af7959b3ac48c05dfef34c3356` |
| OMW Japanese 2.0 | raw | 119,585,081 | `2ad5b1f7017bc38f791c30ca2ae152f0dda2836e10a88b204d69dfdcbcb223ad` |
| OMW Japanese 2.0 | adaptive | 12,223,578 | `fe9774441c2d5b8e7c756194d9752920d046e622193b80a464fec1c3c3b8cb87` |

Every path and SHA-256 above was checked immediately before the paired run;
the result also retains projection and plan hashes under `inputs`.

## Latency comparison

Each cell is the three-sample median, before → after, followed by the relative
change. Positive percentages mean the current binary took longer for that
phase. Values are kept in milliseconds here; raw nanoseconds and every sample
remain in the JSON ledger.

| corpus | codec | fresh process | Archive.open / metadata | Reader.init | first exact | exact batch | prefix batch 0 | first render | first snippet | uncached render batch | uncached snippet batch | session cold render | session same-page render | session same-page snippet | session mixed-page render | session mixed-page snippet | verifyAll after reads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | raw | 612.299 ms → 608.173 ms (-0.7%) | 2.118 ms → 2.151 ms (+1.6%) | 250 ns → 167 ns (display-only) | 0.006 ms → 0.007 ms (+3.9%) | 0.601 ms → 0.592 ms (-1.5%) | 0.004 ms → 0.004 ms (+0.0%) | 0.145 ms → 0.138 ms (-4.7%) | 0.036 ms → 0.036 ms (-0.8%) | 9.319 ms → 9.714 ms (+4.2%) | 9.213 ms → 9.185 ms (-0.3%) | 0.038 ms → 0.036 ms (-4.5%) | 1.451 ms → 1.393 ms (-4.0%) | NOT COLLECTED | 9.351 ms → 9.092 ms (-2.8%) | 9.200 ms → 9.286 ms (+0.9%) | 341.101 ms → 297.799 ms (-12.7%) |
| FreeDict eng-spa | adaptive | 4128.547 ms → 3822.113 ms (-7.4%) | 2.011 ms → 2.004 ms (-0.3%) | 125 ns → 250 ns (display-only) | 0.006 ms → 0.006 ms (+1.4%) | 0.629 ms → 0.634 ms (+0.8%) | 0.004 ms → 0.004 ms (-2.8%) | 1.730 ms → 1.688 ms (-2.4%) | 1.594 ms → 1.537 ms (-3.5%) | 376.588 ms → 351.411 ms (-6.7%) | 390.632 ms → 340.766 ms (-12.8%) | 1.597 ms → 1.518 ms (-4.9%) | 1.422 ms → 1.398 ms (-1.7%) | NOT COLLECTED | 380.355 ms → 342.982 ms (-9.8%) | 381.363 ms → 348.866 ms (-8.5%) | 1598.771 ms → 1558.214 ms (-2.5%) |
| GNU GCIDE 0.54 | raw | 968.500 ms → 881.567 ms (-9.0%) | 3.962 ms → 3.978 ms (+0.4%) | 209 ns → 167 ns (display-only) | 0.007 ms → 0.006 ms (-11.7%) | 0.966 ms → 0.986 ms (+2.2%) | 0.010 ms → 0.011 ms (+5.2%) | 0.085 ms → 0.075 ms (-11.1%) | 0.037 ms → 0.036 ms (-1.6%) | 43.462 ms → 39.307 ms (-9.6%) | 40.938 ms → 37.252 ms (-9.0%) | 0.037 ms → 0.035 ms (-4.4%) | 1.282 ms → 1.123 ms (-12.5%) | NOT COLLECTED | 43.328 ms → 39.430 ms (-9.0%) | 40.231 ms → 36.840 ms (-8.4%) | 460.970 ms → 396.472 ms (-14.0%) |
| GNU GCIDE 0.54 | adaptive | 8474.648 ms → 8339.857 ms (-1.6%) | 4.031 ms → 4.028 ms (-0.1%) | 167 ns → 166 ns (display-only) | 0.007 ms → 0.008 ms (+8.4%) | 0.966 ms → 1.031 ms (+6.8%) | 0.011 ms → 0.011 ms (+3.0%) | 2.733 ms → 2.695 ms (-1.4%) | 2.797 ms → 2.792 ms (-0.2%) | 806.888 ms → 799.307 ms (-0.9%) | 811.812 ms → 812.105 ms (+0.0%) | 2.490 ms → 2.513 ms (+0.9%) | 1.253 ms → 1.166 ms (-6.9%) | NOT COLLECTED | 801.409 ms → 800.394 ms (-0.1%) | 804.215 ms → 801.175 ms (-0.4%) | 3346.514 ms → 3261.862 ms (-2.5%) |
| OMW Japanese 2.0 | raw | 1286.689 ms → 1219.867 ms (-5.2%) | 3.672 ms → 3.172 ms (-13.6%) | 208 ns → 250 ns (display-only) | 0.007 ms → 0.006 ms (-3.1%) | 0.449 ms → 0.440 ms (-1.9%) | 0.003 ms → 0.003 ms (-8.0%) | 0.103 ms → 0.099 ms (-4.0%) | 0.063 ms → 0.044 ms (-30.4%) | 14.342 ms → 14.516 ms (+1.2%) | 13.894 ms → 13.831 ms (-0.5%) | 0.046 ms → 0.046 ms (-1.4%) | 4.003 ms → 3.910 ms (-2.3%) | NOT COLLECTED | 14.187 ms → 14.774 ms (+4.1%) | 14.195 ms → 13.669 ms (-3.7%) | 740.506 ms → 662.805 ms (-10.5%) |
| OMW Japanese 2.0 | adaptive | 7301.869 ms → 7370.502 ms (+0.9%) | 3.461 ms → 3.323 ms (-4.0%) | 167 ns → 167 ns (display-only) | 0.007 ms → 0.007 ms (-3.6%) | 0.455 ms → 0.428 ms (-5.8%) | 0.003 ms → 0.003 ms (+5.7%) | 2.379 ms → 2.478 ms (+4.2%) | 2.288 ms → 2.579 ms (+12.7%) | 486.009 ms → 560.933 ms (+15.4%) | 483.380 ms → 495.576 ms (+2.5%) | 2.154 ms → 2.204 ms (+2.3%) | 4.224 ms → 4.135 ms (-2.1%) | NOT COLLECTED | 482.544 ms → 493.820 ms (+2.3%) | 480.067 ms → 499.527 ms (+4.1%) | 3937.516 ms → 3911.696 ms (-0.7%) |

The existing public measure protocol did not emit a distinct
`session_same_page_snippet` phase. It emitted same-page full render and
mixed-page snippet, and those are reported above; the missing same-page
snippet is explicitly **not collected**, not inferred from another phase.

The measured verifyAll-after-reads medians improve by roughly 10.5–14.0% on
the three raw lanes and 0.7–2.5% on the three adaptive lanes, while
same-page render is generally modestly lower. Mixed-page render/snippet varies
by corpus and codec: OMW raw is +4.1%/+3.7% and OMW adaptive is +2.3%/+4.1%
for mixed render/snippet, and OMW adaptive's uncached render batch is a larger
+15.4% regression. This does not support a universal “faster” conclusion.
`Reader.init` is retained as a separate control even when its nanosecond value
rounds to 0.000 ms in this display.

## Reader cache accounting

The first cold session load must show one or more page loads and zero cache
hits; same-page render must show 256 cache hits and zero page loads; mixed-page
phases must cross page boundaries. The paired counters are shown for sample 0
(they are identical across all three samples).

| corpus | codec | phase | page loads | bzip3 decodes | cache hits | decoded bytes |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| FreeDict eng-spa | raw | before session_first_cold | 1 | 0 | 0 | 65061 |
| FreeDict eng-spa | raw | before session_same_page_render | 0 | 0 | 256 | 0 |
| FreeDict eng-spa | raw | before session_mixed_page_render | 255 | 0 | 1 | 12682139 |
| FreeDict eng-spa | raw | before session_mixed_page_snippet | 256 | 0 | 0 | 12747200 |
| FreeDict eng-spa | raw | after session_first_cold | 1 | 0 | 0 | 65061 |
| FreeDict eng-spa | raw | after session_same_page_render | 0 | 0 | 256 | 0 |
| FreeDict eng-spa | raw | after session_mixed_page_render | 255 | 0 | 1 | 12682139 |
| FreeDict eng-spa | raw | after session_mixed_page_snippet | 256 | 0 | 0 | 12747200 |
| FreeDict eng-spa | adaptive | before session_first_cold | 1 | 1 | 0 | 65061 |
| FreeDict eng-spa | adaptive | before session_same_page_render | 0 | 0 | 256 | 0 |
| FreeDict eng-spa | adaptive | before session_mixed_page_render | 255 | 255 | 1 | 12682139 |
| FreeDict eng-spa | adaptive | before session_mixed_page_snippet | 256 | 256 | 0 | 12747200 |
| FreeDict eng-spa | adaptive | after session_first_cold | 1 | 1 | 0 | 65061 |
| FreeDict eng-spa | adaptive | after session_same_page_render | 0 | 0 | 256 | 0 |
| FreeDict eng-spa | adaptive | after session_mixed_page_render | 255 | 255 | 1 | 12682139 |
| FreeDict eng-spa | adaptive | after session_mixed_page_snippet | 256 | 256 | 0 | 12747200 |
| GNU GCIDE 0.54 | raw | before session_first_cold | 1 | 0 | 0 | 65528 |
| GNU GCIDE 0.54 | raw | before session_same_page_render | 0 | 0 | 256 | 0 |
| GNU GCIDE 0.54 | raw | before session_mixed_page_render | 255 | 0 | 1 | 18335240 |
| GNU GCIDE 0.54 | raw | before session_mixed_page_snippet | 256 | 0 | 0 | 18400768 |
| GNU GCIDE 0.54 | raw | after session_first_cold | 1 | 0 | 0 | 65528 |
| GNU GCIDE 0.54 | raw | after session_same_page_render | 0 | 0 | 256 | 0 |
| GNU GCIDE 0.54 | raw | after session_mixed_page_render | 255 | 0 | 1 | 18335240 |
| GNU GCIDE 0.54 | raw | after session_mixed_page_snippet | 256 | 0 | 0 | 18400768 |
| GNU GCIDE 0.54 | adaptive | before session_first_cold | 1 | 1 | 0 | 65528 |
| GNU GCIDE 0.54 | adaptive | before session_same_page_render | 0 | 0 | 256 | 0 |
| GNU GCIDE 0.54 | adaptive | before session_mixed_page_render | 255 | 255 | 1 | 18335240 |
| GNU GCIDE 0.54 | adaptive | before session_mixed_page_snippet | 256 | 256 | 0 | 18400768 |
| GNU GCIDE 0.54 | adaptive | after session_first_cold | 1 | 1 | 0 | 65528 |
| GNU GCIDE 0.54 | adaptive | after session_same_page_render | 0 | 0 | 256 | 0 |
| GNU GCIDE 0.54 | adaptive | after session_mixed_page_render | 255 | 255 | 1 | 18335240 |
| GNU GCIDE 0.54 | adaptive | after session_mixed_page_snippet | 256 | 256 | 0 | 18400768 |
| OMW Japanese 2.0 | raw | before session_first_cold | 1 | 0 | 0 | 63667 |
| OMW Japanese 2.0 | raw | before session_same_page_render | 0 | 0 | 256 | 0 |
| OMW Japanese 2.0 | raw | before session_mixed_page_render | 255 | 0 | 1 | 13831757 |
| OMW Japanese 2.0 | raw | before session_mixed_page_snippet | 256 | 0 | 0 | 13895424 |
| OMW Japanese 2.0 | raw | after session_first_cold | 1 | 0 | 0 | 63667 |
| OMW Japanese 2.0 | raw | after session_same_page_render | 0 | 0 | 256 | 0 |
| OMW Japanese 2.0 | raw | after session_mixed_page_render | 255 | 0 | 1 | 13831757 |
| OMW Japanese 2.0 | raw | after session_mixed_page_snippet | 256 | 0 | 0 | 13895424 |
| OMW Japanese 2.0 | adaptive | before session_first_cold | 1 | 1 | 0 | 63667 |
| OMW Japanese 2.0 | adaptive | before session_same_page_render | 0 | 0 | 256 | 0 |
| OMW Japanese 2.0 | adaptive | before session_mixed_page_render | 255 | 255 | 1 | 13831757 |
| OMW Japanese 2.0 | adaptive | before session_mixed_page_snippet | 256 | 256 | 0 | 13895424 |
| OMW Japanese 2.0 | adaptive | after session_first_cold | 1 | 1 | 0 | 63667 |
| OMW Japanese 2.0 | adaptive | after session_same_page_render | 0 | 0 | 256 | 0 |
| OMW Japanese 2.0 | adaptive | after session_mixed_page_render | 255 | 255 | 1 | 13831757 |
| OMW Japanese 2.0 | adaptive | after session_mixed_page_snippet | 256 | 256 | 0 | 13895424 |

## Source hashes used by the current build

The current-tree provenance includes all benchmark inputs, the root module's
production imports, `build6.zig`, and the vendored bzip3 tree digest. The
preserved original is treated as a retained executable baseline; this source
tree is not asserted to reproduce that older binary.

| path | bytes | SHA-256 |
| --- | ---: | --- |
| `/Users/mileswirht/Downloads/dictionary/src6/bench/real-world/runner.zig` | 52,168 | `6cfc25d87e8c16a1f25fa92f1c7eeab779062ea529c79c2bd5369cc263c5c3e8` |
| `/Users/mileswirht/Downloads/dictionary/src6/bench/real-world/build.zig` | 914 | `d9b9c43e7e47d265773408b43a6351842974fc91c58971569321479172e91de2` |
| `/Users/mileswirht/Downloads/dictionary/src6/bench/real-world/measure.py` | 48,212 | `4f5dd6f68d813c0fec0cdd473a59a6c9d3cf82d8fa374f467885a1541382ccb4` |
| `/Users/mileswirht/Downloads/dictionary/src6/bench/real-world/formats.py` | 47,900 | `1b6a1c9a74d3f5da5aa7af7cd47e2ba9e29a5fcd231ff2f105a6ad8d55f7eade` |
| `/Users/mileswirht/Downloads/dictionary/src6/bench/real-world/simplifying_measure.py` | 14,011 | `d10696ebdd2b522c57830f7e4934db79bd386e48ae72231745fe2124ee2d0dd7` |
| `/Users/mileswirht/Downloads/dictionary/build6.zig` | 2,483 | `9758a79ebc1955a14d10e4175572bdd87a1782c291363d39ec691c2f4c939f2d` |
| `/Users/mileswirht/Downloads/dictionary/src6/root.zig` | 758 | `d9fab813982de05e44c044af4ce1783aa9ed4781fbc1347d573d18ce5444d3ac` |
| `/Users/mileswirht/Downloads/dictionary/src6/model.zig` | 12,512 | `c7dbba98b517022e8ed35d9246a3f07232475317890215004d6fce15c38e805f` |
| `/Users/mileswirht/Downloads/dictionary/src6/packet.zig` | 13,854 | `624a40b0bcdbe0e70694919b5850e9688d87f1fde0e7cdb7894047ffab4d2c7d` |
| `/Users/mileswirht/Downloads/dictionary/src6/compression.zig` | 10,608 | `f46c9d65a3e48f54515e487721643555ed611f1fb1b59bec37b9dd3ba92a414d` |
| `/Users/mileswirht/Downloads/dictionary/src6/archive.zig` | 61,725 | `fd82d8e3c36f9ab9663809aa669656c0ed648ee17b63f2b13a9d17a61ca03f85` |
| `/Users/mileswirht/Downloads/dictionary/src6/query.zig` | 13,185 | `39a4aae8889b93754b668d1c18711f3279634c0c4c94943e1ebb6afa815a5d87` |
| `/Users/mileswirht/Downloads/dictionary/src6/nodes.zig` | 11,335 | `dcdc7695483b681520507f6e275c5e46d1ac9d6bc19f6dbc78f32f8a822201d2` |
| `/Users/mileswirht/Downloads/dictionary/src6/render.zig` | 5,837 | `d262e9b9f4795e3d7029d4871a67f83f39be6d2ab1b277d1e9216d2c7ebfe51c` |
| `/Users/mileswirht/Downloads/dictionary/src6/walk.zig` | 4,433 | `968efb2fef6088c6895e694ceddea47ea0420e23d8e2f2cf6481dd5a6d47f54f` |
| `/Users/mileswirht/Downloads/dictionary/src6/validate.zig` | 23,905 | `f06c906cc203cf4ff9af03ff22d5d40d08cf9518dfa48a8d4c912f52b8732618` |
| `/Users/mileswirht/Downloads/dictionary/vendor/bzip3` | 7,500,421 | `e1d11b48907373b3509ecd595424ccc485182dc885817b2b8afbbfd3268329cb` |

The vendored bzip3 tree is recorded as a deterministic file-tree digest above.

## Storage and bzip3 interpretation

The retained full report is the authority for all-format storage comparisons:
LEX6 metadata/payload, StarDict, DICT, dictzip (including its required index),
SQLite, and SLOB native files plus separately charged SLOB identity sidecars.
Its bzip3 section records every 16/64/256 KiB page decision: adaptive selected
bzip3 on every page, with zero raw/resource-limit fallbacks and zero probe
errors; adaptive and forced-bzip3 artifacts were byte-identical per target.
Larger pages reduced metadata and adaptive storage on these corpora but make
random-access granularity coarser. Whole-stream bzip3 is storage-only because
it omits packet framing, metadata, and page restart boundaries; it is not a
random-access latency lane.

## Reproduction boundary

The bounded driver is [`simplifying_measure.py`](../simplifying_measure.py).
It wraps the existing public `runner.zig` measure protocol, checks every
retained hash before launch, requires the literal quiet gate, and writes the
paired ledger. No source corpora or archives were regenerated for this run.
The one preflight path-resolution rejection launched zero child processes and
collected zero clocked samples; it is retained as
[`simplifying-post-review-preflight-path-bug.json`](../runs/simplifying-post-review-preflight-path-bug.json).
