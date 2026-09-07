# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `Darwin mileswirht 24.6.0 Darwin Kernel Version 24.6.0: Mon Jan 19 21:59:23 PST 2026; root:xnu-11417.140.69.708.3~1/RELEASE_ARM64_T6030 arm64 arm Darwin` (the run's exact tool versions are in `raw/machine.tsv`).
- Corpus: deterministic fixtures, `16` records, seed `0x4c45583200020001`.
- Repetitions/warmup: Zig `4`/`1`; external `4`/`1`.
- v2 prose presets: `latency`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 646 | 6.769 | 23.08 | 1.04/13.25/13.25 | 3.54/3.71/3.71 | 7029.83/7866.42/7866.42 |
| flat | `dict-index/raw` | 3,445 | 0.181 | 29.92 | 0.33/0.38/0.38 | 1.17/1.33/1.33 | 0.29/0.33/0.33 |
| flat | `slob/lzma2` | 1,963 | 8.676 | 67.88 | 184.79/253.83/253.83 | 634.58/2473.79/2473.79 | 34.08/79.08/79.08 |
| flat | `slob/raw` | 4,874 | 14.443 | 72.58 | 184.21/250.58/250.58 | 1603.12/2247.96/2247.96 | 103.79/171.50/171.50 |
| flat | `sqlite/raw` | 12,288 | 4.205 | 117.46 | 5.79/6.00/6.00 | 9.79/10.00/10.00 | 13.50/70.00/70.00 |
| flat | `sqlite/zlib` | 783 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 710 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 720 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 3,540 | 0.425 | 25.17 | 0.54/1.71/1.71 | 1.29/1.62/1.62 | 0.33/0.38/0.38 |
| flat | `v1/bzip3` | 1,536 | 0.264 | 5.21 | 0.17/0.29/0.29 | 0.50/0.54/0.54 | 202.38/346.79/346.79 |
| flat | `v1/raw` | 4,352 | 0.186 | 16.00 | 0.17/0.38/0.38 | 0.54/0.79/0.79 | 3.46/3.46/3.46 |
| flat | `v2/bzip3.latency` | 11,296 | 1.497 | 254.67 | 0.96/1.25/1.25 | 1.21/1.92/1.92 | 333.04/494.00/494.00 |
| flat | `v2/raw.latency` | 14,176 | 1.159 | 240.54 | 0.67/0.75/0.75 | 1.12/1.38/1.38 | 0.12/0.38/0.38 |
| pathological_prefix | `dict-index/dictzip` | 974 | 6.744 | 41.29 | 1.42/12.46/12.46 | 2.67/3.88/3.88 | 6126.33/8671.46/8671.46 |
| pathological_prefix | `dict-index/raw` | 3,758 | 0.188 | 27.00 | 0.38/0.38/0.38 | 0.46/1.38/1.38 | 0.25/0.29/0.29 |
| pathological_prefix | `slob/lzma2` | 2,276 | 13.749 | 57.79 | 188.58/259.08/259.08 | 623.83/672.17/672.17 | 19.00/32.46/32.46 |
| pathological_prefix | `slob/raw` | 5,187 | 12.103 | 60.04 | 189.04/252.25/252.25 | 618.04/1020.75/1020.75 | 22.25/48.00/48.00 |
| pathological_prefix | `sqlite/raw` | 12,288 | 0.585 | 187.92 | 11.92/12.25/12.25 | 16.75/21.62/21.62 | 15.04/22.92/22.92 |
| pathological_prefix | `sqlite/zlib` | 779 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 682 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 1,048 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 3,853 | 0.452 | 25.38 | 0.62/1.96/1.96 | 0.50/1.42/1.42 | 0.33/0.33/0.33 |
| pathological_prefix | `v1/bzip3` | 1,560 | 0.255 | 7.29 | 0.29/0.29/0.29 | 0.42/0.62/0.62 | 343.79/447.25/447.25 |
| pathological_prefix | `v1/raw` | 4,376 | 0.064 | 14.71 | 0.17/0.33/0.33 | 0.33/0.58/0.58 | 3.42/3.42/3.42 |
| pathological_prefix | `v2/bzip3.latency` | 11,616 | 1.235 | 123.67 | 0.33/0.58/0.58 | 0.29/1.21/1.21 | 83.21/83.92/83.92 |
| pathological_prefix | `v2/raw.latency` | 14,496 | 0.838 | 97.08 | 0.25/0.50/0.50 | 0.25/0.67/0.67 | 0.08/0.08/0.08 |
| prose_heavy | `dict-index/dictzip` | 1,232 | 6.380 | 18.00 | 0.50/10.62/10.62 | 1.46/1.79/1.79 | 5478.00/5652.00/5652.00 |
| prose_heavy | `dict-index/raw` | 82,424 | 0.369 | 30.92 | 0.33/0.33/0.33 | 1.21/1.38/1.38 | 10.38/19.71/19.71 |
| prose_heavy | `slob/lzma2` | 2,304 | 11.224 | 58.75 | 493.75/1699.00/1699.00 | 2397.29/2968.29/2968.29 | 27.71/39.62/39.62 |
| prose_heavy | `slob/raw` | 83,834 | 16.129 | 86.08 | 501.12/1728.83/1728.83 | 1031.79/2694.46/2694.46 | 144.79/149.50/149.50 |
| prose_heavy | `sqlite/raw` | 102,400 | 1.360 | 100.46 | 5.38/5.50/5.50 | 9.58/10.29/10.29 | 32.71/59.33/59.33 |
| prose_heavy | `sqlite/zlib` | 1,408 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 907 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 1,087 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 82,484 | 0.922 | 61.54 | 0.46/1.88/1.88 | 1.38/1.50/1.50 | 0.67/0.75/0.75 |
| prose_heavy | `v1/bzip3` | 1,816 | 3.127 | 8.21 | 0.33/0.42/0.42 | 0.58/0.83/0.83 | 570.33/718.71/718.71 |
| prose_heavy | `v1/raw` | 83,344 | 0.917 | 369.21 | 0.83/1.83/1.83 | 1.25/1.38/1.38 | 102.38/104.50/104.50 |
| prose_heavy | `v2/bzip3.latency` | 11,616 | 3.852 | 143.75 | 0.38/0.46/0.46 | 0.58/1.25/1.25 | 311.25/378.33/378.33 |
| prose_heavy | `v2/raw.latency` | 93,152 | 3.241 | 196.71 | 0.54/0.62/0.62 | 0.62/0.88/0.88 | 0.08/0.29/0.29 |
| repeated | `dict-index/dictzip` | 771 | 5.804 | 46.62 | 1.38/13.17/13.17 | 2.50/2.92/2.92 | 8009.04/10299.54/10299.54 |
| repeated | `dict-index/raw` | 3,793 | 0.556 | 63.96 | 0.83/1.04/1.04 | 1.88/2.00/2.00 | 0.62/0.71/0.71 |
| repeated | `slob/lzma2` | 2,099 | 9.616 | 64.38 | 668.17/2118.58/2118.58 | 608.29/618.88/618.88 | 20.71/43.17/43.17 |
| repeated | `slob/raw` | 5,221 | 11.023 | 63.38 | 611.50/992.21/992.21 | 1979.75/2192.50/2192.50 | 25.62/53.17/53.17 |
| repeated | `sqlite/raw` | 12,288 | 1.831 | 98.71 | 12.58/50.21/50.21 | 30.00/40.25/40.25 | 7.88/17.42/17.42 |
| repeated | `sqlite/zlib` | 844 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 781 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 845 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 3,887 | 0.977 | 25.33 | 3.04/16.62/16.62 | 1.29/1.33/1.33 | 0.42/1.71/1.71 |
| repeated | `v1/bzip3` | 1,496 | 0.372 | 28.00 | 0.38/0.46/0.46 | 0.50/0.58/0.58 | 197.54/800.67/800.67 |
| repeated | `v1/raw` | 2,064 | 0.039 | 7.12 | 0.33/0.42/0.42 | 0.46/0.54/0.54 | 0.96/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 11,360 | 0.731 | 311.54 | 21.08/231.62/231.62 | 1.17/1.42/1.42 | 974.29/1651.00/1651.00 |
| repeated | `v2/raw.latency` | 14,432 | 0.623 | 100.62 | 0.25/0.29/0.29 | 0.42/0.42/0.42 | 0.08/0.12/0.12 |
| rich | `dict-index/dictzip` | 646 | 8.961 | 18.04 | 1.25/10.96/10.96 | 3.29/3.92/3.92 | 8108.50/10271.42/10271.42 |
| rich | `dict-index/raw` | 3,445 | 0.572 | 26.46 | 1.33/2.71/2.71 | 3.17/3.62/3.62 | 0.83/1.54/1.54 |
| rich | `slob/lzma2` | 1,963 | 8.508 | 191.88 | 248.08/278.79/278.79 | 860.71/2039.62/2039.62 | 22.83/46.12/46.12 |
| rich | `slob/raw` | 4,874 | 11.207 | 136.04 | 180.12/243.79/243.79 | 2177.50/2350.46/2350.46 | 23.25/45.88/45.88 |
| rich | `sqlite/raw` | 12,288 | 0.892 | 49.83 | 5.17/5.17/5.17 | 9.92/9.92/9.92 | 24.12/69.92/69.92 |
| rich | `sqlite/zlib` | 783 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 710 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 720 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 3,540 | 0.926 | 74.33 | 0.46/1.62/1.62 | 1.33/1.62/1.62 | 0.33/0.46/0.46 |
| rich | `v1/bzip3` | 1,536 | 0.271 | 6.75 | 0.29/0.38/0.38 | 0.54/0.79/0.79 | 243.04/491.21/491.21 |
| rich | `v1/raw` | 4,352 | 0.130 | 22.92 | 0.46/0.71/0.71 | 1.17/1.46/1.46 | 4.71/4.71/4.71 |
| rich | `v2/bzip3.latency` | 11,936 | 1.199 | 1521.46 | 0.79/1.04/1.04 | 1.21/2.29/2.29 | 233.29/276.71/276.71 |
| rich | `v2/raw.latency` | 14,816 | 0.927 | 302.96 | 0.42/0.62/0.62 | 0.54/0.79/0.79 | 0.08/0.25/0.25 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 13.25 | 1.04 | 2.92 | 1.21 | 3.71 | - |
| flat | `dict-index/raw` | 0.38 | 0.29 | 0.21 | 0.38 | 1.33 | - |
| flat | `slob/lzma2` | 253.83 | 184.79 | 255.92 | 506.83 | 2473.79 | - |
| flat | `slob/raw` | 250.58 | 184.21 | 480.67 | 1603.12 | 2247.96 | - |
| flat | `sqlite/raw` | 5.79 | 6.00 | 6.50 | 7.92 | 10.00 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.54 | 1.71 | 0.25 | 0.46 | 1.62 | - |
| flat | `v1/bzip3` | 0.29 | 0.17 | 0.29 | 0.29 | 0.54 | - |
| flat | `v1/raw` | 0.38 | 0.17 | 0.33 | 0.42 | 0.79 | - |
| flat | `v2/bzip3.latency` | 1.25 | 0.58 | 0.67 | 0.62 | 1.92 | - |
| flat | `v2/raw.latency` | 0.75 | 0.50 | 0.54 | 0.46 | 1.38 | - |
| pathological_prefix | `dict-index/dictzip` | 12.46 | 1.17 | 2.67 | 1.25 | - | 3.88 |
| pathological_prefix | `dict-index/raw` | 0.38 | 0.38 | 0.33 | 0.46 | - | 1.38 |
| pathological_prefix | `slob/lzma2` | 259.08 | 188.58 | 672.17 | 623.83 | - | 617.04 |
| pathological_prefix | `slob/raw` | 252.25 | 188.92 | 388.21 | 1020.75 | - | 618.04 |
| pathological_prefix | `sqlite/raw` | 12.25 | 11.92 | 13.62 | 16.75 | - | 21.62 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.62 | 1.96 | 0.38 | 0.50 | - | 1.42 |
| pathological_prefix | `v1/bzip3` | 0.29 | 0.08 | 0.25 | 0.42 | - | 0.62 |
| pathological_prefix | `v1/raw` | 0.33 | 0.08 | 0.25 | 0.33 | - | 0.58 |
| pathological_prefix | `v2/bzip3.latency` | 0.58 | 0.08 | 0.25 | 0.29 | - | 1.21 |
| pathological_prefix | `v2/raw.latency` | 0.50 | 0.12 | 0.25 | 0.21 | - | 0.67 |
| prose_heavy | `dict-index/dictzip` | 10.62 | 0.50 | 1.46 | 0.88 | 1.79 | - |
| prose_heavy | `dict-index/raw` | 0.33 | 0.29 | 0.33 | 0.46 | 1.38 | - |
| prose_heavy | `slob/lzma2` | 1699.00 | 466.96 | 774.54 | 2397.29 | 2968.29 | - |
| prose_heavy | `slob/raw` | 1728.83 | 480.96 | 658.79 | 2694.46 | 1031.79 | - |
| prose_heavy | `sqlite/raw` | 5.50 | 5.38 | 6.38 | 8.58 | 10.29 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.46 | 1.88 | 0.29 | 0.67 | 1.50 | - |
| prose_heavy | `v1/bzip3` | 0.42 | 0.17 | 0.42 | 0.50 | 0.83 | - |
| prose_heavy | `v1/raw` | 1.83 | 0.42 | 0.71 | 0.92 | 1.38 | - |
| prose_heavy | `v2/bzip3.latency` | 0.46 | 0.29 | 0.25 | 0.50 | 1.25 | - |
| prose_heavy | `v2/raw.latency` | 0.62 | 0.33 | 0.29 | 0.29 | 0.88 | - |
| repeated | `dict-index/dictzip` | 13.17 | 1.38 | 2.92 | - | 1.96 | - |
| repeated | `dict-index/raw` | 1.04 | 0.75 | 0.50 | - | 1.88 | - |
| repeated | `slob/lzma2` | 2118.58 | 453.38 | 280.33 | - | 608.29 | - |
| repeated | `slob/raw` | 992.21 | 503.88 | 612.42 | - | 1979.75 | - |
| repeated | `sqlite/raw` | 12.58 | 50.21 | 29.42 | - | 30.00 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 3.04 | 16.62 | 0.75 | - | 1.29 | - |
| repeated | `v1/bzip3` | 0.46 | 0.21 | 0.29 | - | 0.50 | - |
| repeated | `v1/raw` | 0.42 | 0.21 | 0.25 | - | 0.46 | - |
| repeated | `v2/bzip3.latency` | 1.42 | 231.62 | 0.83 | - | 1.17 | - |
| repeated | `v2/raw.latency` | 0.29 | 0.17 | 0.21 | - | 0.42 | - |
| rich | `dict-index/dictzip` | 10.96 | 1.25 | 2.92 | 1.46 | 3.92 | - |
| rich | `dict-index/raw` | 1.33 | 2.71 | 0.71 | 1.21 | 3.62 | - |
| rich | `slob/lzma2` | 248.08 | 278.79 | 2039.62 | 536.33 | 860.71 | - |
| rich | `slob/raw` | 243.79 | 180.12 | 254.62 | 497.58 | 2350.46 | - |
| rich | `sqlite/raw` | 5.17 | 5.17 | 6.00 | 7.50 | 9.92 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.46 | 1.62 | 0.25 | 0.50 | 1.62 | - |
| rich | `v1/bzip3` | 0.38 | 0.17 | 0.33 | 0.46 | 0.79 | - |
| rich | `v1/raw` | 0.71 | 0.33 | 0.54 | 0.71 | 1.46 | - |
| rich | `v2/bzip3.latency` | 1.04 | 0.54 | 0.67 | 0.58 | 2.29 | - |
| rich | `v2/raw.latency` | 0.62 | 0.29 | 0.38 | 0.25 | 0.79 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `10432184689069109469`
- `pathological_prefix` digest values: `16546272643597045831`
- `prose_heavy` digest values: `9264258618642675565`
- `repeated` digest values: `10420606529423384725`
- `rich` digest values: `10432184689069109469`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `56426496` bytes
- `flat.zig.process_peak_rss_bytes`: `25411584` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `56344576` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `23871488` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `58294272` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `30916608` bytes
- `repeated.external.process_peak_rss_bytes`: `56754176` bytes
- `repeated.zig.process_peak_rss_bytes`: `30015488` bytes
- `rich.external.process_peak_rss_bytes`: `56836096` bytes
- `rich.zig.process_peak_rss_bytes`: `24674304` bytes

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
