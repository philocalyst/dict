# LEX2 benchmark results

This report is generated from `benchmark.json`; the raw TSV files retain every observation.

## Reproduction

- Host: `Darwin mileswirht 24.6.0 Darwin Kernel Version 24.6.0: Mon Jan 19 21:59:23 PST 2026; root:xnu-11417.140.69.708.3~1/RELEASE_ARM64_T6030 arm64 Darwin` (the run's exact tool versions are in `raw/machine.tsv`).
- Corpus: deterministic fixtures, `32` records, seed `0x4c45583200020001`.
- Repetitions/warmup: Zig `8`/`2`; external `8`/`2`.
- v2 prose presets: `latency`; ReleaseFast build: `zig build --build-file build2.zig install -Doptimize=ReleaseFast`.
- Runner: `nix develop .# --command bash bench2/run.sh`; pinned input is recorded in `flake.lock`.
- Every measured reader receives the same TSV key/definition projection and deterministic exact, prefix, and render workload. p50/p95/p99 are retained in JSON; the table shows p50.

## Measured profiles

| Fixture | Profile | Bytes | Build ms | Open p50 us | Exact p50/p95/p99 us | Prefix p50/p95/p99 us | Render p50/p95/p99 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/raw` | 6,895 | 0.615 | 29.88 | 0.88/1.46/1.46 | 5.83/6.92/6.92 | 1.00/1.38/1.38 |
| flat | `sqlite/raw` | 20,480 | 2.656 | 47.54 | 5.12/6.04/6.04 | 10.50/11.62/11.62 | 4.88/6.29/6.29 |
| flat | `sqlite/zlib` | 1,160 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `sqlite/zstd` | 981 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| flat | `stardict/raw` | 6,974 | 0.940 | 28.50 | 0.46/0.54/0.54 | 3.62/3.83/3.83 | 0.21/0.42/0.42 |
| flat | `v1/bzip3` | 2,560 | 0.410 | 13.50 | 0.29/0.50/0.50 | 1.00/1.38/1.38 | 425.25/507.00/507.00 |
| flat | `v1/raw` | 8,384 | 0.333 | 60.29 | 0.54/1.54/1.54 | 1.96/2.29/2.29 | 9.42/9.58/9.58 |
| flat | `v2/bzip3.latency` | 12,640 | 1.498 | 655.42 | 0.62/1.54/1.54 | 2.21/3.38/3.38 | 334.88/523.12/523.12 |
| flat | `v2/raw.latency` | 18,592 | 1.233 | 267.79 | 0.29/0.42/0.42 | 0.92/1.29/1.29 | 0.08/0.21/0.21 |
| pathological_prefix | `dict-index/raw` | 7,534 | 1.812 | 74.38 | 0.83/1.46/1.46 | 2.29/7.17/7.17 | 1.00/2.88/2.88 |
| pathological_prefix | `sqlite/raw` | 20,480 | 2.474 | 49.96 | 4.96/5.25/5.25 | 8.83/11.46/11.46 | 5.08/9.38/9.38 |
| pathological_prefix | `sqlite/zlib` | 1,154 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `sqlite/zstd` | 946 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/gzip` | 1,802 | - | - | -/-/- | -/-/- | -/-/- |
| pathological_prefix | `stardict/raw` | 7,614 | 0.423 | 70.92 | 0.83/1.21/1.21 | 0.96/6.71/6.71 | 0.67/6.29/6.29 |
| pathological_prefix | `v1/bzip3` | 2,616 | 0.316 | 23.67 | 0.50/1.75/1.75 | 0.71/2.12/2.12 | 474.50/1168.17/1168.17 |
| pathological_prefix | `v1/raw` | 8,440 | 0.167 | 48.00 | 0.54/1.08/1.08 | 0.75/2.21/2.21 | 9.50/18.12/18.12 |
| pathological_prefix | `v2/bzip3.latency` | 13,280 | 1.765 | 293.00 | 0.25/0.67/0.67 | 0.29/1.83/1.83 | 103.38/107.29/107.29 |
| pathological_prefix | `v2/raw.latency` | 19,232 | 1.469 | 312.29 | 0.38/0.50/0.50 | 0.21/1.25/1.25 | 0.08/0.17/0.17 |
| prose_heavy | `dict-index/raw` | 164,862 | 0.318 | 81.08 | 0.38/0.46/0.46 | 3.12/3.38/3.38 | 0.96/8.88/8.88 |
| prose_heavy | `sqlite/raw` | 188,416 | 2.096 | 148.38 | 5.04/5.88/5.88 | 11.25/16.42/16.42 | 10.17/23.79/23.79 |
| prose_heavy | `sqlite/zlib` | 2,210 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `sqlite/zstd` | 1,305 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/gzip` | 1,842 | - | - | -/-/- | -/-/- | -/-/- |
| prose_heavy | `stardict/raw` | 164,862 | 0.548 | 34.12 | 0.46/0.54/0.54 | 3.67/3.88/3.88 | 1.67/13.42/13.42 |
| prose_heavy | `v1/bzip3` | 3,096 | 3.361 | 17.17 | 0.25/0.42/0.42 | 0.92/1.21/1.21 | 237.04/406.71/406.71 |
| prose_heavy | `v1/raw` | 166,368 | 3.155 | 660.38 | 0.62/1.79/1.79 | 1.96/2.38/2.38 | 68.92/105.25/105.25 |
| prose_heavy | `v2/bzip3.latency` | 13,280 | 7.847 | 316.00 | 0.33/0.58/0.58 | 1.00/1.67/1.67 | 383.46/868.92/868.92 |
| prose_heavy | `v2/raw.latency` | 176,672 | 4.145 | 705.75 | 0.62/1.17/1.17 | 2.17/19.08/19.08 | 0.21/0.54/0.54 |
| repeated | `dict-index/raw` | 7,593 | 0.431 | 36.21 | 1.04/2.29/2.29 | 3.17/3.71/3.71 | 0.75/2.29/2.29 |
| repeated | `sqlite/raw` | 20,480 | 0.914 | 45.08 | 12.50/57.62/57.62 | 18.62/22.29/22.29 | 23.50/121.33/121.33 |
| repeated | `sqlite/zlib` | 1,185 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `sqlite/zstd` | 1,028 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/gzip` | 1,306 | - | - | -/-/- | -/-/- | -/-/- |
| repeated | `stardict/raw` | 7,671 | 1.006 | 38.17 | 1.08/1.67/1.67 | 2.58/3.88/3.88 | 0.33/1.33/1.33 |
| repeated | `v1/bzip3` | 2,384 | 0.292 | 12.96 | 0.29/0.46/0.46 | 0.58/0.75/0.75 | 79.25/84.46/84.46 |
| repeated | `v1/raw` | 2,952 | 0.052 | 12.75 | 0.29/0.46/0.46 | 0.62/0.79/0.79 | 0.96/0.96/0.96 |
| repeated | `v2/bzip3.latency` | 12,640 | 2.969 | 938.79 | 0.42/0.79/0.79 | 0.62/1.04/1.04 | 353.08/1546.12/1546.12 |
| repeated | `v2/raw.latency` | 19,168 | 1.183 | 269.04 | 0.25/0.38/0.38 | 0.54/0.71/0.71 | 0.08/0.12/0.12 |
| rich | `dict-index/raw` | 6,895 | 0.410 | 34.42 | 0.38/0.50/0.50 | 3.29/3.58/3.58 | 0.25/0.33/0.33 |
| rich | `sqlite/raw` | 20,480 | 0.838 | 51.00 | 11.96/36.96/36.96 | 23.67/63.83/63.83 | 6.83/26.75/26.75 |
| rich | `sqlite/zlib` | 1,160 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `sqlite/zstd` | 981 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/gzip` | 1,147 | - | - | -/-/- | -/-/- | -/-/- |
| rich | `stardict/raw` | 6,974 | 0.489 | 34.04 | 0.38/0.54/0.54 | 3.58/3.75/3.75 | 0.21/0.29/0.29 |
| rich | `v1/bzip3` | 2,560 | 0.545 | 13.88 | 0.25/0.42/0.42 | 0.96/1.21/1.21 | 234.50/322.67/322.67 |
| rich | `v1/raw` | 8,384 | 0.115 | 30.92 | 0.25/0.42/0.42 | 0.92/1.17/1.17 | 6.83/6.88/6.88 |
| rich | `v2/bzip3.latency` | 13,664 | 3.849 | 2639.04 | 0.33/0.92/0.92 | 0.92/1.83/1.83 | 293.71/1716.83/1716.83 |
| rich | `v2/raw.latency` | 19,616 | 3.134 | 1442.92 | 0.67/1.79/1.79 | 1.96/3.17/3.17 | 0.12/0.75/0.75 |

## Cardinality-class timings

Exact probes are split into hit/miss; prefix probes are split into zero/one/many and the pathological fixture class.

| Fixture | Profile | Exact hit p50 us | Exact miss p50 us | Prefix zero p50 us | Prefix one p50 us | Prefix many p50 us | Prefix pathological p50 us |
|---|---|---:|---:|---:|---:|---:|---:|
| flat | `dict-index/raw` | 0.88 | 0.75 | 0.75 | 1.29 | 6.42 | - |
| flat | `sqlite/raw` | 5.12 | 5.04 | 6.12 | 9.46 | 10.96 | - |
| flat | `sqlite/zlib` | - | - | - | - | - | - |
| flat | `sqlite/zstd` | - | - | - | - | - | - |
| flat | `stardict/gzip` | - | - | - | - | - | - |
| flat | `stardict/raw` | 0.46 | 0.33 | 0.38 | 0.54 | 3.79 | - |
| flat | `v1/bzip3` | 0.29 | 0.29 | 0.50 | 0.54 | 1.12 | - |
| flat | `v1/raw` | 0.58 | 0.38 | 1.00 | 0.96 | 2.12 | - |
| flat | `v2/bzip3.latency` | 0.75 | 0.38 | 0.88 | 0.67 | 2.29 | - |
| flat | `v2/raw.latency` | 0.38 | 0.12 | 0.21 | 0.21 | 1.17 | - |
| pathological_prefix | `dict-index/raw` | 0.83 | 0.75 | 0.88 | 0.83 | - | 6.83 |
| pathological_prefix | `sqlite/raw` | 4.96 | 4.71 | 6.08 | 8.83 | - | 11.21 |
| pathological_prefix | `sqlite/zlib` | - | - | - | - | - | - |
| pathological_prefix | `sqlite/zstd` | - | - | - | - | - | - |
| pathological_prefix | `stardict/gzip` | - | - | - | - | - | - |
| pathological_prefix | `stardict/raw` | 0.83 | 0.67 | 0.71 | 0.96 | - | 6.62 |
| pathological_prefix | `v1/bzip3` | 0.67 | 0.29 | 0.38 | 0.71 | - | 1.96 |
| pathological_prefix | `v1/raw` | 0.67 | 0.29 | 0.33 | 0.75 | - | 1.92 |
| pathological_prefix | `v2/bzip3.latency` | 0.38 | 0.08 | 0.12 | 0.25 | - | 1.38 |
| pathological_prefix | `v2/raw.latency` | 0.46 | 0.08 | 0.12 | 0.21 | - | 1.12 |
| prose_heavy | `dict-index/raw` | 0.42 | 0.29 | 0.29 | 0.50 | 3.38 | - |
| prose_heavy | `sqlite/raw` | 5.04 | 4.92 | 6.62 | 7.62 | 11.75 | - |
| prose_heavy | `sqlite/zlib` | - | - | - | - | - | - |
| prose_heavy | `sqlite/zstd` | - | - | - | - | - | - |
| prose_heavy | `stardict/gzip` | - | - | - | - | - | - |
| prose_heavy | `stardict/raw` | 0.50 | 0.33 | 0.33 | 0.54 | 3.79 | - |
| prose_heavy | `v1/bzip3` | 0.25 | 0.17 | 0.38 | 0.29 | 1.17 | - |
| prose_heavy | `v1/raw` | 0.62 | 0.42 | 0.83 | 0.92 | 2.12 | - |
| prose_heavy | `v2/bzip3.latency` | 0.38 | 0.12 | 0.29 | 0.46 | 1.17 | - |
| prose_heavy | `v2/raw.latency` | 0.75 | 0.21 | 0.62 | 0.50 | 2.29 | - |
| repeated | `dict-index/raw` | 1.08 | 0.67 | 0.71 | - | 3.29 | - |
| repeated | `sqlite/raw` | 12.46 | 15.38 | 14.21 | - | 18.88 | - |
| repeated | `sqlite/zlib` | - | - | - | - | - | - |
| repeated | `sqlite/zstd` | - | - | - | - | - | - |
| repeated | `stardict/gzip` | - | - | - | - | - | - |
| repeated | `stardict/raw` | 1.08 | 0.71 | 0.67 | - | 2.58 | - |
| repeated | `v1/bzip3` | 0.33 | 0.12 | 0.17 | - | 0.58 | - |
| repeated | `v1/raw` | 0.33 | 0.12 | 0.17 | - | 0.71 | - |
| repeated | `v2/bzip3.latency` | 0.42 | 0.12 | 0.17 | - | 0.62 | - |
| repeated | `v2/raw.latency` | 0.25 | 0.08 | 0.12 | - | 0.54 | - |
| rich | `dict-index/raw` | 0.46 | 0.29 | 0.29 | 0.62 | 3.50 | - |
| rich | `sqlite/raw` | 11.96 | 11.54 | 16.54 | 23.62 | 25.79 | - |
| rich | `sqlite/zlib` | - | - | - | - | - | - |
| rich | `sqlite/zstd` | - | - | - | - | - | - |
| rich | `stardict/gzip` | - | - | - | - | - | - |
| rich | `stardict/raw` | 0.46 | 0.33 | 0.33 | 0.54 | 3.75 | - |
| rich | `v1/bzip3` | 0.25 | 0.21 | 0.38 | 0.33 | 1.17 | - |
| rich | `v1/raw` | 0.25 | 0.17 | 0.38 | 0.33 | 1.17 | - |
| rich | `v2/bzip3.latency` | 0.42 | 0.12 | 0.42 | 0.33 | 1.00 | - |
| rich | `v2/raw.latency` | 0.75 | 0.29 | 0.67 | 0.71 | 2.04 | - |

## Semantic checks

All measured profiles must carry the fixture's semantic digest and a matching normalized query checksum. A mismatch is a harness failure, not a reported result.

- `flat` digest values: `6775974522125595869`
- `pathological_prefix` digest values: `3708246534312039307`
- `prose_heavy` digest values: `12848969583906786549`
- `repeated` digest values: `17180257314182760903`
- `rich` digest values: `6775974522125595869`

Process wall/RSS (portable child-runner observations; Zig and external runs are separate processes).
Each `fixture/zig` value aggregates every v1/v2 codec and requested preset for that fixture; each `fixture/external` value aggregates all external readers. These are not per-format RSS values.
- `flat.external.process_peak_rss_bytes`: `26558464` bytes
- `flat.zig.process_peak_rss_bytes`: `36978688` bytes
- `pathological_prefix.external.process_peak_rss_bytes`: `26984448` bytes
- `pathological_prefix.zig.process_peak_rss_bytes`: `30031872` bytes
- `prose_heavy.external.process_peak_rss_bytes`: `28950528` bytes
- `prose_heavy.zig.process_peak_rss_bytes`: `35586048` bytes
- `repeated.external.process_peak_rss_bytes`: `27115520` bytes
- `repeated.zig.process_peak_rss_bytes`: `29851648` bytes
- `rich.external.process_peak_rss_bytes`: `26427392` bytes
- `rich.zig.process_peak_rss_bytes`: `31686656` bytes

## Availability and caveats

- `flat sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `flat sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `flat stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `flat dict-index/dictzip`: dictzip executable absent; raw local index retained
- `flat slob/lzma2`: Python SLOB import failed: No module named 'slob'
- `prose_heavy sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `prose_heavy sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `prose_heavy stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `prose_heavy dict-index/dictzip`: dictzip executable absent; raw local index retained
- `prose_heavy slob/lzma2`: Python SLOB import failed: No module named 'slob'
- `repeated sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `repeated sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `repeated stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `repeated dict-index/dictzip`: dictzip executable absent; raw local index retained
- `repeated slob/lzma2`: Python SLOB import failed: No module named 'slob'
- `rich sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `rich sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `rich stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `rich dict-index/dictzip`: dictzip executable absent; raw local index retained
- `rich slob/lzma2`: Python SLOB import failed: No module named 'slob'
- `pathological_prefix sqlite/zlib`: SQLite cannot seek compressed pages without a decompression staging policy
- `pathological_prefix sqlite/zstd`: SQLite cannot seek compressed pages without a decompression staging policy
- `pathological_prefix stardict/gzip`: gzip is not StarDict dictzip random access; raw reader is the measured query baseline
- `pathological_prefix dict-index/dictzip`: dictzip executable absent; raw local index retained
- `pathological_prefix slob/lzma2`: Python SLOB import failed: No module named 'slob'
- The v1/v2 comparison is an equal lexical projection. v2's rich fixture adds graph assertions; external formats intentionally receive only the same flat key/definition projection, so those rows do not measure graph preservation.
- SQLite zlib/zstd and StarDict gzip rows report artifact sizes only: whole-file compression destroys page/index random access unless a decompression staging policy is chosen, so query latency is not fabricated.
- `dict-index` is a local sorted UTF-8 offset reader, not a dictd daemon; it is intentionally relabeled when real dictfmt/dictd service timing is unavailable. Its dictzip variant uses range decompression.
- External profiles are Python readers: Python's sqlite3 wrapper, the custom StarDict and sorted-offset readers, and optional reference SLOB. Their interpreter/library overhead is part of those timings and is not equivalent to the native Zig v1/v2 implementations.
- v1/v2 open timing includes their format-specific structural/semantic open path (v2 validates the canonical manifest, sections, derived indexes, and cached views). External open timing measures reader construction only; every external artifact is semantically validated before warmup and timing, but that validation is not part of external open latency.
- Build timing is format-specific: v1/v2 includes builder/compile plus the in-process Reader/Snapshot.open validation boundary; external build timing covers the custom reader/artifact construction. It is not an equivalent end-to-end build pipeline.
- SLOB is Python reference SLOB with raw and lzma2 compression. Its UUID/timestamp metadata is not byte-for-byte deterministic even though the corpus and semantic digest are.
- Timings are single-process wall-clock samples after deterministic warmup on one otherwise uncontrolled host; use p95/p99 and raw TSV for comparisons, not a claim of universal performance.

Raw outputs: `results/latest/raw/*.tsv`; machine-readable output: `results/latest/benchmark.json`; generated artifacts: `results/latest/artifacts/<fixture>/`; SHA-256 manifest: `results/latest/hashes.tsv`.
