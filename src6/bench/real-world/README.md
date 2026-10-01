# Real-world dictionary comparison harness

This directory is an independent benchmark harness and evidence ledger.  It
does not modify any `src6` production file or reuse the synthetic fixtures in
`src6/bench/evidence`.

The first pinned corpus set is deliberately modest enough to run to
completion, but materially different in shape:

| corpus | exact input | license/provenance | reason for inclusion |
| --- | --- | --- | --- |
| FreeDict `eng-spa` | release `2025.11.23`, complete TEI source archive | CC BY-SA 3.0; source is the release's WikDict/DBnary export | bilingual short entries, translations and nested senses |
| GCIDE | `gcide-0.54`, complete `CIDE.A` through `CIDE.Z` files | GPL-3.0-or-later; GNU GCIDE distribution | long English entries, editorial markup and prose |
| OMW Japanese | OMW data release `2.0`, complete `omw-ja.xml` | NICT Japanese WordNet license, retained verbatim | Japanese script, morphology and synset-linked definitions/examples |

`prepare.py` downloads and checks the exact archives, retains license files,
extracts every complete record, and writes a matched projection.  The
projection is one row per source lexical record, with a `keys[]` array for all
of that record's spellings.  Each format uses its native alias mechanism where
one exists; a fallback that must duplicate payload bytes is called out and
charged separately.  Its three TSV fields are hex encoded UTF-8: stable row
identity, comma-separated `keys[]`, and normalized content.  Hex avoids TSV
quoting ambiguities and preserves empty content, Unicode, duplicate keys, and
embedded markup.  Source order and all source IDs are retained in
`rows.jsonl`; source lexical-record count, unique-key count, and total key-hit
count are reported separately.

The matched content policy is intentionally explicit.  FreeDict content is a
complete deterministic serialization of each TEI entry, including every form,
pronunciation, label, sense, translation, example, and nested child; GCIDE
content is the complete SGML entry span, including `<ent>`/`<hw>` forms and all
editorial fields; OMW content contains the complete lexical entry followed by
each referenced synset's definitions, examples, and relation children once per
lexical entry, without recursively traversing the relation graph.  The
serialization preserves mixed-content text/tails, qualified names and
attributes.  It performs a deterministic XML serialization (so namespace
prefix spelling, quote style, empty-element spelling, and attribute ordering
may differ from the source) plus line-ending normalization; retained source
bytes remain the authority for verbatim provenance.  This is a normalized
matched storage projection, not native semantic-richness evidence.  Native
source XML/SGML is retained and reported separately.

The format matrix is split by what can actually be read independently:

* LEX6 uses the public `src6` archive API through `runner.zig`; raw,
  adaptive, and forced-bzip3 page modes are real codecs.
* Frozen LEX5 and the existing src2/src4 APIs are attempted through their
  repository frontends when their semantic adapter can represent the full
  projection.  An adapter/build failure is recorded verbatim as unavailable;
  no lane is relabeled as implemented.
* StarDict is built as real `.ifo`/`.idx`/`.dict` files and checked with the
  genuine `sdcv` implementation on Unicode, punctuation, duplicate, and
  missing-key cases.  The measured reader is a separate binary reader; sdcv
  process startup/transport is reported as a distinct operation.
* DICT is built as real `.dict`/`.index` files and checked with `dictunformat`
  and the Nix `dict` client.  `dictzip` is a separate random-access lane;
  whole-file gzip/zstd are storage-only controls and are not called random
  access dictionary readers.
* SLOB is built with the real Python `slob` library.  Its sidecar maps stored
  occurrence IDs to canonical rows.  Identity setup is charged to open/start
  measurements; the validation pass that decodes every item is never hidden
  inside a timed fresh reader.
* SQLite is a real indexed table control with a fresh sqlite connection per
  startup sample.  It is not presented as a dictionary-native format.

The reader oracle is outside all format readers.  It reads the projection,
computes occurrence multisets (not invented logical IDs), and checks every
row's content retrieval, every distinct exact key in the external readers,
selected high-multiplicity keys and exact/prefix/missing cases through LEX6,
prefix enumeration, and rendering/snippet output.  LEX6's all-hit digest still
covers every indexed occurrence; its default query file is the fixed
representative workload so compressed pages are not repeatedly decoded once
per 100k-key corpus.  `smoke.py --all-exact-queries` enables the exhaustive
LEX6 query audit; the completed all-corpus audit is retained as
`evidence/runs/all-exact-smoke.json`.  Counts alone are never accepted as
proof.

## Reproducible preparation

From the repository root, the non-timed preparation is:

```sh
python3 src6/bench/real-world/prepare.py fetch \
  --cache-dir /tmp/dictionary-real-world-cache
python3 src6/bench/real-world/prepare.py project \
  --cache-dir /tmp/dictionary-real-world-cache \
  --output-dir src6/bench/real-world/evidence/corpora
nix develop .# --command python3 src6/bench/real-world/smoke.py \
  --all-exact-queries --reuse-lex6 \
  --output src6/bench/real-world/evidence/runs/all-exact-smoke.json
```

The script fails on a checksum mismatch, malformed source record, missing
required field, or an unresolved OMW sense→synset reference.  It reports
front matter and parse counts instead of silently dropping them.  The source
archives and extracted licenses stay in the cache; the generated manifest
records absolute paths, byte counts, SHA-256/SHA-512 checksums, and retention
costs.

The LEX6 non-timed smoke build is compiled with `build.zig` and then run on
each projection.  It opens and validates every page/document through
`Archive.verifyAll`, enumerates every index hit, then performs one independent
page walk to decode, digest, and render every entry content packet.  This
avoids repeatedly decompressing the same page once per entry while preserving
the full content check.  It has no clock calls.

## Pinned measurement schedule (disabled until the root quiet gate)

No invocation of a timing mode is valid without the literal argument
`--quiet-gate ROOT-EXPLICIT-QUIET-GATE`; preparation and smoke modes reject
that argument.  The schedule is fixed before collection:

* Main 64 KiB page lanes: three paired fresh-process runs per format and
  codec, with one declared warmup and 256 batched exact, missing, prefix,
  load/render, and snippet operations per sample where the operation is
  available.  LEX6 reports uncached `Archive.load` separately from a
  stateful `Reader` session: one cold first decode, 256 same-page loads
  (expected cache hits), and 256 mixed-page render/snippet loads with
  page-load/decode/cache-hit counters.  `Reader.init`/SourceIndex setup is
  its own phase; `prepareLinks()` is not called for the plain-text projection
  lane.
* Prefix enumeration: one complete all-hit correctness pass per corpus and
  three measured batches for the predefined short-prefix keys; the work count
  (hits and bytes) is reported with each sample.
* Fresh open/startup and CLI process lanes: three runs, no warm-cache reuse;
  eager decode is a separately named control.
* Page-size sweep: one build/open/verify/control run at each target of 16,
  64, and 256 KiB, while `max_block_bytes` remains at least 1 MiB and
  `max_document_bytes` remains at least 1 MiB.  Oversized documents remain in
  the input and are reported, never discarded.
* Bzip3 diagnosis: for every real input and page size, record page raw and
  encoded lengths, selected codec, raw/adaptive/forced-bzip3 totals, metadata
  bytes (header/index/directory), payload bytes, and any resource-limit raw
  fallback.  A whole-stream bzip3 diagnostic is storage-only and is not used
  as a random-access comparison.

The harness uses paired fixed-order samples, normal allocation, checksum
consumption, and a bounded schedule.  It does not retry or tune encodings in
response to noise and does not claim cross-language microsecond rankings.  A
timed sample is rejected unless its fixed exact/prefix/render/snippet digests,
operation counts, and (for LEX6 sessions) page-cache counters match the
independent projection oracle.

The separate `measure.py` driver is the only timing entry point.  It refuses
to read a clock unless the exact argument `--quiet-gate
ROOT-EXPLICIT-QUIET-GATE` is supplied by the coordinating root; without that
literal gate it exits before touching the clock.  It writes raw process output,
phase samples, operation/hit/output counts, checksums, build artifacts, and
the fixed query/row plans to `evidence/runs/timing-results.json`.
