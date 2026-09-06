# Benchmark methodology

`bench/benchmark.zig` is a deterministic experiment driver for the raw and
bzip3 snapshot payload profiles. It is intentionally separate from the library build so
benchmark-only policies cannot become format or API promises.

Build and run it from the repository root:

```sh
zig build --build-file bench/build.zig test -Doptimize=Debug
zig build --build-file bench/build.zig -Doptimize=ReleaseFast
./bench/zig-out/bin/lexicon-bench --records=20000 --repetitions=20000 --warmup=2000
```

Select the complete snapshot payload and posting profiles explicitly:

```sh
./bench/zig-out/bin/lexicon-bench --payload-codec=raw --posting-encoding=raw --no-codec
./bench/zig-out/bin/lexicon-bench --payload-codec=raw --posting-encoding=adaptive --no-codec
./bench/zig-out/bin/lexicon-bench --payload-codec=bzip3 --posting-encoding=raw --no-codec
./bench/zig-out/bin/lexicon-bench --payload-codec=bzip3 --posting-encoding=adaptive --no-codec
```

Each command builds and measures the selected complete snapshot, and reports
both selections as `config.payload_codec` and `config.posting_encoding`.
`--no-codec` skips the separate low-level block comparison; it does not change
the snapshot profile. If a
checkout predates `Writer.initWithOptions`, a bzip3 profile must be reported as
unavailable rather than relabeling a raw snapshot. Low-level codec measurements
are emitted under `lowlevel_codec.*` and must not be presented as a
whole-snapshot result.

The output is tab-separated `metric`, `name`, `value` records. Save it as an
artifact together with the command line, Zig version, target, optimization
mode, CPU model, operating-system power state, and repository revision. The
harness records Zig and target metadata plus its seed/configuration directly;
machine and VCS metadata belong in the surrounding run record because they are
not stable library inputs.

The fixture uses a fixed xorshift64* generator and a fixed seed. Keys have
repeated stems to create duplicate-key postings, while every seventeenth key
contains non-ASCII text. Definitions contain repeated lexical prose and a
small deterministic variant set. The workload mixes exact hits, exact misses,
prefix hits, and prefix misses in a fixed four-way sequence. Definition IDs
are selected independently from the same seed stream. The fixture digest and
every lookup result are checked, so an implementation cannot remove work and
silently return different answers.

Each timed class performs a warmup phase, then a measured phase. Exact and
prefix lookup counters are reset immediately before measurement. The reader's
`keyRecordsExamined` and `payloadReadCount` counters are reported per completed
operation. Definition lookups additionally checksum returned bytes. A checksum
is consumed after each lookup; the compiler cannot replace the loop with an
unused-result loop without changing observable output. The output checksum is
an integrity guard, not a cryptographic claim.

The main measurements are:

| Metric | Meaning |
| --- | --- |
| `fixture.snapshot_bytes` | Complete encoded snapshot length, including all sections and directory overhead. |
| `fixture.snapshot.*_bytes` | Header, directory, and per-section ledger entries included in the complete snapshot. |
| `fixture.build_ns` | Writer build time after fixture construction, including canonical sorting and payload layout. |
| `config.posting_encoding` | Posting representation selected for this run: raw or adaptive. |
| `exact.*` | Exact hit/miss lookup time, throughput, output count, and key records examined. |
| `prefix.*` | Prefix hit/miss lookup time, throughput, output count, and key records examined. |
| `definition.*` | Definition retrieval time, returned bytes, and payload reads. |
| `config.payload_codec` | The codec used by the complete snapshot payload blocks. |
| `lowlevel_codec.*` | Independent raw versus bzip3 block size and encode/decode time over the same generated definitions. |

The benchmark's current comparison is a baseline measurement, not a claim of
superiority. Run the same binary and workload across revisions and record
Debug, ReleaseSafe, and ReleaseFast separately. Do not combine one build's
size with another build's latency. Report medians and tail latency from an
external repetition runner when making performance claims; one process run is
useful for smoke checks but does not characterize a machine.

The plan's proposed tenfold target is evaluated only after a declared baseline
and a matched competitor run exist. For each workload, compare complete
snapshot bytes, build time, p50/p95/p99 lookup latency, throughput, decoded
payload bytes, key records examined, and peak memory under the same answers and
warm/cold policy. A “10x” result is valid only when the same metric improves by
at least 10.0 on the same workload and configuration; compression ratio alone
cannot support a lookup-latency claim. The harness deliberately makes no
invented hardware numbers and prints no 10x verdict.

The benchmark does not measure semantic fidelity. Semantic round-trip,
relation identity, unresolved targets, mixed-content order, and preservation
tests belong to the semantic model and serialization suites. Likewise, the
low-level codec comparison does not establish that bzip3 is the best layout;
block placement, metadata, cache policy, and complete-file overhead are
included only in the selected complete snapshot profile.

`bench/semantic_benchmark.zig` measures the semantic model separately. It
builds repeated-string and unique-string fixtures containing multilingual
values, distinct source occurrences, QNames, repeated roles and namespaces,
evidence, anchors, mixed text/comments/processing instructions, and temporal
assertions. For each fixture it reports complete reference and compact encoded
bytes, encode/decode time per repetition, checksums, and a decoded-model query
checksum. The compact profile is reported unavailable until the compact API is
present; the harness never labels the reference encoding as compact. Run it
with:

```sh
zig build --build-file bench/build.zig semantic-test -Dsemantic=true -Doptimize=Debug
zig build --build-file bench/build.zig -Dsemantic=true -Doptimize=ReleaseSafe
./bench/zig-out/bin/semantic-bench --records=16 --repetitions=8
```

The semantic byte metric is the complete encoded artifact returned by the
format API, including its header, section counts, shared value pools, IDs,
checksums, and all metadata. No component is omitted from the reported total.
The repeated and unique fixtures are controls for measuring interning gains;
they are not forecasts for a production corpus.
