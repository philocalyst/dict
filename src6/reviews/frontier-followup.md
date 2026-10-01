# After the real-corpus report

## What the evidence actually says

The retained [post-review report](../bench/real-world/evidence/reports/real-world-report-post-review.md)
compares complete normalized projections, not native linguistic graph adapters.
Its measurements do not establish interchangeability with all TEI/LIFT/OntoLex
tooling, nor a native-language speed ranking against Python reader harnesses.

At a 64 KiB page target, LEX6 adaptive files are 6,406,243 / 16,274,792 /
12,223,578 bytes for FreeDict / GCIDE / OMW Japanese. All pages selected real
bzip3. The native SLOB lzma2 files are 7,315,317 / 18,530,020 / 13,172,996 bytes;
SLOB's benchmark identity sidecars must not be counted as compression losses.

The important remaining cost is access amplification. Same-page session renders
take roughly 5–16 microseconds, whereas a compressed page miss is millisecond
scale. Larger pages improve storage but do not answer that problem. The next
compression experiment must separate its *learning horizon* from its *decode
horizon*: reuse corpus-wide redundancy without reconstructing a large page for
every small query. A faster decoder with worse storage is a tradeoff, not an
unqualified replacement.

## Structural changes, not line-count tactics

1. **One language-context rule.** Structural frames already know their Zig
   type. They now specialize the same `walk.Language.at` operation as lexical
   traversal and typed projections, removing the erased language callback from
   every node descriptor. Direct inline-element projection now respects both
   explicit language and reset. Identity still belongs to the actual metadata
   owner, not to a tagged wrapper.
2. **One admission traversal.** Validation collects identities and checks local
   semantics during the same bounded walk. Only local-link obligations wait
   until the table is complete. Those obligations borrow identifiers, include
   required target kinds, and consume the same work budget. Forward references
   remain valid. This trades a small pending-link buffer on linked documents for
   eliminating a second traversal of every document; allocator failures are
   tested, and documents without local links allocate no pending buffer.
3. **One archive admission contract.** Cached reads, uncached reads, and full
   verification use the same document-kind, semantic and resource-catalog
   checks. Previously the uncached path could admit a resealed resource whose
   identity disagreed with the catalog. A regression exercises all three paths,
   including reuse of an already decoded page.

These changes do not alter the packet schema, archive version, compression
selection or encoded bytes. Their latency effects must be measured separately
against the retained executable; unchanged storage is not evidence of speed.

Current production verification: 72/72 runtime tests (71 library plus one
independent client) in Debug, ReleaseSafe and ReleaseFast; four expected
compile-time misuse rejections in each mode. The prior 69-test matrix in
`resolution.md` describes the earlier frozen benchmark revision.

The independent [paired latency ledger](../bench/real-world/evidence/runs/simplifying-post-review-timing.json)
retains 36 successful samples: original/current executables, three corpora,
raw/adaptive codecs, three fixed pairs per lane. All output digests and cache
counters matched. No archives or query plans were rebuilt. Original always ran
first, so order bias remains possible; three samples do not establish a general
performance guarantee.

| Raw archive full verification | Before median | After median |
| --- | ---: | ---: |
| FreeDict | 341.10 ms | 297.80 ms |
| GCIDE | 460.97 ms | 396.47 ms |
| OMW Japanese | 740.51 ms | 662.80 ms |

Same-page render medians improved by 1.7–12.5% across the six lanes. Mixed-page
results are not uniformly better: OMW raw render rose 4.1%; OMW adaptive render
and snippet rose 2.3% and 4.1%. Metadata-open controls also varied despite no
change to their algorithm. The OMW adaptive **uncached** render batch rose
15.4%, a larger loss that also needs to remain visible. Adaptive full-verification
improvements were only 0.7–2.5%, unlike the 10–14% raw results above.
Preserve these observations rather than rerunning
until favorable. The harness has no separate same-page snippet phase; it must
not be inferred from the mixed-page snippet or same-page render result.

A separately retained [OMW order diagnostic](../bench/real-world/evidence/reports/real-world-report-simplifying-post-review-omw-adaptive-abba.md)
then ran exactly two original/current/current/original blocks, with no retries.
All eight processes passed. Its uncached-render median was 518.33 → 506.49 ms
(2.3% lower), with broad overlapping ranges. This makes the initial +15.4%
observation sensitive to order/variation; it neither erases that observation
nor proves a stable universal improvement. The original 36 samples are intact.

## Compression experiment acceptance

`bzip4` is an experimental working name, not an official successor or a claim
of novelty. Its isolated implementation lives under `experiments/bzip4` and is
not selected by production archives. A candidate must account for its complete
dictionary, model, framing, restart tables and integrity bytes. It needs held-out
inputs, deterministic lossless roundtrips, malformed-input and allocation-failure
tests, bounded decode memory, and comparisons against bzip3 at both the same
access granularity and the existing 64 KiB baseline. Training time and shared
state initialization are not free.

Useful prior art, not evidence of our own results:

- [bzip3](https://github.com/iczelia/bzip3) combines LZP/RLE, BWT and an order-0
  context-mixing entropy coder. Merely rearranging those stages is not proof of
  a new compression frontier.
- [Language Modeling Is Compression](https://arxiv.org/abs/2309.10668) motivates
  learned probability models. Model distribution cost, deterministic prediction,
inference latency and memory still matter for a portable dictionary reader.
- [Random Access to Grammar Compressed Strings](https://arxiv.org/abs/1001.1565)
  and [Compressed String Dictionaries](https://arxiv.org/abs/1101.5506) motivate
  sharing redundancy while retaining selective access.

### First codec result: reject production adoption

The [shared-LZ/online-predictor experiment](../experiments/bzip4/results/README.md)
used the first 1 MiB of normalized content for training and the next 8 MiB
for held-out evaluation. These are codec-section experiments, not complete
dictionary-file comparisons. At identical 16 KiB restart boundaries, even its
best charged dictionary choice lost to bzip3 on every corpus:

| Held-out corpus | Best candidate, complete frame | bzip3 matched frame |
| --- | ---: | ---: |
| FreeDict | 1,716,235 B | 1,189,002 B |
| GCIDE | 3,472,196 B | 2,362,319 B |
| OMW Japanese | 1,556,273 B | 1,124,142 B |

The timed 32 KiB-dictionary candidate also decoded more slowly. It is not a
replacement. Its numerical tables were transcribed from tool output; original
raw stdout was not retained, as the experiment's provenance notice explains.
Further comparisons must save raw output, commands and measured source/binary
hashes directly.

### Second codec result: a measured tradeoff, not a replacement

The pure-Zig BWT/MTF/zero-run/rANS candidate uses a charged 512-byte trained
model. A prepared entropy decoder is shared across blocks; move-to-front
decoding operates in place. These remove repeated preparation and a temporary
buffer without adding a new wire strategy. Parent review also caught overflowing
ULEB aliases and missing temporary/prepared-state budget charges before timing.

The implementation agent's fixed matrix used three serial samples for each corpus/boundary pair,
the same 1 MiB training / 8 MiB evaluation split, and no retries:

| Corpus | Block | Complete candidate frame | Matched bzip3 frame | Candidate decode median | Retained-state bzip3 decode median |
| --- | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 16 KiB | 1,195,903 B | 1,189,002 B | 98.35 ms | 204.13 ms |
| FreeDict | 64 KiB | 940,246 B | 899,408 B | 112.09 ms | 169.73 ms |
| GCIDE | 16 KiB | 2,490,928 B | 2,362,319 B | 133.07 ms | 346.47 ms |
| GCIDE | 64 KiB | 2,087,612 B | 1,905,560 B | 149.56 ms | 310.98 ms |
| OMW Japanese | 16 KiB | 1,194,897 B | 1,124,142 B | 99.20 ms | 241.93 ms |
| OMW Japanese | 64 KiB | 825,074 B | 674,384 B | 111.63 ms | 172.16 ms |

This is approximately 1.5–2.6× faster batch decoding at 0.6–22.3% greater storage.
Training costs roughly 63–94 ms; encoding results are mixed. This does **not**
establish faster end-to-end archive queries, cold-disk behavior, smaller complete
dictionary files, or universal superiority. It remains isolated from production.
All 18 processes emitted successful roundtrip output; the first process's exit
status was not captured because the surrounding shell bookkeeping failed after
output. That status is unavailable, not an invented zero; the remaining 17
statuses were captured as zero. No sample was rerun.

Provenance qualification: the agent retained a per-field transcription, not
directly captured original stdout files. These numbers remain provisional.
An independent Luna run of the entire prespecified matrix is required, saving
exact stdout/stderr and exit status automatically before parsing. Its purpose
is to resolve the capture gap, not to replace unfavorable measurements.

Root independently verified the final experiment build in Debug, ReleaseSafe
and ReleaseFast: 26 successful test executions per mode, representing 17
distinct tests because the second codec imports the first codec's nine tests.
The separate public-API audit exercises every independent block and 768
deterministic mutations. Exported trainer/encoder/parser/decoder paths also
compile for wasm32-freestanding and x86_64-linux without the bzip3 C control.
These are compile-only portability checks, not execution on those targets.

## Important experiments still outside this result

- **Fuse typed decoding and semantic admission.** `packet.decodeValue` builds
  the typed tree, then admission traverses it again. A `decodeInto(T, slot,
  observer)` specialization could notify the same semantic rules when each
  typed value is complete; the in-memory admission path would retain its cursor
  adapter. This is more substantial than shortening the walker. It must not
  retain pointers to temporary return-by-value structs: decode into final arena
  or root slots, finish admission before moving the root, and let no admission
  pointer escape. Forward local links already have deferred obligations;
  anchors would need the same treatment because entry-local sources occur later
  in the packet. Measure the added obligation memory against the removed walk.
  Require differential valid/invalid-model tests, allocation-failure cleanup,
  work/depth limits and unchanged wire bytes before comparing full decode/query
  latency. This remains a proposal, not implemented or benchmarked evidence.
- Native OMW shared-synset storage: the matched flattened projection introduces
  54,771,203 bytes of duplicate synset XML before compression. A native graph
  lane must preserve reference/occurrence semantics and coexist with the matched
  projection rather than quietly replacing it in the comparison.
- Typed corpus adapters and query workloads for senses, evidence, qualified
  relations and shared values. XML carried as text does not prove these features.
- Persisted logical-ID lookup versus explicit `prepareLinks`, with all storage,
  initialization and memory costs charged.
- Borrowed or selective packet decoding, provided the API makes page eviction
  and ownership unambiguous. Do not sacrifice current independently owned results.
- Query result capabilities rather than duplicated events: `StructuralMatch`
  currently retains a whole traversal event as well as its public node, parent,
  edge, depth and language fields. Retaining just the ancestor cursor/generation
  capability is worth measuring for smaller returned values. Preserve the
  existing invalidation rule; this is a layout hypothesis, not a measured win
  or a reason to erase typed query results.
- Bounded microblock dictionaries with entropy-coded match streams, compared
  against simple shared-LZ and bzip3 ablations before adding prediction machinery.
- Treat BWT as an addressable compressed index rather than a transform that
  must be inverted wholesale. Sampled LF/Psi navigation could share a large
  redundancy horizon while extracting short byte ranges. This is an application
  of existing [compressed self-index research](https://people.unipmn.it/manzini/papers/focs00.html),
  not a new algorithm claim. Rank structures, samples, integrity boundaries and
  per-output-byte navigation must all be charged. Byte searching also cannot
  replace typed lexical predicates or semantic admission.
