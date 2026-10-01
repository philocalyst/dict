# Dictionary frontier comparison

Two distinct workloads are retained. `compare.py` checks complete natural
source projections (identity, byte keys, exact normalized definition content)
and then runs the existing native query/render protocol. It independently
checks every entry and posting and reads frozen v2 artifacts with the new
reader. Natural projections do not test the entire expressive lexical schema.
`compare_rich.py` uses the identical native-rich multilingual fixture on both
cores, with complete deep equality before timed selected-field access. It is
an ownership/access control with repeated content, not natural compression.

The baseline is canonical commit `eda533210ddfa8901a4fde66b558bd84e4e3b555`.
Both clients compile with Zig 0.16.0, ReleaseFast, the same target, and bzip3
1.5.1 commit `d149f093793484d8eb55900ecf09c5714e277dba`. Vendor source is a
real dependency and remains ignored by Git. Source, binary, Python harness,
compiler and vendor hashes plus exact build commands are captured.

## Reproduction

Restore the pinned corpora with [the corpus builder](../frontier2026/CORPORA.md)
and put the bzip3 checkout in `vendor/bzip3`. Make a detached worktree at the
baseline commit and link its `vendor/bzip3` to that checkout. From the current
repository root, replacing the example scratch paths as needed:

```sh
python3 src6/bench/dictionary_frontier/build.py \
  --before-source /workspace/scratch/dict-baseline --output /workspace/scratch/dictionary-builds
python3 src6/bench/dictionary_frontier/compare_rich.py \
  --before /workspace/scratch/dictionary-builds/before-rich/bin/dictionary-frontier \
  --after /workspace/scratch/dictionary-builds/after-rich/bin/dictionary-frontier \
  --before-source /workspace/scratch/dict-baseline --entries 4096 --pairs 5 \
  --quiet-gate ROOT-EXPLICIT-QUIET-GATE --output /workspace/scratch/rich-final
python3 src6/bench/dictionary_frontier/compare.py \
  --before /workspace/scratch/dictionary-builds/before-real/bin/real-lex6 \
  --after /workspace/scratch/dictionary-builds/after-real/bin/real-lex6 \
  --before-source /workspace/scratch/dict-baseline \
  --projection /workspace/scratch/frontier-corpora/dictionaries/omw-ja-20/final/projection.tsv \
  --pairs 5 --quiet-gate ROOT-EXPLICIT-QUIET-GATE --output /workspace/scratch/dictionary-final
```

Pass repeated `--projection` arguments for additional corpora. The natural
storage/correctness sweep uses 16, 64 and 256 KiB page targets with raw and
adaptive bzip3 modes. Timing uses 64 KiB, five alternating AB/BA fresh-process
pairs and the native runner's existing 256-operation batches and warmups.
`--size-only` retains complete correctness gates without speed claims.

## Accounting and admission

All archive bytes count. In the rich fixture, the candidate reports plain and
optional identity-indexed builds and uses the indexed artifact for access;
the old core uses its plain artifact and scan-derived link catalog. This is
an explicit trade of metadata bytes for link preparation. Opening metadata,
per-document semantic admission, and full semantic verification have different
scopes and stay separate. Prepared wire projections run **after full semantic
verification** and borrow the same immutable mapping and limits. Their setup
cost must be included when evaluating application startup or amortization.

"Cold" in the older phase names means no application page cache. Data is
memory resident and previously touched; there is no disk/OS-cache eviction.
The bounded reader caches one page, so a sequential multi-page access pass
still decodes each new compressed page. Retained-field projection repeats
one entry and is reported separately. Every path consumes the same headword
and first sense label; no speed is inferred from discarding output.

Rich allocation counters describe successful Zig `alloc` hook calls and
requested live bytes; resize/remap byte growth is counted but their calls
are not added to `alloc_calls`. Fixture construction, allocator bookkeeping
and bzip3's internal C memory are excluded. These are **not RSS** measurements.
Native codec benchmarks separately report whole-process peak RSS. Internal
phase timing excludes subprocess launch and dynamic loader costs.

Raw stdout, stderr, command and exit status survive alongside all samples.
Source or binary changes during a comparison invalidate the run. Small
paired samples characterize this host/workload; they do not establish a
universal latency guarantee.

## Natural prepared projection access

After the complete five-corpus final `compare.py` report, run the common
`dictionary-projection` client against its matching 64 KiB raw/adaptive
artifacts. Freeze all harness files before creating that artifact report;
the access driver checks the same core and dependency snapshots. For example:

```sh
python3 src6/bench/dictionary_frontier/compare_natural.py \
  --artifacts-report /workspace/scratch/dictionary-final/results.json \
  --before /workspace/scratch/dictionary-builds/before-rich/bin/dictionary-projection \
  --after /workspace/scratch/dictionary-builds/after-rich/bin/dictionary-projection \
  --before-source /workspace/scratch/dict-baseline --pairs 5 --operations 1024 \
  --quiet-gate ROOT-EXPLICIT-QUIET-GATE --output /workspace/scratch/natural-access-final
```

Every process validates all entries and consumes the headword and complete
single-definition text. Fixed batches repeat entry zero or spread ordinals
evenly across the archive; raw prepared views borrow mapped bytes, while
compressed page transitions retain their actual decode/page-load cost. Full
semantic verification and prepared reader setup are reported separately from
access. Five alternating AB/BA pairs follow one untimed warmup per lane.
Checksums, complete-entry and sampled consumed-byte totals, artifact hashes,
runtime libraries, sources and binaries must agree. This narrower natural
projection workload makes no claim about rich graph traversal or allocations.
