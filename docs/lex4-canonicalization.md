# LEX4 canonicalization record

This is a historical checkpoint. The 8 September architectural rewrite and
current evidence are in [lex4-unification.md](lex4-unification.md). Early direct
benchmark commands had a per-module optimization-order mistake; their timings
must not be treated as ReleaseFast evidence. The build-system test matrix
below is unaffected. See the retained
[correction](../experiments/frontier/unification-20260908/OPTIMIZATION-CORRECTION.md).

Measured 7 September 2026 in the repository workspace. This record describes
the canonical source tree and its internal integration gates; it does not
close benchmark rubric #7 or substitute for a matched `src2` comparison.

## Selected implementations

| Primitive | Canonical source | Canonical tests | Retired source present? |
| --- | --- | --- | --- |
| Bitvector | `src4/bitvector.zig` | `src4/bitvector_test.zig` | No `bitvector_wire*` file or import |
| Entropy | `src4/entropy.zig` | `src4/entropy_test.zig` | No alternate entropy wire |
| Grammar | `src4/grammar.zig` (`L4GC`) | `src4/grammar_test.zig`, `src4/grammar_adversarial_test.zig` | No `grammar_compact*` file, `L4GR` magic, or import |

L4GC was selected on the complete architecture rubric, not byte size alone.
It has structural-only envelope opening, a separate linear verification pass,
source-routed verification/extraction/snippets, a comptime `ViewFor(Source)`,
direct snippets, caller-owned stacks, hostile-wire and allocation-failure
tests, and measured compactness/scaling ledgers.

## Source size

The command counts physical lines in `src4/*.zig`, excluding files named
`*_test.zig` for the production figure. Production modules may still contain
embedded Zig tests.

| Checkpoint | Production LOC | Separate test LOC | All `src4` Zig LOC |
| --- | ---: | ---: | ---: |
| Pre-audit live tree | 17,080 | 3,864 | 20,944 |
| Post-integration live tree | 17,098 | 3,899 | 20,997 |

The retired candidates were already absent when this audit began. The measured
increase is the subsequent forest directory hardening and hostile grammar
source-authentication evidence, not a second implementation. A historical
pre-retirement LOC total cannot be reconstructed from this untracked checkout
and is intentionally not invented.

## `build4` integration

Sequential commands were timed with `/usr/bin/time -p`; they were not run
concurrently. Both execute the complete `build4.zig` test step. The first pair
followed source changes and rebuilt several test binaries; an independent
immediate rerun records the fully cached floor rather than silently replacing
the earlier observation.

| Mode | Cache state | Result | Real | User | System |
| --- | --- | --- | ---: | ---: | ---: |
| ReleaseSafe | incremental, some recompilation | 39/39 steps; 428/428 tests | 43.41 s | 174.24 s | 10.06 s |
| ReleaseFast | incremental, some recompilation | 39/39 steps; 428/428 tests | 45.39 s | 170.93 s | 10.00 s |
| ReleaseSafe | fully cached rerun | 39/39 steps; 428/428 tests | 18.83 s | 17.92 s | 4.51 s |
| ReleaseFast | fully cached rerun | 39/39 steps; 428/428 tests | 18.46 s | 17.17 s | 4.51 s |
| ReleaseSafe | final integration after forest/concepts | 39/39 steps; 429/429 tests | 34.73 s | 171.89 s | 9.68 s |
| ReleaseFast | final integration after forest/concepts | 39/39 steps; 429/429 tests | 55.70 s | 163.58 s | 9.32 s |

These are whole-build wall/CPU measurements, including compilation and all
tests. They are not query or render latency measurements.

## Compact grammar-section ledger

The ReleaseFast integration gate builds and verifies 2,048 records for each
fixture. `Wire bytes` is the complete L4GC grammar wire: its 96-byte header,
packed rules, symbol sequence, cumulative item ends, alias bits, u32 alias-rank
checkpoints, and packed alias targets. No grammar-internal table, directory, or
alignment byte is omitted, and `openEnvelope` checks the exact offsets and
total length.

This is not a complete Step-B container artifact. A whole-snapshot ledger must
separately include the container header/directory, section alignment, page
digests, and every other required section. `build_ns` measures `grammar.build`
only. `render_ns` is the sum of four direct `extract` calls; verification and
correctness comparisons are outside that timer. It is a small integration
probe, not the warmed query microbenchmark.

| Fixture | Wire bytes | Rules | Sequence symbols | Build ns | Four renders ns |
| --- | ---: | ---: | ---: | ---: | ---: |
| flat | 9,684 | 256 | 4,480 | 3,722,800,000 | 28,916 |
| prose-heavy | 10,117 | 256 | 4,722 | 6,773,717,416 | 996,791 |
| repeated | 5,657 | 134 | 119 | 12,481,000 | 539,416 |
| rich | 9,684 | 256 | 4,480 | 3,997,574,250 | 29,500 |
| pathological-prefix | 9,684 | 256 | 4,480 | 4,031,668,208 | 30,624 |

The bytes are deterministic; timings are observations from this run and must
retain their mode, machine, cache, and measurement-boundary context.

## Vendored bzip3 cold-section probe

An ephemeral ReleaseFast probe linked `vendor/bzip3/src/libbz3.c` directly
with `-I vendor/bzip3/include`, `-DVERSION=1.5.1`, and
`-fno-sanitize=undefined`. The probe source was removed after measurement, so
these are retained observations rather than a reproducible bench4 artifact.
They demonstrate the existing non-build4 adapter, not bzip3 availability in
LEX4's `build4.zig` integration.

All three runs encoded identical bytes from the same generated 35,104-entry
terms payload:

| Measurement | Bytes |
| --- | ---: |
| Raw terms section | 17,630 |
| bzip3 payload | 3,139 |
| Complete cold envelope, including its 64-byte header | 3,203 |
| Saving versus raw section | 14,427 |

The compressed payload is 17.8% of the raw section; the complete cold envelope
is 18.2%. The raw section ledger reported dictionary 385, checkpoints 408,
metadata 2,267, and postings payload 14,494 bytes, with its remaining bytes in
the section header/alignment.

| Run | Encode ns | Verify decode + digest ns | First `Reader.read` decode ns |
| ---: | ---: | ---: | ---: |
| 1 | 1,359,833 | 823,125 | 1,324,083 |
| 2 | 1,033,667 | 843,125 | 524,125 |
| 3 | 956,167 | 645,667 | 760,250 |
| Median | 1,033,667 | 823,125 | 760,250 |

Verification and first read used separate readers and therefore separate
decodes; their latencies must not be added or presented as one operation. Each
first-read reader reported `decode_count = 1` and
`decoded_bytes = 17,630`. Canonical `src4/cold.zig` still returns
`CodecUnavailable` without caller-supplied hooks. Its identity hooks validate
accounting only and are not compression. The real vendored adapter remains in
the non-build4 codec layer until build wiring is explicitly authorized.

## External gate

Rubric #7 is decided by the current-source retained campaign at
`bench4/results/latest`. A qualifying run executes actual `src2` and LEX4 over
identical inputs for all five fixtures and retains complete bytes, matched
timings, semantic digests, and every honestly available ablation. Its generated
report is authoritative about passes, failures, and unavailable mechanisms;
internal candidate minima, projected/reference rows, and the grammar-section
ledger above cannot substitute for it. Benchmark-specific encoding assumptions
or format changes are prohibited.

## Ablation gate record

The benchmark report distinguishes a controlled component ablation from a
matched cross-generation observation. A cross-generation row is useful
evidence, but it changes too many mechanisms at once to identify the effect of
one proposal choice. The retained `lex2-current-native` and `lex4-native`
profiles therefore appear under `cross_generation_observations` in
`benchmark.json` (same fixture, independent build/open/verify, equal oracle,
and the same native reader-self timing boundary), not as automaton/front-code
or grammar/blocks ablation numbers.

The exact controlled-variant audit is:

| Row | Status | Source/API evidence |
| --- | --- | --- |
| automaton vs front-code | unavailable as a controlled ablation | `src4/automaton.zig::Builder` and `src2/keys.zig::Builder` are separate builders; no same-compiler switch exists. |
| outputs | unavailable as a controlled ablation | `src4/axes.zig::AxisBuilder.build` chooses single-target delta mode or the generic directory from input collisions; no force-both API exists. |
| grammar vs blocks | unavailable as a controlled ablation | `src4/grammar.zig::build` has only the L4GC grammar wire; `src2/prose.zig` is an independent block reader/writer. |
| entropy vs packed | measured only from retained component evidence | `src4/entropy.zig::buildForced` exposes both strategies. A report admits a number only when the component probe retains both complete wires, independent `open`/`verify`, equal value-oracle digest, matched reader timing, raw observations, and provenance. |
| memberships vs pairwise | unavailable as a controlled ablation | `src4/concepts.zig::pairwiseBaseline` is byte arithmetic, not a pairwise builder/view; only the membership wire can be reopened and verified. |
| interval planner | unavailable as a controlled ablation | `src4/rank.zig::operatorPlan` is a comptime trait and `src4/snapshot.zig::nodesForPrefix` always projects to intervals; there is no planner-off reader switch. |

No row is filled from a projected/reference result, a formula-only baseline,
or a benchmark-only encoding branch. The component evidence paths and raw
observations are emitted into the completed run's manifest when a canonical
probe is available; missing evidence leaves the row unavailable with its
source/API reason.

The retained component probe is `bench4/component_ablations.zig`. It calls the
public `src4/entropy.zig::buildForced` writer for both strategies, reopens the
complete envelope, runs `verify`, checks the checkpoint index, decodes and
probes the values against one deterministic lane oracle, and records a shared
reader timing boundary. `bench4/run.py --component-executable` stages all
low/medium/high wires, the JSONL ledger, stderr, and the component executable
provenance; the report admits the row only after checking each staged wire's
actual size and SHA-256. Membership/pairwise is deliberately not emitted:
the available readers expose different query contracts, so normalizing their
answers would not create a controlled proposal ablation.
