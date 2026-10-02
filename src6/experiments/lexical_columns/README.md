# Reflected construction pages and literal registers

This isolated experiment encodes the same public `model.Entry` used by LEX6.
Production packet/archive/query APIs are unchanged. Every native canonical packet
must reconstruct byte for byte, then pass full native semantic admission before
an immutable page can issue a projection proof. No linguistic fields, occurrence
order, duplicate claim/evidence counts, language declarations, source bytes,
Unicode spellings or explicit references are discarded.

The current representation cuts a construction at its leading required root byte
fields, derived from Zig reflection. In `Entry`, these are `id` and `headword`.
The root v3 default mask and exact field encodings occupy a small hot stream;
all remaining nested packet bytes retain their original adjacency in the cold
stream. Two monotone offsets per root recover the exact native packet. This
addresses the compressed-size loss from globally separating structure and
literal bytes, and from recursive-template/DAG reference entropy.

A cold stream can additionally use the generic, exact quoted-field register
constructors from `word_constructions`. A quoted field may reconstruct list
members with an earlier field's byte prefix/suffix, or copy a bounded ancestor
field slice/prefix/literal/suffix. The stream carries every donor index, stack
depth, overlap/slice length and literal. Literal zero bytes are escaped. These
are generic byte constructions; XML language/schema/identity is not inferred.
The full native packet and original frame SHA256 remain authoritative.

`register_screen.py` uses one fixed global policy: independently encode literal,
attribute, and attribute-plus-scope cold representations, pay all three complete
trials, and choose the smallest actual complete frame, with the lower mode
winning ties. Each hot and cold stream separately chooses raw or its configured
backend after actual encoding. A constructor is ineligible above 131,072
intermediate bytes or 262,144 original cold bytes; the exact ordinary cold stream
is the fallback. The dictionary's semantic model and decoder do not change when
a construction loses. The distinct whole-flat comparison remains the stronger
size baseline; the prefix representation still has a cost on rich pages.

The native inverse includes the independently audited `register_decode.cpp`
through a bounded C ABI. `register.zig` rejects bad codecs, constructor flags,
reserved bytes, extents, root counts, raw totals and constructor sizes before
crossing that ABI. It then restores the complete frame, verifies its SHA256,
restores every canonical native packet and runs lexical validation. Admitted
compressed bytes must remain immutable. `loadHot()` invokes no cold constructor
and returns the actual native root byte fields. `loadFull()` restores the cold
stream for labels/prose/other fields; its owned packet views rely on that same
prior admission proof. Full native allocation is bounded by packet limits;
native C/C++ allocations are not individually metered as Zig allocator calls.
The C++ inverse caps each expanded stage at 262,144 bytes and has a fixed
32-frame/32-field/256-byte donor register bound. Native bzip3 uses the production
bounded backend, including its native-state budget and 65 KiB state floor.

The complete LCB1 ordinal bundle pays 64 bytes plus 24 bytes per page. Each LCP2
frame pays 80 bytes of routing/original-schema/SHA header, two 16-byte restart
records, every stored payload and a four-byte intermediate-length operand when
a constructor is used. This is a page-representation experiment: lexical and
identity search indexes are equally excluded from both sides. Source groups are
exactly the existing flat/shared/shape workload groups, ordinary raw pages at
most 64 KiB and exceptional single-root pages at most 1 MiB. No final partition
was used to select this representation or its fixed policy.

Byte-only development evidence after the donor-index-256 literal-fallback fix:

| Native workload | Pages | Flat bzip3 | Prefix + adaptive registers bzip3 | Flat zstd19 | Prefix + adaptive registers zstd19 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Varied rich, 128 entries | 7 | 36,457 | 37,995 (+4.22%) | 34,456 | 35,914 (+4.23%) |
| OMW Japanese development, first 512 | 30 | 136,947 | 127,884 (-6.62%) | 140,593 | 131,037 (-6.80%) |

Rich pages all choose the literal cold representation. Natural pages choose one
attribute and 29 attribute-plus-scope frames for both backends. The hot decoded
payload is 5,208 versus 423,526 full-page bytes for rich data, and 18,225 versus
1,472,163 for natural data: about 81 times less decoded data for a headword-only
query. These are stream-volume facts, not measured latency. Full-source queries
must decode the cold stream and pay the constructor inverse. The natural loader
preserves its established three-column projection; source XML remains one exact
`Inline.text`, so this evidence does not claim a new XML-to-lexical importer.

Two prior cost negatives remain available. The complete prefix-only codec costs
37,995/142,656 bzip3 bytes for rich/natural (+4.22%/+4.17%). The original full
field-cursor spine with sparse optional byte sites has a native direct label
projection, but costs 43,580/144,579 bzip3 bytes (+19.5%/+5.57%); its rich
headword-plus-first-sense-label hot data is 107,219 bytes, about 3.95 times less
than flat pages. `columns.zig` and `reader.zig` retain this tradeoff experiment.
The earlier length-256 routing screens are also retained as rejected evidence.

Build and check the isolated programs (Zig 0.16.0):

```sh
/home/agent/.local/bin/zig build --build-file src6/experiments/lexical_columns/build.zig test -Doptimize=ReleaseSafe
/home/agent/.local/bin/zig build --build-file src6/experiments/lexical_columns/build.zig -Doptimize=ReleaseSafe --prefix /workspace/scratch/lexical-columns-install
python3 src6/experiments/lexical_columns/register_screen.py /workspace/scratch/lexical-pages-shape-omw-ja-dev512.flat.raw.lpb --retain-directory /workspace/scratch/lexical-prefix-register-omw-ja-dev512
/workspace/scratch/lexical-columns-install/bin/lexical-register-access /workspace/scratch/lexical-pages-shape-omw-ja-dev512.flat.raw.lpb /workspace/scratch/lexical-prefix-register-omw-ja-dev512 512
```

The native client additionally compares its reflection-encoded construction frame
with the Python-produced frame, checks global identity uniqueness, exact complete
canonical packets, and all headword/first-direct-sense-label/first-direct-definition
projections for every root. Unit tests cover multilingual varied morphology,
source bytes including invalid UTF8/NUL, duplicate inline occurrences, exact
composed/decomposed spellings, malformed offsets, checkpoints, limits, all
truncations and allocator-failure cleanup. The independent constructor audit
also covers the donor-index-255/256/257, register-index-31/32 and depth-31/32
boundaries; the forward donor-index-256 bug was fixed before freezing.

No access timings run without `--quiet-gate ROOT-EXPLICIT-QUIET-GATE`. The client
prints full native admission, baseline backend encoding, and source-parity/frame
re-encoding separately from timed queries. Queries retain compressed pages,
decompress the necessary blocks afresh on every operation, and do not use a page
cache. Headwords use only the hot stream; labels/full definitions pay full inverse
and a root packet copy. Same-root and deterministic mixed-root access each
compare full query byte/hash observations against the original native packets.

`register_screen.py` accepts that same explicit quiet gate for encoder clocks.
It reports the complete pipeline for every paid candidate, including forward
construction, both backend encodes, fallback decisions and per-page frame
assembly. Verification inverse/decode and backend initialization have separate
clocks; named forward/backend clocks are subsets of the pipeline clock. Retained
evidence IO and root-prefix preparation are outside that encoder comparison.
No encoder clocks are enabled during ordinary size/admission evaluation.

`evaluate.py` verifies the frozen hashes before applying this exact policy to
hash-locked native groups. Its input manifest has protocol
`LEXICAL-CONSTRUCTIONS-EVALUATION-INPUT/1` and a `datasets` list with `name`,
`flat_bundle`, `sha256`, `pages` and `roots` for each workload. It restores both
complete selected backend bundles to the original frames, then invokes native
admission for the selected bzip3 frames and every constructor mode. Checking all
modes also covers a zstd choice that differs from bzip3. It records exact source
and complete-bundle hashes, policy/runtime versions and all native gates.

```sh
python3 src6/experiments/lexical_columns/evaluate.py --manifest /workspace/scratch/lexical-columns-evaluation-input.json --freeze /workspace/scratch/lexical-columns-freeze-manifest.json --output /workspace/scratch/lexical-columns-evaluation --native-client /workspace/scratch/lexical-columns-install/bin/lexical-register-access
```

The same command with the coordinated quiet gate records paid encoder trials
and native query/preparation clocks, while asserting that all previous complete
frame bytes remain unchanged. Constructor choice is a transmitted per-page
opcode under the fixed global policy; no outcome changes the algorithm.

Retained evidence is under `/workspace/scratch/lexical-prefix-register-rich128*`
and `/workspace/scratch/lexical-prefix-register-omw-ja-dev512*`, including complete
LCB1 bundles, independent frames, transformed stage bytes and constructor stats.
The source/model/binary/evidence freeze manifest is
`/workspace/scratch/lexical-columns-freeze-manifest.json`.
