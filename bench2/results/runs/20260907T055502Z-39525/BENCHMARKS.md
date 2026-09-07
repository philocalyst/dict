# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `Darwin mileswirht 24.6.0 Darwin Kernel Version 24.6.0: Mon Jan 19 21:59:23 PST 2026; root:xnu-11417.140.69.708.3~1/RELEASE_ARM64_T6030 arm64 arm Darwin` (the run's exact tool versions are in `raw/machine.tsv`).
- Corpus: deterministic fixtures, `32` records, seed `0x4c45583200020001`.
- Repetitions/warmup: Zig `8`/`2`; external `8`/`2`.
- v2 prose presets: `latency`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 1,088 | 5.386 | 21.62 | 1.29/13.46/13.46 | 5.29/14.33/14.33 | 7552.96/9548.92/9548.92 |
| flat | `dict-index/raw` | 6,895 | 0.581 | 31.71 | 0.38/0.46/0.46 | 2.21/2.42/2.42 | 0.29/0.33/0.33 |
| flat | `slob/lzma2` | 2,553 | 18.075 | 65.50 | 431.92/2057.17/2057.17 | 1196.33/2006.17/2006.17 | 20.29/55.62/55.62 |
| flat | `slob/raw` | 8,580 | 11.892 | 177.04 | 857.92/2092.62/2092.62 | 1444.33/1852.21/1852.21 | 21.08/65.71/65.71 |
| flat | `sqlite/raw` | 20,480 | 9.185 | 163.12 | 5.04/5.25/5.25 | 13.08/13.79/13.79 | 5.00/5.88/5.88 |
| flat | `sqlite/zlib` | 1,131 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 985 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 6,974 | 0.579 | 29.79 | 0.42/0.67/0.67 | 2.38/2.50/2.50 | 0.21/0.38/0.38 |
| flat | `v1/bzip3` | 2,560 | 0.603 | 74.96 | 0.58/2.12/2.12 | 1.92/2.29/2.29 | 558.12/1401.96/1401.96 |
| flat | `v1/raw` | 8,384 | 0.245 | 47.75 | 0.42/0.67/0.67 | 1.88/2.25/2.25 | 9.33/9.38/9.38 |
| flat | `v2/bzip3.latency` | 12,640 | 5.056 | 378.96 | 0.29/0.67/0.67 | 1.04/1.92/1.92 | 108.33/110.04/110.04 |
| flat | `v2/raw.latency` | 18,592 | 1.778 | 261.58 | 0.29/0.38/0.38 | 0.96/1.25/1.25 | 0.08/0.12/0.12 |
| pathological_prefix | `dict-index/dictzip` | 1,742 | 8.128 | 50.88 | 0.88/14.25/14.25 | 3.33/8.12/8.12 | 10248.96/16260.83/16260.83 |
| pathological_prefix | `dict-index/raw` | 7,534 | 0.426 | 76.29 | 0.75/1.04/1.04 | 0.92/5.54/5.54 | 0.75/1.17/1.17 |
| pathological_prefix | `slob/lzma2` | 3,192 | 12.445 | 213.62 | 998.71/2432.88/2432.88 | 1791.04/3030.12/3030.12 | 56.38/112.62/112.62 |
| pathological_prefix | `slob/raw` | 9,219 | 10.420 | 61.58 | 638.92/1658.04/1658.04 | 1291.50/2448.00/2448.00 | 20.12/57.42/57.42 |
| pathological_prefix | `sqlite/raw` | 20,480 | 1.060 | 46.88 | 5.00/5.62/5.62 | 6.88/13.42/13.42 | 5.00/9.83/9.83 |
| pathological_prefix | `sqlite/zlib` | 1,126 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 943 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 1,802 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 7,614 | 1.000 | 29.50 | 0.38/0.79/0.79 | 0.38/2.54/2.54 | 0.21/0.42/0.42 |
| pathological_prefix | `v1/bzip3` | 2,616 | 0.311 | 14.04 | 0.21/0.38/0.38 | 0.46/1.08/1.08 | 297.12/516.83/516.83 |
| pathological_prefix | `v1/raw` | 8,440 | 0.224 | 32.62 | 0.25/0.38/0.38 | 0.33/1.08/1.08 | 9.46/361.96/361.96 |
| pathological_prefix | `v2/bzip3.latency` | 13,280 | 2.716 | 389.38 | 0.38/1.50/1.50 | 0.42/1.79/1.79 | 103.08/247.08/247.08 |
| pathological_prefix | `v2/raw.latency` | 19,232 | 2.796 | 878.04 | 0.96/1.46/1.46 | 0.71/3.29/3.29 | 0.12/0.75/0.75 |
| prose_heavy | `dict-index/dictzip` | 2,242 | 8.108 | 58.25 | 0.54/13.00/13.00 | 2.21/5.50/5.50 | 5950.04/9036.12/9036.12 |
| prose_heavy | `dict-index/raw` | 164,862 | 0.751 | 36.17 | 0.79/1.29/1.29 | 5.33/23.50/23.50 | 5.67/21.88/21.88 |
| prose_heavy | `slob/lzma2` | 3,211 | 18.001 | 160.29 | 404.08/877.58/877.58 | 934.00/1713.50/1713.50 | 90.54/133.25/133.25 |
| prose_heavy | `slob/raw` | 166,500 | 16.155 | 97.96 | 325.79/1401.83/1401.83 | 918.54/1362.33/1362.33 | 60.71/203.12/203.12 |
| prose_heavy | `sqlite/raw` | 188,416 | 1.593 | 51.38 | 5.04/5.54/5.54 | 13.21/17.71/17.71 | 45.42/170.08/170.08 |
| prose_heavy | `sqlite/zlib` | 2,193 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 1,288 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 1,842 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 164,862 | 1.930 | 50.42 | 0.88/1.42/1.42 | 6.04/21.33/21.33 | 15.96/26.75/26.75 |
| prose_heavy | `v1/bzip3` | 3,096 | 3.075 | 14.46 | 0.29/0.92/0.92 | 0.96/1.25/1.25 | 343.38/640.92/640.92 |
| prose_heavy | `v1/raw` | 166,368 | 3.941 | 687.79 | 0.38/0.96/0.96 | 0.96/1.38/1.38 | 69.00/86.04/86.04 |
| prose_heavy | `v2/bzip3.latency` | 13,280 | 5.745 | 297.50 | 0.29/0.83/0.83 | 0.96/2.08/2.08 | 286.71/390.50/390.50 |
| prose_heavy | `v2/raw.latency` | 176,672 | 4.166 | 423.92 | 0.33/0.62/0.62 | 1.00/1.88/1.88 | 0.04/0.33/0.33 |
| repeated | `dict-index/dictzip` | 1,249 | 9.051 | 52.21 | 2.08/13.79/13.79 | 3.46/6.21/6.21 | 6105.54/7457.08/7457.08 |
| repeated | `dict-index/raw` | 7,593 | 0.239 | 40.83 | 0.38/0.46/0.46 | 1.21/1.42/1.42 | 0.25/0.38/0.38 |
| repeated | `slob/lzma2` | 2,734 | 24.940 | 70.08 | 592.42/981.62/981.62 | 1001.62/2102.58/2102.58 | 20.42/43.67/43.67 |
| repeated | `slob/raw` | 9,277 | 14.328 | 79.46 | 868.08/1269.50/1269.50 | 1567.00/1951.67/1951.67 | 20.62/55.67/55.67 |
| repeated | `sqlite/raw` | 20,480 | 1.403 | 92.88 | 5.38/5.67/5.67 | 55.67/74.38/74.38 | 47.62/92.75/92.75 |
| repeated | `sqlite/zlib` | 1,162 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 1,033 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 1,306 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 7,671 | 0.837 | 105.88 | 0.92/3.67/3.67 | 3.12/8.38/8.38 | 1.08/21.92/21.92 |
| repeated | `v1/bzip3` | 2,384 | 0.253 | 13.33 | 0.33/0.62/0.62 | 0.62/0.79/0.79 | 145.88/292.92/292.92 |
| repeated | `v1/raw` | 2,952 | 0.064 | 12.58 | 0.29/0.42/0.42 | 0.58/0.75/0.75 | 0.96/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 12,640 | 2.049 | 348.29 | 0.46/0.88/0.88 | 0.54/1.29/1.29 | 121.92/221.12/221.12 |
| repeated | `v2/raw.latency` | 19,168 | 3.425 | 270.29 | 0.25/0.33/0.33 | 0.58/0.75/0.75 | 0.08/0.25/0.25 |
| rich | `dict-index/dictzip` | 1,088 | 7.776 | 58.12 | 1.12/14.29/14.29 | 5.25/8.17/8.17 | 7056.79/10407.62/10407.62 |
| rich | `dict-index/raw` | 6,895 | 1.135 | 74.25 | 0.75/1.54/1.54 | 5.04/5.83/5.83 | 0.67/4.33/4.33 |
| rich | `slob/lzma2` | 2,553 | 25.453 | 58.58 | 283.88/821.08/821.08 | 1552.67/2613.96/2613.96 | 116.29/202.25/202.25 |
| rich | `slob/raw` | 8,580 | 18.903 | 61.12 | 593.54/746.42/746.42 | 1236.83/3056.08/3056.08 | 20.79/53.25/53.25 |
| rich | `sqlite/raw` | 20,480 | 0.678 | 46.67 | 11.29/12.21/12.21 | 42.38/84.21/84.21 | 5.29/8.67/8.67 |
| rich | `sqlite/zlib` | 1,131 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 985 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 6,974 | 0.638 | 83.50 | 0.88/1.54/1.54 | 5.54/6.21/6.21 | 0.67/4.46/4.46 |
| rich | `v1/bzip3` | 2,560 | 1.672 | 23.46 | 0.71/13.12/13.12 | 1.96/11.25/11.25 | 176.46/382.17/382.17 |
| rich | `v1/raw` | 8,384 | 0.500 | 132.83 | 0.38/1.17/1.17 | 1.00/1.42/1.42 | 6.83/6.96/6.96 |
| rich | `v2/bzip3.latency` | 13,664 | 5.814 | 2356.29 | 0.33/2.04/2.04 | 0.96/1.79/1.79 | 434.33/496.50/496.50 |
| rich | `v2/raw.latency` | 19,616 | 3.185 | 698.21 | 0.29/0.46/0.46 | 0.92/1.12/1.12 | 0.08/0.33/0.33 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 1.46 | 1.04 | 3.58 | 1.12 | 8.54 | - |
| flat | `dict-index/raw` | 0.38 | 0.33 | 0.33 | 0.46 | 2.29 | - |
| flat | `slob/lzma2` | 442.96 | 271.50 | 924.79 | 1254.00 | 1826.42 | - |
| flat | `slob/raw` | 857.92 | 604.50 | 1852.21 | 1052.12 | 1459.33 | - |
| flat | `sqlite/raw` | 5.04 | 4.75 | 6.54 | 7.42 | 13.67 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.42 | 0.29 | 0.29 | 0.46 | 2.46 | - |
| flat | `v1/bzip3` | 0.58 | 0.42 | 0.88 | 0.92 | 2.04 | - |
| flat | `v1/raw` | 0.42 | 0.33 | 0.58 | 0.62 | 2.08 | - |
| flat | `v2/bzip3.latency` | 0.38 | 0.12 | 0.29 | 0.21 | 1.12 | - |
| flat | `v2/raw.latency` | 0.29 | 0.12 | 0.25 | 0.21 | 1.12 | - |
| pathological_prefix | `dict-index/dictzip` | 0.88 | 0.67 | 0.92 | 1.12 | - | 5.67 |
| pathological_prefix | `dict-index/raw` | 0.75 | 0.62 | 0.75 | 0.79 | - | 5.50 |
| pathological_prefix | `slob/lzma2` | 998.71 | 843.58 | 1211.33 | 1791.04 | - | 2594.58 |
| pathological_prefix | `slob/raw` | 638.92 | 374.04 | 1158.04 | 1850.75 | - | 2107.50 |
| pathological_prefix | `sqlite/raw` | 5.00 | 4.88 | 6.08 | 6.88 | - | 13.17 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.38 | 0.33 | 0.38 | 0.38 | - | 2.54 |
| pathological_prefix | `v1/bzip3` | 0.21 | 0.12 | 0.17 | 0.46 | - | 1.00 |
| pathological_prefix | `v1/raw` | 0.25 | 0.12 | 0.17 | 0.33 | - | 1.04 |
| pathological_prefix | `v2/bzip3.latency` | 0.46 | 0.08 | 0.17 | 0.42 | - | 1.46 |
| pathological_prefix | `v2/raw.latency` | 1.17 | 0.21 | 0.29 | 0.62 | - | 2.50 |
| prose_heavy | `dict-index/dictzip` | 0.54 | 0.50 | 1.58 | 0.62 | 4.58 | - |
| prose_heavy | `dict-index/raw` | 0.79 | 0.67 | 0.67 | 3.42 | 7.04 | - |
| prose_heavy | `slob/lzma2` | 324.17 | 404.08 | 687.38 | 1713.50 | 1272.58 | - |
| prose_heavy | `slob/raw` | 325.79 | 317.42 | 714.46 | 558.21 | 1226.71 | - |
| prose_heavy | `sqlite/raw` | 5.04 | 4.83 | 6.88 | 17.71 | 13.42 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.88 | 0.62 | 0.92 | 3.92 | 6.46 | - |
| prose_heavy | `v1/bzip3` | 0.29 | 0.25 | 0.58 | 0.50 | 1.17 | - |
| prose_heavy | `v1/raw` | 0.38 | 0.29 | 0.46 | 0.58 | 1.25 | - |
| prose_heavy | `v2/bzip3.latency` | 0.29 | 0.12 | 0.25 | 0.25 | 1.08 | - |
| prose_heavy | `v2/raw.latency` | 0.38 | 0.12 | 0.33 | 0.38 | 1.21 | - |
| repeated | `dict-index/dictzip` | 2.08 | 1.08 | 0.79 | - | 3.46 | - |
| repeated | `dict-index/raw` | 0.42 | 0.33 | 0.29 | - | 1.29 | - |
| repeated | `slob/lzma2` | 724.96 | 219.54 | 641.29 | - | 1001.62 | - |
| repeated | `slob/raw` | 888.58 | 639.92 | 764.50 | - | 1591.42 | - |
| repeated | `sqlite/raw` | 5.38 | 5.08 | 21.46 | - | 69.88 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 0.92 | 0.62 | 0.71 | - | 3.33 | - |
| repeated | `v1/bzip3` | 0.38 | 0.17 | 0.21 | - | 0.67 | - |
| repeated | `v1/raw` | 0.29 | 0.12 | 0.17 | - | 0.58 | - |
| repeated | `v2/bzip3.latency` | 0.46 | 0.08 | 0.17 | - | 0.71 | - |
| repeated | `v2/raw.latency` | 0.25 | 0.08 | 0.12 | - | 0.62 | - |
| rich | `dict-index/dictzip` | 1.12 | 1.08 | 2.83 | 1.08 | 5.42 | - |
| rich | `dict-index/raw` | 0.79 | 0.62 | 0.58 | 1.00 | 5.67 | - |
| rich | `slob/lzma2` | 273.88 | 283.88 | 445.58 | 1162.12 | 2379.21 | - |
| rich | `slob/raw` | 593.54 | 478.50 | 1236.83 | 998.62 | 3031.54 | - |
| rich | `sqlite/raw` | 11.04 | 11.29 | 18.54 | 80.12 | 81.71 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.88 | 0.71 | 0.67 | 1.04 | 5.88 | - |
| rich | `v1/bzip3` | 0.71 | 0.50 | 0.88 | 0.88 | 2.38 | - |
| rich | `v1/raw` | 0.42 | 0.25 | 0.62 | 0.58 | 1.17 | - |
| rich | `v2/bzip3.latency` | 0.33 | 0.12 | 0.38 | 0.29 | 1.00 | - |
| rich | `v2/raw.latency` | 0.33 | 0.12 | 0.21 | 0.17 | 1.00 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `6775974522125595869`
- `pathological_prefix` digest values: `3708246534312039307`
- `prose_heavy` digest values: `12848969583906786549`
- `repeated` digest values: `17180257314182760903`
- `rich` digest values: `6775974522125595869`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `56754176` bytes
- `flat.zig.process_peak_rss_bytes`: `28721152` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `56819712` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `32227328` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `59850752` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `38125568` bytes
- `repeated.external.process_peak_rss_bytes`: `57114624` bytes
- `repeated.zig.process_peak_rss_bytes`: `34570240` bytes
- `rich.external.process_peak_rss_bytes`: `56672256` bytes
- `rich.zig.process_peak_rss_bytes`: `34734080` bytes

## Availability and caveats

- `flat sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `flat sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `flat stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `prose_heavy sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `prose_heavy sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `prose_heavy stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `repeated sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `repeated sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `repeated stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `rich sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `rich sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `rich stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `pathological_prefix sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `pathological_prefix sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `pathological_prefix stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- The v1/v2 comparison is an equal lexical projection. v2's rich fixture adds graph assertions; external formats intentionally receive only the same flat key/definition projection, so those rows do not measure graph preservation.
- SQLite zlib/zstd and StarDict gzip rows report artifact sizes only: whole-file compression destroys page/index random access unless a decompression staging policy is chosen, so query latency is not fabricated.
- `dict-index` is a local sorted UTF-8 offset reader, not a dictd daemon; it is intentionally relabeled when real dictfmt/dictd service timing is unavailable. Its dictzip variant uses range decompression.
- External profiles are Python readers: Python's sqlite3 wrapper, the custom StarDict and sorted-offset readers, and optional reference SLOB. Their interpreter/library overhead is part of those timings and is not equivalent to the native Zig v1/v2 implementations.
- v1/v2 open timing includes their format-specific structural/semantic open path (v2 validates the canonical manifest, sections, derived indexes, and cached views). External open timing measures reader construction only; every external artifact is semantically validated before warmup and timing, but that validation is not part of external open latency.
- Build timing is format-specific: v1/v2 includes builder/compile plus the in-process Reader/Snapshot.open validation boundary; external build timing covers the custom reader/artifact construction. It is not an equivalent end-to-end build pipeline.
- SLOB is Python reference SLOB with raw and lzma2 compression. Its UUID/timestamp metadata is not byte-for-byte deterministic even though the corpus and semantic digest are.
- Timings are single-process wall-clock samples after deterministic warmup on one otherwise uncontrolled host; use p95/p99 and raw TSV for comparisons, not a claim of universal performance.

Raw outputs: `results/latest/raw/*.tsv`; machine-readable output: `results/latest/benchmark.json`; generated artifacts: `results/latest/artifacts/<fixture>/`; SHA-256 manifest: `results/latest/hashes.tsv`.
