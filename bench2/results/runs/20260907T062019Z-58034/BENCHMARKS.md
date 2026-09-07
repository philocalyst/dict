# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `Darwin mileswirht 24.6.0 Darwin Kernel Version 24.6.0: Mon Jan 19 21:59:23 PST 2026; root:xnu-11417.140.69.708.3~1/RELEASE_ARM64_T6030 arm64 arm Darwin` (the run's exact tool versions are in `raw/machine.tsv`).
- Corpus: deterministic fixtures, `2048` records, seed `0x4c45583200020001`.
- Repetitions/warmup: Zig `1000`/`200`; external `1000`/`200`.
- v2 prose presets: `latency,balanced,compact`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 61,414 | 8.328 | 597.46 | 0.96/4.62/13.50 | 125.54/440.12/1279.00 | 5708.21/8612.88/10710.00 |
| flat | `dict-index/raw` | 448,231 | 0.820 | 1348.75 | 0.62/2.29/6.96 | 124.04/384.54/1234.46 | 0.75/2.50/8.00 |
| flat | `slob/lzma2` | 74,476 | 82.763 | 69.92 | 459.67/1820.79/2594.83 | 34757.33/65188.29/81270.71 | 43.75/157.83/620.50 |
| flat | `slob/raw` | 478,747 | 60.077 | 157.17 | 474.54/2236.33/3433.62 | 39158.08/76128.79/90538.58 | 59.50/334.08/2338.33 |
| flat | `sqlite/raw` | 532,480 | 7.061 | 50.08 | 6.17/47.54/115.79 | 467.29/1442.21/2079.12 | 10.54/31.21/78.33 |
| flat | `sqlite/zlib` | 35,597 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 24,732 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 55,034 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 442,777 | 1.557 | 948.58 | 0.79/3.46/10.29 | 138.71/437.17/1203.33 | 0.46/1.46/5.21 |
| flat | `v1/bzip3` | 130,920 | 47.233 | 20671.33 | 0.50/1.21/2.00 | 41.62/107.42/315.58 | 809.50/2844.00/17481.38 |
| flat | `v1/raw` | 520,760 | 54.747 | 23311.04 | 0.33/0.62/1.88 | 41.42/55.54/146.42 | 73.38/126.88/775.88 |
| flat | `v2/bzip3.balanced` | 235,168 | 181.555 | 39905.54 | 0.38/0.88/1.58 | 56.75/125.00/509.67 | 2231.17/4121.88/5274.42 |
| flat | `v2/bzip3.compact` | 234,336 | 115.109 | 43452.96 | 0.42/1.17/1.83 | 56.79/168.58/591.79 | 5235.54/8416.00/9910.62 |
| flat | `v2/bzip3.latency` | 237,984 | 134.431 | 38567.12 | 0.38/1.08/1.46 | 56.67/130.25/423.08 | 685.25/1877.54/2264.50 |
| flat | `v2/raw.balanced` | 636,960 | 104.596 | 40406.12 | 0.50/1.25/1.88 | 56.54/146.04/421.79 | 0.79/1.62/1.71 |
| flat | `v2/raw.compact` | 636,896 | 102.872 | 34286.29 | 0.42/1.08/1.62 | 56.96/127.17/457.00 | 1.21/2.33/2.38 |
| flat | `v2/raw.latency` | 637,344 | 139.185 | 42010.58 | 0.42/1.25/4.00 | 56.42/135.33/300.88 | 0.25/0.29/0.33 |
| pathological_prefix | `dict-index/dictzip` | 103,025 | 7.032 | 552.25 | 0.62/2.62/7.83 | 5.58/359.38/497.96 | 4568.54/6459.62/8084.08 |
| pathological_prefix | `dict-index/raw` | 489,827 | 1.721 | 563.38 | 0.58/1.92/5.33 | 4.54/177.08/382.25 | 0.29/1.00/3.25 |
| pathological_prefix | `slob/lzma2` | 116,072 | 75.006 | 62.83 | 475.29/1122.75/1341.96 | 1453.62/48819.71/51744.46 | 44.04/136.38/195.75 |
| pathological_prefix | `slob/raw` | 520,343 | 82.719 | 74.96 | 860.08/1823.33/3117.83 | 2460.33/101886.00/302000.29 | 58.38/233.96/446.75 |
| pathological_prefix | `sqlite/raw` | 602,112 | 5.349 | 46.71 | 5.62/11.54/34.92 | 29.58/512.79/993.29 | 5.04/11.79/29.12 |
| pathological_prefix | `sqlite/zlib` | 33,342 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 22,723 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 96,645 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 484,373 | 1.232 | 726.04 | 0.58/1.04/3.08 | 4.54/206.21/411.71 | 0.29/1.08/3.29 |
| pathological_prefix | `v1/bzip3` | 134,888 | 36.171 | 16869.88 | 0.42/1.21/1.50 | 0.88/78.42/111.54 | 426.04/934.75/1169.71 |
| pathological_prefix | `v1/raw` | 524,728 | 38.517 | 18617.88 | 0.38/0.62/1.12 | 0.79/36.71/82.67 | 73.29/112.04/136.62 |
| pathological_prefix | `v2/bzip3.balanced` | 280,352 | 113.051 | 30555.46 | 0.42/1.29/1.75 | 0.71/63.75/134.12 | 1844.12/2532.29/3178.83 |
| pathological_prefix | `v2/bzip3.compact` | 279,520 | 96.658 | 26938.92 | 0.38/0.71/0.79 | 0.62/59.00/61.25 | 3152.92/3975.25/4711.42 |
| pathological_prefix | `v2/bzip3.latency` | 283,168 | 107.522 | 29565.42 | 0.42/1.50/3.79 | 0.71/116.38/146.00 | 633.38/1118.25/1287.75 |
| pathological_prefix | `v2/raw.balanced` | 682,144 | 97.436 | 28900.96 | 0.42/1.25/1.83 | 0.71/69.17/135.12 | 0.79/1.62/1.67 |
| pathological_prefix | `v2/raw.compact` | 682,080 | 82.297 | 28436.42 | 0.42/1.04/1.79 | 0.71/69.62/148.83 | 1.21/1.29/1.29 |
| pathological_prefix | `v2/raw.latency` | 682,528 | 97.913 | 32397.17 | 0.46/1.42/7.54 | 0.67/87.79/165.38 | 0.25/0.33/0.58 |
| prose_heavy | `dict-index/dictzip` | 141,199 | 50.974 | 655.54 | 0.75/3.50/9.71 | 128.25/415.00/941.96 | 6324.08/9936.50/12157.58 |
| prose_heavy | `dict-index/raw` | 10,557,618 | 8.377 | 2788.75 | 0.83/4.33/10.88 | 130.50/447.46/1414.04 | 4.88/14.08/33.92 |
| prose_heavy | `slob/lzma2` | 123,820 | 1339.581 | 63.71 | 773.58/10011.79/38539.08 | 33308.42/78452.62/136083.00 | 21.83/118.96/211.29 |
| prose_heavy | `slob/raw` | 10,585,995 | 78.674 | 170.46 | 518.25/1947.79/2967.04 | 42613.75/82740.25/291223.54 | 134.71/1353.50/15611.96 |
| prose_heavy | `sqlite/raw` | 11,259,904 | 37.395 | 47.54 | 6.75/90.17/279.88 | 475.21/1552.08/2382.25 | 38.79/210.08/1157.71 |
| prose_heavy | `sqlite/zlib` | 98,801 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 46,173 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 95,779 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 10,547,609 | 13.758 | 3114.42 | 0.92/4.88/11.04 | 142.17/494.17/1450.17 | 3.04/12.58/31.00 |
| prose_heavy | `v1/bzip3` | 176,424 | 550.125 | 19480.04 | 0.33/0.54/1.00 | 41.46/43.79/183.08 | 262.88/854.96/1518.17 |
| prose_heavy | `v1/raw` | 10,633,464 | 561.906 | 63212.00 | 0.33/0.71/1.33 | 41.54/87.83/181.50 | 69.17/107.50/891.12 |
| prose_heavy | `v2/bzip3.balanced` | 256,224 | 578.099 | 35090.38 | 0.38/0.83/1.46 | 56.54/126.25/209.08 | 1311.25/2574.21/3106.96 |
| prose_heavy | `v2/bzip3.compact` | 241,248 | 546.453 | 45681.25 | 0.54/1.21/1sl.83 | 56.33/164.21/538.75 | 20993.25/24871.42/26842.46 |
| prose_heavy | `v2/bzip3.latency` | 293,024 | 609.994 | 34983.17 | 0.38/0.79/1.46 | 56.46/121.21/255.96 | 337.92/1008.29/1730.54 |
| prose_heavy | `v2/raw.balanced` | 10,747,936 | 440.027 | 34751.25 | 0.33/0.54/0.67 | 56.33/126.17/265.04 | 0.08/0.33/0.62 |
| prose_heavy | `v2/raw.compact` | 10,745,184 | 463.347 | 35762.42 | 0.33/0.96/1.71 | 56.50/60.62/176.67 | 0.54/0.67/1.29 |
| prose_heavy | `v2/raw.latency` | 10,757,280 | 455.539 | 34261.88 | 0.33/0.67/1.25 | 56.46/126.04/397.08 | 0.04/0.25/0.42 |
| repeated | `dict-index/dictzip` | 66,050 | 7.243 | 645.88 | 0.67/1.54/4.46 | 61.67/189.42/262.04 | 3990.29/5439.62/6589.88 |
| repeated | `dict-index/raw` | 490,328 | 0.833 | 585.71 | 0.58/1.12/3.08 | 61.71/99.38/201.00 | 0.46/1.12/3.25 |
| repeated | `slob/lzma2` | 82,898 | 53.689 | 61.50 | 470.33/848.29/1087.25 | 15994.79/24227.25/30675.42 | 42.54/123.46/189.00 |
| repeated | `slob/raw` | 520,793 | 47.098 | 64.21 | 495.08/1197.62/1653.88 | 16575.75/22650.46/29796.08 | 52.92/87.12/201.17 |
| repeated | `sqlite/raw` | 569,344 | 7.907 | 47.29 | 5.79/13.12/58.88 | 231.71/412.83/645.17 | 5.00/10.96/21.50 |
| repeated | `sqlite/zlib` | 29,697 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 21,521 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 58,976 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 484,823 | 1.360 | 686.62 | 0.92/3.75/6.67 | 67.04/88.29/203.08 | 0.50/1.08/3.92 |
| repeated | `v1/bzip3` | 116,688 | 18.084 | 15858.88 | 0.33/0.62/0.88 | 20.96/22.88/43.54 | 84.04/178.21/291.25 |
| repeated | `v1/raw` | 117,256 | 20.972 | 16408.29 | 0.33/0.62/0.96 | 20.88/22.79/32.33 | 0.96/1.00/1.46 |
| repeated | `v2/bzip3.balanced` | 226,976 | 88.280 | 27248.33 | 0.38/0.96/1.46 | 28.12/30.12/63.17 | 1368.88/1804.08/2364.04 |
| repeated | `v2/bzip3.compact` | 226,080 | 89.319 | 29086.62 | 0.38/0.75/1.54 | 28.29/47.50/78.25 | 2748.92/4030.12/4932.25 |
| repeated | `v2/bzip3.latency` | 229,536 | 98.950 | 28866.00 | 0.42/1.12/1.79 | 28.50/65.38/94.96 | 495.58/770.75/915.50 |
| repeated | `v2/raw.balanced` | 663,072 | 79.368 | 27293.79 | 0.38/0.71/1.25 | 28.29/31.00/78.92 | 0.71/0.75/0.83 |
| repeated | `v2/raw.compact` | 663,008 | 78.051 | 28082.58 | 0.38/0.62/0.83 | 28.62/32.25/74.67 | 1.21/2.38/2.96 |
| repeated | `v2/raw.latency` | 663,456 | 82.097 | 27844.12 | 0.38/1.00/1.46 | 28.12/30.25/63.12 | 0.25/0.50/0.58 |
| rich | `dict-index/dictzip` | 61,414 | 8.577 | 513.38 | 0.58/1.42/5.29 | 124.04/227.67/377.33 | 4159.75/5760.54/7610.62 |
| rich | `dict-index/raw` | 448,231 | 0.823 | 559.25 | 0.58/1.54/3.71 | 122.33/288.58/401.50 | 0.33/1.04/3.21 |
| rich | `slob/lzma2` | 74,476 | 79.418 | 61.67 | 434.54/1092.21/1296.21 | 33936.21/48125.92/56304.38 | 44.08/152.00/215.75 |
| rich | `slob/raw` | 478,747 | 48.414 | 66.96 | 434.54/1130.25/1357.17 | 33384.00/49667.38/60510.67 | 56.08/180.83/240.92 |
| rich | `sqlite/raw` | 532,480 | 6.131 | 111.46 | 5.62/13.96/53.67 | 454.33/970.50/1165.54 | 5.17/18.67/38.08 |
| rich | `sqlite/zlib` | 35,597 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 24,732 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 55,034 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 442,777 | 1.703 | 677.88 | 0.67/1.96/4.58 | 132.88/284.79/431.58 | 0.33/1.12/3.79 |
| rich | `v1/bzip3` | 130,920 | 34.902 | 16348.42 | 0.62/1.17/1.79 | 41.54/105.42/191.38 | 668.54/1015.92/1180.62 |
| rich | `v1/raw` | 520,760 | 36.646 | 16978.96 | 0.33/0.54/0.83 | 41.42/89.33/114.46 | 73.29/103.83/125.00 |
| rich | `v2/bzip3.balanced` | 288,096 | 210.631 | 75397.96 | 0.33/0.62/0.75 | 56.54/60.79/128.88 | 2012.62/2951.04/3748.58 |
| rich | `v2/bzip3.compact` | 287,392 | 173.146 | 67841.38 | 0.38/1.04/1.50 | 55.88/116.08/134.54 | 3536.75/5420.88/6923.08 |
| rich | `v2/bzip3.latency` | 290,336 | 218.195 | 74920.62 | 0.46/1.21/1.58 | 56.42/136.25/186.96 | 648.29/1132.33/1368.17 |
| rich | `v2/raw.balanced` | 688,480 | 176.517 | 80438.42 | 0.38/0.92/1.46 | 56.71/125.88/153.54 | 0.79/1.54/1.67 |
| rich | `v2/raw.compact` | 688,416 | 159.638 | 69242.62 | 0.33/0.58/0.67 | 56.04/67.08/137.00 | 1.25/2.50/2.79 |
| rich | `v2/raw.latency` | 688,864 | 172.119 | 88656.21 | 0.33/0.62/1.21 | 56.79/125.08/171.04 | 0.25/0.29/0.33 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 1.12 | 0.50 | 5.92 | 6.54 | 146.21 | - |
| flat | `dict-index/raw` | 0.71 | 0.42 | 3.79 | 4.50 | 137.88 | - |
| flat | `slob/lzma2` | 468.67 | 406.96 | 987.29 | 1141.71 | 52116.96 | - |
| flat | `slob/raw` | 496.08 | 417.33 | 1301.54 | 1378.25 | 58476.75 | - |
| flat | `sqlite/raw` | 6.25 | 5.88 | 51.25 | 54.67 | 555.25 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 1.00 | 0.46 | 3.96 | 4.88 | 152.42 | - |
| flat | `v1/bzip3` | 0.62 | 0.42 | 0.54 | 0.88 | 43.08 | - |
| flat | `v1/raw` | 0.42 | 0.25 | 0.50 | 0.67 | 42.75 | - |
| flat | `v2/bzip3.balanced` | 0.46 | 0.25 | 0.33 | 0.58 | 58.92 | - |
| flat | `v2/bzip3.compact` | 0.50 | 0.29 | 0.54 | 0.92 | 125.46 | - |
| flat | `v2/bzip3.latency` | 0.46 | 0.25 | 0.33 | 0.62 | 59.92 | - |
| flat | `v2/raw.balanced` | 0.58 | 0.33 | 0.38 | 0.71 | 61.29 | - |
| flat | `v2/raw.compact` | 0.50 | 0.29 | 0.33 | 0.58 | 58.75 | - |
| flat | `v2/raw.latency` | 0.50 | 0.29 | 0.33 | 0.58 | 59.12 | - |
| pathological_prefix | `dict-index/dictzip` | 0.75 | 0.42 | 2.38 | 1.79 | - | 134.38 |
| pathological_prefix | `dict-index/raw` | 0.71 | 0.38 | 2.08 | 1.67 | - | 129.88 |
| pathological_prefix | `slob/lzma2` | 481.12 | 427.54 | 943.58 | 1059.29 | - | 45161.75 |
| pathological_prefix | `slob/raw` | 884.92 | 824.58 | 1455.62 | 1556.79 | - | 62714.58 |
| pathological_prefix | `sqlite/raw` | 5.75 | 5.42 | 21.25 | 10.29 | - | 476.62 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.71 | 0.42 | 2.21 | 1.79 | - | 143.29 |
| pathological_prefix | `v1/bzip3` | 0.54 | 0.17 | 0.38 | 0.92 | - | 35.92 |
| pathological_prefix | `v1/raw` | 0.46 | 0.17 | 0.33 | 0.88 | - | 35.29 |
| pathological_prefix | `v2/bzip3.balanced` | 0.58 | 0.17 | 0.21 | 0.79 | - | 57.54 |
| pathological_prefix | `v2/bzip3.compact` | 0.50 | 0.17 | 0.21 | 0.75 | - | 58.04 |
| pathological_prefix | `v2/bzip3.latency` | 0.58 | 0.17 | 0.21 | 0.79 | - | 58.75 |
| pathological_prefix | `v2/raw.balanced` | 0.58 | 0.17 | 0.21 | 0.79 | - | 59.17 |
| pathological_prefix | `v2/raw.compact` | 0.54 | 0.17 | 0.21 | 0.75 | - | 59.42 |
| pathological_prefix | `v2/raw.latency` | 0.58 | 0.17 | 0.21 | 0.75 | - | 58.29 |
| prose_heavy | `dict-index/dictzip` | 0.88 | 0.46 | 5.38 | 6.25 | 146.96 | - |
| prose_heavy | `dict-index/raw` | 1.04 | 0.46 | 7.12 | 9.21 | 152.33 | - |
| prose_heavy | `slob/lzma2` | 833.67 | 648.29 | 885.29 | 1075.58 | 47592.25 | - |
| prose_heavy | `slob/raw` | 540.75 | 461.21 | 1264.38 | 1577.21 | 61489.79 | - |
| prose_heavy | `sqlite/raw` | 6.83 | 6.46 | 72.33 | 78.33 | 794.29 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 1.17 | 0.50 | 6.25 | 8.12 | 163.92 | - |
| prose_heavy | `v1/bzip3` | 0.42 | 0.25 | 0.50 | 0.71 | 42.21 | - |
| prose_heavy | `v1/raw` | 0.42 | 0.25 | 0.50 | 0.71 | 42.42 | - |
| prose_heavy | `v2/bzip3.balanced` | 0.46 | 0.25 | 0.33 | 0.58 | 59.58 | - |
| prose_heavy | `v2/bzip3.compact` | 0.67 | 0.42 | 0.38 | 0.75 | 60.46 | - |
| prose_heavy | `v2/bzip3.latency` | 0.46 | 0.25 | 0.33 | 0.58 | 59.12 | - |
| prose_heavy | `v2/raw.balanced` | 0.42 | 0.21 | 0.33 | 0.58 | 58.62 | - |
| prose_heavy | `v2/raw.compact` | 0.42 | 0.21 | 0.29 | 0.54 | 58.75 | - |
| prose_heavy | `v2/raw.latency` | 0.42 | 0.25 | 0.33 | 0.54 | 59.00 | - |
| repeated | `dict-index/dictzip` | 0.79 | 0.42 | 1.83 | - | 65.54 | - |
| repeated | `dict-index/raw` | 0.67 | 0.42 | 1.79 | - | 65.42 | - |
| repeated | `slob/lzma2` | 493.92 | 397.29 | 839.50 | - | 18577.79 | - |
| repeated | `slob/raw` | 501.04 | 400.04 | 836.50 | - | 18414.75 | - |
| repeated | `sqlite/raw` | 5.92 | 5.42 | 20.42 | - | 248.46 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 1.08 | 0.42 | 1.67 | - | 71.46 | - |
| repeated | `v1/bzip3` | 0.42 | 0.21 | 0.46 | - | 21.79 | - |
| repeated | `v1/raw` | 0.42 | 0.21 | 0.46 | - | 21.42 | - |
| repeated | `v2/bzip3.balanced` | 0.42 | 0.21 | 0.25 | - | 28.83 | - |
| repeated | `v2/bzip3.compact` | 0.46 | 0.21 | 0.25 | - | 29.08 | - |
| repeated | `v2/bzip3.latency` | 0.50 | 0.25 | 0.29 | - | 29.79 | - |
| repeated | `v2/raw.balanced` | 0.42 | 0.21 | 0.25 | - | 29.71 | - |
| repeated | `v2/raw.compact` | 0.42 | 0.21 | 0.25 | - | 29.58 | - |
| repeated | `v2/raw.latency` | 0.46 | 0.21 | 0.25 | - | 29.00 | - |
| rich | `dict-index/dictzip` | 0.67 | 0.42 | 2.75 | 2.92 | 132.79 | - |
| rich | `dict-index/raw` | 0.62 | 0.42 | 2.46 | 2.58 | 131.71 | - |
| rich | `slob/lzma2` | 441.46 | 402.79 | 824.54 | 917.33 | 41673.38 | - |
| rich | `slob/raw` | 444.04 | 402.62 | 824.42 | 912.88 | 39634.38 | - |
| rich | `sqlite/raw` | 5.67 | 5.42 | 34.83 | 38.17 | 511.46 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.79 | 0.42 | 2.62 | 2.79 | 145.00 | - |
| rich | `v1/bzip3` | 0.75 | 0.46 | 0.67 | 1.08 | 86.58 | - |
| rich | `v1/raw` | 0.42 | 0.25 | 0.50 | 0.71 | 42.83 | - |
| rich | `v2/bzip3.balanced` | 0.42 | 0.25 | 0.33 | 0.58 | 58.75 | - |
| rich | `v2/bzip3.compact` | 0.42 | 0.21 | 0.29 | 0.54 | 58.88 | - |
| rich | `v2/bzip3.latency` | 0.58 | 0.33 | 0.33 | 0.62 | 59.00 | - |
| rich | `v2/raw.balanced` | 0.46 | 0.25 | 0.33 | 0.62 | 59.38 | - |
| rich | `v2/raw.compact` | 0.42 | 0.25 | 0.33 | 0.58 | 58.75 | - |
| rich | `v2/raw.latency` | 0.42 | 0.25 | 0.33 | 0.62 | 59.50 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `14813021753239549239`
- `pathological_prefix` digest values: `9820961896636093275`
- `prose_heavy` digest values: `11367502346538253063`
- `repeated` digest values: `3649450152805327167`
- `rich` digest values: `14813021753239549239`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `72024064` bytes
- `flat.zig.process_peak_rss_bytes`: `152649728` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `64028672` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `125730816` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `112754688` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `478134272` bytes
- `repeated.external.process_peak_rss_bytes`: `70221824` bytes
- `repeated.zig.process_peak_rss_bytes`: `99532800` bytes
- `rich.external.process_peak_rss_bytes`: `52674560` bytes
- `rich.zig.process_peak_rss_bytes`: `107479040` bytes

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
