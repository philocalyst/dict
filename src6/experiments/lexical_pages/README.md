# Exact lexical page experiments

These isolated experiments encode the existing public `model.Entry` directly.
They do not introduce a second lexical model or change the production packet,
archive, validation, query, or compression modules. The production format stays
separate from this page-representation cost oracle.

`workloads.zig` provides `OwnedEntries` with `entries` and `deinit()`,
`rich(allocator,count)`, `naturalBytes(allocator,projection,max_entries)`, and
`natural(allocator,io,path,max_entries)`. The natural loader reads the existing
three-column projection: hexadecimal identity, comma-separated hexadecimal
spellings, and hexadecimal source payload. The first spelling becomes the
headword, remaining spellings remain ordered aliases, and the complete source
payload becomes one definition containing one `Inline.text`. It preserves that
source projection; it does not claim to parse lexical XML. A limit of zero reads
all records, and a positive limit reads an explicit leading prefix.

The rich workload is synthetic. It combines eight language families, qualified
feature bundles, variable one-to-four sense counts, changing prose and labels,
optional examples and nested senses, language resets, exact decimal spellings,
ordered duplicate claims/evidence/bag members, embedded shared values and local
references, raw source bytes, and residual anchors. Analyses include Arabic
discontinuous root/pattern spans, Turkish suffix chains, Japanese and Chinese
compounds without spaces, Hindi inflection, and German discontinuous multiword
constituents. Repeated features and smaller subtrees recur independently of
whole-entry equality. Synthetic compression gains must not be generalized to
natural dictionaries.

`dag.zig` offers flat canonical Entry packets and exact typed hash-consed nodes.
Scalars stay inline; equal strings and composites can share stored nodes while
every ordered occurrence and semantic declaration remains in the expanded native
model. `shape.zig` offers schema-derived structural templates and an ordered
literal lane, with explicit leaf lengths, template hole counts, and checkpoints
every 32 leaves. Its initial implementation materializes native values; the
runner makes no direct-query performance claim for shapes.

The runner uses identical root groups for every representation. It first packs
complete flat frames up to 64 KiB, then bisects groups whose shared or shape frame
would exceed that bound. A single oversized root may occupy an explicitly
counted page of up to 1 MiB. Every natural record survives; a root beyond that
declared limit is an error. This common packing isolates representation costs.
It is not an optimal standalone flat compressor: flat-only packing can sometimes
use fewer pages, and a production adaptive planner could keep the original flat
groups and discard an oversized shared candidate instead of bisecting.

LPB1 envelope version 2 pays a 64-byte header/checksum, a 24-byte directory record
per page, and every complete inner frame or compressed frame. The directory
stores first root, root count, uncompressed length, stored length, payload offset,
and actual codec. This envelope supports ordinal access. Lexical and logical
identity indexes are equally excluded, so its sizes are not complete production
archive sizes. Inner frames pay their own offsets, root records, checkpoints,
schema fingerprint, checksums and payloads.

The runner compares flat, shared, shape, the smallest complete raw frame, and the
smallest actual compressed frame. Compressed selection encodes all three
candidates and charges all three trials. Each candidate is compressed as an
independent page with raw, bzip3, or adaptive raw/bzip3 backends. Every stored page
must decode exactly to its fully admitted original frame.

Before access timings, every input ID must be globally unique, every native
document is validated, every flat/shared/shape root is admitted and compared by
complete native equality, and an independent recursive native observation checks
all fields. Both DAG representations additionally pass the measured projection
against the original native query for every root. This observation retains exact
strings, scalar values, union tags, ordered collections, duplicate multiplicity,
language declarations, source bytes, and embedded pointer definitions. Hashes
supplement complete native equality; they do not replace it.

Timings require `--quiet-gate ROOT-EXPLICIT-QUIET-GATE`. Without that explicit
gate, the runner reports byte costs and correctness only. Timed access retains
all immutable uncompressed frames and all page metadata after complete setup.
It compares materializing one native root with direct typed projections: headword
plus first direct sense label for rich data, or headword plus complete preserved
source text for natural data. It does not measure cold disk access or compressed
page-cache misses. Successful Zig allocator hooks and requested growth/peak are
reported; native C bzip3 state, RSS, and OS caches are excluded.

The isolated build installs `lexical-pages`:

```sh
zig build --build-file src6/experiments/lexical_pages/build.zig -Doptimize=ReleaseSafe --prefix /workspace/scratch/lexical-pages-install
/workspace/scratch/lexical-pages-install/bin/lexical-pages rich 128 --retain-prefix /workspace/scratch/lexical-pages-rich128
/workspace/scratch/lexical-pages-install/bin/lexical-pages natural /workspace/scratch/frontier-corpora/dictionaries/omw-ja-20/development/projection.tsv --entries 512 --retain-prefix /workspace/scratch/lexical-pages-omw-ja-dev512
```

Known successful direct compilation during development used Zig 0.16.0:

```sh
/home/agent/.local/bin/zig build-exe -O ReleaseSafe --dep lex6 -Mroot=src6/experiments/lexical_pages/runner.zig -lc -Ivendor/bzip3/include -cflags '-DVERSION="1.5.1"' -fno-sanitize=undefined -- vendor/bzip3/src/libbz3.c -Mlex6=src6/root.zig -femit-bin=/workspace/scratch/lexical-pages-runner-shape
```

Initial byte-only development screens, including the complete LPB1 envelope,
passed all gates:

| Workload | Pages | Flat raw | Shared raw | Shape raw | Flat bzip3 | Shared bzip3 | Shape bzip3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Varied rich, 128 entries | 7 | 423,758 | 193,786 | 412,734 | 36,457 | 85,336 | 54,236 |
| OMW Japanese development, first 512 entries | 30 | 1,472,947 | 1,498,677 | 1,478,965 | 136,947 | 155,088 | 140,310 |

These results support a raw physical-footprint gain for rich DAG pages, not a
compressed-size gain. Raw adaptation chose shared pages for the rich workload
and flat pages for the natural workload. Compressed adaptation chose flat pages
for both. Shapes improved compressed size relative to shared DAG pages but still
lost to flat pages. No timings were taken for these screens.

Evidence is retained in `/workspace/scratch/lexical-pages-shape-rich128.jsonl`
and `/workspace/scratch/lexical-pages-shape-omw-ja-dev512.jsonl`. Complete raw
envelopes use those prefixes followed by `.flat.raw.lpb`, `.shared.raw.lpb`, or
`.shape.raw.lpb`; all other strategy/backend envelopes are retained too. A
75,000-byte source-text root plus a smaller entry also passed every gate with two
preserved roots and one counted oversized page, recorded in
`/workspace/scratch/lexical-pages-shape-oversized.jsonl`.

The direct shape client is now implemented in `shape_view.zig`. After complete
`Page.prepare`, `fromAdmittedPage` returns immutable borrowed typed views.
Composite field access reads shape references and stored hole counts; a literal
uses its 32-leaf checkpoint and skips at most 31 length headers. This avoids
reconstructing unrelated descendants and accepts no allocator. The full-byte
mapping, root type and configured limits must remain unchanged; wrappers are
caller contracts. Two tests recursively compare every projected native field
across varied multilingual values, including defaults, pointer payloads,
duplicate occurrences, and text after multiple checkpoints. The runner now
checks all three direct query paths and exposes shape projection timings when
the explicit quiet gate is supplied. No new timing claims have been taken.

`compare_backends.py PREFIX --retain-directory DIR` reads the retained flat,
shared and shape raw LPB1 envelopes, checks every frame digest, then constructs
actual independent zstd19 LPZ1 envelopes. It also tests exact reversible shape
literal transposition by root-template rows and root-template hole columns;
every transform marker, source metadata, digest and page directory byte is paid.
Compression and transposition must reconstruct the exact previously admitted
frame. The selector pays all five complete compression trials per page.

| Development screen | Flat zstd19 | Shared zstd19 | Shape zstd19 | Shape rows | Shape columns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Varied rich128 | 34,456 | 81,971 | 51,869 | 51,898 | 51,895 |
| Japanese development512 | 140,593 | 159,898 | 144,848 | 145,025 | 145,741 |

The zstd selector also chooses all flat pages. Rich128 has 128 distinct complete
root templates across its seven pages: whole-root column transposition cannot
exploit construction overlap across those distinct shapes. Natural512 has one
root template per page, but its column variant still loses. Further experiments
should investigate partial construction templates and typed field channels,
rather than generalizing a compressed gain from raw sharing. Complete LPZ1
envelopes, source hashes and raw records live under
`/workspace/scratch/lexical-pages-zstd-{rich128,omw-ja-dev512}`.

Isolated tests pass in Debug, ReleaseSafe and ReleaseFast: 11 exact-DAG tests,
seven shape admission tests, and two recursive direct-shape-view tests. Run
`zig build --build-file src6/experiments/lexical_pages/build.zig test test-shape
-Doptimize=ReleaseSafe` to reproduce. Frozen production tests are separate.
