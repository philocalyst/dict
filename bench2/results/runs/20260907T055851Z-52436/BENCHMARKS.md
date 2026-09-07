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
| flat | `dict-index/dictzip` | 1,088 | 5.109 | 30.83 | 1.17/12.58/12.58 | 5.08/9.00/9.00 | 5819.71/7124.38/7124.38 |
| flat | `dict-index/raw` | 6,895 | 0.242 | 95.62 | 0.33/0.50/0.50 | 2.08/2.42/2.42 | 0.25/0.33/0.33 |
| flat | `slob/lzma2` | 2,553 | 12.020 | 73.42 | 242.00/878.08/878.08 | 1646.88/2911.50/2911.50 | 53.42/115.79/115.79 |
| flat | `slob/raw` | 8,580 | 13.866 | 65.12 | 607.08/884.12/884.12 | 1102.50/2184.04/2184.04 | 20.12/48.42/48.42 |
| flat | `sqlite/raw` | 20,480 | 1.345 | 139.04 | 12.62/128.54/128.54 | 32.71/81.08/81.08 | 5.58/9.42/9.42 |
| flat | `sqlite/zlib` | 1,131 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 985 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 6,974 | 1.846 | 80.42 | 0.46/0.58/0.58 | 2.33/2.67/2.67 | 0.25/0.42/0.42 |
| flat | `v1/bzip3` | 2,560 | 0.613 | 23.96 | 0.50/3.29/3.29 | 1.92/2.33/2.33 | 299.83/1653.62/1653.62 |
| flat | `v1/raw` | 8,384 | 0.172 | 49.17 | 0.54/2.12/2.12 | 1.92/2.33/2.33 | 9.46/44.25/44.25 |
| flat | `v2/bzip3.latency` | 12,640 | 4.650 | 594.12 | 0.38/1.17/1.17 | 1.00/1.88/1.88 | 338.46/682.58/682.58 |
| flat | `v2/raw.latency` | 18,592 | 3.225 | 620.62 | 0.62/0.96/0.96 | 2.12/2.83/2.83 | 0.12/0.54/0.54 |
| pathological_prefix | `dict-index/dictzip` | 1,742 | 13.963 | 68.00 | 0.42/8.96/8.96 | 1.71/3.88/3.88 | 6387.83/8119.08/8119.08 |
| pathological_prefix | `dict-index/raw` | 7,534 | 0.675 | 32.38 | 0.33/0.62/0.62 | 0.38/2.33/2.33 | 0.25/0.33/0.33 |
| pathological_prefix | `slob/lzma2` | 3,192 | 16.277 | 201.75 | 755.88/1278.38/1278.38 | 2847.17/3962.38/3962.38 | 20.71/1210.54/1210.54 |
| pathological_prefix | `slob/raw` | 9,219 | 18.212 | 192.08 | 442.88/1905.21/1905.21 | 1424.42/2656.42/2656.42 | 52.04/107.33/107.33 |
| pathological_prefix | `sqlite/raw` | 20,480 | 2.687 | 83.00 | 5.21/509.17/509.17 | 133.00/652.50/652.50 | 26.29/64.12/64.12 |
| pathological_prefix | `sqlite/zlib` | 1,126 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 943 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 1,802 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 7,614 | 1.378 | 70.92 | 0.46/1.92/1.92 | 2.96/7.04/7.04 | 0.54/2.67/2.67 |
| pathological_prefix | `v1/bzip3` | 2,616 | 0.616 | 13.46 | 0.25/0.42/0.42 | 0.33/1.08/1.08 | 104.67/106.17/106.17 |
| pathological_prefix | `v1/raw` | 8,440 | 0.123 | 30.88 | 0.29/0.46/0.46 | 0.33/1.12/1.12 | 6.83/6.96/6.96 |
| pathological_prefix | `v2/bzip3.latency` | 13,280 | 2.802 | 466.08 | 0.42/1.04/1.04 | 0.50/1.92/1.92 | 205.96/648.50/648.50 |
| pathological_prefix | `v2/raw.latency` | 19,232 | 1.885 | 261.58 | 0.25/0.54/0.54 | 0.25/1.17/1.17 | 0.08/0.21/0.21 |
| prose_heavy | `dict-index/dictzip` | 2,242 | 8.274 | 61.92 | 1.38/12.29/12.29 | 5.12/10.62/10.62 | 7834.17/11096.83/11096.83 |
| prose_heavy | `dict-index/raw` | 164,862 | 0.727 | 208.00 | 1.17/4.50/4.50 | 5.38/6.46/6.46 | 10.04/15.46/15.46 |
| prose_heavy | `slob/lzma2` | 3,211 | 21.280 | 62.83 | 313.62/740.29/740.29 | 2452.92/3179.21/3179.21 | 158.21/209.92/209.92 |
| prose_heavy | `slob/raw` | 166,500 | 14.480 | 71.21 | 248.29/1439.92/1439.92 | 2782.33/4479.25/4479.25 | 75.08/377.71/377.71 |
| prose_heavy | `sqlite/raw` | 188,416 | 0.862 | 131.79 | 9.83/13.21/13.21 | 28.25/127.50/127.50 | 57.79/153.33/153.33 |
| prose_heavy | `sqlite/zlib` | 2,193 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 1,288 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 1,842 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 164,862 | 0.966 | 74.38 | 0.38/0.58/0.58 | 2.33/2.58/2.58 | 21.29/327.25/327.25 |
| prose_heavy | `v1/bzip3` | 3,096 | 2.590 | 36.50 | 0.54/1.75/1.75 | 1.96/2.38/2.38 | 448.62/621.75/621.75 |
| prose_heavy | `v1/raw` | 166,368 | 4.874 | 916.33 | 0.33/1.08/1.08 | 1.08/1.46/1.46 | 68.92/69.42/69.42 |
| prose_heavy | `v2/bzip3.latency` | 13,280 | 14.730 | 295.54 | 0.29/0.75/0.75 | 0.96/2.04/2.04 | 512.46/984.42/984.42 |
| prose_heavy | `v2/raw.latency` | 176,672 | 6.374 | 678.38 | 0.71/1.17/1.17 | 2.17/3.29/3.29 | 0.12/0.75/0.75 |
| repeated | `dict-index/dictzip` | 1,249 | 8.521 | 22.46 | 1.21/14.00/14.00 | 3.67/5.58/5.58 | 6983.58/12230.33/12230.33 |
| repeated | `dict-index/raw` | 7,593 | 0.750 | 40.29 | 0.79/1.29/1.29 | 3.04/6.04/6.04 | 0.88/1.88/1.88 |
| repeated | `slob/lzma2` | 2,734 | 9.753 | 168.71 | 572.46/673.75/673.75 | 1424.67/2827.67/2827.67 | 20.46/62.29/62.29 |
| repeated | `slob/raw` | 9,277 | 7.813 | 68.71 | 310.00/1183.25/1183.25 | 1429.25/2828.92/2828.92 | 20.46/54.88/54.88 |
| repeated | `sqlite/raw` | 20,480 | 0.985 | 50.62 | 12.17/13.71/13.71 | 20.46/22.46/22.46 | 15.67/49.75/49.75 |
| repeated | `sqlite/zlib` | 1,162 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 1,033 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 1,306 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 7,671 | 1.246 | 74.96 | 0.96/4.46/4.46 | 3.04/3.42/3.42 | 0.54/0.79/0.79 |
| repeated | `v1/bzip3` | 2,384 | 0.596 | 22.29 | 0.67/2.00/2.00 | 1.17/1.42/1.42 | 320.50/398.92/398.92 |
| repeated | `v1/raw` | 2,952 | 0.454 | 13.29 | 0.29/0.54/0.54 | 0.58/0.75/0.75 | 0.92/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 12,640 | 2.502 | 651.92 | 0.83/1.38/1.38 | 1.25/2.21/2.21 | 340.04/422.50/422.50 |
| repeated | `v2/raw.latency` | 19,168 | 1.836 | 284.12 | 0.29/0.38/0.38 | 0.54/0.79/0.79 | 0.08/0.17/0.17 |
| rich | `dict-index/dictzip` | 1,088 | 6.285 | 56.75 | 1.21/12.62/12.62 | 5.62/12.75/12.75 | 6857.62/9358.46/9358.46 |
| rich | `dict-index/raw` | 6,895 | 0.752 | 32.58 | 0.79/1.29/1.29 | 5.29/5.83/5.83 | 0.79/1.12/1.12 |
| rich | `slob/lzma2` | 2,553 | 13.460 | 242.21 | 249.62/1954.88/1954.88 | 2070.33/3883.79/3883.79 | 87.04/180.67/180.67 |
| rich | `slob/raw` | 8,580 | 19.992 | 167.92 | 1113.00/2626.67/2626.67 | 1233.25/2587.62/2587.62 | 51.38/201.75/201.75 |
| rich | `sqlite/raw` | 20,480 | 1.329 | 47.17 | 12.38/34.71/34.71 | 15.25/75.33/75.33 | 5.17/8.00/8.00 |
| rich | `sqlite/zlib` | 1,131 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 985 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 6,974 | 0.495 | 72.00 | 0.54/0.62/0.62 | 2.38/2.62/2.62 | 1.00/5.83/5.83 |
| rich | `v1/bzip3` | 2,560 | 0.357 | 13.96 | 0.25/0.42/0.42 | 0.92/1.25/1.25 | 334.83/1054.08/1054.08 |
| rich | `v1/raw` | 8,384 | 0.244 | 49.12 | 0.46/0.71/0.71 | 1.92/2.21/2.21 | 9.29/9.33/9.33 |
| rich | `v2/bzip3.latency` | 13,664 | 3.873 | 1969.96 | 0.71/1.62/1.62 | 2.00/3.04/3.04 | 183.21/560.42/560.42 |
| rich | `v2/raw.latency` | 19,616 | 3.326 | 3302.79 | 0.33/1.08/1.08 | 0.96/1.58/1.58 | 0.08/0.46/0.46 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 1.17 | 1.04 | 2.79 | 1.17 | 5.67 | - |
| flat | `dict-index/raw` | 0.42 | 0.29 | 0.29 | 0.42 | 2.38 | - |
| flat | `slob/lzma2` | 734.58 | 211.79 | 1317.29 | 1646.88 | 2427.83 | - |
| flat | `slob/raw` | 699.29 | 222.88 | 816.46 | 1752.12 | 1658.92 | - |
| flat | `sqlite/raw` | 12.38 | 12.62 | 81.08 | 42.29 | 32.71 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.46 | 0.33 | 0.33 | 0.46 | 2.62 | - |
| flat | `v1/bzip3` | 0.58 | 0.38 | 0.79 | 0.79 | 2.12 | - |
| flat | `v1/raw` | 0.58 | 0.38 | 0.79 | 0.92 | 2.04 | - |
| flat | `v2/bzip3.latency` | 0.38 | 0.12 | 0.42 | 0.33 | 1.17 | - |
| flat | `v2/raw.latency` | 0.71 | 0.21 | 0.62 | 0.62 | 2.29 | - |
| pathological_prefix | `dict-index/dictzip` | 0.42 | 0.38 | 0.42 | 0.50 | - | 2.42 |
| pathological_prefix | `dict-index/raw` | 0.33 | 0.33 | 0.33 | 0.38 | - | 2.25 |
| pathological_prefix | `slob/lzma2` | 790.17 | 583.67 | 1305.71 | 2847.17 | - | 3477.96 |
| pathological_prefix | `slob/raw` | 442.88 | 238.46 | 1402.21 | 590.71 | - | 1464.38 |
| pathological_prefix | `sqlite/raw` | 5.21 | 5.04 | 34.08 | 652.50 | - | 263.88 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.46 | 0.38 | 2.50 | 0.50 | - | 6.38 |
| pathological_prefix | `v1/bzip3` | 0.25 | 0.12 | 0.21 | 0.33 | - | 1.08 |
| pathological_prefix | `v1/raw` | 0.29 | 0.12 | 0.17 | 0.33 | - | 1.04 |
| pathological_prefix | `v2/bzip3.latency` | 0.50 | 0.12 | 0.17 | 0.50 | - | 1.33 |
| pathological_prefix | `v2/raw.latency` | 0.42 | 0.08 | 0.12 | 0.25 | - | 1.17 |
| prose_heavy | `dict-index/dictzip` | 1.38 | 1.17 | 3.08 | 1.21 | 5.88 | - |
| prose_heavy | `dict-index/raw` | 1.17 | 0.67 | 0.71 | 1.29 | 6.12 | - |
| prose_heavy | `slob/lzma2` | 313.62 | 215.92 | 1305.58 | 2891.88 | 2497.79 | - |
| prose_heavy | `slob/raw` | 251.29 | 221.46 | 1577.08 | 3856.21 | 3279.92 | - |
| prose_heavy | `sqlite/raw` | 9.83 | 9.46 | 77.33 | 127.50 | 28.25 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.38 | 0.29 | 0.29 | 0.54 | 2.50 | - |
| prose_heavy | `v1/bzip3` | 0.58 | 0.42 | 0.92 | 0.88 | 2.08 | - |
| prose_heavy | `v1/raw` | 0.33 | 0.29 | 0.50 | 0.62 | 1.21 | - |
| prose_heavy | `v2/bzip3.latency` | 0.42 | 0.12 | 0.29 | 0.25 | 1.12 | - |
| prose_heavy | `v2/raw.latency` | 0.83 | 0.25 | 0.79 | 0.50 | 2.25 | - |
| repeated | `dict-index/dictzip` | 1.21 | 0.96 | 2.50 | - | 3.92 | - |
| repeated | `dict-index/raw` | 0.88 | 0.67 | 0.75 | - | 3.12 | - |
| repeated | `slob/lzma2` | 572.46 | 277.21 | 459.12 | - | 1766.54 | - |
| repeated | `slob/raw` | 313.38 | 215.42 | 443.46 | - | 1484.08 | - |
| repeated | `sqlite/raw` | 12.17 | 11.92 | 18.71 | - | 20.75 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 0.96 | 0.71 | 0.67 | - | 3.29 | - |
| repeated | `v1/bzip3` | 0.75 | 0.33 | 0.42 | - | 1.21 | - |
| repeated | `v1/raw` | 0.33 | 0.12 | 0.21 | - | 0.58 | - |
| repeated | `v2/bzip3.latency` | 0.83 | 0.21 | 0.29 | - | 1.38 | - |
| repeated | `v2/raw.latency` | 0.29 | 0.08 | 0.12 | - | 0.54 | - |
| rich | `dict-index/dictzip` | 1.21 | 0.96 | 3.12 | 4.83 | 8.46 | - |
| rich | `dict-index/raw` | 0.79 | 0.62 | 0.62 | 0.96 | 5.50 | - |
| rich | `slob/lzma2` | 249.62 | 229.17 | 1031.58 | 1743.17 | 2788.00 | - |
| rich | `slob/raw` | 1113.00 | 676.12 | 678.83 | 1687.17 | 1518.62 | - |
| rich | `sqlite/raw` | 12.38 | 11.38 | 75.33 | 22.92 | 15.25 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.54 | 0.42 | 0.38 | 0.54 | 2.54 | - |
| rich | `v1/bzip3` | 0.25 | 0.21 | 0.46 | 0.33 | 1.12 | - |
| rich | `v1/raw` | 0.50 | 0.33 | 0.75 | 0.71 | 2.04 | - |
| rich | `v2/bzip3.latency` | 0.75 | 0.33 | 0.79 | 0.50 | 2.08 | - |
| rich | `v2/raw.latency` | 0.42 | 0.08 | 0.42 | 0.42 | 1.04 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `6775974522125595869`
- `pathological_prefix` digest values: `3708246534312039307`
- `prose_heavy` digest values: `12848969583906786549`
- `repeated` digest values: `17180257314182760903`
- `rich` digest values: `6775974522125595869`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `56557568` bytes
- `flat.zig.process_peak_rss_bytes`: `30359552` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `57589760` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `28901376` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `60358656` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `41353216` bytes
- `repeated.external.process_peak_rss_bytes`: `57360384` bytes
- `repeated.zig.process_peak_rss_bytes`: `35405824` bytes
- `rich.external.process_peak_rss_bytes`: `57524224` bytes
- `rich.zig.process_peak_rss_bytes`: `30949376` bytes

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
