# LEX4 unification: facts, coordinates, and projections

8 September 2026. Implemented design, retained experiments, and remaining
questions. Optimized results below are distinguished from the explicitly
corrected preliminary Debug observations.

## The architecture at the frozen control

The primary automaton maps byte strings to entry-rank intervals. The forest
maps those roots to preorder ranges, then counts each semantic kind within a
range. The text map maps text-kind ranks to zero or more grammar-item ranks.
The grammar maps symbols to output bytes. Derived axes and terms map another
ordered key space back to entry ranks. Concepts map senses to groups and back.
Assertions retain one canonical physical claim and sorted references for its
logical directions. These are not interchangeable semantic objects, but their
bookkeeping repeatedly stores coordinates and projections between coordinates.

The frozen control failed to exploit that common structure consistently:

- Graph records and their search references have four separate fixed-width
  serializers. The rich retained graph is 168,064 bytes. Its 2,098 memberships
  alone cost 134,272 bytes: 32 bytes per fact plus two 16-byte references.
  The same unqualified sense/concept membership is also in the 6,616-byte
  concept section. Language is already in the sense metadata.
- A constant forest pays 828 bytes of checkpoints although each checkpoint
  is a linear function of its ordinal. `kindRankAt` replays up to 255 roots
  even when the wire already proves every root has the same skeleton.
- The text map has six separately named storage modes for mappings that are
  functions of rank; graph fields use fixed widths; metadata has another
  independently implemented scalar cascade.
- `Entry`, prose handles, and query helpers repeat navigation paths. A kind
  interval alone does **not** preserve subtree ownership. Projecting selected
  senses to examples needs structural scope, not just integer endpoints.
- Raw and authenticated prose readers repeat traversal and packed-field logic.

These observations come from the implementation, not proposal-v4's projected
model. General TEI import, all declared schema columns, and real-corpus claims
remain separate delivery questions.

## Derivation: remove stored consequences and serial dependencies

[Ben Joffe's time-of-day derivation](https://www.benjoffe.com/fast-time-of-day)
starts with a dependency chain and changes the formulation so independent
coordinates can be computed together. The analogous question here is not
which extra codec to add, but which coordinates we can derive directly from
the same identity and which repeated facts we should never store twice.

### One scalar representation, generated records

For an unsigned field indexed by row `i`, store

```
value(i) = base + step * i + packed_residual(i)
```

Constant, identity, shifted identity, and ordinary packed values are parameter
values of this equation, not separate decoder strategies. Choose the model
from finalized values by complete encoded size. At minimum compare step zero
with the integer slope of the endpoints; fit the lower envelope exactly and
retain nonnegative residuals. Ties prefer step zero. Never infer values from
fixture names or external source inputs.

The decoder must prove its arithmetic envelope before accessing data, check
residual tails and value domains, and reject invalid enum/optional encodings.
An empty/default-zero field needs no descriptor. A comptime `Table(Row)`
derives scalar leaves from a Zig record, including nested endpoints and
optional values. It generates one writer, verifier, field accessor, and row
accessor. A binary search can read just its key fields, without reconstructing
unneeded attributes or following an extra record reference.

The initial consumers are all four graph tables and text-owner spans. This
is a concrete removal of serializers and mode dispatch. The metadata delta
dictionary is **not** blindly replaced: prefix-summing a compressed difference
lane has a different random-access cost. Further migration needs an ablation.

### One owner for a fact; projections carry ranks

An unqualified functional concept assignment belongs to the compact concept
index. Its inverse serves both member enumeration and translation filtering.
It must not be copied into general qualified membership rows merely because
one query currently starts from the graph API. The compiler/adapter must
establish eligibility from actual cardinalities and qualifiers, and both
operations must read the same reopened owner. Qualified or multivalued claims
remain real records; they cannot be silently reduced to one assignment.

Graph search order and logical reverse directions remain projections of
canonical physical records. Preserve assertion direction, qualifiers, source,
and inverse/symmetric semantics. Packing fields does not authorize merging
distinct claims or storing inferred arcs as asserted ones.

### One structural selection with composable measures

A document selection retains its preorder scope and typed result domain.
`count(kind, boundary)` is the common measure. For repeated skeletons it is
`root_ordinal * count_in_skeleton + local_prefix`; for mixed skeletons it uses
the same measure over the checkpointed sequence. The inverse operation selects
a kind occurrence through the same counts, enabling navigation from a sense
rank without a full forest scan or a per-node lookup table.

Comptime navigation legality must use `legalParent` (the intersection of both
declarations), not one side of the schema. A chain can fuse projections only
when that graph proves the intermediate kind dominates the target. For
example, a direct projection cannot generally stand in for an arbitrary
selected subset of senses. Noncontiguous subtree unions need a lazy ordered
iterator and overlap suppression, not an invented enclosing interval.

### One execution body per source contract

Raw bytes and authenticated ranges should instantiate one prose traversal.
The source type is a compile-time choice; authentication still covers every
touched rule, sequence symbol, boundary, and alias lane. Share checked word
loads, including unaligned nine-byte windows and exact short tails. Derive
fields from the same record window together, avoiding repeated range lookup.

## Acceptance and rejection rules

Freeze the current source and executable, rebuild all five complete artifacts,
and independently check identical operation/structure results. Keep all byte
overhead, source hashes, raw timings, and failed experiments. Report exact
hits separately from misses, full rendering separately from snippets, and
server-ready startup separately from envelope open and full verification.
Measure dependency latency and throughput separately when using a batch probe.

Admit a refactor only when it removes duplicate algorithms or redundant stored
facts and preserves safety. Charge every descriptor, alignment byte, cache,
workspace, and preparation pass. Do not combine one variant's size with another
variant's latency. No global-frontier or real-corpus victory follows from the
synthetic fixture ledger.

`build4.zig` remains unchanged. New shared tests must be reachable through the
existing imported suites. The frozen control is under
`experiments/frontier/unification-20260908/control/`.

## Directions to explore after these experiments

The [next-experiments proposal](lex4-next-experiments.md) develops the three
larger architectural directions below into concrete hypotheses, prototype
boundaries, and rejection gates. None is claimed as implemented here.

- A measured sequence/DAG abstraction shared by automaton accepted-counts,
  forest kind-counts, and grammar expansion lengths: same algebra, but avoid a
  generic interpreter that loses specialized hot loops.
- Extend the implemented compile-time dominance fusion to joins with
  assertion endpoints, language predicates, and mixed-content text runs.
  Keep ownership scopes in the proof; a bag of kind ranks is insufficient.
- Shared incidence projections for terms, derived axes, qualified membership,
  and assertions, with one boundary primitive and rank-only references.
- Prefix measures over compressed difference lanes, balancing direct indexing
  against checkpoint replay; this is necessary before unifying metadata IDs.
- Dictionary- or frame-adaptive residual slopes, only if their complete
  descriptor cost beats the single affine model on non-synthetic input.
- Grammar rules as small straight-line copy programs, with independent source
  and destination offsets; compare cacheless execution before adding memory.
- A typed verified-table capability that removes repeated scalar-domain
  checks without creating parallel raw/verified decoding implementations.
  Do not introduce unchecked reads through an ordinary borrowed `View`.
- Rank/source-identity inversion without eagerly expanded ID maps. A succinct
  permutation may unify the remaining metadata, terms, and axis references,
  but its startup cost, resident bytes, and random access must all be charged.
- Real TEI dictionaries with mixed content, irregular senses, provenance, and
  multiple competing assertions. They are required to test whether these
  simplifications transfer beyond generated repeated structures.

## What landed, and what was deliberately not generalized

`Table(Row)` derives nested scalar leaves, optional presence/value pairs,
enum admission, complete wire accounting, one verifier, and direct row/field
projections from the record declaration. Opening lowers each descriptor once
into a fixed borrowed lane. It proves the affine arithmetic in `i128`, so
queries reconstruct values with bounded `i64` multiply/add rather than
repeating checked wide arithmetic or searching descriptors per field.

Assertions and qualified memberships now use the same sorted endpoint-stream
operation: one lower bound, then stop when the key changes. Computing an upper
bound before yielding was unnecessary work, not an index that needed a more
elaborate replacement. All cursors require a verified, immutable table.

The grammar has one traversal and one semantic-validation body across raw
and authenticated source types. It executes the left child directly, keeps
only pending right siblings on the stack, and keeps sequence state outside
the stack. A scratch slot is four bytes instead of 24. Packed rule fields are
derived from one record window; the wide-record fallback is still checked.
No decoded-rule cache or item-length array was added.

The common packed reader now lowers exact 1–8-byte windows at comptime;
unaligned 64-bit fields read their necessary ninth byte separately. This
replaces a serial byte-accumulation loop. Concepts also use this primitive
instead of their private bit-by-bit reader/writer. The actual optimized ARM64
code was inspected, and 1,552 cases passed with inaccessible pages immediately
before/after the readable region. That is a bounds-safety probe, not timing.

Typed selections are immutable plans seeded by entry intervals, arbitrary
sorted rank sets, or concept members. Schema-dominance fusion removes an
intermediate kind only when every legal path crosses it. Disjoint and nested
scopes retain their exact subtree union; zero/many text spans emit once.
Forest topology is verified before applying the proof. Source identities are
never substituted for forest ranks, and concept-to-forest composition checks
its domain cardinality at the API boundary.

The native fixture projection explicitly supports one sense per entry, not
an arbitrary TEI importer. It rejects unsupported ownership shapes and
inconsistent forward/reverse concept declarations. Independent tests use
zero, negative, sparse, and nonmonotonic IDs, change membership/language and
assertions, delete the input files, and query only the reopened artifact.
The core structural tests exercise deeper subsenses and multiple definitions;
that does not make the benchmark projection a full TEI implementation.

Metadata delta dictionaries were not forced into the affine table: cumulative
differences and direct random-access residuals have different costs. Likewise,
the automaton, forest, and grammar retain specialized hot loops. The desired
unification is common coordinate algebra and one fact owner, not a universal
runtime interpreter with a growing collection of strategy cases.

## Measurement correction and acceptance

The first direct benchmark builds accidentally put `-O ReleaseFast` after
both module declarations. Zig resets per-module settings after `-M`, so those
readers were Debug builds. They are retained and explicitly disqualified as
optimized latency evidence in
[OPTIMIZATION-CORRECTION.md](../experiments/frontier/unification-20260908/OPTIMIZATION-CORRECTION.md).
Their independently verified artifact bytes remain valid. The build-system
Debug/Safe/Fast test matrix was correctly configured and is unaffected.

Final measurements use new executables from `build_release.py`, with
optimization set before each module and a two-module compile-mode assertion.
The initial short-load-only timing experiment was noisy and did not establish
a standalone performance win. Its raw observations remain available; it is
not silently replaced by the combined follow-up. Final numeric evidence follows.

## Corrected before/after results

All figures here use the frozen control and final **ReleaseFast** readers,
2,048 generated base records plus 50 homographs (2,098 entries), all five
fixtures, three alternating rounds, 600 warmups and 4,000 mixed measured
operations per reader/round. These are warm-cache macOS ARM64 observations,
not cold-disk latency. All rounds, exact hit/miss classes, p50/p95/p99,
complete files, semantic checksums, and hashes are retained under
[paired-release](../experiments/frontier/unification-20260908/paired-release/).
The [analysis](../experiments/frontier/unification-20260908/paired-release-analysis.json)
reports the median of the three per-round medians, never a pooled percentile.

| Fixture | Complete bytes, before → after | Full render µs, before → after | Snippet µs, before → after | Build ms, before → after |
|---|---:|---:|---:|---:|
| Flat | 66,072 → 64,848 | 7.166 → 2.000 | 3.542 → 1.167 | 170.21 → 171.10 |
| Repeated | 37,328 → 36,104 | 4.334 → 1.250 | 3.250 → 0.916 | 92.79 → 91.03 |
| Prose-heavy | 36,464 → 35,240 | 32.167 → 8.625 | 4.250 → 1.167 | 339.06 → 329.44 |
| Pathological prefix | 60,304 → 59,080 | 5.375 → 1.583 | 3.250 → 0.959 | 157.36 → 160.02 |
| Rich | 241,480 → 74,912 | 6.125 → 1.584 | 3.292 → 1.000 | 203.36 → 167.32 |

Full rendering improves **3.40–3.87×** across the five fixtures. Rich whole-file
size falls **68.98%**. Every ordinary fixture saves exactly 1,224 bytes:
920 forest-summary bytes plus 304 text-map bytes. The rich ledger is:

| Rich section | Before B | After B |
|---|---:|---:|
| Primary automaton | 6,394 | 6,394 |
| Text ownership | 408 | 104 |
| Concepts | 6,616 | 6,616 |
| Forest | 1,073 | 153 |
| Identity metadata | 1,011 | 1,011 |
| Grammar prose | 28,903 | 28,903 |
| Assertions/memberships | 168,064 | 2,752 |
| Reversed index | 9,088 | 9,088 |
| Terms | 19,347 | 19,347 |
| Header, directory, page digests, padding | 576 | 544 |
| **Total** | **241,480** | **74,912** |

The graph saving is not attributed entirely to compression. Removing the
duplicate functional membership owner eliminates 134,272 bytes of old fixed
rows/references. Generated packing saves the remaining 31,040 graph bytes,
including the revised graph envelope and empty-table overhead. Fewer digest
pages save another 32 container bytes. No prose, source identity, qualifier,
or asserted direction was dropped. Every before/after artifact hash is also
identical to its corresponding Debug-produced artifact.

Rich member enumeration is 1.167 → 1.084 µs, translations 2.833 → 0.791 µs,
and asserted relations 1.209 → 1.167 µs. The initial Debug relation regression
motivated shared short loads and lower-bound streaming; it is not present in
this optimized median. Do not infer a large independent relation speedup
from a 42 ns change near the clock's resolution.

Exact lookup is **not** a general win: exact-hit medians are flat
0.750 → 0.875 µs, repeated 0.666 → 0.666, prose-heavy 0.875 → 0.750,
pathological 0.791 → 0.791, rich 0.750 → 0.709. Prefix/select likewise contain
small regressions and noise. This rewrite does not change the primary
automaton's wire or claim to solve its lookup dependency chain.

### Opening, throughput, and memory: separate boundaries

The [direct kernel](../experiments/frontier/unification-20260908/kernel-release/)
reopens and verifies the same five artifact pairs, derives its keys and first
definition from the artifact, and checks identical semantic results. Each
metric has two warmup and 16 measured batches. No JSON parsing or process
launch is inside these timers. The envelope lane materializes each returned
view behind a compiler barrier; query/render lanes use a caller-owned trust
bitmap and preverified views.

| Fixture | Envelope open ns, before → after | Dependent exact ns/call, before → after | Four-stream exact ns/call, before → after |
|---|---:|---:|---:|
| Flat | 6,198.50 → 523.39 | 328.88 → 326.69 | 331.27 → 323.08 |
| Repeated | 5,825.63 → 530.99 | 327.69 → 328.09 | 330.68 → 325.42 |
| Prose-heavy | 5,742.61 → 525.45 | 327.69 → 325.57 | 333.56 → 323.91 |
| Pathological prefix | 5,522.73 → 553.75 | 238.30 → 220.21 | 232.75 → 221.43 |
| Rich | 5,685.52 → 600.04 | 327.66 → 325.73 | 345.88 → 328.23 |

Envelope opening improves **9.5–11.8×**, chiefly by precomputing the unchanged
schema-manifest digest. It still validates the actual header/directory and
compares the expected digest. It does not imply that full verification or
process startup is 10× faster. Process-ready medians, including launch,
loading, verification, and adapter preparation, are:

- flat 5.99 → 4.94 ms; repeated 5.25 → 5.13 ms; prose-heavy 6.68 → 6.17 ms;
- pathological 6.58 → 7.10 ms; rich 7.64 → 8.82 ms.

The last two regress in that three-round workload. A separate
[startup-only probe](../experiments/frontier/unification-20260908/startup-release-final/)
then launches 30 fresh processes per variant/fixture after two warmups, in
alternating order. It uses the retained artifacts and validated ready event,
supplies no fixture input or query schedule, and excludes shutdown. Its
control → final medians are flat 4.237 → 3.857 ms, repeated 3.477 → 3.324 ms,
prose-heavy 3.596 → 3.415 ms, pathological 4.280 → 3.804 ms, and rich
5.220 → 4.542 ms. That is a 4–13% median reduction in this warm-filesystem
probe, not a universal startup win or cold-disk result. Both experiments and
all samples are retained; the different surrounding workload matters.

The direct lookup probe has 128 prepared
keys, but its result-dependent cycles visit **7–16 distinct keys per lane**.
It is a small warm-working-set test. Four lanes execute in one interleaved
loop with independent states, not four separately timed serial loops. Their
shared elapsed time is recorded four times alongside individual checksums;
count it **once**, with 4× calls. No meaningful four-way throughput breakthrough
was measured. A real multikey automaton kernel remains an open experiment.

`Snapshot` grows from 2,504 to 4,088 bytes for fixed lowered table lanes and
typed-view state. At 512 caller-chosen render frames, stack storage falls
from 12,288 to 2,048 bytes. These are explicit type/workspace sizes, **not**
total process RSS: allocator overhead and verification-arena retention are
not included. The main harness retains aggregate driver-process RSS, which
cannot be attributed to an individual reader or format.
No per-entry render cache or expanded metadata answer table was introduced.

### Real external formats and the current src2 reader

The final Nix campaign,
[unification-2048-release-final](../bench4/results/unification-2048-release-final/BENCHMARKS.md),
rebuilds and reopens the same semantic fixtures through actual src2 and LEX4
native readers, SQLite, StarDict, dict-index, and the installed SLOB reader
with both uncompressed and LZMA2 storage. Source and executable provenance,
complete artifacts, operation samples, independent semantic digests, and all
file hashes are retained. Root independently rechecked both provenance and
the complete run manifest after promotion; neither had a mismatch.
The SLOB writer uses `min_bin_size = 64 * 1024` and its library's default
LZMA2 settings; this is one explicit profile, not a compression-parameter sweep.

These are complete artifact bytes, including each format's metadata and
sidecars, not compressed payload estimates:

| Fixture | LEX4 | Current src2 | SQLite | StarDict, raw | dict-index, raw | SLOB, raw | SLOB, LZMA2 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Flat | 64,848 | 224,028 | 397,312 | 322,165 | 327,422 | 358,948 | 94,928 |
| Repeated | 36,104 | 219,100 | 393,216 | 320,629 | 325,880 | 357,396 | 93,741 |
| Prose-heavy | 35,240 | 203,228 | 2,875,392 | 2,653,301 | 2,662,722 | 2,690,644 | 108,228 |
| Pathological prefix | 59,080 | 244,124 | 442,368 | 342,154 | 347,417 | 378,937 | 114,917 |
| Rich | 74,912 | 348,796 | — | — | — | — | — |

LEX4 is **31.69–67.44% smaller than SLOB/LZMA2** on these four flat profiles.
Rich external-format cells are unavailable: those adapters do not implement
the same graph semantics, so an entry-only export would not be a comparison.
StarDict/dict-index numbers here are explicitly their raw profiles, not every
possible compressed variant. This is evidence on generated fixtures, not a
claim to beat every dictionary format or real-world corpus.

External adapters use host-language timing while native readers self-time
the reader operation; the report refuses cross-boundary latency ratios.
The mock/reference profile remains clearly labeled and is not a native
competitor. The campaign's single-run timings are not substituted for the
three-round before/after medians above. Only the entropy-vs-packed component
ablation is presently measured; five proposal ablations remain explicitly
unavailable because their required alternative production builders/readers
do not exist. Cross-generation comparisons are not controlled ablations.

### Validation and source accounting

- Full build-system Debug, ReleaseSafe, ReleaseFast: **562/562 tests** and
  39/39 steps in each; logs are `accepted-tests-*.log` in the experiment folder.
- Normal benchmark build: 3/3 steps, explicitly ReleaseFast; `build4.zig`
  SHA-256 remains `93465e1ff3e2c54b77dc4b91af4ef27d497c40f4aa4c72ae81e7d8bd865fb2e8`.
- Nix host/integration tests with the actual optimized reader: **45/45**.
- Optimized packed-load guard-page check: **1,552 assertions**; generated
  assembly, library, and SHA-256 are retained.
- Final Luna/max [read-only evidence review](../experiments/frontier/unification-20260908/FINAL-REVIEW.md):
  no blocking finding; independently checked modes, manifests, semantic
  agreement, timing denominators, and documented limits. It did not rerun
  the test matrices or performance campaigns.
- Focused hostile tests cover packed tails/overflow, optional and enum domains,
  missing-key stream boundaries, cyclic/oversized grammar expansion, forged
  alias checkpoints, and authenticated malformed structural edges before
  compile-time fusion can be used.

The code is not smaller in aggregate. Physical production-file lines
(including embedded tests/comments) grow from 17,464 to 18,413; focused test
files contain 4,416 lines. The structural simplification is six text-map modes
replaced by one equation, four generated graph tables replacing ten bespoke
serialization/access paths, shared raw/source grammar execution/validation,
and immutable typed plans instead of repeated navigation helpers. Grammar
falls 1,632 → 1,527 lines, text ownership 616 → 357; the new shared table,
inverse forest selection, topology proofs, comments, and tests cost lines.
No compactness score is improved by hiding code in generated output.

## Acceptance decision and reproduction

Keep the generated coordinate table, single functional fact owner, typed
scope-preserving plans, measured forest summaries, and shared continuation
renderer. They remove real duplicated algorithms or stored facts and improve
complete storage and rendering on every retained fixture. They do not earn
an exception to hostile validation or authenticated reads. The cost is larger
fixed view state and more total source lines; exact lookup is broadly neutral
and startup remains workload-sensitive. No global novelty or full-TEI claim
is made. The next major gate is irregular real-corpus data, not another
synthetic fixture-specific encoding mode. The exploration list above records
the larger ideas deliberately left open.

From the repository root, use unused output/run names when reproducing:

```sh
python3 experiments/frontier/unification-20260908/build_release.py
nix develop --command zig build --build-file build4.zig test -Doptimize=ReleaseSafe
nix develop --command python bench4/run.py \
  --records 2048 --repetitions 2000 --warmup 300 \
  --native-executable experiments/frontier/unification-20260908/final/bin/lex4-final-release \
  --src2-executable bench4/zig-out/bin/src2-bench \
  --component-executable experiments/frontier/unification-20260908/final/bin/components-release \
  --run-id unification-reproduction
```

The src2 executable is built through `bench4/build_src2.zig` as documented in
the [benchmark guide](../bench4/README.md), with the real vendored codecs.
Repeat the test command with `Debug` and `ReleaseFast` for the full matrix.
`compare.py`, `kernel_run.py`, and `startup.py` in the retained experiment
directory reproduce the narrower paired boundaries. Correct module flag
ordering is part of the experiment, not an optional optimization hint.
