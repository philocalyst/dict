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
| flat | `dict-index/dictzip` | 433 | 8.042 | 17.83 | 0.58/8.83/8.83 | 1.29/1.88/1.88 | 5862.62/6184.58/6184.58 |
| flat | `dict-index/raw` | 1,727 | 0.191 | 27.04 | 0.33/0.33/0.33 | 0.79/0.88/0.88 | 0.25/0.29/0.29 |
| flat | `slob/lzma2` | 1,662 | 8.980 | 61.29 | 156.21/680.17/680.17 | 434.17/446.96/446.96 | 20.58/36.58/36.58 |
| flat | `slob/raw` | 3,028 | 7.739 | 70.25 | 155.79/219.96/219.96 | 596.46/980.33/980.33 | 21.46/48.17/48.17 |
| flat | `sqlite/raw` | 12,288 | 1.776 | 46.38 | 10.21/13.79/13.79 | 17.08/19.00/19.00 | 5.42/5.67/5.67 |
| flat | `sqlite/zlib` | 632 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 586 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 507 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 1,829 | 0.561 | 22.08 | 0.42/0.42/0.42 | 0.88/0.96/0.96 | 0.33/0.33/0.33 |
| flat | `v1/bzip3` | 1,040 | 1.324 | 3.21 | 0.29/0.33/0.33 | 0.38/0.50/0.50 | 90.00/191.62/191.62 |
| flat | `v1/raw` | 2,352 | 0.089 | 7.46 | 0.12/0.33/0.33 | 0.38/0.50/0.50 | 1.71/1.83/1.83 |
| flat | `v2/bzip3.latency` | 10,528 | 1.465 | 68.38 | 0.29/0.38/0.38 | 0.33/0.62/0.62 | 75.75/84.25/84.25 |
| flat | `v2/raw.latency` | 11,872 | 0.400 | 42.29 | 0.17/0.25/0.25 | 0.33/0.38/0.38 | 0.08/0.08/0.08 |
| pathological_prefix | `dict-index/dictzip` | 593 | 6.667 | 41.79 | 1.54/10.46/10.46 | 2.12/3.04/3.04 | 6878.12/9619.42/9619.42 |
| pathological_prefix | `dict-index/raw` | 1,872 | 0.172 | 25.08 | 0.33/0.38/0.38 | 0.42/0.88/0.88 | 0.25/0.29/0.29 |
| pathological_prefix | `slob/lzma2` | 1,807 | 8.189 | 58.71 | 214.08/228.79/228.79 | 1879.17/2080.79/2080.79 | 80.58/92.88/92.88 |
| pathological_prefix | `slob/raw` | 3,173 | 9.644 | 69.83 | 260.83/724.29/724.29 | 780.29/1587.00/1587.00 | 71.25/103.08/103.08 |
| pathological_prefix | `sqlite/raw` | 12,288 | 0.797 | 47.42 | 5.83/5.88/5.88 | 9.29/9.38/9.38 | 5.71/5.79/5.79 |
| pathological_prefix | `sqlite/zlib` | 628 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 558 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 667 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 1,974 | 0.350 | 21.42 | 0.42/0.42/0.42 | 0.46/1.00/1.00 | 0.33/0.33/0.33 |
| pathological_prefix | `v1/bzip3` | 1,032 | 0.286 | 4.71 | 0.21/0.38/0.38 | 0.29/0.38/0.38 | 78.79/86.83/86.83 |
| pathological_prefix | `v1/raw` | 2,344 | 0.080 | 10.38 | 0.42/0.67/0.67 | 0.46/0.67/0.67 | 2.38/2.38/2.38 |
| pathological_prefix | `v2/bzip3.latency` | 10,656 | 2.969 | 46.67 | 0.17/0.29/0.29 | 0.25/0.38/0.38 | 71.88/72.04/72.04 |
| pathological_prefix | `v2/raw.latency` | 12,000 | 0.273 | 41.46 | 0.21/0.33/0.33 | 0.17/0.42/0.42 | 0.08/0.08/0.08 |
| prose_heavy | `dict-index/dictzip` | 657 | 6.502 | 20.83 | 0.75/10.58/10.58 | 1.17/2.71/2.71 | 7220.42/8758.67/8758.67 |
| prose_heavy | `dict-index/raw` | 41,218 | 0.290 | 26.29 | 0.42/0.54/0.54 | 0.96/1.17/1.17 | 6.92/9.29/9.29 |
| prose_heavy | `slob/lzma2` | 1,741 | 9.377 | 58.71 | 428.04/434.50/434.50 | 557.25/2006.92/2006.92 | 57.08/154.83/154.83 |
| prose_heavy | `slob/raw` | 42,500 | 7.234 | 66.92 | 214.12/1523.38/1523.38 | 455.46/1253.21/1253.21 | 68.67/153.38/153.38 |
| prose_heavy | `sqlite/raw` | 57,344 | 2.705 | 108.79 | 5.92/6.12/6.12 | 9.75/9.88/9.88 | 13.75/18.25/18.25 |
| prose_heavy | `sqlite/zlib` | 959 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 688 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 713 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 41,301 | 0.462 | 23.75 | 0.42/0.42/0.42 | 0.79/0.92/0.92 | 23.62/25.92/25.92 |
| prose_heavy | `v1/bzip3` | 1,064 | 0.590 | 5.29 | 0.50/1.00/1.00 | 0.46/0.54/0.54 | 187.33/215.54/215.54 |
| prose_heavy | `v1/raw` | 41,824 | 0.409 | 139.83 | 0.25/0.33/0.33 | 0.46/0.50/0.50 | 46.00/61.04/61.04 |
| prose_heavy | `v2/bzip3.latency` | 10,592 | 1.389 | 90.83 | 0.38/0.67/0.67 | 0.42/0.54/0.54 | 265.04/266.62/266.62 |
| prose_heavy | `v2/raw.latency` | 51,360 | 0.988 | 46.42 | 0.17/0.21/0.21 | 0.29/0.38/0.38 | 0.04/0.08/0.08 |
| repeated | `dict-index/dictzip` | 535 | 4.925 | 18.50 | 1.25/15.62/15.62 | 1.71/3.21/3.21 | 5039.79/6531.62/6531.62 |
| repeated | `dict-index/raw` | 1,893 | 0.207 | 25.25 | 0.42/0.46/0.46 | 0.50/0.62/0.62 | 0.25/0.29/0.29 |
| repeated | `slob/lzma2` | 1,777 | 12.453 | 146.96 | 187.38/251.42/251.42 | 824.54/1095.29/1095.29 | 20.33/40.50/40.50 |
| repeated | `slob/raw` | 3,193 | 7.755 | 59.71 | 254.42/297.46/297.46 | 588.83/609.58/609.58 | 79.21/82.50/82.50 |
| repeated | `sqlite/raw` | 12,288 | 1.578 | 102.67 | 11.62/15.04/15.04 | 18.96/22.38/22.38 | 11.33/12.54/12.54 |
| repeated | `sqlite/zlib` | 716 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 664 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 609 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 1,994 | 1.178 | 51.00 | 0.83/1.04/1.04 | 1.46/1.88/1.88 | 0.50/0.62/0.62 |
| repeated | `v1/bzip3` | 1,064 | 0.217 | 2.79 | 0.21/0.25/0.25 | 0.29/0.42/0.42 | 80.08/81.92/81.92 |
| repeated | `v1/raw` | 1,632 | 0.029 | 4.88 | 0.25/0.29/0.29 | 0.33/0.58/0.58 | 0.92/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 10,720 | 0.612 | 148.50 | 0.54/0.83/0.83 | 0.75/0.79/0.79 | 191.79/230.33/230.33 |
| repeated | `v2/raw.latency` | 12,128 | 0.312 | 55.17 | 0.17/0.25/0.25 | 0.29/0.33/0.33 | 0.04/0.08/0.08 |
| rich | `dict-index/dictzip` | 433 | 8.349 | 16.58 | 1.17/15.00/15.00 | 2.58/2.62/2.62 | 6877.38/8582.38/8582.38 |
| rich | `dict-index/raw` | 1,727 | 0.188 | 25.17 | 0.33/0.38/0.38 | 0.75/0.83/0.83 | 0.33/0.33/0.33 |
| rich | `slob/lzma2` | 1,662 | 11.126 | 71.33 | 156.42/218.54/218.54 | 1125.92/1776.75/1776.75 | 45.75/80.88/80.88 |
| rich | `slob/raw` | 3,028 | 18.748 | 59.08 | 504.79/539.00/539.00 | 1167.83/2615.67/2615.67 | 52.75/96.96/96.96 |
| rich | `sqlite/raw` | 12,288 | 0.572 | 46.71 | 5.21/5.29/5.29 | 8.17/8.17/8.17 | 5.54/13.38/13.38 |
| rich | `sqlite/zlib` | 632 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 586 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 507 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 1,829 | 0.428 | 20.58 | 0.38/0.42/0.42 | 0.88/1.04/1.04 | 0.33/0.38/0.38 |
| rich | `v1/bzip3` | 1,040 | 0.205 | 5.29 | 0.54/0.75/0.75 | 0.46/0.54/0.54 | 112.21/344.38/344.38 |
| rich | `v1/raw` | 2,352 | 0.042 | 7.33 | 0.25/0.33/0.33 | 0.42/0.50/0.50 | 1.71/1.75/1.75 |
| rich | `v2/bzip3.latency` | 11,168 | 1.660 | 337.17 | 0.71/0.71/0.71 | 0.71/1.17/1.17 | 305.17/458.54/458.54 |
| rich | `v2/raw.latency` | 12,512 | 0.461 | 1178.50 | 0.67/1.04/1.04 | 0.71/1.12/1.12 | 0.12/0.75/0.75 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 8.83 | 0.58 | 1.88 | 0.71 | 1.29 | - |
| flat | `dict-index/raw` | 0.33 | 0.29 | 0.21 | 0.46 | 0.88 | - |
| flat | `slob/lzma2` | 680.17 | 155.96 | 198.71 | 446.96 | 434.17 | - |
| flat | `slob/raw` | 219.96 | 155.79 | 596.46 | 980.33 | 515.50 | - |
| flat | `sqlite/raw` | 10.21 | 13.79 | 19.00 | 17.08 | 8.54 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.42 | 0.38 | 0.21 | 0.50 | 0.96 | - |
| flat | `v1/bzip3` | 0.33 | 0.17 | 0.33 | 0.38 | 0.50 | - |
| flat | `v1/raw` | 0.33 | 0.12 | 0.29 | 0.38 | 0.50 | - |
| flat | `v2/bzip3.latency` | 0.38 | 0.21 | 0.21 | 0.33 | 0.62 | - |
| flat | `v2/raw.latency` | 0.25 | 0.17 | 0.17 | 0.21 | 0.38 | - |
| pathological_prefix | `dict-index/dictzip` | 10.46 | 1.25 | 3.04 | 1.12 | - | 2.12 |
| pathological_prefix | `dict-index/raw` | 0.38 | 0.29 | 0.29 | 0.42 | - | 0.88 |
| pathological_prefix | `slob/lzma2` | 228.79 | 214.08 | 1879.17 | 2080.79 | - | 468.21 |
| pathological_prefix | `slob/raw` | 724.29 | 162.83 | 651.42 | 1587.00 | - | 780.29 |
| pathological_prefix | `sqlite/raw` | 5.88 | 5.83 | 7.17 | 9.29 | - | 9.38 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.42 | 0.42 | 0.38 | 0.46 | - | 1.00 |
| pathological_prefix | `v1/bzip3` | 0.38 | 0.12 | 0.25 | 0.29 | - | 0.38 |
| pathological_prefix | `v1/raw` | 0.67 | 0.17 | 0.46 | 0.46 | - | 0.67 |
| pathological_prefix | `v2/bzip3.latency` | 0.29 | 0.08 | 0.17 | 0.25 | - | 0.38 |
| pathological_prefix | `v2/raw.latency` | 0.33 | 0.08 | 0.17 | 0.17 | - | 0.42 |
| prose_heavy | `dict-index/dictzip` | 10.58 | 0.75 | 2.71 | 0.75 | 1.17 | - |
| prose_heavy | `dict-index/raw` | 0.54 | 0.42 | 0.38 | 0.62 | 1.17 | - |
| prose_heavy | `slob/lzma2` | 434.50 | 428.04 | 557.25 | 2006.92 | 453.71 | - |
| prose_heavy | `slob/raw` | 1523.38 | 214.12 | 204.88 | 455.46 | 1253.21 | - |
| prose_heavy | `sqlite/raw` | 6.12 | 5.92 | 7.21 | 9.75 | 9.88 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.42 | 0.38 | 0.25 | 0.58 | 0.92 | - |
| prose_heavy | `v1/bzip3` | 1.00 | 0.29 | 0.42 | 0.46 | 0.54 | - |
| prose_heavy | `v1/raw` | 0.33 | 0.17 | 0.29 | 0.46 | 0.50 | - |
| prose_heavy | `v2/bzip3.latency` | 0.67 | 0.25 | 0.21 | 0.33 | 0.54 | - |
| prose_heavy | `v2/raw.latency` | 0.21 | 0.17 | 0.12 | 0.21 | 0.38 | - |
| repeated | `dict-index/dictzip` | 15.62 | 1.25 | 3.21 | - | 1.54 | - |
| repeated | `dict-index/raw` | 0.46 | 0.42 | 0.25 | - | 0.50 | - |
| repeated | `slob/lzma2` | 251.42 | 154.83 | 308.38 | - | 824.54 | - |
| repeated | `slob/raw` | 254.42 | 297.46 | 200.92 | - | 588.83 | - |
| repeated | `sqlite/raw` | 15.04 | 11.62 | 14.38 | - | 18.96 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 1.04 | 0.75 | 0.50 | - | 1.46 | - |
| repeated | `v1/bzip3` | 0.25 | 0.21 | 0.29 | - | 0.25 | - |
| repeated | `v1/raw` | 0.29 | 0.21 | 0.29 | - | 0.33 | - |
| repeated | `v2/bzip3.latency` | 0.83 | 0.29 | 0.33 | - | 0.75 | - |
| repeated | `v2/raw.latency` | 0.25 | 0.17 | 0.17 | - | 0.29 | - |
| rich | `dict-index/dictzip` | 15.00 | 1.17 | 2.58 | 1.17 | 2.62 | - |
| rich | `dict-index/raw` | 0.38 | 0.33 | 0.25 | 0.38 | 0.83 | - |
| rich | `slob/lzma2` | 218.54 | 156.42 | 634.96 | 452.04 | 1776.75 | - |
| rich | `slob/raw` | 539.00 | 504.79 | 271.12 | 471.25 | 2615.67 | - |
| rich | `sqlite/raw` | 5.21 | 5.29 | 6.17 | 7.42 | 8.17 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.42 | 0.33 | 0.29 | 0.50 | 1.04 | - |
| rich | `v1/bzip3` | 0.75 | 0.21 | 0.42 | 0.42 | 0.54 | - |
| rich | `v1/raw` | 0.33 | 0.17 | 0.33 | 0.38 | 0.50 | - |
| rich | `v2/bzip3.latency` | 0.71 | 0.38 | 0.42 | 0.71 | 1.17 | - |
| rich | `v2/raw.latency` | 1.04 | 0.38 | 0.58 | 0.54 | 1.12 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `15738163737576562899`
- `pathological_prefix` digest values: `3634334578162408469`
- `prose_heavy` digest values: `7281851064008506163`
- `repeated` digest values: `7526048132029780665`
- `rich` digest values: `15738163737576562899`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `56000512` bytes
- `flat.zig.process_peak_rss_bytes`: `12959744` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `56688640` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `19415040` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `57491456` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `23281664` bytes
- `repeated.external.process_peak_rss_bytes`: `56229888` bytes
- `repeated.zig.process_peak_rss_bytes`: `16777216` bytes
- `rich.external.process_peak_rss_bytes`: `56557568` bytes
- `rich.zig.process_peak_rss_bytes`: `24592384` bytes

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
