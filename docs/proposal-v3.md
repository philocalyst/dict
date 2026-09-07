# LEX3: key-ordered forests, permuted key spaces, and zero-byte columns

Proposal · 7 September 2026 · builds on the shipped `src2/` (LEX2) implementation
and its benchmark run `bench2/results/runs/20260907T062019Z-58034`.

LEX2 delivered the architecture: one preorder forest, kind-ranked columns,
Elias–Fano adjacency, prose blocks with explicit pins, budgeted queries. The
benchmark then said two things clearly. Selective lookups are already at v1
speed or better. Bytes are not: on the flat fixture LEX2 is 238 KB where slob
is 74 KB and whole-file zstd of the SQLite artifact is 25 KB. This document
dissects those 238 KB byte by byte, shows that about 95 % of them are
structure that carries no information the snapshot does not already have
elsewhere, and proposes the representation that removes them while making
the type system and the word model stronger. Every projected figure is
arithmetic over the measured ledger; none is a measurement.

---

## 0. The thesis in one paragraph

Store entries in **headword order** so the key ordinal *is* the entry ordinal
and postings disappear. Store every **derived key space as a permutation** over
the primary one so no string is ever written twice. Intern **entry skeletons**
so the forest costs a few bits per entry instead of twenty bits per node. Let
the compiler pick, per column, from a cascade of storage strategies that starts
with **identity** and **constant** (zero bytes) before it spends a single bit.
Give the prose block an item directory that is derived from the forest and
**bit-packed lengths** instead of eight-byte records, and boost small bzip3
blocks with a corpus **primer** so latency-preset blocks compress like large
ones. Encode full-text postings as **run/bitmap/EF containers** over entry
ordinals. Emit nothing for empty sections and a digest for the schema. Then
make the whole thing *more* typed: kinds with declared children and columns,
relations with declared symmetry and inverses (which also halves reverse
adjacency), feature bundles and language tags as packed structs, and a
comptime-typed query pipeline in which an illegal navigation is a compile
error. Projected result on the benchmark fixtures: roughly 10× smaller than
LEX2 and 3–4× smaller than slob, with exact lookup unchanged, prefix
enumeration collapsing from 60 µs to about 1 µs, and open dropping from 38 ms
to microseconds.

---

## 1. Where LEX2's bytes actually go

Dissected from `flat-v2-latency-bzip3.bin` (2,048 entries, 8,192 nodes, 237,984 bytes):

| Section | Bytes | Share | What it holds | Information content |
|---|---:|---:|---|---|
| `key_terms` | 93,026 | 39.1 % | full-text: 2,072 terms, 51,200 postings @ 13 bits | ~24 terms occur in *every* entry (a run each), 2,048 numeric tokens occur once |
| `key_reversed` | 38,185 | 16.0 % | reversed headwords, front-coded (stream 30,465) | a permutation of the headword space; front-coding fails on reversed strings |
| `forest` | 20,648 | 8.7 % | subtree 2,216 · parents 2,216 · roots 1,344 · kinds 5,120 · kind ranks 3,828 · kind indexes 5,376 · dir 464 | every entry has the identical 4-node skeleton |
| `columns` | 20,572 | 8.6 % | five 11-bit lanes: `headword`, `written`, `normalized`, `reversed`, `text` | all five are identity maps of the node's kind-rank once entries are key-ordered |
| `prose` | 19,954 | 8.4 % | payload 11,394 · directory 8,528 (7 records × 48 B + root table 2,048 × 4 B) | v1 compresses the same text to 4,318 B; LEX2's in-block 8-byte item records cost 7 KB *after* compression |
| `key_headword` | 19,183 | 8.1 % | 2,048 keys (stream 11,463) + 4,096 postings @ 13 bits (6,656) + restarts 1,024 | the postings are the entry ordinals in key order: an identity |
| `key_normalized` | 19,183 | 8.1 % | byte-identical to `key_headword` | zero: ASCII folding changed nothing |
| `schema` | 3,249 | 1.4 % | the manifest as text | 32-byte digest |
| `edges` | 3,070 | 1.3 % | 14 empty adjacency records | zero |
| empty sections, header, directory, 64 B alignment | 914 | 0.4 % | | ~150 B |

Structure that is not prose text: 226,590 bytes, i.e. **110 bytes per entry**.
The prose itself, at v1's block layout, is 4.3 KB. slob's entire file is 74 KB.

Three of the findings generalise beyond this synthetic corpus and are the
levers of this proposal:

1. **Postings, headword columns, and prose ordinals are permutations of each other.** Once the physical order is chosen well, all of them are identities.
2. **Per-node structure is dominated by repeated skeletons.** Real dictionaries have hundreds of distinct entry shapes, not millions.
3. **Anything stored inside a bzip3 block competes with the text for compression.** Fixed-width integers are poison; derive them from the forest instead.

Two more are latency, not bytes. `Snapshot.open` walks every key, posting,
node, column and edge (38 ms for 2,048 entries; 500× slower than slob's open),
and prefix enumeration decodes every posting of every matching key with a
budget check per element (60 µs versus v1's 43 µs and a range-answer floor of
about 1 µs).

---

## 2. Physical order: headword order is the forest order

LEX2 compiles the forest in builder insertion order. LEX3 sorts roots by
`(collation key of headword, homograph ordinal)` before preorder numbering.
Nothing about the model changes; everything about the bytes does:

| Consequence | Bytes today (flat) | Bytes after |
|---|---:|---:|
| headword postings (entry ordinal is the key ordinal) | 6,656 | 0 |
| `headword` column (root rank → key ordinal is identity) | 2,816 | 0 |
| prose blocks in key order (already true by accident) | — | — |
| prefix query result | materialised posting list | a root-ordinal *range* |
| homographs | duplicate keys with two postings | one key with a `count` bit |

**Homographs.** The primary key space stores each distinct headword once with
a one-bit "multiple" flag; a small side list (EF) gives the extra counts. Entry
ordinal of key ordinal `k` = cumulative count, which the restart record already
carries (`posting_index` becomes `root_index`).

**Non-lemma forms.** Inflected and variant forms that are searchable but are
not entries go into a separate **form space**. Its postings target entry
ordinals, but a form usually sorts near its lemma, so the compiler stores each
posting as a **signed delta from the key's own insertion rank among the lemma
keys** (the lower bound where the form would sit in the primary space). For
"banks → bank" that delta is 0 or 1. Widths fall from `log2(N)` to a few bits.
Forms whose `written` equals the entry's headword (the flat fixture's `form`
nodes) are not stored at all; the column strategy below records "same as
owner's headword".

**Collation.** Physical order uses the profile's binary collation of the
normalized key so that prefix ranges are exact. Display order under a locale
collation is a cold permutation when a profile asks for it.

---

## 3. Derived key spaces are permutations, never strings

`normalized`, `reversed`, `collated`, and any future derived space are defined
by a total function of the primary keys. LEX3 stores:

- **Overlay** for spaces where the derivation is usually the identity (`normalized`): only the keys whose derived form differs, front-coded, each pointing at its primary ordinal. On an already-lowercase corpus this is a 40-byte header. Lookup = merge of the overlay hit and the primary hit.
- **Permutation** for spaces where the derivation changes every key (`reversed`): a FOR-packed array `perm[i] = primary ordinal of the i-th key in derived order` (`log2(N)` bits per key: 2,816 B for the flat fixture instead of 38,185) plus one 8-byte **u64 prefix skip-index** entry per 32 keys for cache-friendly binary search (the first eight bytes of the derived key, so probes compare integers and never decode). Comparing at a probe decodes one primary key (≤ 16 front-coded records) and applies the derivation in a stack buffer. Prefix enumeration over the derived space yields primary ordinals directly.

This is general: a derived space costs `n·log2(n)` bits plus the skip-index,
regardless of how badly its strings front-code, and it can never disagree with
the primary space because it has no strings of its own.

The **primary space** keeps front-coding with two byte-level fixes measured
against the 11,463-byte stream: `(shared, suffix_len)` packed into one byte
when both are below 16 (saves ~1 B/key on the fixture), and the u64 prefix
skip-index per restart so the binary search touches one contiguous array
instead of decoding a restart key per probe (this is the exact-lookup latency
guard for a larger restart interval).

---

## 4. Forest: skeletons, not nodes

An entry's subtree, as a sequence of `(kind, subtree_size)` in preorder, is its
**skeleton**. The compiler interns skeletons into a table (bounded, say 65,536
entries, each at most 4,096 nodes) and stores per root a skeleton ordinal in a
FOR-packed column. Entries whose skeleton does not fit the table fall back to
an explicit per-node encoding for that root only (a "wild" skeleton flag).

| Structure | LEX2 bits per node | LEX3 |
|---|---:|---|
| `subtree` + `parent_delta` | ~4.3 | skeleton table only |
| `kind` | 5 | skeleton table only |
| kind rank directory | ~3.7 | per-256-root checkpoint of cumulative kind counts (same bytes per root as today per node ÷ 4) |
| per-kind EF node indexes | ~5.2 | none: `all(.sense)` iterates roots × skeleton offsets |
| root starts | EF | constant stride when all skeletons have equal size, else EF |

Navigation is arithmetic on the skeleton: `parent(n)`, `children(n)`, `subtree
end`, and `kind(n)` are table lookups after `root(n)` (EF predecessor or stride
division). `kindRank(n)` = checkpoint count + sum over ≤ 255 skeleton kind
counts (a precomputed `[skeleton][kind]` u16 table) + local rank in the
skeleton. All O(1) or O(256) table reads; no bit-level decode.

On the flat fixture the forest is one skeleton (four nodes) and one constant
stride: about 100 bytes instead of 20,648. On a real dictionary with, say, 400
skeletons it is 9 bits per entry plus the table, against 20 bits per node.

Extension-heavy TEI entries produce long skeletons; the compiler measures
skeleton table bytes plus fallbacks against the per-node encoding and picks
per snapshot. That choice is recorded in the section header, so a reader has
one code path per variant and no heuristics.

---

## 5. Columns: a storage cascade that starts at zero bytes

Every column keeps its schema (kind set, presence policy, value type). What
changes is that the compiler chooses a **storage strategy** per column per
snapshot, and records it in the column record:

| Strategy | When | Bytes |
|---|---|---:|
| `identity` | value[i] == i for all rows (prose ordinals; headword under key order) | 0 |
| `constant` | one distinct value | one value |
| `same_as_owner(C)` | value equals column C of the nearest ancestor of a declared kind (`form.written == entry.headword`) | presence bitmap only when mixed |
| `runs` | few distinct runs (language of a monolingual dictionary, `state = asserted`) | run boundaries EF + values |
| `packed` | minimum width lane (today's default) | `n · width` |
| `frame_of_reference` | numeric with locality | frames |
| `dictionary` | few distinct values but no locality | packed codes + value table |
| `exceptions(default)` | almost always one value | sparse EF row list + values |

The reader is a tagged union with `inline else`; `get` is one switch. The
compiler tries the cascade in the order above and keeps the first that is also
the smallest, so a regression in any strategy is a measured, reported event.
On the flat fixture all five stored columns become `identity` or
`same_as_owner`: 20,572 bytes become the 23-entry directory (~200 bytes).

The kind-scoped domain and presence bitmap rules of LEX2 stay exactly as they
are; they are what make `identity` possible.

---

## 6. Prose: derive the directory, pack the lengths, prime the block

### 6.1 In-block directory

LEX2 stores `(node u32, cumulative_end u32)` per item inside the compressed
payload. On the flat fixture that is 2,624 bytes of high-entropy integers per
64 KB block, and it explains why v1 compresses the same text to 617 bytes per
block while LEX2 needs 1,680. LEX3 stores:

- no node IDs: item `i` of a block is the `i`-th text-bearing node in the block's node range, which the skeleton table enumerates;
- lengths as a FOR frame (width = bits of the largest item in the block; 8 bits on the fixture, so 328 bytes raw and a few dozen after bzip3).

### 6.2 Block directory

`(root_first, root_last, node_first, node_last, root_index, root_count)` and the
2,048-entry root table are all derivable from `node_first` plus the forest.
LEX3's record is `node_first` (EF over nodes), `stored_offset` (cumulative,
EF), `original_size` (FOR) and a codec bit: about 6 bytes per block against 48
plus 4 per root. The flat fixture's 8,528-byte directory becomes about 50.

### 6.3 Prose aliasing

v1 interned identical definitions; LEX2 does not, which is why the `repeated`
fixture is 227 KB in LEX2 against 117 KB in v1. LEX3 restores it as a column
strategy on the `text` column: `alias(prose)` marks items whose bytes equal an
earlier item and stores the earlier ordinal in an exceptions list. Aliased
items are not emitted into any block. High-fanout shared texts (a definition
reused by thousands of entries) are placed in an explicitly addressed shared
block so one entry render decodes at most two blocks, per the plan's §7.2.

### 6.4 Primer-boosted small blocks

bzip3 has no dictionary API, but its LZP and context model benefit from any
text in the same block. The compiler builds a **primer**: up to 8 KB of the
most frequent byte sequences across the prose (sampled substrings scored by
occurrence × length, deduplicated). Each block is encoded as `primer ‖ items`
and the primer bytes are discarded after decoding. The primer costs its
compressed size per block (typically 100–400 bytes) and buys small blocks the
vocabulary of the whole corpus. This is the trick that makes an **entry-count
preset** viable: the latency preset becomes "16 entries per block" instead of
"64 KiB per block", so a cold render decodes ~3–8 KB (tens of microseconds)
instead of 64 KB (685 µs measured). The primer is an ablation with three arms
(none / 2 KB / 8 KB) reported per preset; if it does not pay on real corpora
it is switched off per snapshot and the flag says so.

### 6.5 Runtime

Unchanged ownership model (pins, request-owned decoder), plus a bounded LRU
of decoded blocks keyed by `(snapshot, block)` with pin counts, and batch
render through `bz3_decode_blocks` when the host supplies a thread pool.

---

## 7. Full-text index: containers over entry ordinals

Postings target entry ordinals (not node IDs), because the reverse-lookup
answer is "which entries" and the render unit is the entry. Each term's
posting list is encoded as one of three containers chosen by density:

| Container | Condition | Bytes for the flat fixture's "every entry" terms |
|---|---|---:|
| run list | ≤ 8 runs cover the list | 24 terms × ~6 B = 150 |
| bitmap | density > 1/32 | `N/8` |
| Elias–Fano | otherwise | `n(log2(N/n)+2)/8` |

The term dictionary stays front-coded. The whole section is a **cold section**:
stored bzip3-compressed, decoded once on first `terms` query into a query-arena
cache, verified by its digest at that point. The search profile gains a
`skip_numeric_tokens` policy so corpora full of citation numbers do not
index every number as a term; the flat fixture's 2,048 single-use numeric
terms are 90 % of its term dictionary.

Projected for the flat fixture: ~8 KB raw, ~2.5 KB stored, against 93,026.

---

## 8. Container hygiene

- Schema manifest → 32-byte xxh3-128 digest plus the 2-byte version; the text is regenerated at comptime by the reader and compared by digest. A `lex inspect` tool can still print it. Saves 3.2 KB per snapshot.
- Empty sections are not emitted. A reader treats a missing optional section as empty.
- Alignment: 64 bytes for sections ≥ 4 KB, 8 bytes otherwise.
- Adjacency records only for predicates with edges; reverse only when the policy says so *and* the predicate has edges.

Per snapshot this is about 4 KB. It matters only at small sizes, which is
exactly where the benchmark compares.

---

## 9. Open in microseconds, verify on demand

LEX2 validates every structure at open. LEX3 splits trust into three tiers,
all present in the format:

1. **Envelope** (always at open): header, directory, digests of the directory and of every section *header* (first 256 bytes). Microseconds.
2. **Page digests** (verified on first touch): each section carries a table of 32-bit xxh3 digests per 64 KB page; an accessor that touches a page for the first time verifies it (a `std.bit_set.DynamicBitSet` of verified pages per snapshot, one bit per 64 KB). Corruption is still detected before any byte influences an answer; cost is amortised and proportional to what is read.
3. **Structural audit** (`verify`, and inside `compile`): everything LEX2's `open` and `validateDeep` do today.

All accessors already bounds-check every index they compute, so an
unverified page can never cause an out-of-bounds read; it can only cause an
explicit `Corrupt*` error. The `Snapshot` API gains `openTrusted` (tier 1 +
2) and `openVerified` (all tiers); the benchmark reports both.

Projected: open p50 from 38,567 µs to well under 100 µs, independent of size.

---

## 10. Projected ledger

Arithmetic over the measured ledger, same fixtures, same content and the same
semantic digest; "terms" is the full-text index that no external baseline
carries, so both figures are shown.

| Fixture | LEX2 | slob/lzma2 | sqlite whole-file zstd | LEX3 with terms | LEX3 without terms |
|---|---:|---:|---:|---:|---:|
| flat | 237,984 | 74,476 | 24,732 | ≈ 20,500 | ≈ 18,000 |
| repeated (prose aliasing) | 229,536 | 82,898 | 21,521 | ≈ 15,000 | ≈ 12,500 |
| prose_heavy (compact) | 241,248 | 123,820 | 46,173 | ≈ 27,000 | ≈ 24,500 |
| pathological_prefix | 283,168 | 116,072 | 22,723 | ≈ 24,000 | ≈ 21,500 |

Where the flat estimate comes from:

| Part | Bytes |
|---|---:|
| primary key space (front-coded, packed shared/len, interval 32, u64 skip-index) | ≈ 9,500 |
| homograph flags | 256 |
| normalized overlay | 64 |
| reversed permutation (11 bits × 2,048) + skip-index | ≈ 3,400 |
| form space | 0 (all forms equal their headword) |
| forest (one skeleton, constant stride) | ≈ 100 |
| columns (all identity / same-as-owner) | ≈ 200 |
| prose payload at v1's compression, 64 KB blocks | ≈ 4,400 |
| prose directory + in-block length lanes | ≈ 150 |
| terms, cold, bzip3 | ≈ 2,500 |
| edges | 0 |
| header, directory, digests, page tables | ≈ 450 |

These fixtures compress absurdly well (the flat prose is 394 KB of one
sentence with a counter), so the *ratio* to slob will not transfer to a real
dictionary, where prose dominates and the codec decides. What transfers is
the structural overhead: LEX2 spends ~110 B per entry outside the prose;
LEX3 spends about 8 (keys ≈ 4.5, reversed 1.4, terms ≈ 1.2, everything else
< 1). slob spends roughly 12–20 per entry on its key list, offsets and blob
references. So the size gate below is stated on real corpora, not on the
fixtures.

---

## 11. Latency paths after the change

| Operation | LEX2 measured (flat) | LEX3 projected | Why |
|---|---:|---:|---|
| exact hit | 0.46 µs | ≈ 0.3 µs | u64 skip-index probes, no posting decode |
| exact miss | 0.25 µs | ≈ 0.2 µs | same |
| prefix, one result | 0.62 µs | ≈ 0.4 µs | range from two lower bounds |
| prefix, many | 59.9 µs | ≈ 1 µs | `NodeSet.range`, nothing materialised |
| prefix, pathological (1,536 hits) | 58.8 µs | ≈ 1 µs | same |
| suffix | not measured | ≈ prefix + one derivation per probe | permutation space |
| render, latency preset | 685 µs | ≈ 30–60 µs cold, ≈ 1 µs cached | 16-entry primed blocks + LRU |
| render, compact preset | 5,235 µs | unchanged cold | 4 MiB blocks are the archive trade |
| open | 38,567 µs | < 100 µs | envelope-only |
| reverse lookup | not measured | one cold-section decode, then container merges | |

The only path that gets slower is the first `terms` query on a cold section
(one bzip3 decode of a few hundred KB per 100 k entries).

---

## 12. Stronger types and stronger word semantics

The byte work above is enabled by a schema that says more. Each addition
below both tightens the type system and removes bytes or code.

### 12.1 Kinds declare their shape

```zig
pub const KindSpec = struct {
    parents: KindSet,            // legal owners (replaces the hand-written legalParent switch)
    children: KindSet,           // legal children, ordered as in the source
    columns: []const ColumnId,   // the columns this kind may carry
    text: bool = false,          // contributes an item to the prose stream
    searchable: ?KeySpaceId = null,
};
pub const kind_specs = std.enums.EnumArray(Kind, KindSpec).init(.{ ... });
```

`schema.columns.X.over` becomes derived from `kind_specs` (a column is "over"
every kind that lists it), so the two can never disagree. `KindSet` becomes
`std.bit_set.IntegerBitSet(kind_count)` instead of a hand-rolled `u32`, which
also removes the current 32-kind ceiling.

From `kind_specs` the schema generates **typed node views**:

```zig
pub fn View(comptime kind: Kind) type {
    return struct {
        snapshot: *const Snapshot, id: Ref(kind),
        // one accessor per declared column, typed by Column.Value:
        pub fn lang(self) ?LanguageTag { ... }           // only if .lang is declared for kind
        pub fn definition(self, pin: *ProsePin) ![]const u8   // only if kind.text
        pub fn children(self, comptime child: Kind) ChildIterator(child) // comptime-checked legality
        pub fn owner(self, comptime parent: Kind) ?Ref(parent)
    };
}
```

Reading a column a kind cannot carry is a compile error, not a `null`.

### 12.2 Relations declare algebra

```zig
pub const RelationSpec = struct {
    id: PredicateId, name: []const u8,
    domain: KindSet, range: KindSet,
    symmetric: bool = false,          // synonymy, antonymy, cognate_of
    inverse: ?PredicateId = null,     // hypernym ↔ hyponym, holonym ↔ meronym, form_of ↔ has_form
    transitive: bool = false,         // hypernym, entailment (declared, never auto-closed)
    reverse: Reverse = .materialized,
};
```

The compiler stores a symmetric relation once (each edge in the adjacency of
its smaller endpoint; `follow` and `back` both read it) and stores an inverse
pair as one adjacency with two names. That removes the reverse copy for the
relations that dominate a lexical graph, and it makes the query planner able
to answer `hyponyms(x)` from the `hypernym` adjacency without anyone having
materialised it. `transitive` is metadata for `traverse` (depth-bounded, cycle
safe), never an implicit closure.

Built-in inventory (OntoLex / WordNet / TEI aligned): `synonym`, `antonym`,
`hypernym`/`hyponym`, `holonym`/`meronym`, `troponym`, `entails`, `similar_to`,
`also_see`, `derived_from`, `variant_of`, `form_of`/`has_form`, `sense_of`,
`realizes`, `translation`, `etymon_of`, `cognate_of`, `see_also`. Runtime
predicates keep the LEX2 path (atom name + assertion node + shadow edges).

### 12.3 Values stop being bytes

| LEX2 | LEX3 |
|---|---|
| `lang: atom` (free string) | `LanguageTag = packed struct(u32){ language: u15, script: u7, region: u9, has_variant: bool }` interned in a `languages` table; the original spelling is an `exceptions` column present only when it differs from the canonical spelling; `direction` derived from script unless overridden |
| `pos: atom` | `Pos = enum(u5)` (the 17 Universal POS tags + `x` + extension), with `pos_extension: atom` only for `extension` |
| no morphology | `Features = packed struct(u32){ number: u2, gender: u3, case: u4, person: u2, tense: u3, mood: u3, aspect: u2, voice: u2, degree: u2, definite: u2, polarity: u2, reserved: u5 }` interned into a `bundles` table (sorted distinct u32s, FOR); nodes carry a bundle ordinal (a few bits) |
| `temporal: bytes` | `Temporal = packed struct(u64){ start: Date, end: Date }` with `Date = packed struct(u32){ year: i16, month: u4, day: u5, precision: u3, approximate: bool, ... }` |
| `certainty`, `state` as `enum_value` u8 | remain enums, but stored through the cascade (`constant` when every assertion is `asserted`) |
| `context: bytes` | `context: node` (a `source` or `extension` node) |
| `anchor: bytes` | `Anchor = struct { node: Node, span: ?Span }` in the cold section |
| `notation` absent | `notation: enum(u3){ orthographic, ipa, xsampa, romanized, extension }` on `pronunciation` and `part` |
| `sense` has no lexical-semantic fields | `sense` gains `domain: atom`, `register: atom`, `synset: external id`, `frequency_rank: u16 (exceptions)` |
| `lexeme`/`entry` implicit | `entry.lexeme` typed edge `sense_of`/`form_of`; a lexeme may own senses shared by several source entries |

None of this widens the file: bundles and language tags are small ordinals
into tables of distinct values, and the packed structs give the query engine
typed comparisons (`features.number == .plural`) with no string handling.

### 12.4 The query pipeline is typed at comptime

```zig
pub fn Set(comptime kind: Kind) type {
    return struct {
        // navigation returns the kind the schema says it returns
        pub fn senses(self: @This()) Set(.sense)                       // requires kind_specs[kind].children.has(.sense)
        pub fn definitions(self: @This()) Set(.definition)
        pub fn follow(self: @This(), comptime rel: RelationSpec) Set(rel.rangeKind())  // requires rel.domain.has(kind)
        pub fn back(self: @This(), comptime rel: RelationSpec) Set(rel.domainKind())
        pub fn where(self: @This(), comptime C: type, cmp: Compare, value: C.Input) @This() // C must be declared on kind
        pub fn lang(self: @This(), tag: []const u8) @This()
        pub fn take(self: @This(), n: usize) @This()
        pub fn run(self: @This()) !NodeSet(kind)
        pub fn rows(self: @This(), comptime fields: anytype) !Rows(kind, fields) // typed row struct
    };
}
```

`Rows(kind, .{ .headword, .definition, .lang })` produces a comptime-generated
`struct { headword: []const u8, definition: []const u8, lang: LanguageTag }`
per row. The stringly `ColumnValue` union and the runtime `InvalidColumn`
checks disappear; the pipeline's `Op` list stays as the erased executable
form beneath the typed surface. `NodeSet` becomes

```zig
pub fn NodeSet(comptime kind: Kind) type {
    return union(enum) {
        range: struct { first: Ref(kind), end: Node },      // prefix queries, descendants of a range
        sorted: []const Ref(kind),
        roots_by_skeleton: struct { roots: RootRange, kind_offsets: []const u16 }, // all(.sense) over a range
    };
}
```

so a prefix query never materialises, and `descendants` of a range is a range.

### 12.5 Builder ergonomics and Zig idioms

- Drafts move to `std.MultiArrayList(NodeDraft)` with cells in one arena-backed `std.ArrayListUnmanaged(Cell)` per builder, indexed by `(first, count)` per node, instead of one `ArrayList` per node.
- `root(.entry, .{ .headword = "bank" })` and `child(...)` keep their shape, but the initializer struct is checked against `kind_specs[kind].columns` at comptime, so a misplaced field is a compile error naming the kind.
- Predicate names use `std.StaticStringMap(PredicateId)`; roles are `Role` enums for built-ins and atoms for runtime vocabulary, as today.
- All on-wire fixed records stay `wire.Layout`-generated; the new packed value types get `comptime { if (@bitSizeOf(Features) != 32) @compileError(...) }` guards.
- Column strategy readers are `union(enum)` with `inline else` dispatch; every strategy has one encoder, one decoder, and one fuzz target.

---

## 13. Delivery and the gates that can fail it

| Step | Change | Gate (same digest, same workload, `bench2`) |
|---|---|---|
| A | key-ordered compile; identity/constant/same-as-owner strategies; skeleton forest; derived prose directory + packed lengths; omit empties; digest manifest | flat ≤ 40 KB; prefix-many ≤ 5 µs; exact within 10 % of LEX2 |
| B | permutation/overlay key spaces; form space with positional deltas; run/bitmap/EF term containers; cold-section bzip3; prose aliasing | flat ≤ 25 KB; repeated ≤ 20 KB; every fixture ≤ slob/lzma2 |
| C | primer, entry-count latency preset, LRU, batch decode; tiered open | render latency-preset p50 ≤ 100 µs; open p50 ≤ 100 µs |
| D | typed kinds, relation algebra, packed values, typed pipeline | no size regression; compile errors for the twelve illegal navigations in the test matrix; rich fixture graph queries agree with the reference evaluator |

Ablations, each a compiler flag and a row in the report: skeleton table vs
per-node forest; identity/constant detection on/off; permutation vs stored
strings for `reversed`; primer 0/2/8 KB; entry-count vs byte-count blocking;
container thresholds; interval 16 vs 32 with and without the u64 skip-index.

Real-corpus gates, stated so the fixture results cannot be mistaken for them:
on a prose-heavy real dictionary (Wiktionary subset, TEI), LEX3 total bytes ≤
slob/lzma2 of the same projection, structural bytes per entry ≤ 12, exact hit
p50 ≤ 0.5 µs warm, and render p50 in the latency preset ≤ 100 µs cold.

---

## 14. What this deliberately does not do

- No FST or trie for the primary key space. Front-coding with the skip-index is within ~2× of an FST on the fixtures and a fraction of the code; it stays an ablation.
- No wavelet matrix. Symmetric and inverse relations remove most reverse copies without one.
- No global compression of keys, skeletons or columns: membership, prefix and navigation stay decode-free.
- No new codec. The primer is a layout trick on top of the pinned libbz3.
- No claim on real corpora until the step-B gate runs on one; the fixture ratios above are arithmetic over a synthetic corpus whose prose compresses 90:1.
