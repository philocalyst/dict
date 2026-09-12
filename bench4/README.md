# LEX4 benchmark harness

## Acceptance status

**Rubric #7 — cross-generation size/performance evidence is decided only by
the retained current-source campaign at `bench4/results/latest`.** Primitive
suites prove internal adaptive-candidate minima and compactness/scaling
ledgers, but do not by themselves constitute a comparison with `src2` or
prove the `build4.zig` integration path. The generated report records each
proposal target as measured, failed, or unavailable without upgrading a
projection into evidence.

Close this gate only with a retained run that builds `src2` and LEX4 from the
same inputs for all five fixtures, executes the allowed `build4` integration,
and records complete artifact bytes, matched timing boundaries, semantic
digests, and the required ablation rows. A reference model or projected LEX2
row is not a substitute for executing the actual `src2` implementation. The
benchmark must adapt to the format as implemented; benchmark-specific encoding
choices or assumptions are forbidden.

The benchmark is intentionally independent of `src4`: `oracle.py` owns the
semantic answers, while `adapter.py` owns reader implementations. A native
reader must implement the JSON-lines contract described by
`SubprocessAdapter`; until then the run uses explicitly labelled reference and
SQLite adapters.

Run a small complete campaign:

```sh
python3 bench4/run.py --records 64 --repetitions 256 --warmup 32
```

Supply both compiled readers to make the cross-generation row real:

```sh
python3 bench4/run.py \
  --native-executable /path/to/lex4-bench \
  --src2-executable /path/to/lex2-bench \
  --records 2048 --repetitions 1000 --warmup 200
```

To retain the one controlled component ablation currently exposed by the
production API, build and pass the canonical entropy probe as well:

```sh
zig build-exe -O ReleaseFast --dep src4 \
  -Mroot=bench4/component_ablations.zig \
  -O ReleaseFast -Msrc4=src4/root.zig \
  -femit-bin=/tmp/lex4-component-ablations
python3 bench4/run.py \
  --native-executable /path/to/lex4-bench \
  --src2-executable /path/to/lex2-bench \
  --component-executable /tmp/lex4-component-ablations \
  --records 2048 --repetitions 1000 --warmup 200
```

Zig resets per-module options after each `-M`: the optimization flag must
precede **both** module declarations. A trailing `-OReleaseFast` leaves
previously declared modules in Debug. Use `zig build --build-file build4.zig
bench4 -Doptimize=ReleaseFast` for the normal reader build; its build API sets
both modules explicitly. See `experiments/frontier/unification-20260908/
OPTIMIZATION-CORRECTION.md` for the retained correction to early direct runs.

`--component-executable` is optional. When supplied, `run.py` invokes the
probe with its own deterministic low/medium/high lanes, stages each complete
entropy and packed wire under `artifacts/component-ablations/`, retains the
JSONL ledger and stderr under `raw/`, checks every retained file's byte count
and SHA-256, and adds the executable to provenance. The report keeps all three
lanes under the measured `entropy_vs_packed` row. If the probe is omitted, or
its retained evidence fails any check, that row remains unavailable; no
in-memory or formula-only value is accepted. Membership/pairwise is not
emitted because the available readers do not share an identical query
contract.

Outputs are staged atomically under `bench4/results/<run-id>/`: `benchmark.json`
and `BENCHMARKS.md` are projections, `raw/observations.jsonl` retains every
warmup/measured operation, `artifacts/` retains encoded bytes, `provenance.json`
and `raw/provenance-end.json` bound the source/executable/environment, and
`hashes.tsv` hashes every completed byte except its own self-hash. A failed
semantic check or source-drift check prevents promotion to `latest`.

The workload separates exact hit/miss, prefix interval and prefix enumeration,
prefix cardinalities (zero/one/many/pathological), select/render/snippet, and
rich concept/graph operations. Missing adapters are explicit unavailable
rows, never zero-valued metrics.

Reader latency and process transport are separate metrics. Reference and
SQLite adapters use the harness clock around one reader method. A native
adapter uses the `reader_self` response timing described below for the reader
core; the harness independently retains outer JSONL request/response time.
Host-operation profiles do not expose a fabricated transport metric.
Native-vs-baseline latency ratios are emitted only when both profiles have the
same timing boundary; native reader-self time is therefore not conflated with
Python host-operation time from external formats. Native transport latency is
reported as a diagnostic and is never substituted for the proposal's native
latency gates. Artifact-byte comparisons remain valid across boundaries.

## Native subprocess contract

The native command is invoked without a shell in three phases:

```text
<cmd> --bench4-build --fixture NAME --records N --corpus INPUT.tsv --semantic-input FIXTURE.json --output ARTIFACT
<cmd> --bench4-verify --artifact ARTIFACT
<cmd> --bench4-server --artifact ARTIFACT
```

Before accepting requests, the server emits exactly one readiness line after
loading and verifying its retained artifact:

```json
{"protocol":"LEX4-BENCH/1","event":"ready","artifact_bytes":1234}
```

`artifact_bytes` is the actual primary file length. The adapter validates the
event and waits for it before ending `open_ns`; startup includes process
launch and readiness, not merely process creation. Full bundle hashes are
checked separately. It is not a cold-filesystem-cache measurement.

The native fixture projection owns one sense per entry when rich semantic
rows are supplied. Those sense ranks follow forest/entry order, independently
of source-ID ordering. Forward sense/concept assignments and inverse member
lists must agree; only the compact concept index retains the fact. Qualified
asserted relations remain graph records. Unsupported sense cardinalities are
rejected rather than silently collapsed. This benchmark projection is not a
claim of general TEI import support.

The server consumes UTF-8 JSON Lines. Every request has
`{"protocol":"LEX4-BENCH/1","request_id":N,"op":...,"sample":N}`;
Measured and warmup query requests additionally carry
`"timing_mode":"reader_self"`; the server must time only its reader
operation and echo that mode plus a nonnegative integer
`"reader_elapsed_ns":N` at the response top level. JSON parsing, response
serialization, and pipe I/O are outside this self-timed interval. The harness
still records the outer transport duration separately.
The response must be
`{"protocol":"LEX4-BENCH/1","request_id":N,"sample":N,"ok":true,"result":{...}}`.
`sample` is a deterministic, unique-per-scheduled-query request nonce and
must not change semantics.
The request contains fixture/query fields only: expected answers, oracle
digests, and the complete query schedule are never sent. `FIXTURE.json` is
canonical source input (including rich concepts/relations), not expected
query output. A malformed response,
id/version mismatch, early child exit, non-zero child status, or changed
artifact is fatal. `query_checksum` is intentionally not a protocol operation;
the harness validates each response independently and computes its digest
afterwards.

The result payloads are fixed by operation: `exact` and `prefix_enumerate`
return `{"ids":[...]}`; `prefix_interval` returns integer `{"lo":L,"hi":H}`;
`select` returns `{"id":ID,"key":KEY,"rank":R}`; `render` and `snippet`
return `{"bytes_hex":HEX}`; `concept_members` and `translations` return
`{"members":[...]}`; `relations` returns `{"relations":[...]}`; and
`structure_checksum` returns `{"sha256":HEX64}`. Empty exact/prefix inputs
carry an explicit `"key":""` field. IDs/ranks are integers and all returned
arrays are ordered according to the canonical fixture. The server must emit no
diagnostic text on stdout, must flush one response line per request, and must
exit successfully after stdin EOF.

The build phase must write a non-empty primary artifact at `--output`. Any
retained sidecars must live beneath that artifact's parent directory, must be
regular files (no symlinks), and must remain byte-for-byte unchanged from the
end of build through close; their bytes are included in the size ledger. The
verify phase is separate and read-only. The server phase receives only
`--artifact` and must not mutate the encoded bundle.

The native artifact is a whole-file snapshot, not only the protocol hot path:
every build includes the authenticated reversed-key axis and raw term/posting
index derived from definition bytes. Snapshot verification opens and verifies
both optional sections before serving requests. The native build emits a
`LEX4_BENCH_SECTION_LEDGER` diagnostic on stderr with total, section, reversed,
and term byte counts; it is not part of the JSONL protocol or benchmark timing.

For a pinned, Nix-friendly run use the same command shape inside the existing
development shell, for example:

```sh
nix develop .# --command python3 bench4/run.py --records 64 --repetitions 256 --warmup 32
```

`run.py` stages every output, writes a complete byte manifest excluding only
`hashes.tsv` itself, verifies it, and atomically promotes the completed
directory and `latest` pointer. Failed semantic, provenance, manifest, or
child-process checks leave no staging run eligible for promotion.
