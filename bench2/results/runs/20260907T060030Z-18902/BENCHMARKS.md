# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `Darwin mileswirht 24.6.0 Darwin Kernel Version 24.6.0: Mon Jan 19 21:59:23 PST 2026; root:xnu-11417.140.69.708.3~1/RELEASE_ARM64_T6030 arm64 arm Darwin` (the run's exact tool versions are in `raw/machine.tsv`).
- Corpus: deterministic fixtures, `8` records, seed `0x4c45583200020001`.
- Repetitions/warmup: Zig `4`/`1`; external `4`/`1`.
- v2 prose presets: `latency`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 426 | 7.497 | 39.79 | 1.17/11.58/11.58 | 2.38/2.54/2.54 | 9439.33/9819.92/9819.92 |
| flat | `dict-index/raw` | 1,727 | 0.212 | 25.21 | 0.38/0.42/0.42 | 0.79/0.83/0.83 | 0.29/0.38/0.38 |
| flat | `slob/lzma2` | 1,662 | 9.289 | 66.46 | 268.29/558.88/558.88 | 454.79/465.42/465.42 | 21.17/41.71/41.71 |
| flat | `slob/raw` | 3,028 | 11.548 | 60.04 | 156.96/579.62/579.62 | 1458.79/1904.21/1904.21 | 22.79/55.54/55.54 |
| flat | `sqlite/raw` | 12,288 | 6.608 | 85.79 | 5.33/5.62/5.62 | 8.08/8.33/8.33 | 19.08/73.62/73.62 |
| flat | `sqlite/zlib` | 632 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 586 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 507 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 1,829 | 1.035 | 22.38 | 0.33/0.42/0.42 | 0.79/0.96/0.96 | 0.29/0.38/0.38 |
| flat | `v1/bzip3` | 1,040 | 0.240 | 4.75 | 0.25/0.38/0.38 | 0.42/0.46/0.46 | 79.21/79.42/79.42 |
| flat | `v1/raw` | 2,352 | 0.111 | 8.75 | 0.29/0.46/0.46 | 0.46/0.62/0.62 | 2.12/2.12/2.12 |
| flat | `v2/bzip3.latency` | 10,528 | 0.973 | 46.92 | 0.17/0.25/0.25 | 0.29/0.42/0.42 | 166.71/186.17/186.17 |
| flat | `v2/raw.latency` | 11,872 | 0.457 | 93.50 | 0.38/0.54/0.54 | 0.38/0.58/0.58 | 0.08/0.33/0.33 |
| pathological_prefix | `dict-index/dictzip` | 586 | 11.686 | 15.46 | 9.04/443.92/443.92 | 2.25/5.46/5.46 | 10390.08/12929.12/12929.12 |
| pathological_prefix | `dict-index/raw` | 1,872 | 0.636 | 29.75 | 0.88/1.17/1.17 | 0.83/1.88/1.88 | 0.67/2.96/2.96 |
| pathological_prefix | `slob/lzma2` | 1,807 | 14.866 | 65.50 | 478.88/608.33/608.33 | 437.67/465.83/465.83 | 42.29/64.96/64.96 |
| pathological_prefix | `slob/raw` | 3,173 | 19.795 | 81.29 | 751.50/862.83/862.83 | 453.12/2436.67/2436.67 | 43.67/48.00/48.00 |
| pathological_prefix | `sqlite/raw` | 12,288 | 2.246 | 217.58 | 11.83/12.62/12.62 | 17.17/19.25/19.25 | 21.54/28.08/28.08 |
| pathological_prefix | `sqlite/zlib` | 628 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 558 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 667 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 1,974 | 0.492 | 22.29 | 0.42/0.46/0.46 | 0.46/0.96/0.96 | 0.29/0.38/0.38 |
| pathological_prefix | `v1/bzip3` | 1,032 | 0.455 | 3.04 | 0.29/0.29/0.29 | 0.42/0.50/0.50 | 81.67/82.25/82.25 |
| pathological_prefix | `v1/raw` | 2,344 | 0.062 | 10.50 | 0.33/0.71/0.71 | 0.50/0.71/0.71 | 2.42/2.42/2.42 |
| pathological_prefix | `v2/bzip3.latency` | 10,656 | 1.387 | 63.00 | 0.33/0.42/0.42 | 0.29/0.46/0.46 | 324.83/377.83/377.83 |
| pathological_prefix | `v2/raw.latency` | 12,000 | 0.325 | 42.17 | 0.29/0.29/0.29 | 0.29/0.42/0.42 | 0.04/0.29/0.29 |
| prose_heavy | `dict-index/dictzip` | 650 | 13.296 | 39.62 | 1.21/13.38/13.38 | 2.33/2.58/2.58 | 7863.42/8587.54/8587.54 |
| prose_heavy | `dict-index/raw` | 41,218 | 0.536 | 79.38 | 0.71/0.88/0.88 | 1.83/1.92/1.92 | 18.12/20.21/20.21 |
| prose_heavy | `slob/lzma2` | 1,741 | 12.436 | 61.04 | 297.58/705.54/705.54 | 707.67/890.42/890.42 | 24.08/43.92/43.92 |
| prose_heavy | `slob/raw` | 42,500 | 9.155 | 64.12 | 202.54/1893.75/1893.75 | 451.42/849.04/849.04 | 104.08/926.17/926.17 |
| prose_heavy | `sqlite/raw` | 57,344 | 2.598 | 49.38 | 13.67/31.62/31.62 | 27.67/40.54/40.54 | 109.08/117.00/117.00 |
| prose_heavy | `sqlite/zlib` | 959 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 688 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 713 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 41,301 | 0.440 | 23.54 | 0.38/0.42/0.42 | 0.83/0.92/0.92 | 0.92/2.08/2.08 |
| prose_heavy | `v1/bzip3` | 1,064 | 0.794 | 17.33 | 0.88/1.71/1.71 | 0.83/0.92/0.92 | 190.46/435.33/435.33 |
| prose_heavy | `v1/raw` | 41,824 | 0.511 | 205.88 | 0.75/0.92/0.92 | 0.71/0.92/0.92 | 62.88/75.75/75.75 |
| prose_heavy | `v2/bzip3.latency` | 10,592 | 1.423 | 151.92 | 0.67/0.92/0.92 | 0.67/1.29/1.29 | 337.62/435.96/435.96 |
| prose_heavy | `v2/raw.latency` | 51,360 | 1.599 | 46.62 | 0.17/0.21/0.21 | 0.29/0.38/0.38 | 0.08/0.08/0.08 |
| repeated | `dict-index/dictzip` | 528 | 8.464 | 36.17 | 1.38/12.62/12.62 | 2.58/11.42/11.42 | 8969.08/10171.92/10171.92 |
| repeated | `dict-index/raw` | 1,893 | 0.608 | 63.92 | 0.50/1.83/1.83 | 0.75/0.96/0.96 | 0.96/5.04/5.04 |
| repeated | `slob/lzma2` | 1,777 | 18.261 | 163.38 | 186.50/1529.83/1529.83 | 539.54/1183.50/1183.50 | 78.38/119.38/119.38 |
| repeated | `slob/raw` | 3,193 | 14.614 | 63.21 | 409.75/483.17/483.17 | 916.50/1312.50/1312.50 | 22.83/50.21/50.21 |
| repeated | `sqlite/raw` | 12,288 | 1.057 | 126.42 | 5.21/6.00/6.00 | 55.54/210.17/210.17 | 6.21/7.25/7.25 |
| repeated | `sqlite/zlib` | 716 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 664 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 609 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 1,994 | 2.539 | 50.25 | 0.92/1.25/1.25 | 1.42/2.08/2.08 | 0.58/0.79/0.79 |
| repeated | `v1/bzip3` | 1,064 | 0.229 | 4.96 | 0.25/0.33/0.33 | 0.33/0.46/0.46 | 82.50/83.08/83.08 |
| repeated | `v1/raw` | 1,632 | 0.030 | 4.88 | 0.25/0.33/0.33 | 0.38/0.50/0.50 | 0.96/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 10,720 | 0.454 | 121.38 | 0.38/1.58/1.58 | 0.38/0.46/0.46 | 218.62/403.92/403.92 |
| repeated | `v2/raw.latency` | 12,128 | 0.560 | 110.21 | 0.33/0.79/0.79 | 0.42/0.50/0.50 | 0.08/0.25/0.25 |
| rich | `dict-index/dictzip` | 426 | 4.446 | 21.04 | 0.54/9.38/9.38 | 1.25/1.58/1.58 | 9124.96/9747.88/9747.88 |
| rich | `dict-index/raw` | 1,727 | 0.208 | 26.79 | 0.71/0.92/0.92 | 1.88/4.33/4.33 | 1.88/2.12/2.12 |
| rich | `slob/lzma2` | 1,662 | 14.737 | 63.83 | 248.38/470.12/470.12 | 510.58/734.71/734.71 | 28.04/49.25/49.25 |
| rich | `slob/raw` | 3,028 | 12.304 | 163.17 | 396.17/593.67/593.67 | 1838.12/4179.17/4179.17 | 49.83/94.50/94.50 |
| rich | `sqlite/raw` | 12,288 | 0.667 | 47.29 | 53.33/73.75/73.75 | 37.33/63.50/63.50 | 16.33/18.88/18.88 |
| rich | `sqlite/zlib` | 632 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 586 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 507 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 1,829 | 0.496 | 20.88 | 0.38/0.42/0.42 | 0.83/1.00/1.00 | 0.33/0.33/0.33 |
| rich | `v1/bzip3` | 1,040 | 0.547 | 8.04 | 0.71/1.83/1.83 | 0.83/0.92/0.92 | 362.62/455.96/455.96 |
| rich | `v1/raw` | 2,352 | 0.045 | 7.29 | 0.17/0.38/0.38 | 0.42/0.54/0.54 | 1.71/1.71/1.71 |
| rich | `v2/bzip3.latency` | 11,168 | 0.730 | 132.46 | 0.29/0.38/0.38 | 0.33/0.62/0.62 | 72.12/116.04/116.04 |
| rich | `v2/raw.latency` | 12,512 | 0.660 | 89.42 | 0.21/0.25/0.25 | 0.29/0.46/0.46 | 0.04/0.17/0.17 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 11.58 | 1.17 | 2.54 | 1.21 | 2.38 | - |
| flat | `dict-index/raw` | 0.42 | 0.29 | 0.25 | 0.46 | 0.83 | - |
| flat | `slob/lzma2` | 558.88 | 219.67 | 211.46 | 454.79 | 465.42 | - |
| flat | `slob/raw` | 579.62 | 156.92 | 967.92 | 1904.21 | 1458.79 | - |
| flat | `sqlite/raw` | 5.62 | 5.29 | 6.04 | 7.96 | 8.33 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.42 | 0.29 | 0.25 | 0.46 | 0.96 | - |
| flat | `v1/bzip3` | 0.38 | 0.17 | 0.29 | 0.38 | 0.46 | - |
| flat | `v1/raw` | 0.46 | 0.17 | 0.33 | 0.46 | 0.62 | - |
| flat | `v2/bzip3.latency` | 0.25 | 0.17 | 0.12 | 0.25 | 0.42 | - |
| flat | `v2/raw.latency` | 0.54 | 0.21 | 0.21 | 0.29 | 0.58 | - |
| pathological_prefix | `dict-index/dictzip` | 443.92 | 9.04 | 5.46 | 1.12 | - | 2.25 |
| pathological_prefix | `dict-index/raw` | 1.17 | 0.88 | 0.62 | 0.83 | - | 1.88 |
| pathological_prefix | `slob/lzma2` | 608.33 | 424.21 | 323.75 | 465.83 | - | 437.67 |
| pathological_prefix | `slob/raw` | 862.83 | 608.92 | 345.75 | 2436.67 | - | 453.12 |
| pathological_prefix | `sqlite/raw` | 12.62 | 11.83 | 14.54 | 17.17 | - | 19.25 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.46 | 0.42 | 0.29 | 0.46 | - | 0.96 |
| pathological_prefix | `v1/bzip3` | 0.29 | 0.08 | 0.25 | 0.50 | - | 0.42 |
| pathological_prefix | `v1/raw` | 0.71 | 0.17 | 0.42 | 0.50 | - | 0.71 |
| pathological_prefix | `v2/bzip3.latency` | 0.42 | 0.08 | 0.17 | 0.29 | - | 0.46 |
| pathological_prefix | `v2/raw.latency` | 0.29 | 0.08 | 0.21 | 0.29 | - | 0.42 |
| prose_heavy | `dict-index/dictzip` | 13.38 | 1.21 | 2.58 | 1.38 | 2.33 | - |
| prose_heavy | `dict-index/raw` | 0.88 | 0.67 | 0.50 | 0.92 | 1.92 | - |
| prose_heavy | `slob/lzma2` | 705.54 | 297.58 | 211.50 | 451.17 | 890.42 | - |
| prose_heavy | `slob/raw` | 1893.75 | 202.54 | 204.62 | 451.42 | 849.04 | - |
| prose_heavy | `sqlite/raw` | 13.67 | 31.62 | 27.67 | 24.75 | 40.54 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.42 | 0.33 | 0.25 | 0.54 | 0.92 | - |
| prose_heavy | `v1/bzip3` | 1.71 | 0.42 | 0.71 | 0.71 | 0.92 | - |
| prose_heavy | `v1/raw` | 0.92 | 0.54 | 0.50 | 0.58 | 0.92 | - |
| prose_heavy | `v2/bzip3.latency` | 0.92 | 0.54 | 0.38 | 0.54 | 1.29 | - |
| prose_heavy | `v2/raw.latency` | 0.21 | 0.17 | 0.12 | 0.21 | 0.38 | - |
| repeated | `dict-index/dictzip` | 12.62 | 1.38 | 2.58 | - | 1.67 | - |
| repeated | `dict-index/raw` | 0.46 | 1.83 | 0.58 | - | 0.75 | - |
| repeated | `slob/lzma2` | 1529.83 | 152.29 | 210.46 | - | 539.54 | - |
| repeated | `slob/raw` | 409.75 | 483.17 | 916.50 | - | 572.33 | - |
| repeated | `sqlite/raw` | 6.00 | 5.21 | 210.17 | - | 13.21 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 1.25 | 0.92 | 0.54 | - | 1.42 | - |
| repeated | `v1/bzip3` | 0.33 | 0.21 | 0.25 | - | 0.33 | - |
| repeated | `v1/raw` | 0.33 | 0.21 | 0.29 | - | 0.38 | - |
| repeated | `v2/bzip3.latency` | 1.58 | 0.17 | 0.21 | - | 0.38 | - |
| repeated | `v2/raw.latency` | 0.79 | 0.21 | 0.25 | - | 0.42 | - |
| rich | `dict-index/dictzip` | 9.38 | 0.54 | 1.58 | 0.62 | 1.25 | - |
| rich | `dict-index/raw` | 0.92 | 0.62 | 0.46 | 0.83 | 4.33 | - |
| rich | `slob/lzma2` | 248.38 | 470.12 | 734.71 | 510.58 | 441.88 | - |
| rich | `slob/raw` | 396.17 | 593.67 | 1838.12 | 1392.08 | 4179.17 | - |
| rich | `sqlite/raw` | 73.75 | 53.33 | 34.58 | 63.50 | 37.33 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.42 | 0.33 | 0.29 | 0.50 | 1.00 | - |
| rich | `v1/bzip3` | 1.83 | 0.33 | 0.71 | 0.67 | 0.92 | - |
| rich | `v1/raw` | 0.38 | 0.17 | 0.33 | 0.42 | 0.54 | - |
| rich | `v2/bzip3.latency` | 0.38 | 0.21 | 0.17 | 0.33 | 0.62 | - |
| rich | `v2/raw.latency` | 0.25 | 0.21 | 0.17 | 0.25 | 0.46 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `15738163737576562899`
- `pathological_prefix` digest values: `3634334578162408469`
- `prose_heavy` digest values: `7281851064008506163`
- `repeated` digest values: `7526048132029780665`
- `rich` digest values: `15738163737576562899`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `56279040` bytes
- `flat.zig.process_peak_rss_bytes`: `15941632` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `56737792` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `17612800` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `57098240` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `27000832` bytes
- `repeated.external.process_peak_rss_bytes`: `56115200` bytes
- `repeated.zig.process_peak_rss_bytes`: `17399808` bytes
- `rich.external.process_peak_rss_bytes`: `56164352` bytes
- `rich.zig.process_peak_rss_bytes`: `28131328` bytes

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
