# Lexicon v2: one forest, three string tiers, bzip3 where bytes are

Greenfield proposal · 7 September 2026 · targets Zig 0.16.0 and the `src2/` line
budget already reserved in `build2.zig` (≤ 3,000 production lines).

This document analyses what the current `src/` prototype actually is, then
proposes a replacement that is smaller, faster to open and query, far more
expressive for words and their relationships, and much simpler. Every byte
figure below is arithmetic on stated assumptions, not a measurement. The
falsifiable gates from `plan.md` §14 still apply; nothing here is a result.

---

## 0. The one-paragraph version

Put **every** lexical object, whether a native entry, a TEI element, a sense, a
form, a word part, an example, or a qualified n-ary assertion, into **one
ordered forest** whose node IDs are preorder ranks. That single choice makes
ownership, order, containment, "which entry does this belong to", and
"everything under this sense" free: a subtree is a contiguous ID range.
Columns hang off nodes and are declared once in a comptime schema, so the
reader, writer, byte ledger, and query column access are generated, not
hand-written. Cross-entry relationships are typed edges in per-predicate
compressed adjacency; anything with evidence, certainty, order, or extra roles
is an assertion node inside the forest, and its binary shadow edges are
materialized so traversal is uniform. Strings live in three tiers: **atoms**
(tiny, dictionary-coded), **keys** (front-coded sorted spaces with packed
postings, one implementation used for headwords, normalized forms, reversed
forms, external IDs, and full-text terms), and **prose** (bzip3 blocks laid out
in forest preorder so one decode renders one entry, with the item directory
*inside* the compressed block). Queries are a small algebra over sorted node
sets with late materialization and a block-aware `explain`. The whole thing is
about 2,800 lines of Zig.

---

## 1. Diagnosis of the current implementation

`src/` is roughly 9,000 lines split into two worlds that never meet.

### 1.1 Two disconnected models

| World | Module(s) | What it stores | Addressable? | Indexed? |
|---|---|---|---|---|
| Raw snapshot `LEXSNAP` | `lexicon.zig`, `codec/` | `(u64 id, key, definition bytes)` | Yes (keys, postings, atoms, blocks) | Exact/prefix only |
| Semantic model `LEXSEM` | `semantic.zig`, `semantic_format.zig`, `query.zig`, `lexical.zig`, `scopes.zig`, `language.zig` | Values, entities, n-ary assertions, document forest, anchors | No: one sequential stream, fully materialized on open | No: every query is a linear scan |

The README admits it: "direct semantic sections and indexes in the raw
snapshot" are unimplemented. The rich model exists only as a heap object graph
plus a reference serialization. Nothing the plan promises about rich queries
without decompression is possible in this shape, because the rich data is not
in the snapshot at all.

### 1.2 Where the bytes go today

- Every payload atom costs a **32-byte** directory record (`docs/format-v0.1.md`, payload section): 8-byte ID, 4-byte block, 4 reserved, 8-byte offset, 8-byte length. For one million definitions that is 32 MB of directory before any text.
- Every key record carries a **16-byte** `(posting_start, posting_count)` pair plus a 5–7 byte marker/length header, so a 9-byte headword costs about 27 bytes of key stream before the restart table.
- Every block costs 48 bytes, every section 48 bytes of directory, and all counts are `u64`.
- The compact semantic stream (`semantic_format.zig:343`) pools atoms but stores every ID as an absolute varint, every role as a pool reference, every participant as a tagged record, and has no section offsets. The audit in `docs/reviews/structural-compactness-audit.md` already lists this as P1: the pool is not directly addressable, unique strings pay pool overhead, and nothing is columnar.

### 1.3 Where the time goes today

- `Writer.add` (`lexicon.zig:198`) scans all previous records to reject a duplicate ID, so adding *n* records is O(n²).
- `encodePayload` (`lexicon.zig:397`) deduplicates definitions with a nested linear scan, then maps each record back to its definition with a second nested scan: O(n²) twice.
- `Builder.addValue` (`semantic.zig:338`) interns by scanning every existing value: O(n²) semantic builds.
- `query.collectEdges` (`lexical.zig`, `query.zig`) walks every assertion for every query, revalidates each one on every visit, and compares role strings byte-by-byte per participant. A single `formsOf` on a million-assertion model touches all of them.
- `semantic_format.decodeCompact` duplicates every atom out of the pool (`atomOwned` → `allocator.dupe`) and then the builder copies again, so opening costs at least two copies of all text.
- `Reader` lookups take `*Reader` because they mutate counters, so one reader cannot be shared by concurrent queries.

### 1.4 Where the Zig idiom is off

- IDs are `struct { index: u32 }` instead of distinct non-exhaustive enums, so nullability costs an `?` wrapper and there is no type safety between `EntityId` and `ValueId` beyond the field name.
- On-disk fields are decoded with dozens of hand-written `readU64(bytes, try checkedAdd(base, try mul(i, 32)))` chains (`Reader.definition` performs ~20 checked operations for one lookup). A comptime layout generator would produce the same checked reads from a single struct declaration.
- `codec.zig` maps a 14-member error set onto an identical 14-member error set by hand (`mapBzip3Error`). Zig error sets coerce; the table is 40 lines of nothing.
- The builder owns thousands of individually allocated strings and mirrors every allocation with a bespoke `free*` function family (`freeNamespaces`, `freeSources`, `freeValue`, `freeParticipantItems`, …). An arena plus an intern table removes all of it.
- Options structs are copied field-by-field between layers (`codec.Options` → `bzip3.Options` → `raw.Options`).
- Contracts are documented in five separate `docs/*-v0.1.md` files for code that is explicitly a prototype.

### 1.5 What the semantic model cannot say

The audit's P0 findings stand: no native word parts, no typed language/direction/profile, statement references forced backward, a global "≥ 2 participants" rule, a closed `EntityKind` enum with `other`. v2 must close these in the data model, not with views.

Conclusion: the prototype validated three things worth keeping (front-coded keys with restart directories, independent bzip3 blocks through the low-level libbz3 API, and the *conceptual* separation of value / occurrence / search key). Everything else should be rebuilt.

---

## 2. Design rules for v2

1. **One forest.** Every identity-bearing thing is a node with a preorder ID. No second ID domain for "entities" versus "document nodes" versus "assertions".
2. **Schema-implied bits.** A column's type, width, presence policy, and which node kinds carry it are comptime schema facts. The reader never stores a tag per value.
3. **Entry-local everything.** References inside an entry are small deltas; only cross-entry edges use global IDs.
4. **One key-space primitive.** Sorted front-coded strings plus optional packed postings, instantiated N times (headwords, normalized, reversed, external IDs, terms, atoms).
5. **Prose is placed for rendering, not for storage.** bzip3 blocks follow preorder, so the unit of decode is the unit of display.
6. **Late materialization.** Queries compute sorted node-ID sets first; text is fetched last, batched by block.
7. **Immutable, borrowable, shareable.** A `Snapshot` is `[]const u8` plus validated slices. It never allocates after `open`; queries own their arenas; block cache pins are explicit handles.
8. **Small.** ≤ 3,000 production lines. Every decoder or operator must earn its lines with measured bytes or latency.

---

## 3. Data model

### 3.1 The forest

Nodes are numbered in **preorder**, roots (entries and other top-level objects) first, depth-first. Three structural columns give O(1) navigation:

| Column | Width | Meaning |
|---|---|---|
| `subtree` | entry-local, FOR-packed per 1,024-node frame | number of nodes in the subtree including self |
| `parent_delta` | entry-local, FOR-packed per frame | `id − parent_id` (0 for roots) |
| `root_starts` | Elias–Fano over node IDs | IDs of root nodes |

Derived operations, all O(1) or O(children):

```zig
fn subtreeEnd(n)     = n + subtree(n)            // exclusive
fn parent(n)         = n - parentDelta(n)
fn firstChild(n)     = if (subtree(n) > 1) n + 1 else none
fn nextSibling(n)    = n + subtree(n) if still inside parent's subtree
fn root(n)           = root_starts.predecessor(n)  // "entry of"
fn depth(n)          = walk parents (dictionary depth is < 12)
fn contains(a, b)    = a <= b and b < subtreeEnd(a)
```

Because a subtree is a range, "all senses of entry E" is `range(E).filter(kind == sense)`, "the entry that owns example X" is one predecessor query, and intersecting "descendants of E" with any sorted node set is two binary searches. Entry-local widths are typically 8–10 bits, so the forest costs ~16–20 bits per node. A balanced-parentheses encoding at ~2.5 bits per node is a later experiment; it needs a range-min-max tree (~200 lines) and is only worth it if the structural columns dominate the ledger, which the ledger in §5 says they will not.

### 3.2 Kinds

A `kind` column (packed enum, 5–6 bits) selects one of the built-in kinds or `extension`:

```
entry lexeme homograph sense subsense form variant pronunciation inflection
part example citation quote definition gloss note usage etymology etymon
translation assertion participant evidence text comment pi media
extension
```

`extension` nodes carry a `qname` atom (optional column, present only on extension nodes), so an unknown TEI element is a typed generic node with its expanded name, exactly as the plan requires. Any TEI element with a known mapping (`<sense>`, `<form type="inflected">`, `<cit type="translation">`) gets the built-in kind **and** retains its source qname in a residual column when byte-exact or source-order export is requested. There is no `other` sink and no fixed built-in opcode per TEI element.

### 3.3 Columns: declared once, generated everywhere

```zig
pub const columns = [_]Column{
    .{ .name = "lang",      .over = kinds(.{ .entry, .sense, .form, .text, .translation, .extension }),
       .repr = .atom, .presence = .optional_inherited },
    .{ .name = "pos",       .over = kinds(.{ .entry, .sense, .form }), .repr = .atom, .presence = .optional_inherited },
    .{ .name = "written",   .over = kinds(.{ .form, .variant, .inflection, .part }), .repr = .key(.headword), .presence = .required },
    .{ .name = "text",      .over = kinds(.{ .definition, .gloss, .example, .note, .text, .comment, .pi, .etymology }),
       .repr = .prose, .presence = .required },
    .{ .name = "span",      .over = kinds(.{ .part }), .repr = .span,  .presence = .optional },
    .{ .name = "certainty", .over = kinds(.{ .assertion }), .repr = .enum(Certainty), .presence = .optional },
    .{ .name = "qname",     .over = kinds(.{ .extension }), .repr = .atom, .presence = .required },
    // ...
};
```

Rules the generator enforces:

- A column declared over kind set K is indexed by **kind-rank**: the value for node *n* sits at position `rankK(n)` in a dense packed array. A required column over K therefore has zero presence overhead.
- An optional column adds one presence bit per node **of those kinds only**, with a rank directory (4 bytes per 512 bits, ~6 % overhead), so a present value is found by one popcount-rank.
- `optional_inherited` columns resolve effective values by walking `parent()` until a present value or a root. Explicit absence (`xml:lang=""`) is a distinct atom, never confused with omission.
- `repr` picks storage: packed enum, FOR-packed integer, atom reference, key reference, prose reference (implicit: the prose rank *is* the kind-rank), node reference (entry-local delta or global), span (`unit`, `start`, `end` packed), or `bytes` (rare opaque payload in a cold section).
- The writer, reader, byte ledger (`explain size`), and query column filters are all produced by `inline for (columns)`; adding a column is one line.

Attributes on extension nodes (arbitrary TEI attributes) use a **shape** column: the ordered set of attribute names on a node is interned as a shape ID (atom over a name-list key space); values are stored in a per-shape value stream. Nodes with identical attribute name sets pay one small shape ID plus values, not names.

### 3.4 Edges and assertions

Relationships come in two physical forms, selected per occurrence at build time:

**Binary edge** (no evidence, no qualifiers, order not semantic): stored in per-predicate compressed adjacency:

```
predicate p:
  sources  : Elias–Fano over distinct source node IDs
  offsets  : Elias–Fano over cumulative degree
  targets  : per source group, Elias–Fano over sorted target IDs
```

Cost per edge ≈ log2(N / degree) + 2 bits for the target plus ~5 bits amortized source/offset overhead. For a million-node forest that is ~25 bits per edge, about 3 bytes. Reverse traversal uses a reverse adjacency built the same way, emitted only for predicates whose schema declares `reverse = .materialized` (default for translation, synonymy, etymology; off for `see_also`). A wavelet-matrix over the target sequence remains the plan's experiment for replacing the reverse copy; it is not in the baseline.

**Assertion node** (anything richer): a node of kind `assertion` in the forest, under the entry that asserts it, with columns `predicate` (atom), `state`, `certainty`, `temporal`, `context`, `source`, and `participant` child nodes carrying `role` (atom) and a `target` (node reference, prose/key value, unresolved bytes with status, or another assertion node). Evidence is `evidence` child nodes with `quote`, `source`, `anchor` columns.

Every assertion additionally **materializes its binary shadow edges** into the predicate adjacency, tagged by a `qualified` presence bit whose value column points back to the assertion node. Traversal code has one path; queries that need evidence follow the back-pointer. Statement targets can point anywhere in the forest, forward or backward; cycles are ordinary references. Unary assertions are legal; cardinality is a schema fact per predicate, checked at build.

This also removes the plan's separate `TranslationAssertion` and `EtymologyEvent` kinds as special cases: they are assertions with declared role sets.

### 3.5 Strings: three tiers, one primitive

| Tier | What | Representation | Access |
|---|---|---|---|
| Atoms | language tags, POS labels, roles, qnames, usage labels, attribute names, short enums from source | sorted, front-coded, blocks of 16, no postings; **ordinal is the ID** | id→string: decode ≤16; string→id: binary search on restart keys |
| Keys | headwords, written forms, normalized search forms, reversed forms, external IDs, full-text terms | sorted, front-coded, blocks of 16, restart directory, packed postings into node IDs | exact, prefix, range, reverse iterate; fuzzy via automaton over restart keys |
| Prose | definitions, examples, notes, mixed-content text, etymology prose, comments | bzip3 blocks in preorder; per-block item offsets stored **inside** the decompressed block as a packed prefix | decode block (cached) → slice |

One `KeySpace` type implements both atoms and keys; the postings column is optional. A key record is `(shared_len: u8 | u16 escape, suffix_len, suffix bytes)`; postings for a key are a packed range into the global posting array (width = log2(N)), and the key stores only its posting **count** because the start is the running sum recovered from the restart entry (restart entries store the cumulative posting index). That replaces the current 16-byte `(start, count)` with about one byte.

Short display strings (headwords) are therefore never in bzip3; membership and prefix never decode prose. Long strings that repeat exactly (identical definitions across two sources) are interned at build time: the second occurrence stores a `prose_alias` reference instead of bytes. Interning is decided by measured savings per string, as the plan demands, not by tokenizing prose into words.

### 3.6 Language, script, direction, profile

`lang` is an atom, but the atom table for language tags is a **typed key space**: each entry stores the original spelling, and a parallel packed column gives the canonical BCP 47 comparison key ID, script atom, direction (2 bits), and analysis-profile ID. Effective language is inherited (§3.3). Searchable normalized forms are produced by named profiles at build time into separate key spaces whose section header carries the profile digest, so a reader can refuse an incompatible profile explicitly instead of falling back to a host locale.

### 3.7 Identity

Preorder IDs are physical and change on rebuild. Stable identity is a key space `external_ids` mapping `(source_ordinal, id_bytes)` to nodes. Because it is just another key space it costs nothing extra in code, is prefix-searchable by source, and is a cold section (bzip3-compressed, decoded on first use).

### 3.8 TEI preservation without a second copy

- Element → node (`extension` or mapped kind), preorder = document order.
- Mixed content → `text` child nodes in place; their bytes are prose.
- Attributes → shape + values; `xml:id` also goes to `external_ids`; `xml:lang` also feeds the `lang` column.
- Comments and PIs → nodes of those kinds when the import profile retains them.
- Byte-exact mode → an optional cold section holding a residual tape (whitespace tokens, entity spellings, attribute order), bzip3-compressed. It is counted in the ledger as duplication, per the plan.

Semantic export walks the forest; nothing is reconstructed from a second object graph.

### 3.9 Word parts, natively

A `form` node may own ordered `part` children. A `part` has `written` (its surface, possibly empty for a zero morph), an optional `span` into the owning form's surface in a declared unit, a `role` atom (root, stem, prefix, suffix, clitic, …), optional `realizes` edge to a lexeme, and may itself own `part` children (nested decomposition). Two competing analyses are two sibling `analysis` nodes under the form. Discontinuous parts are one part with several `span` child nodes. This closes the audit's first P0 with three kinds and two columns rather than a separate view module.

---

## 4. bzip3: used where it pays, kept off the lookup path

### 4.1 What goes into bzip3 blocks

1. **Prose stream** (hot, per entry): text of all text-bearing nodes in preorder. Block boundaries snap to root boundaries; an oversized entry gets its own block(s). Within a block, an ablation compares pure preorder against "grouped by kind within the block" (all definitions, then all examples) since the BWT benefits from homogeneous context. The item directory (packed offsets, one per text node in the block) is the first thing inside the block and is compressed with it, so it costs zero directory bytes.
2. **Cold structural sections** (decoded once on first touch, then cached): full-text postings, reverse adjacency for rarely reversed predicates, `external_ids`, attribute value streams for extension nodes, the byte-exact residual tape. The section directory marks these with `codec = bzip3` and a page size; a reader that never reverse-looks-up never decodes them.
3. **Nothing else.** Keys, atoms, forest, kind, and hot columns stay raw and bit-packed. The block directory is never inside a block.

### 4.2 Block size from a latency budget, three presets

Same reader, same answers:

| Preset | Prose block target | Cold section page | Intended use |
|---|---|---|---|
| latency | 64 KiB (libbz3 minimum state is 65 KiB; data may be smaller) | 256 KiB | interactive lookup, DICT serving |
| balanced (default) | 256 KiB | 1 MiB | general |
| compact | 2–4 MiB | 4 MiB | archival, offline export |

Cold entry latency is `block_decode_time + O(entry)`; decode time is measured by `bench`, never assumed. The build report prints, per preset, the compressed prose bytes, mean and p99 decode time per block on the build machine, and the decode-amplification ratio (decoded bytes / returned bytes) for a random-entry workload.

### 4.3 Runtime

- One `bz3_state` per block-size class in a small pool; a decode borrows a state, never allocates a state per lookup.
- Block cache keyed by `(snapshot_id, block_id)` with explicit pin handles; a query result slice borrows from a pinned block and the pin is released with the query arena.
- Batch materialization sorts requested nodes by block, decodes distinct blocks once, and uses `bz3_decode_blocks` with a thread pool when the host provides one; single-threaded hosts get the same code path with `n = 1`.
- Build uses `bz3_encode_blocks` across a `std.Thread.Pool` for the prose stream; determinism is preserved because block boundaries are decided before encoding.

---

## 5. Container and byte ledger

### 5.1 Container

```
header (64 B)    magic "LEX2", major/minor, flags, file length, section count,
                 directory offset, root xxhash3-64, build profile id
directory        one 32 B entry per section, two packed 128-bit words:
                 word 0: kind u8 | codec u4 | flags u4 | items u32 | offset u40 | stored_len u40
                 word 1: logical_len u40 (compressed sections) | digest u32 | profile u16 | reserved u40
sections (64 B aligned)
```

Every section decoder is generated from a comptime layout struct; open validates header, directory, overlap, alignment, and the digests of **hot** sections only; cold section digests are verified on first touch. Open therefore reads a few KiB for a multi-gigabyte snapshot and never touches prose.

### 5.2 Ledger, worked example (arithmetic, not a forecast)

Assumptions: 100 k entries, 1.2 M nodes total, 160 k distinct headwords averaging 9 bytes, 500 k cross-entry edges over 6 predicates, 120 MB of prose that bzip3 compresses 4:1 on dictionary text.

| Section | Bits per item | Items | Bytes |
|---|---:|---:|---:|
| forest (`subtree` + `parent_delta` @ ~9 bits each, frames) | 19 | 1.2 M | 2.9 MB |
| `root_starts` (Elias–Fano, n = 100 k, U = 1.2 M) | ~5.6 | 100 k | 70 KB |
| `kind` | 5 | 1.2 M | 0.75 MB |
| `lang`, `pos`, `usage`, `certainty`, … (10 typical columns, mostly optional, kind-scoped) | ~8 avg | 1.2 M | 1.2 MB |
| headword key space (front-coding saves ~55 %, +1 B length, +1 B count) | ~50 | 160 k | 1.0 MB |
| postings (node IDs @ 21 bits) | 21 | 250 k | 0.66 MB |
| normalized + reversed key spaces (2 × the above, no separate postings when identical) | | | 2.0 MB |
| atoms (~20 k short strings) | | | 0.15 MB |
| edges forward (~25 bits) + reverse for 4 of 6 predicates | 25 | 500 k + 350 k | 2.7 MB |
| prose directory (16 B per 256 KiB block) | | 470 blocks | 8 KB |
| prose (bzip3) | | | **30 MB** |
| full-text index, cold, bzip3 (estimate 12 % of prose) | | | 3.6 MB |
| header, directory, rank directories, alignment | | | < 0.4 MB |
| **Total** | | | **≈ 45 MB** |

The same content in the current v1 raw snapshot spends 38 MB on atom directory records alone (1.2 M × 32 B) before keys or text, and cannot represent the edges, kinds, or columns at all. Structure in v2 is about 15 MB against 30 MB of prose; the design goal that "bytes go where the information is" holds on paper, and the ablation in §10 decides whether it holds on real corpora.

---

## 6. Access paths and their costs

| Operation | Steps | Touches prose? |
|---|---|---|
| exact headword | binary search over restart keys (log2(10 k) ≈ 14 probes), decode ≤ 16 keys, read `count` packed postings | no |
| prefix | two lower bounds, iterate keys in range, gather postings | no |
| suffix / ends-with | same, on the reversed key space | no |
| fuzzy (Levenshtein ≤ k) | automaton-guided walk over restart keys, prune blocks whose restart prefix cannot match, verify in-block | no |
| regex on headwords | bounded linear scan of the front-coded stream (decoding is a memcpy of suffixes; tens of MB/s), optional prefix-literal pruning | no |
| entry of node / subtree / parent / siblings | O(1) arithmetic on packed columns | no |
| senses of entry E in language L | range(E) ∩ kind == sense, then inherited `lang` check per hit | no |
| translations of sense S into French | forward adjacency for `translation`, filter targets by effective `lang` | no |
| what translates to node T | reverse adjacency | no (cold section on first use) |
| reverse dictionary ("words whose definition mentions *river*") | full-text term → node postings → `root()` of each | no; cold index decode once |
| render entry E | one block lookup by prose rank (binary search over ~500 block starts), one cached decode, slices for every text node in range(E) | one block |
| render 20 prefix matches | sort by block, decode distinct blocks (usually 1–2 because prefix neighbours are preorder neighbours) | 1–2 blocks |

Warm exact lookup is a few hundred nanoseconds of pointer-free arithmetic over borrowed slices; there is no allocation, no `*Reader` mutation, and no locking, so a single `Snapshot` serves any number of threads.

---

## 7. Query facilities

### 7.1 The algebra

A query is a pipeline over `NodeSet`, which is always a **sorted** `[]const Node` (or a range, which is the degenerate sorted set). Every operator is a merge, a binary search, or a range walk, so costs are predictable and every operator composes with every other.

```zig
pub const Op = union(enum) {
    // seeds
    key: struct { space: KeySpace.Id, needle: []const u8, mode: enum { exact, prefix, suffix, fuzzy, range }, k: u8 = 0 },
    ids: []const Node,
    roots,                                    // every entry
    all: Kind,                                // every node of a kind (a kind-rank range walk)
    // navigation
    descendants, ancestors, root, children, parent,
    follow: Predicate, back: Predicate,       // typed edges, forward / reverse
    participants: struct { role: ?Atom = null },
    assertions_of: Predicate,                 // qualified edges → assertion nodes
    // filters
    kind: Kind,
    col: struct { name: []const u8, cmp: enum { eq, ne, in, lt, le, gt, ge, present, absent }, value: Value },
    lang: struct { tag: []const u8, matching: enum { exact, basic, extended } = .basic },
    text: struct { field: Column.Id, terms: []const []const u8, mode: enum { all, any, phrase } },
    // set ops (operands are sub-pipelines)
    both: [2]*const Pipeline, either: [2]*const Pipeline, except: [2]*const Pipeline,
    // shaping
    distinct_by: enum { node, root },         // bag → set on a declared identity
    order: enum { preorder, key, score },
    take: u32, after: Node,                   // keyset pagination on node id
};
```

Builder API (fluent, arena-owned, no hidden allocation after `run`):

```zig
var q = try snap.query(arena, .{ .max_visited = 1_000_000, .max_blocks = 8, .allow_scan = false });
const hits = try q
    .key(.headword, "bank", .exact)          // entry nodes
    .descendants().kind(.sense)
    .lang("en")
    .follow(.translation).lang("fr")
    .distinctBy(.node)
    .take(20)
    .run();

var rows = try q.materialize(hits, &.{ .written, .definition, .lang });
while (rows.next()) |row| {
    // row.written / row.definition are slices borrowed from pinned blocks
    // valid until q.deinit()
}
```

Equally, the graph and document operations that `query.zig`, `lexical.zig`, and `scopes.zig` implement today are single operators here: `formsOf` = `.children().kind(.form)`, `decompose` = `.descendants().kind(.part)` with the forest giving order and nesting, `scopes.lookup` = the inherited column read, `traverse depth 1..4` = repeated `.follow` with a visited bitmap and the `max_visited` budget.

### 7.2 Planning and explain

Planning is deliberately tiny:

1. Seeds are indexed or scans; `allow_scan = false` rejects a plan whose seed is `all` over a large kind or a `col` filter with no index.
2. Filters are pushed to the cheapest position: kind and column filters before edge follows, `lang` last among filters because inheritance walks parents.
3. Set operations merge sorted inputs; the smaller side drives.
4. `materialize` groups by prose block and reports the distinct block count **before** decoding; `max_blocks` is enforced there, returning `error.BudgetExceeded` with the partial count, never a silently truncated answer.

`explain` returns a struct, not text: per-operator estimated input/output cardinalities, which key space or adjacency it used, whether a scan happened, and the block count for materialization. `explain analyze` fills the actual numbers after `run`.

### 7.3 LexQL-lite (optional module, ~250 lines)

A pipe grammar that compiles to the same `Op` list, for tools and the DICT strategy table:

```
headword = "bank" | senses | lang en | translation -> | lang fr | take 20 | show written, definition
form ends "ung" | root | pos noun | show written
sense ~ "river bank" phrase | root | show written, definition
entry id "tei:e-0042" | descendants | kind extension | show qname, attrs
sense = $s | assertions etymology | participants | show role, target, certainty, evidence.quote
```

Parsing is bounded (input length, token count, nesting), and there is no regex engine other than the bounded key-space scanner with a documented subset.

### 7.4 DICT mapping

`DEFINE` = `key exact → roots → materialize(render)`. `MATCH exact/prefix/suffix/lev/re` map to the key modes above; `MATCH` never decodes prose. Rendering walks `range(entry)` in preorder with a versioned template, so output order equals source order.

---

## 8. Zig idioms and comptime in v2

Concrete before/after choices; each one removes code from the current tree.

**Distinct IDs, free null.**
```zig
pub const Node = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Atom = enum(u32) { none = std.math.maxInt(u32), _ };
```
No `?struct{index}`; `@intFromEnum` at the edges; `Node` and `Atom` cannot be mixed.

**On-disk records as `packed struct` over explicit little-endian loads.** The plan's rule "never reinterpret bytes as native structs" is kept, because the bridge is an explicit integer read followed by a bit-cast of an integer:
```zig
pub const DirWord0 = packed struct(u128) { kind: u8, codec: u4, flags: u4, items: u32, offset: u40, stored_len: u40 };
fn dirWord0(bytes: []const u8, i: usize) !DirWord0 {
    const at = try std.math.mul(usize, i, 32);
    if (at + 16 > bytes.len) return error.Truncated;
    return @bitCast(std.mem.readInt(u128, bytes[at..][0..16], .little));
}
```
Named bit fields, no shifts by hand, endian-safe, same on every target.

**Generated layouts.** `fn Layout(comptime T: type) type` walks `@typeInfo(T).@"struct".fields` and emits `read(bytes, at) !T` / `write(w, value)` with checked bounds; every section header and the whole directory use it. The ~40 `readU16/readU32/readU64/checkedAdd/mul` call sites disappear.

**Generated columns.** `fn Column(comptime desc: ColumnDesc) type` produces `get(self, node) ?Value`, `present(self, node) bool`, `bytes(self) usize`, and the writer's packer. Fixed schema widths are comptime constants; frame-of-reference widths are runtime `u6`. One 25-line `readBits(bytes, bit, width)` using two `u64` loads serves every packed column.

**Schema as comptime data.** `schema.zig` declares kinds, columns, predicates (with arity, role sets, reverse policy), and key spaces. Writer section order, reader field set, `explain size`, and column-filter dispatch are all `inline for` over that data. Extension kinds and predicates are runtime atoms layered on the same machinery.

**Builder = arena + intern tables + `MultiArrayList`.**
```zig
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.MultiArrayList(NodeRow) = .{},
    atoms: std.StringArrayHashMapUnmanaged(void) = .{},
    keys: std.StringArrayHashMapUnmanaged(Postings) = .{},
    ...
    pub fn deinit(b: *Builder) void { b.arena.deinit(); }
};
```
No `free*` families, no per-string `errdefer`, O(1) interning, and `std.testing.checkAllAllocationFailures` proves cleanup instead of hand-rolled failing-allocator loops.

**Error sets that compose.** Each module declares a small set (`Snapshot.Error`, `Bz3.Error`, `Query.Error`); public functions return `Error!T` where `Error` is `||` of what they call. No mapping tables. Corruption is always `error.Corrupt{Section,Block,Checksum}`; budget is `error.BudgetExceeded`; absence is `null`, never an error.

**Tagged unions with `inline else`** for codec dispatch and value kinds; exhaustive `switch` so a new kind fails to compile until every reader handles it.

**Immutable, thread-shareable `Snapshot`.** Methods take `*const Snapshot`; work counters live in the per-query `Explain` struct, not the reader. `comptime builtin.single_threaded` selects a no-op mutex for the block cache.

**No I/O in the library.** The host maps or reads a file with `std.Io` (0.16) and hands over `[]const u8`; the same code runs in Wasm and embedded hosts. A 40-line `lex` CLI wraps it.

**Tests that match the threat model.** `std.testing.fuzz` on `Snapshot.open`, key-space decode, and `Prose.decodeBlock`; differential tests against a 200-line naive reference evaluator (the "slow model" the plan asks for) over generated forests; property tests for `parent/subtree/root` invariants; `checkAllAllocationFailures` on every builder path.

**`@Vector` unpacking** is an optional later step behind differential tests, per the plan's SIMD rule.

---

## 9. Module map and line budget

```
src2/
  root.zig        40   public surface: Snapshot, Builder, Query, schema
  schema.zig     220   kinds, columns, predicates, key spaces, comptime Layout/Column generators
  bits.zig       260   readBits/writeBits, presence bitmap + rank, Elias–Fano, FOR frames
  keys.zig       320   KeySpace: front-coded blocks, restart dir, exact/prefix/range/reverse/fuzzy walk, postings
  forest.zig     140   preorder navigation over the three structural columns
  prose.zig      330   prose stream, block directory, bzip3 wrapper (bz3_new/encode/decode/_blocks/bound/min_memory), state pool, block cache + pins
  snapshot.zig   360   container header/directory, open/validate, hot/cold sections, digests
  compile.zig    520   Builder → snapshot: interning, preorder numbering, entry-local widths, edge CSR, prose placement, presets, byte ledger
  query.zig      480   NodeSet algebra, planner-lite, budgets, explain, materialize
  lexql.zig      230   optional textual front end
                ----
               ≈2,900   (tests excluded; build2.zig `line-budget` step enforces 3,000)
```

Not in the budget and not in v2's first cut: DICT server (`dict.zig`, an adapter over `query`), TEI XML importer (a separate tool that drives `Builder`), language analysis packs, the editor. The existing `src/` stays untouched as the **semantic oracle**: `bench2.zig` builds the same fixture through both and compares a semantic digest until v2 replaces it.

---

## 10. Delivery sequence and falsifiable gates

| Step | Deliverable | Exit test |
|---|---|---|
| A · core | `bits`, `keys`, `forest`, `snapshot`, `compile` with kinds entry/sense/form/definition; exact/prefix/render | Four-way build of one corpus (v1 raw, v1 bzip3, v2 balanced, dictd/dictzip): bytes, warm exact p50/p99, cold render p99; `explain size` ledger matches file length exactly |
| B · graph and TEI | edges, assertions, participants, evidence, extension nodes, shapes, inherited columns, word parts | Semantic digest of a TEI fixture (the audit's acceptance matrix) equals the `LEXSEM` oracle digest after export; fuzz and allocation-failure suites green |
| C · search and query | normalized/reversed/full-text key spaces, `query.zig`, `lexql.zig`, cold-section bzip3 | Slow reference evaluator agrees on 10 k generated queries; no query decodes a prose block before `materialize`; budgets return `BudgetExceeded` never truncation |
| D · serve | `dict.zig`, CLI | RFC 2229 transcript diff against dictd on the same import |

Ablations (each a flag in `compile`): preorder vs kind-grouped prose within blocks; 64 KiB / 256 KiB / 1 MiB / 4 MiB blocks; reverse adjacency vs none vs wavelet; front-coded keys vs FST; shapes vs per-column presence; Elias–Fano vs FOR for edge targets; inline vs interned repeated prose. Each reports total bytes, warm/cold latency, decode amplification, and lines of code, and loses if it does not pay.

Gates carried over unchanged from `plan.md` §14.4: ≥ 20 % smaller than the smallest equivalent legacy artifact on the prose-heavy suite, ≥ 2× warm lookup throughput at equal semantics and RAM, both from the same build, cold p99 within 10 % of the fastest equivalent cold baseline, memory ceiling honoured including codec buffers.

---

## 11. Deliberate omissions

- No global compression of the key or structural sections: membership and prefix must stay decode-free.
- No FST in the baseline; front-coded blocks are simpler and the ablation decides.
- No wavelet matrix in the baseline; the reverse CSR is a few lines and honest about its bytes.
- No generic SQL, no unbounded regex, no transitive closure of translation/synonymy/etymology.
- No editor or WAL in v2's first cut; snapshots are immutable generations exactly as the plan's Stage 1–5.
- No claim that bzip3 wins: the `bench2` harness carries raw and zstd controls and prints whatever it measures.
