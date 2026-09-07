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
| flat | `dict-index/dictzip` | 61,407 | 11.898 | 1089.00 | 0.75/3.38/9.17 | 127.62/481.00/1433.21 | 6575.83/9585.38/11068.92 |
| flat | `dict-index/raw` | 448,231 | 2.706 | 683.38 | 0.71/3.62/11.83 | 127.29/469.00/1199.88 | 0.54/1.83/7.12 |
| flat | `slob/lzma2` | 74,476 | 76.671 | 94.38 | 496.58/1714.92/2670.79 | 46735.96/74605.88/87433.12 | 45.21/198.38/687.88 |
| flat | `slob/raw` | 478,747 | 73.993 | 89.29 | 711.96/2239.00/2916.67 | 46995.79/79480.54/86530.88 | 57.50/215.54/723.38 |
| flat | `sqlite/raw` | 532,480 | 9.152 | 56.54 | 6.17/48.46/119.88 | 472.96/1660.62/2460.54 | 6.62/47.75/191.29 |
| flat | `sqlite/zlib` | 35,597 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 24,732 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 55,034 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 442,777 | 3.605 | 1155.25 | 1.62/5.04/12.92 | 137.96/453.83/1254.67 | 0.58/2.04/10.54 |
| flat | `v1/bzip3` | 130,920 | 59.157 | 34676.12 | 0.46/1.46/2.75 | 41.71/109.92/236.92 | 795.62/1969.17/3356.21 |
| flat | `v1/raw` | 520,760 | 46.331 | 34973.38 | 0.38/0.96/1.75 | 41.46/102.71/233.54 | 74.04/154.88/865.04 |
| flat | `v2/bzip3.balanced` | 235,168 | 195.543 | 41179.58 | 0.38/1.00/1.79 | 56.79/123.29/258.29 | 2448.83/4305.83/5433.12 |
| flat | `v2/bzip3.compact` | 234,336 | 125.611 | 48073.54 | 0.46/1.29/2.04 | 55.79/159.12/337.25 | 5495.58/8407.12/9818.75 |
| flat | `v2/bzip3.latency` | 237,984 | 174.709 | 47774.67 | 0.62/1.29/2.00 | 57.25/153.25/657.33 | 965.33/2135.67/3094.38 |
| flat | `v2/raw.balanced` | 636,960 | 145.890 | 48240.96 | 0.42/1.17/2.29 | 57.12/168.00/415.42 | 0.96/1.62/1.83 |
| flat | `v2/raw.compact` | 636,896 | 123.237 | 43615.50 | 0.33/0.67/1.38 | 56.54/137.33/195.38 | 1.25/2.62/11.96 |
| flat | `v2/raw.latency` | 637,344 | 158.505 | 49977.54 | 0.71/1.25/1.96 | 57.54/182.71/540.50 | 0.46/0.54/0.62 |
| pathological_prefix | `dict-index/dictzip` | 103,018 | 8.773 | 720.12 | 0.75/3.71/11.25 | 9.62/396.38/784.96 | 6092.29/9442.00/14117.71 |
| pathological_prefix | `dict-index/raw` | 489,827 | 0.830 | 802.75 | 0.67/3.21/7.50 | 10.12/382.58/793.79 | 0.62/2.29/7.38 |
| pathological_prefix | `slob/lzma2` | 116,072 | 83.607 | 147.92 | 511.79/2001.08/2837.33 | 2560.33/82860.62/113661.25 | 44.79/180.71/798.08 |
| pathological_prefix | `slob/raw` | 520,343 | 77.294 | 83.88 | 508.88/1822.29/2460.12 | 2123.79/64184.62/81143.75 | 57.92/288.92/1027.75 |
| pathological_prefix | `sqlite/raw` | 602,112 | 3.573 | 120.25 | 6.04/37.42/98.42 | 74.88/1257.88/2055.83 | 5.25/34.46/133.25 |
| pathological_prefix | `sqlite/zlib` | 33,342 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 22,723 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 96,645 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 484,373 | 1.426 | 1105.38 | 0.79/3.54/12.62 | 11.04/441.79/1170.54 | 0.54/2.04/6.71 |
| pathological_prefix | `v1/bzip3` | 134,888 | 102.076 | 23649.96 | 0.42/1.25/1.83 | 0.88/79.54/203.58 | 508.38/1536.92/2188.79 |
| pathological_prefix | `v1/raw` | 524,728 | 47.042 | 25243.67 | 0.42/1.25/2.04 | 0.88/78.00/113.92 | 73.67/140.96/722.29 |
| pathological_prefix | `v2/bzip3.balanced` | 280,352 | 127.825 | 54534.12 | 0.46/1.42/1.88 | 1.00/145.25/582.42 | 3208.96/5781.83/7070.00 |
| pathological_prefix | `v2/bzip3.compact` | 279,520 | 172.999 | 42344.92 | 0.62/1.75/2.38 | 0.79/135.62/234.33 | 5012.38/7645.04/9569.88 |
| pathological_prefix | `v2/bzip3.latency` | 283,168 | 171.907 | 48965.04 | 0.46/1.42/2.12 | 0.71/118.00/230.17 | 722.12/1871.33/2314.08 |
| pathological_prefix | `v2/raw.balanced` | 682,144 | 115.008 | 39558.71 | 0.42/0.79/1.25 | 0.75/124.96/213.75 | 0.79/0.88/1.08 |
| pathological_prefix | `v2/raw.compact` | 682,080 | 141.376 | 48502.62 | 0.54/1.58/3.08 | 0.79/126.79/297.79 | 1.21/2.46/2.54 |
| pathological_prefix | `v2/raw.latency` | 682,528 | 130.103 | 40990.21 | 0.58/1.75/2.42 | 1.21/159.50/544.08 | 0.25/0.29/0.38 |
| prose_heavy | `dict-index/dictzip` | 141,192 | 47.174 | 833.79 | 0.67/2.58/7.21 | 128.29/453.88/1353.08 | 6349.38/9057.54/10298.96 |
| prose_heavy | `dict-index/raw` | 10,557,618 | 10.885 | 2981.46 | 0.67/2.75/7.54 | 130.29/431.79/1085.62 | 3.46/12.04/34.54 |
| prose_heavy | `slob/lzma2` | 123,820 | 719.857 | 85.12 | 573.62/1993.29/2721.00 | 41633.88/65569.42/82655.75 | 33.08/195.62/572.08 |
| prose_heavy | `slob/raw` | 10,585,995 | 83.455 | 79.96 | 566.67/2103.75/2824.12 | 45999.79/70093.71/83471.83 | 144.29/625.71/1993.25 |
| prose_heavy | `sqlite/raw` | 11,259,904 | 45.047 | 68.83 | 5.88/49.04/121.46 | 475.29/1356.33/2117.96 | 21.42/125.08/425.04 |
| prose_heavy | `sqlite/zlib` | 98,801 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 46,173 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 95,779 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 10,547,609 | 15.294 | 2837.50 | 0.88/3.21/7.67 | 140.29/454.50/1415.33 | 2.79/11.79/25.17 |
| prose_heavy | `v1/bzip3` | 176,424 | 700.629 | 23026.50 | 0.38/0.88/1.50 | 41.50/89.58/125.25 | 344.17/1072.00/1710.00 |
| prose_heavy | `v1/raw` | 10,633,464 | 649.458 | 72643.67 | 0.42/1.08/2.21 | 41.42/103.21/170.79 | 70.04/140.17/946.00 |
| prose_heavy | `v2/bzip3.balanced` | 256,224 | 660.385 | 41338.92 | 0.54/1.21/1.71 | 57.17/148.54/407.33 | 1814.33/3711.42/5318.33 |
| prose_heavy | `v2/bzip3.compact` | 241,248 | 756.634 | 44670.25 | 0.42/1.12/1.58 | 56.75/148.71/321.38 | 21672.08/26857.54/31805.58 |
| prose_heavy | `v2/bzip3.latency` | 293,024 | 658.468 | 37819.29 | 0.46/1.25/2.04 | 56.67/128.88/186.58 | 374.42/1052.46/1629.71 |
| prose_heavy | `v2/raw.balanced` | 10,747,936 | 521.911 | 40662.58 | 0.42/1.21/2.29 | 56.75/129.83/234.75 | 0.08/0.46/0.92 |
| prose_heavy | `v2/raw.compact` | 10,745,184 | 701.984 | 46767.62 | 0.38/0.92/1.71 | 56.42/151.88/644.17 | 0.54/1.17/1.75 |
| prose_heavy | `v2/raw.latency` | 10,757,280 | 558.678 | 40555.46 | 0.38/0.79/1.67 | 56.42/138.46/580.58 | 0.04/0.29/0.50 |
| repeated | `dict-index/dictzip` | 66,043 | 13.176 | 973.79 | 1.04/4.12/12.88 | 63.38/224.12/997.79 | 5952.62/8265.58/9624.42 |
| repeated | `dict-index/raw` | 490,328 | 7.226 | 1284.50 | 1.00/3.79/8.12 | 64.58/248.00/582.25 | 0.75/2.46/6.12 |
| repeated | `slob/lzma2` | 82,898 | 90.694 | 60.88 | 612.75/2212.75/2934.21 | 22236.29/39791.00/45457.04 | 44.38/197.50/707.46 |
| repeated | `slob/raw` | 520,793 | 76.990 | 76.54 | 744.12/2350.58/3100.17 | 20025.96/38130.54/43176.25 | 56.62/260.00/953.08 |
| repeated | `sqlite/raw` | 569,344 | 17.597 | 191.00 | 10.75/62.04/170.79 | 243.92/1128.29/1926.71 | 6.75/41.42/195.79 |
| repeated | `sqlite/zlib` | 29,697 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 21,521 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 58,976 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 484,823 | 3.359 | 2187.67 | 1.33/5.54/10.62 | 72.29/323.79/1044.75 | 1.12/3.21/6.71 |
| repeated | `v1/bzip3` | 116,688 | 23.432 | 20596.58 | 0.42/1.25/1.96 | 21.00/44.25/78.00 | 87.12/357.58/1196.67 |
| repeated | `v1/raw` | 117,256 | 25.618 | 25308.75 | 0.38/1.00/1.88 | 20.96/44.75/68.50 | 0.96/1.00/1.25 |
| repeated | `v2/bzip3.balanced` | 226,976 | 146.013 | 43988.42 | 0.42/1.21/1.58 | 28.29/76.25/168.08 | 1878.04/3559.17/4280.21 |
| repeated | `v2/bzip3.compact` | 226,080 | 124.076 | 45768.75 | 0.50/1.38/1.88 | 28.75/81.88/264.92 | 4607.67/6940.67/8591.75 |
| repeated | `v2/bzip3.latency` | 229,536 | 167.193 | 44974.88 | 0.54/1.33/1.88 | 28.42/85.42/231.38 | 750.67/1879.50/2253.04 |
| repeated | `v2/raw.balanced` | 663,072 | 149.958 | 49782.04 | 0.54/1.33/1.67 | 28.54/75.38/245.42 | 0.71/0.83/1.50 |
| repeated | `v2/raw.compact` | 663,008 | 117.190 | 44859.54 | 0.38/0.71/1.46 | 27.96/65.29/122.29 | 1.21/2.46/3.08 |
| repeated | `v2/raw.latency` | 663,456 | 111.318 | 40264.08 | 0.38/0.62/0.83 | 28.88/92.21/229.17 | 0.46/0.50/0.75 |
| rich | `dict-index/dictzip` | 61,407 | 8.968 | 736.71 | 0.71/3.25/10.54 | 127.04/427.58/1359.67 | 6101.29/9167.71/12037.29 |
| rich | `dict-index/raw` | 448,231 | 2.944 | 1328.50 | 0.79/3.04/7.29 | 130.46/520.04/1242.75 | 0.62/2.04/17.83 |
| rich | `slob/lzma2` | 74,476 | 84.023 | 75.25 | 505.92/1803.25/2733.08 | 45247.38/71552.50/87012.25 | 45.33/213.75/737.33 |
| rich | `slob/raw` | 478,747 | 97.626 | 183.25 | 492.88/1778.42/2397.08 | 45321.62/78586.96/89812.62 | 58.58/263.38/1179.33 |
| rich | `sqlite/raw` | 532,480 | 13.382 | 45.79 | 5.92/44.88/104.83 | 469.29/1335.38/2234.38 | 5.33/29.88/156.33 |
| rich | `sqlite/zlib` | 35,597 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 24,732 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 55,034 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 442,777 | 2.692 | 1284.00 | 0.83/3.71/7.29 | 139.92/548.71/1436.92 | 0.71/2.38/6.96 |
| rich | `v1/bzip3` | 130,920 | 48.229 | 21509.38 | 0.33/0.67/1.46 | 41.71/90.62/161.71 | 520.79/1608.54/2005.00 |
| rich | `v1/raw` | 520,760 | 48.721 | 24753.46 | 0.33/0.67/2.12 | 41.50/100.62/214.33 | 73.62/133.96/713.21 |
| rich | `v2/bzip3.balanced` | 288,096 | 306.194 | 96953.29 | 0.42/1.25/2.04 | 55.83/141.79/255.29 | 2527.12/4535.08/5352.62 |
| rich | `v2/bzip3.compact` | 287,392 | 257.360 | 100500.12 | 0.42/1.08/1.88 | 56.33/128.04/303.21 | 5006.21/7511.92/9058.83 |
| rich | `v2/bzip3.latency` | 290,336 | 261.643 | 120144.92 | 0.54/1.42/2.08 | 56.92/153.50/521.88 | 857.25/2086.08/2576.25 |
| rich | `v2/raw.balanced` | 688,480 | 243.183 | 95948.54 | 0.46/1.17/1.62 | 56.17/134.88/374.46 | 0.79/0.83/0.88 |
| rich | `v2/raw.compact` | 688,416 | 234.793 | 94046.42 | 0.38/1.12/1.58 | 56.21/133.42/336.67 | 1.21/2.38/2.92 |
| rich | `v2/raw.latency` | 688,864 | 242.046 | 95285.00 | 0.42/1.21/1.83 | 56.42/141.83/551.42 | 0.25/0.29/0.54 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/dictzip` | 0.88 | 0.46 | 7.04 | 9.42 | 151.62 | - |
| flat | `dict-index/raw` | 0.83 | 0.46 | 5.71 | 7.88 | 146.21 | - |
| flat | `slob/lzma2` | 525.33 | 442.42 | 1395.00 | 1557.21 | 60478.17 | - |
| flat | `slob/raw` | 767.83 | 640.50 | 1270.12 | 1468.83 | 62721.29 | - |
| flat | `sqlite/raw` | 6.21 | 5.92 | 62.21 | 68.79 | 689.75 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 2.25 | 1.04 | 6.04 | 7.46 | 166.00 | - |
| flat | `v1/bzip3` | 0.54 | 0.29 | 0.58 | 1.04 | 43.62 | - |
| flat | `v1/raw` | 0.46 | 0.25 | 0.50 | 0.79 | 42.88 | - |
| flat | `v2/bzip3.balanced` | 0.46 | 0.25 | 0.33 | 0.58 | 59.04 | - |
| flat | `v2/bzip3.compact` | 0.54 | 0.33 | 0.38 | 0.71 | 60.38 | - |
| flat | `v2/bzip3.latency` | 0.79 | 0.42 | 0.38 | 0.75 | 60.17 | - |
| flat | `v2/raw.balanced` | 0.50 | 0.29 | 0.54 | 0.88 | 104.29 | - |
| flat | `v2/raw.compact` | 0.46 | 0.25 | 0.33 | 0.58 | 59.12 | - |
| flat | `v2/raw.latency` | 0.83 | 0.42 | 0.50 | 0.88 | 124.75 | - |
| pathological_prefix | `dict-index/dictzip` | 0.92 | 0.42 | 4.50 | 2.33 | - | 143.00 |
| pathological_prefix | `dict-index/raw` | 0.83 | 0.42 | 4.88 | 2.33 | - | 140.62 |
| pathological_prefix | `slob/lzma2` | 545.88 | 450.25 | 1551.92 | 1736.42 | - | 68935.46 |
| pathological_prefix | `slob/raw` | 539.71 | 457.71 | 1271.62 | 1253.08 | - | 56015.00 |
| pathological_prefix | `sqlite/raw` | 6.21 | 5.75 | 54.88 | 19.92 | - | 573.71 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 1.04 | 0.42 | 6.12 | 2.75 | - | 166.46 |
| pathological_prefix | `v1/bzip3` | 0.54 | 0.17 | 0.38 | 0.88 | - | 35.79 |
| pathological_prefix | `v1/raw` | 0.54 | 0.17 | 0.33 | 0.88 | - | 35.67 |
| pathological_prefix | `v2/bzip3.balanced` | 0.62 | 0.21 | 0.38 | 1.00 | - | 62.62 |
| pathological_prefix | `v2/bzip3.compact` | 0.92 | 0.38 | 0.25 | 0.83 | - | 59.21 |
| pathological_prefix | `v2/bzip3.latency` | 0.62 | 0.21 | 0.25 | 0.79 | - | 58.75 |
| pathological_prefix | `v2/raw.balanced` | 0.58 | 0.21 | 0.25 | 0.79 | - | 58.92 |
| pathological_prefix | `v2/raw.compact` | 0.75 | 0.25 | 0.25 | 0.83 | - | 59.33 |
| pathological_prefix | `v2/raw.latency` | 0.83 | 0.33 | 0.50 | 1.71 | - | 123.33 |
| prose_heavy | `dict-index/dictzip` | 0.75 | 0.46 | 5.25 | 6.58 | 145.46 | - |
| prose_heavy | `dict-index/raw` | 0.79 | 0.46 | 6.42 | 7.58 | 147.83 | - |
| prose_heavy | `slob/lzma2` | 643.38 | 480.33 | 1106.38 | 1280.54 | 56896.71 | - |
| prose_heavy | `slob/raw` | 597.83 | 517.04 | 1128.38 | 1318.54 | 59638.17 | - |
| prose_heavy | `sqlite/raw` | 5.96 | 5.62 | 56.42 | 68.29 | 638.04 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 1.08 | 0.46 | 5.46 | 6.83 | 158.00 | - |
| prose_heavy | `v1/bzip3` | 0.42 | 0.29 | 0.50 | 0.75 | 42.38 | - |
| prose_heavy | `v1/raw` | 0.46 | 0.29 | 0.54 | 0.88 | 43.25 | - |
| prose_heavy | `v2/bzip3.balanced` | 0.71 | 0.42 | 0.38 | 0.71 | 60.88 | - |
| prose_heavy | `v2/bzip3.compact` | 0.50 | 0.29 | 0.38 | 0.71 | 60.38 | - |
| prose_heavy | `v2/bzip3.latency` | 0.58 | 0.33 | 0.33 | 0.62 | 59.71 | - |
| prose_heavy | `v2/raw.balanced` | 0.50 | 0.29 | 0.33 | 0.62 | 59.00 | - |
| prose_heavy | `v2/raw.compact` | 0.46 | 0.25 | 0.42 | 0.75 | 60.58 | - |
| prose_heavy | `v2/raw.latency` | 0.46 | 0.25 | 0.33 | 0.62 | 59.54 | - |
| repeated | `dict-index/dictzip` | 1.21 | 0.46 | 3.88 | - | 70.21 | - |
| repeated | `dict-index/raw` | 1.21 | 0.46 | 6.92 | - | 77.62 | - |
| repeated | `slob/lzma2` | 696.58 | 494.54 | 1351.38 | - | 30104.88 | - |
| repeated | `slob/raw` | 791.71 | 604.00 | 1324.62 | - | 28834.25 | - |
| repeated | `sqlite/raw` | 10.71 | 10.75 | 71.54 | - | 339.42 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 1.71 | 0.50 | 8.33 | - | 94.92 | - |
| repeated | `v1/bzip3` | 0.50 | 0.29 | 0.50 | - | 21.67 | - |
| repeated | `v1/raw` | 0.46 | 0.25 | 0.50 | - | 21.58 | - |
| repeated | `v2/bzip3.balanced` | 0.50 | 0.29 | 0.42 | - | 30.21 | - |
| repeated | `v2/bzip3.compact` | 0.67 | 0.38 | 0.46 | - | 30.54 | - |
| repeated | `v2/bzip3.latency` | 0.75 | 0.38 | 0.50 | - | 30.62 | - |
| repeated | `v2/raw.balanced` | 0.83 | 0.38 | 0.42 | - | 30.12 | - |
| repeated | `v2/raw.compact` | 0.46 | 0.21 | 0.33 | - | 29.83 | - |
| repeated | `v2/raw.latency` | 0.42 | 0.21 | 0.54 | - | 62.50 | - |
| rich | `dict-index/dictzip` | 0.83 | 0.46 | 4.83 | 6.17 | 146.21 | - |
| rich | `dict-index/raw` | 0.92 | 0.46 | 7.04 | 8.50 | 217.96 | - |
| rich | `slob/lzma2` | 540.04 | 452.08 | 1365.08 | 1418.08 | 59545.50 | - |
| rich | `slob/raw` | 522.88 | 437.08 | 1390.25 | 1535.25 | 64086.88 | - |
| rich | `sqlite/raw` | 6.04 | 5.67 | 66.67 | 66.42 | 643.38 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 1.00 | 0.46 | 6.04 | 7.71 | 225.04 | - |
| rich | `v1/bzip3` | 0.42 | 0.29 | 0.50 | 0.75 | 42.29 | - |
| rich | `v1/raw` | 0.42 | 0.25 | 0.50 | 0.79 | 43.29 | - |
| rich | `v2/bzip3.balanced` | 0.50 | 0.29 | 0.38 | 0.67 | 59.25 | - |
| rich | `v2/bzip3.compact` | 0.50 | 0.25 | 0.33 | 0.62 | 59.50 | - |
| rich | `v2/bzip3.latency` | 0.71 | 0.38 | 0.46 | 0.75 | 61.21 | - |
| rich | `v2/raw.balanced` | 0.54 | 0.29 | 0.33 | 0.62 | 59.21 | - |
| rich | `v2/raw.compact` | 0.46 | 0.25 | 0.33 | 0.62 | 59.96 | - |
| rich | `v2/raw.latency` | 0.50 | 0.25 | 0.38 | 0.71 | 60.33 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `14813021753239549239`
- `pathological_prefix` digest values: `9820961896636093275`
- `prose_heavy` digest values: `11367502346538253063`
- `repeated` digest values: `3649450152805327167`
- `rich` digest values: `14813021753239549239`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `70615040` bytes
- `flat.zig.process_peak_rss_bytes`: `140574720` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `71450624` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `141885440` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `135364608` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `479461376` bytes
- `repeated.external.process_peak_rss_bytes`: `66043904` bytes
- `repeated.zig.process_peak_rss_bytes`: `135725056` bytes
- `rich.external.process_peak_rss_bytes`: `65896448` bytes
- `rich.zig.process_peak_rss_bytes`: `138051584` bytes

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
