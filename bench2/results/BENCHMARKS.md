# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `macOS-15.7.4-arm64-64bit-Mach-O` (the run's exact `uname` and tool versions are in `raw/machine.tsv`).
- Corpus: 4 deterministic fixtures, `2048` records, seed `0x4c45583200020001`.
- Zig repetitions/warmup: `1000`/`200`; external repetitions/warmup: `1000`/`200`.
- v2 prose presets: `latency,balanced,compact`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dictd/dictzip` | 60705 | 7.272 | 1417.08 | 23.29/36.54/86.17 | 216.46/492.58/672.71 | 4324.25/6959.62/13043.71 |
| flat | `dictd/raw` | 447529 | 1.428 | 617.46 | 23.04/38.50/97.04 | 211.50/534.29/690.08 | 7.46/14.46/29.21 |
| flat | `slob/lzma2` | 73774 | 53.989 | 59.96 | 711.21/1434.08/2038.50 | 33450.83/38530.21/44561.42 | 43.21/70.46/162.79 |
| flat | `slob/raw` | 478045 | 70.940 | 69.62 | 706.96/1084.83/1673.79 | 33467.29/42661.00/50562.38 | 55.12/124.58/214.92 |
| flat | `sqlite/raw` | 532480 | 11.857 | 45.92 | 29.21/116.75/182.12 | 665.33/1486.42/1783.42 | 5.42/38.42/90.25 |
| flat | `sqlite/zlib` | 33850 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 22942 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 54332 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 442075 | 3.192 | 635.46 | 40.50/140.46/187.62 | 260.00/718.38/914.46 | 19.12/45.17/105.50 |
| flat | `v1/bzip3` | 130224 | 36.092 | 16298.71 | 0.29/0.71/1.25 | 41.29/68.71/100.96 | 403.08/637.08/892.33 |
| flat | `v1/raw` | 520064 | 37.024 | 20002.49 | 0.38/0.79/1.88 | 41.04/60.08/99.71 | 73.29/109.71/132.21 |
| flat | `v2/bzip3.balanced` | 1518976 | 248.534 | 143.85 | 0.42/0.71/0.83 | 2701.33/3059.42/3811.12 | 100.88/368.42/538.79 |
| flat | `v2/bzip3.compact` | 1518976 | 943.543 | 126.61 | 0.46/1.04/1.71 | 2928.17/4829.46/9246.08 | 420.62/819.54/1083.38 |
| flat | `v2/bzip3.latency` | 1518976 | 190.771 | 98.54 | 0.46/1.21/1.79 | 2722.33/3348.42/3994.42 | 73.17/143.75/215.88 |
| flat | `v2/raw.balanced` | 1652352 | 115.781 | 98.21 | 0.42/1.04/1.67 | 2726.96/3660.42/5025.04 | 0.04/0.12/0.79 |
| flat | `v2/raw.compact` | 1652352 | 210.098 | 136.56 | 0.79/1.46/1.83 | 2860.38/4494.46/6977.17 | 0.04/0.17/0.33 |
| flat | `v2/raw.latency` | 1652352 | 112.377 | 95.72 | 0.42/0.67/0.79 | 2725.17/3416.42/4230.08 | 0.04/0.12/0.21 |
| prose_heavy | `dictd/dictzip` | 140490 | 26.778 | 1554.71 | 23.33/29.88/76.58 | 209.08/303.25/379.62 | 5313.29/12773.96/23011.54 |
| prose_heavy | `dictd/raw` | 10556916 | 46.975 | 2055.83 | 23.67/29.29/80.54 | 218.33/399.08/626.62 | 8.79/16.42/34.00 |
| prose_heavy | `slob/lzma2` | 123118 | 287.023 | 69.46 | 791.75/1709.79/2359.25 | 37952.54/60290.88/76074.33 | 22.50/116.62/198.42 |
| prose_heavy | `slob/raw` | 10585293 | 209.293 | 68.75 | 756.62/1381.83/1744.50 | 37386.00/51368.62/66775.42 | 43.83/324.46/462.04 |
| prose_heavy | `sqlite/raw` | 11259904 | 85.414 | 45.88 | 28.29/38.12/87.12 | 1329.42/3028.75/4112.67 | 13.58/48.79/118.38 |
| prose_heavy | `sqlite/zlib` | 96235 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 43837 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 95077 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 10546907 | 52.081 | 2134.54 | 40.75/50.42/139.08 | 255.83/638.25/928.33 | 22.92/79.71/130.62 |
| prose_heavy | `v1/bzip3` | 175728 | 422.253 | 15832.47 | 0.25/0.42/0.50 | 41.04/46.96/59.96 | 259.38/347.38/497.38 |
| prose_heavy | `v1/raw` | 10632768 | 454.328 | 52423.71 | 0.25/0.46/0.54 | 41.17/51.17/92.54 | 69.08/96.00/131.67 |
| prose_heavy | `v2/bzip3.balanced` | 1593920 | 400.205 | 91.82 | 0.42/0.75/0.83 | 2715.83/3085.54/3380.33 | 119.62/217.83/369.92 |
| prose_heavy | `v2/bzip3.compact` | 1593920 | 951.791 | 93.94 | 0.42/0.71/0.83 | 2763.83/3529.00/4390.12 | 431.79/764.04/901.96 |
| prose_heavy | `v2/bzip3.latency` | 1593920 | 380.528 | 94.00 | 0.42/1.04/1.71 | 2708.17/3243.38/3901.04 | 109.00/181.75/288.79 |
| prose_heavy | `v2/raw.balanced` | 11757184 | 210.144 | 724.51 | 0.42/0.67/0.79 | 2713.88/3164.50/3580.21 | 0.29/0.50/0.71 |
| prose_heavy | `v2/raw.compact` | 11757184 | 180.162 | 811.23 | 0.42/0.83/1.46 | 2719.33/3394.88/5077.88 | 0.29/0.67/1.17 |
| prose_heavy | `v2/raw.latency` | 11757184 | 225.390 | 832.14 | 0.42/0.75/1.00 | 2714.25/3644.54/5778.79 | 0.29/0.75/1.58 |
| repeated | `dictd/dictzip` | 57876 | 8.668 | 529.67 | 22.92/40.62/93.88 | 206.33/331.79/591.79 | 3891.62/5291.88/7039.71 |
| repeated | `dictd/raw` | 481456 | 4.899 | 639.75 | 23.29/87.21/687.04 | 221.83/727.58/2285.08 | 7.79/18.04/30.79 |
| repeated | `slob/lzma2` | 74028 | 61.673 | 60.04 | 746.50/1322.67/1716.92 | 65417.92/85405.54/94498.88 | 45.92/171.92/240.46 |
| repeated | `slob/raw` | 511923 | 57.220 | 79.71 | 788.83/1545.42/2106.88 | 36186.08/45290.50/285828.79 | 54.00/111.04/244.29 |
| repeated | `sqlite/raw` | 561152 | 9.085 | 53.25 | 27.21/88.71/150.92 | 602.00/1190.96/1591.17 | 5.08/28.04/61.46 |
| repeated | `sqlite/zlib` | 30997 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 23139 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 50313 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 475953 | 1.812 | 1561.71 | 68.92/632.25/12247.46 | 259.75/1027.54/1885.83 | 21.12/85.00/233.17 |
| repeated | `v1/bzip3` | 125888 | 17.735 | 16885.76 | 0.21/0.42/0.54 | 41.25/84.08/105.92 | 83.33/225.17/373.88 |
| repeated | `v1/raw` | 126456 | 18.752 | 18817.03 | 0.25/0.42/0.50 | 41.29/75.00/106.71 | 0.96/1.46/1.83 |
| repeated | `v2/bzip3.balanced` | 1535680 | 247.992 | 93.36 | 0.42/0.71/0.83 | 2850.83/3858.75/4880.88 | 85.12/248.21/418.54 |
| repeated | `v2/bzip3.compact` | 1535680 | 749.949 | 117.68 | 0.42/0.88/1.62 | 3125.75/5179.21/8175.46 | 637.12/1109.04/1514.42 |
| repeated | `v2/bzip3.latency` | 1535680 | 270.249 | 102.14 | 0.42/0.75/0.83 | 2859.54/3850.83/4841.62 | 77.67/162.08/263.17 |
| repeated | `v2/raw.balanced` | 1686208 | 117.468 | 109.71 | 0.42/0.75/0.88 | 2839.04/3676.50/5310.79 | 0.04/0.12/0.21 |
| repeated | `v2/raw.compact` | 1686208 | 121.176 | 105.81 | 0.42/0.67/0.79 | 2996.38/4425.33/5453.92 | 0.04/0.21/0.33 |
| repeated | `v2/raw.latency` | 1686208 | 127.842 | 127.24 | 0.42/0.71/0.83 | 2842.00/3784.54/5023.96 | 0.04/0.21/0.33 |
| rich | `dictd/dictzip` | 60705 | 8.137 | 608.21 | 23.58/77.58/114.50 | 234.67/610.25/856.92 | 4064.71/5981.12/7406.79 |
| rich | `dictd/raw` | 447529 | 1.827 | 686.17 | 23.33/54.04/95.88 | 258.79/647.75/752.38 | 7.96/25.38/39.62 |
| rich | `slob/lzma2` | 73774 | 55.565 | 63.08 | 772.29/1556.33/1992.88 | 38103.88/57747.17/72494.79 | 44.46/150.42/303.21 |
| rich | `slob/raw` | 478045 | 49.019 | 88.38 | 925.54/2529.83/3690.75 | 37112.92/65397.71/92871.83 | 55.75/155.83/250.83 |
| rich | `sqlite/raw` | 532480 | 6.276 | 43.75 | 27.33/49.92/119.25 | 599.25/971.67/1384.21 | 4.75/13.17/44.62 |
| rich | `sqlite/zlib` | 33850 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 22942 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 54332 | 0.000 | 0.00 | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 442075 | 1.324 | 666.67 | 40.33/116.00/181.33 | 262.96/633.88/819.38 | 19.79/55.08/113.50 |
| rich | `v1/bzip3` | 130224 | 66.800 | 20491.57 | 0.33/0.79/1.29 | 41.25/97.29/123.17 | 485.46/927.42/1070.50 |
| rich | `v1/raw` | 520064 | 38.638 | 24333.67 | 0.38/0.79/1.46 | 41.33/99.00/122.62 | 73.54/117.21/144.62 |
| rich | `v2/bzip3.balanced` | 2338048 | 264.458 | 161.35 | 0.42/0.92/1.75 | 2831.54/3704.79/4291.88 | 87.12/310.46/448.54 |
| rich | `v2/bzip3.compact` | 2338048 | 739.002 | 147.64 | 0.46/0.83/1.25 | 2841.92/3618.33/4247.25 | 433.83/810.33/990.08 |
| rich | `v2/bzip3.latency` | 2338048 | 246.248 | 232.46 | 0.42/0.75/0.88 | 3814.12/11884.50/20819.79 | 144.08/567.50/1630.96 |
| rich | `v2/raw.balanced` | 2471296 | 209.105 | 180.34 | 0.42/0.71/0.83 | 3176.38/5519.75/6864.04 | 0.04/0.17/0.21 |
| rich | `v2/raw.compact` | 2471296 | 133.381 | 181.87 | 0.46/0.83/1.71 | 2861.58/4101.12/4881.04 | 0.04/0.12/0.92 |
| rich | `v2/raw.latency` | 2471296 | 162.992 | 186.44 | 0.42/0.83/1.58 | 4467.38/7509.21/12265.12 | 0.04/0.12/0.21 |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `16769177117638402855`
- `prose_heavy` digest values: `2609159946720600431`
- `repeated` digest values: `1239717369033652253`
- `rich` digest values: `16769177117638402855`

Process peak RSS (from `/usr/bin/time -l`; Zig and external runs are separate processes):
- `flat.external.process_peak_rss_bytes`: `48252800` bytes
- `flat.zig.process_peak_rss_bytes`: `35128768` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `93914816` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `79414848` bytes
- `repeated.external.process_peak_rss_bytes`: `48416512` bytes
- `repeated.zig.process_peak_rss_bytes`: `39585280` bytes
- `rich.external.process_peak_rss_bytes`: `49317760` bytes
- `rich.zig.process_peak_rss_bytes`: `31098432` bytes

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
- The v1/v2 comparison is an equal lexical projection. v2's rich fixture adds graph assertions; external formats intentionally receive only the same flat key/definition projection, so those rows do not measure graph preservation.
- SQLite zlib/zstd and StarDict gzip rows report artifact sizes only: whole-file compression destroys page/index random access unless a decompression staging policy is chosen, so query latency is not fabricated.
- dictd raw uses the standard UTF-8 `.index` offset layout generated by the harness; dictzip render invokes Nix `dictzip` range decompression. It does not start a dictd daemon, avoiding network/service noise.
- SLOB is Python reference SLOB with raw and lzma2 compression. Its UUID/timestamp metadata is not byte-for-byte deterministic even though the corpus and semantic digest are.
- Timings are single-process wall-clock samples after deterministic warmup on one otherwise uncontrolled host; use p95/p99 and raw TSV for comparisons, not a claim of universal performance.

Raw outputs: `results/raw/*.tsv`; machine-readable output: `results/benchmark.json`; generated artifacts: `results/artifacts/<fixture>/`.
