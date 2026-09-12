# LEX4: rank is identity, automata are indexes, grammars are text

Proposal · 7 September 2026 · supersedes the incremental `proposal-v3.md`.

v3 removed the redundant bytes that LEX2 spends. It kept LEX2's four load-
bearing assumptions: keys are stored as strings, prose is decoded in blocks,
relations are pairwise edges, and structure is stored at fixed bit widths. Each
of those is a ceiling. This proposal removes all four and replaces them with
one organising principle and four mechanisms that follow from it. The result
is a snapshot with no stored IDs at all, prefix and containment queries that
cost O(length of the prefix), definition access in microseconds *without*
block decompression, an entropy-coded forest, a concept-centred lexical model
that is strictly richer than TEI or OntoLex-Lemon, and a size that on the
benchmark fixtures is projected below whole-file zstd of the SQLite artifact.
Numbers are arithmetic on the measured LEX2 ledger and on published results
for the named techniques; nothing here is measured yet.

---

## 0. One principle, four mechanisms

**Rank is identity.** Every object in the snapshot is identified only by its
rank in some sorted order, and every sorted order is one that a succinct
structure can compute. Entries are ranked by headword. Nodes are ranked by
preorder within key order. Senses are ranked among senses, definitions among
definitions, concepts among concepts. No ID is stored anywhere; the file
contains only structures that answer *rank* and *select*. Once this holds,
four things become possible that block-and-pointer designs cannot do:

1. **The key index is a minimal acyclic automaton whose accepting paths are numbered.** Walking a key yields its rank; walking a prefix yields a rank *interval*. There are no postings, no key strings outside the automaton, no permutation for headwords. Fuzzy, regex, and phonetic search are products with other automata over the same structure.
2. **Navigation is interval arithmetic in kind-rank space.** Because roots are in key order and nodes in preorder, the senses of the entries in a prefix interval are themselves an interval of sense ranks, and their definitions an interval of definition ranks. A query never materialises a node list until it hits a filter that is not interval-closed.
3. **Prose is a grammar, not a block.** A global grammar built with a deterministic, bounded-sample Re-Pair heuristic factors corpus-wide phrase redundancy once; each definition is a short sequence of grammar symbols that expands in microseconds with no codec state, no cache, and no decode amplification. bzip3 is applied to the *symbol stream*, per preset, as residual compression only.
4. **Structure is entropy-coded.** Entry skeletons, kinds, parts of speech, languages, and assertion states are low-entropy columns; a static rANS coder with checkpointed random access stores them at their entropy (often under one bit per entry) instead of their width.

Around these, the lexical model gains a concept layer (synsets and interlingual
concepts as nodes, so synonymy and translation are memberships rather than
quadratic edge sets), relations gain declared algebra, and the query surface
is typed at comptime so that an illegal navigation is a compile error.

---

## 1. What v3 still pays for, and why it is a ceiling

| v3 keeps | Cost on the flat fixture | Why it cannot go lower |
|---|---:|---|
| front-coded key strings | ≈ 9.5 KB for 2,048 keys (4.6 B/key) | front-coding shares only the prefix with the previous key; "entry-00001234" shares nothing structural with "entry-00002234" |
| a permutation per derived space | 2.8 KB each | correct, but every new search axis (phonetic, collated, stemmed) costs n·log₂n bits |
| block decode for any definition | 685 µs (64 KB) or 30–60 µs (16-entry blocks) | every render decodes bytes it does not return; a cache only hides it |
| pairwise relations | k² edges for a k-way synonym set or a k-language translation cluster | pairwise is the wrong model for equivalence-like relations |
| FOR / packed columns | ≥ 1 bit per value even when one value covers 99 % | width-based codes cannot spend fractional bits |
| blocks bounded by bytes | latency and size traded against each other per block | the trade is inherent to block coding |

Each row is removed below.

---

## 2. The automaton key index

### 2.1 Structure

All searchable strings of the primary search space (headwords, and the
`written` forms of variants and inflections) are compiled into one **minimal
acyclic deterministic automaton** over bytes, in the Lucene-FST style: states
serialised in reverse topological order, arcs as `(label, flags, target
delta)`. Suffix sharing is what distinguishes this from a trie; on real
dictionaries ("-ation", "-ness", "-ing", "-ly") it is a 2–3× reduction over a
trie and roughly 2–4 bytes per key on English word lists. On the flat fixture
the digit structure collapses: about 2,300 states and ≈ 3–4 KB.

### 2.2 Ranks instead of outputs

Each state carries `count` = number of accepted strings reachable from it.
Each arc carries the cumulative count of the arcs before it at that state
(delta-coded, usually one byte). Walking a key `k` accumulates the rank of `k`
in lexicographic order:

```
rank(k) = Σ over the path of  cumulative_count_before(arc)  +  Σ [state is final before taking arc]
```

Because entries are compiled in exactly that order, `rank(headword) = entry
ordinal`. There is no output table and no postings section. Walking a prefix
`p` to state `s` yields the interval `[rank(p), rank(p) + count(s))`. Prefix
enumeration is O(|p|) regardless of how many keys match; the headwords
themselves are enumerated on demand by a bounded DFS from `s`.

### 2.3 Forms and homographs

A string that is not an entry headword (an inflected form) is accepted by the
same automaton, but its rank in the automaton is not an entry ordinal. Its
final arc carries an **explicit output**: the target entry ordinal as a signed
delta from the string's own automaton rank (forms sort near their lemmas, so
the delta is a few bits). A `flags` bit marks explicit-output arcs. Homographs
are one accepted string with a `multiplicity` bit; a small Elias–Fano list
maps the multiplicity ranks to extra counts, and entry ordinal = automaton
rank + cumulative extra count (one EF `rank` query).

### 2.4 Derived search axes are automata with explicit outputs

Any derived axis (normalized, reversed, collated, phonetic, stemmed) is a
second automaton over the derived strings whose explicit output is the primary
ordinal delta. Two properties keep this cheap:

- an axis whose derivation is mostly the identity (`normalized` on a lowercase corpus) becomes an **overlay automaton** containing only the strings whose derived form differs, merged with the primary automaton at query time;
- an axis that permutes everything (`reversed`) is a full automaton, but suffix sharing on reversed strings is *prefix* sharing on the originals, so it compresses as well as the primary. The explicit outputs are the n·log₂n bits v3 already paid, now delta-coded against the axis rank and typically smaller.

The strings are never stored twice as strings; the automaton *is* the string
store.

### 2.5 Products: fuzzy, regex, phonetic, and DICT strategies

Levenshtein-automaton intersection, regex-DFA intersection, and bounded
wildcard are all products with the key automaton and return rank intervals or
rank lists. DICT `MATCH exact/prefix/suffix/re/lev/soundex/metaphone` map to
walks on the primary, reversed, and phonetic axes. None of them decodes
anything but automaton arcs. The plan's "minimal automaton with rank-addressed
postings" experiment becomes the baseline.

### 2.6 Cost model

| Operation | Work |
|---|---|
| exact | one arc scan per byte of the key (`@Vector(16, u8)` label compare per state) |
| prefix interval | same, then two reads |
| enumerate a prefix's headwords | DFS over the subtree; output bytes only |
| fuzzy (k) | product walk bounded by `max_visited` |
| lookup by ordinal (inverse) | `select`: descend by counts, O(depth) |

The last row matters: rendering an entry needs its headword, and `select` on
the automaton reconstructs the string from the ordinal without any key
storage elsewhere.

---

## 3. Interval algebra in kind-rank space

Nodes are ranked in preorder within key order. Each kind K has its own rank
space (LEX2's kind-rank). Two facts make queries cheap:

- **A root interval is a node interval.** `[root_start(a), root_start(b))`.
- **A node interval is a kind-rank interval for every kind.** `[kindRank(K, root_start(a)), kindRank(K, root_start(b)))`.

So `entries with prefix "ban" → senses → definitions` is three interval
computations and the answer is a contiguous slice of the definition column.
The query engine represents a set as

```zig
pub fn NodeSet(comptime kind: Kind) type {
    return union(enum) {
        interval: struct { lo: Rank(kind), hi: Rank(kind) },   // closed under descendants, kind projection, take, after
        list: []const Rank(kind),                              // produced by follow/back, where, set operations
    };
}
```

and only the `list` arm allocates. `where` on a column whose storage strategy
is `runs` or `constant` also preserves intervals (a run boundary search), so
"senses in language *fr* under prefix *ban*" stays interval-shaped in a
bilingual dictionary compiled with runs.

`kindRank(K, node)` needs a directory: per 256 roots, cumulative counts per
kind (u32 × kinds × ⌈roots/256⌉), and per skeleton a `[kind]u16` count table
so the within-checkpoint scan is 256 table adds. On the flat fixture that is
under 1 KB; on a million-entry dictionary about 500 KB, or 0.5 B per entry.

---

## 4. Grammar-compressed prose with direct access

### 4.1 Representation

All text items (definitions, examples, notes, mixed-content text) are
compressed together with a **deterministic bounded-sample Re-Pair heuristic**.
Each round counts a bounded prefix of adjacent symbol occurrences, replaces
the most frequent pair in that sample, and stops at the configured rule or
work budget. It therefore does not claim the exact globally most frequent
pair; increasing the sample cap trades compiler memory and time for a chance
at a better ratio. The output is a bit-packed rule table (`R` rules × 2
symbols), a bit-packed symbol sequence, packed cumulative item ends, and
sparse alias metadata for identical text. Every non-aliased item is a
contiguous range of the symbol sequence.

Item text is produced by expanding its symbols with an explicit stack; the
cost is linear in the output bytes, with no codec state and no allocation
beyond the caller's output buffer. A definition of 200 bytes expands in about
a microsecond.

Published results for Re-Pair on English text put the rule table plus
sequence at roughly 3.5–4 bits per character without entropy coding the
sequence, and 2.5–3 with. The fixtures are far more repetitive: the flat
fixture's 162-byte common sentence becomes one symbol, so each item is about
seven symbols.

### 4.2 The three presets become residual policies

| Preset | Symbol sequence storage | Access | Size on English prose (projected) |
|---|---|---|---|
| latency | bit-packed at `log₂(alphabet)` bits, directly addressable | expand in place, ~1–3 µs | ≈ 40–45 % of raw |
| balanced | bzip3 blocks of symbols (256 KiB of symbols ≈ 1 MiB of text) | one block decode per cold render, then expand; LRU | ≈ 20–25 % |
| compact | 4 MiB symbol blocks | archive | ≈ 18–22 % |

The latency preset is the revolution: LEX2's latency preset is either 685 µs
per render at 238 KB or 0.25 µs at 637 KB. Grammar access gives microseconds
at well under half the raw size, with zero decode amplification and no cache
to manage. The balanced preset is where bzip3 works best: the symbol stream
has already had its long-range redundancy removed, so blocks can be large
without hurting latency much (decode is over a stream 4–8× shorter than the
text).

On the flat fixture the symbol sequence is ≈ 2,048 × 7 symbols × 11 bits ≈
19 KB in the latency preset and, after bzip3 on the symbol stream, ≈ 3 KB in
the balanced preset (against LEX2's 11.4 KB and v1's 4.3 KB).

### 4.3 What the grammar gives for free

- **Aliasing.** The compiler removes an exact duplicate before grammar construction and records a backward item reference in packed alias bits, rank checkpoints, and targets. Repeated text therefore adds no duplicate symbol run or grammar rule.
- **Snippets.** A preview of the first `n` bytes expands left-to-right and stops; DICT `MATCH` with previews never touches the rest of the item.
- **Partial rendering by field.** Because items are kind-ranked, "all examples of this sense" is an interval of the example sequence, not a scan of the entry's text.
- **Grammar-level full text.** A term's occurrences can be stored per *symbol* whose expansion contains the term (the set of such symbols is small), and per-entry postings derived from symbol positions at query time. This is the self-index direction of Claude and Navarro; it is an optional accelerator, not the baseline, because §7's containers are simpler and already small.
- **Build-time parallelism.** Re-Pair is offline and single-pass per round; bzip3 residual blocks encode in parallel through `bz3_encode_blocks`.

### 4.4 Why not an FM-index over everything

An FM-index over the prose would make every definition substring-searchable,
but with a wavelet tree it costs ≈ 1.2–1.6× the raw text with dense rank
support, or ≈ 0.6–0.8× with RRR bitvectors, against grammar + bzip3 at
0.2×. Random extraction also costs O(sample distance) per byte. The plan's
warning stands: a BWT inside a compressor is not an index. An FM-index over
the *key strings only* (≈ 30–40 KB on the flat fixture, versus the automata's
≈ 7 KB) buys infix search on headwords; it stays an opt-in section for
dictionaries that want it.

---

## 5. Entropy-coded structure

### 5.1 Skeletons, coded

The forest is a sequence of entry skeletons (v3 §4). Instead of a FOR column
of skeleton ordinals, LEX4 stores the sequence with a **static rANS coder**
over the empirical skeleton distribution (frequency table stored once; 2
bytes per distinct skeleton). Random access uses a checkpoint every 64 roots
holding `(rans_state: u32, bit_offset: u40)`; reaching root `r` decodes at
most 63 symbols at ≈ 5 ns each. Cost: `H(skeletons)` bits per entry plus 10
bytes per 64 entries. When one skeleton dominates (the fixtures; many real
dictionaries have a 60–70 % modal shape) that is a fraction of a bit per
entry.

### 5.2 Columns, coded

The storage cascade of v3 §5 gains a strategy `entropy(model, checkpoint)` for
any column whose empirical entropy is below its packed width by more than
the checkpoint overhead: `pos` (a few dozen values, skewed), `lang` in a
multilingual dictionary, `state`, `certainty`, `notation`, `register`. The
compiler computes the entropy, compares `n·H + checkpoints` against every
other strategy, and records the winner. Reading a value costs one checkpoint
lookup and at most 63 symbol decodes; filters over intervals decode
sequentially at full speed.

rANS in Zig is about 80 lines: a `packed struct(u32)` state, a frequency
table in a `std.BoundedArray`, encode in reverse at build, decode forward at
read, differential-tested against an arithmetic reference and fuzzed.

### 5.3 Everything else is a bitvector

Root starts, item boundaries, homograph multiplicity, presence: all are
bitvectors with rank/select directories (dense: 64-bit words with a
cumulative popcount per 512 bits; sparse: Elias–Fano; very sparse:
RRR-style block classes). One `Bitvector` type with a comptime density hint
replaces the separate FOR/EF/presence readers of LEX2, and `@popCount` on
`@Vector(8, u64)` does the in-block rank.

---

## 6. The lexical model: layers and concepts

LEX2's kinds are a flat list with a hand-written parent legality function and
pairwise predicates. LEX4 states the model as five layers with declared
membership relations between them; the declaration is data, the storage is
derived.

| Layer | Kinds | What it asserts | Storage |
|---|---|---|---|
| **Orthographic** | `form`, `variant`, `inflection`, `part`, `pronunciation` | strings and how they are built: features, spans, notation | key automata (primary + axes), feature bundles, spans |
| **Lexical** | `entry`, `lexeme`, `homograph` | what a source treats as one word; a lexeme may be shared by several source entries | roots in key order; `sense_of`/`form_of` as interval-local links |
| **Semantic** | `sense`, `subsense`, `definition`, `gloss`, `example`, `usage`, `citation` | meaning as a source states it | forest + grammar prose |
| **Conceptual** | `concept` (synset), `interlingual` | meaning independent of language and source | membership columns (§6.1) |
| **Provenance** | `source`, `assertion`, `participant`, `evidence`, `annotation` | who claims what, with what confidence, when | forest under the asserting root; shadow edges |

### 6.1 Equivalence relations are memberships

Synonymy within a language and translation across languages are
equivalence-like. Stored pairwise, a `k`-way cluster costs `k(k−1)` directed
edges. LEX4 stores a **concept node** per cluster and one `concept` column on
`sense` (FOR or entropy-coded), plus the reverse `concept → senses` as an
Elias–Fano select list. A bilingual translation between sense *a* (en) and
sense *b* (fr) is both pointing at interlingual concept *c*; adding a third
language adds one membership, not two more edges per existing member.
`synonyms(a)` = members of `concept(a)` minus `a`; `translations(a, fr)` =
members of `concept(a)` filtered by inherited language (interval-friendly).
Asserted-but-not-equivalent claims (near-synonymy, disputed translations)
remain pairwise assertions with evidence; the concept membership carries the
source's confidence as a column.

This is the OntoLex `LexicalConcept`/`ontolex:isLexicalizedSenseOf` shape and
the WordNet synset shape, and TEI has no equivalent. It is also the single
largest byte saving in a multilingual graph.

### 6.2 Relations declare their algebra

Asymmetric relations (`hypernym`/`hyponym`, `holonym`/`meronym`,
`derived_from`, `etymon_of`, `entails`, `see_also`, `variant_of`) stay
adjacency, with v3's declared `symmetric`, `inverse`, and `transitive` so that
inverse pairs share one adjacency and symmetric relations are stored once.
Domain and range are kind sets checked at compile and at build.

### 6.3 Typed values

Language tags, features, dates, notation, certainty, and state are packed
structs interned into small sorted tables (v3 §12.3), and their columns go
through the cascade including `entropy`. Feature bundles use the Universal
Dependencies inventory with an extension escape; part-of-speech uses the 17
UD tags plus extension.

### 6.4 Word parts and analyses

`form` owns ordered `part` nodes with `role`, optional `span` into the owning
surface, optional `realizes` link to a lexeme, and nested parts; competing
analyses are sibling `analysis` nodes. Morphological search ("all forms with
suffix *-ung*") is the reversed-axis automaton over `written`, and "all forms
whose part realises lexeme *L*" is the `realizes` reverse adjacency: both
without touching prose.

### 6.5 Provenance stays first-class

Every assertion node lives under the root that asserts it; evidence is child
nodes; certainty and temporal are typed columns; sources are nodes. Shadow
edges keep traversal uniform. Nothing here changes from LEX2 except that the
byte cost of the columns drops to their entropy.

---

## 7. Full-text and the other cold indexes

Term postings are containers over entry ordinals (v3 §7: run list, bitmap,
Elias–Fano by density) in a bzip3 cold section decoded once. The term
dictionary is itself an automaton with explicit outputs (container offsets),
so `terms` shares the key-index code. External IDs and shape names are
automata too. Every index in the file is therefore one of two things: an
automaton or a bitvector.

---

## 8. Container, open, verify

Unchanged from v3 §8–9: digest-only schema, no empty sections, 8-byte
alignment for small sections, envelope-only open with per-64 KB page digests
verified on first touch, and a full `verify` tier. The automaton, the rANS
checkpoints, and the grammar rule table are all directly addressable in the
mapped bytes; open touches the header, the directory, and the section headers.

---

## 9. Projected ledger and latency

Flat fixture, balanced preset, with the full-text index (which no external
baseline carries):

| Part | LEX2 | LEX4 |
|---|---:|---:|
| primary key automaton (headwords + identical forms) | 19,183 + 2,816 | ≈ 3,500 |
| reversed axis automaton with explicit output deltas | 38,185 + 5,632 | ≈ 4,500 |
| normalized overlay | 19,183 | 64 |
| homograph multiplicity | — | 256 |
| forest: skeleton table + rANS sequence + checkpoints | 20,648 | ≈ 150 |
| kind-rank directory | (in forest) | ≈ 600 |
| columns (all identity / constant after cascade) | 20,572 | ≈ 200 |
| prose: grammar rules + item boundary bitvector + bzip3 symbol blocks | 19,954 | ≈ 3,800 |
| terms (containers, cold bzip3) | 93,026 | ≈ 2,500 |
| edges | 3,070 | 0 |
| header, directory, digests, page tables | 4,163 | ≈ 450 |
| **total** | **237,984** | **≈ 16,000** |

Against slob/lzma2 at 74,476, SQLite whole-file zstd at 24,732, v1/bzip3 at
130,920. The latency preset (directly addressable symbols) is projected at
≈ 32 KB with ≈ 2 µs renders; slob renders in 44 µs at 74 KB.

The same arithmetic on the other fixtures: `repeated` ≈ 12 KB (four template
rules), `prose_heavy` ≈ 20 KB balanced (the 32× repeated sentence is one rule
applied 32 times; the item is 33 symbols), `pathological_prefix` ≈ 17 KB
(the automaton collapses the shared 27-byte prefix to one path).

The ratios are fixture artefacts; the structural claim that transfers is
**≈ 4–6 bytes of non-prose structure per entry** (automaton ≈ 3, axes ≈ 1.5,
everything else < 1) against LEX2's 110 and slob's roughly 12–20, and the
codec claim is grammar + bzip3 residual on real English prose at ≈ 20–25 %
against lzma2's ≈ 22–28 %, which must be measured.

| Operation | LEX2 (flat) | LEX4 projected | Mechanism |
|---|---:|---:|---|
| exact hit | 0.46 µs | ≈ 0.15 µs | automaton walk, 14 arcs, no decode |
| exact miss | 0.25 µs | ≈ 0.1 µs | walk fails early |
| prefix, one / many / pathological | 0.62 / 59.9 / 58.8 µs | ≈ 0.2 µs each | interval from the prefix state |
| suffix, fuzzy(1), regex | – | ≈ 0.3 µs / tens of µs / bounded | axis automaton, product walks |
| render, latency preset | 685 µs | ≈ 2 µs | grammar expansion, no block |
| render, balanced preset, cold / warm | 2,231 µs / – | ≈ 300 µs / ≈ 2 µs | one symbol-block decode, then expansion |
| senses of a prefix → definitions | list building | interval arithmetic, O(1) | §3 |
| translations of a sense | adjacency walk | concept membership select | §6.1 |
| open | 38,567 µs | < 100 µs | envelope-only |

---

## 10. Zig realisation

**Types.** `Rank(kind)` is `enum(u32) { none = maxInt, _ }` per kind,
generated by `fn Rank(comptime kind: Kind) type`; `Node` (preorder) and
`Rank(.entry)` are distinct types with explicit conversions through the
forest. `NodeSet(kind)` is the tagged union of §3; `Set(kind)` is v3's typed
pipeline over it with `interval`-preserving operators marked at comptime so
the planner knows which operators allocate.

**Automaton.** A `packed struct(u64)` arc: `label: u8, flags: u4, count_delta:
u20, target_delta: u32`; states are arc runs; `@Vector(16, u8)` label
comparison per state; `count` per state in a parallel FOR column. Builder:
sorted-input incremental minimisation (the Daciuk et al. algorithm) with a
`std.HashMapUnmanaged` of state signatures during build only; the reader has
no hash tables.

**Grammar.** Each rule's `left`, `right`, and `expansion_length` fields share a
bit-packed rule lane at the minimum widths declared by the authenticated
section header; the symbol stream and cumulative item ends are bit-packed too.
Expansion uses an explicit caller-provided frame stack and output/step budgets,
so a malicious grammar cannot expand past the caller's storage or work limit
(the decompression-bomb guard the plan requires). The source type—not a
snapshot-specific bit width—is known at comptime, allowing authenticated and
raw-slice readers to share statically dispatched control flow.

**rANS.** State `u32`, frequency table `std.BoundedArray(u16, 4096)`, checkpoint
records through `wire.Layout`; encode at build in reverse, decode forward;
`checkAllAllocationFailures` on the builder, `std.testing.fuzz` on the decoder
against arbitrary checkpoint tables.

**Bitvectors.** One `Bitvector(comptime density: enum { dense, sparse, very_sparse })`
generating the three representations with a common `rank1/select1/get` API;
in-block rank via `@popCount(@Vector(8, u64))`.

**Schema.** `kind_specs` as `std.enums.EnumArray(Kind, KindSpec)` with layer
membership; relation specs with algebra; concept membership declared as a
`membership` column kind so the compiler emits both directions; `KindSet` on
`std.bit_set.IntegerBitSet`.

**No I/O, no threads in the reader.** Hosts map bytes; batch encode uses
`std.Thread.Pool` only in the compiler.

Line budget: automaton ≈ 450, grammar ≈ 300, rANS ≈ 120, bitvector ≈ 250,
interval algebra ≈ 200 (replacing list-only operators), concept layer ≈ 150.
Removed: front-coded key spaces (459), FOR/EF/presence trio (≈ 300), block
root tables and in-block item records (≈ 120), pairwise reverse copies for
symmetric relations. Net roughly +900 lines over LEX2.

---

## 11. Delivery and gates

| Step | Change | Gate on `bench2` (same digests, same workload) |
|---|---|---|
| A | key-ordered compile; automaton primary index with rank outputs; interval `NodeSet`; identity/constant cascade; skeleton forest | exact ≤ LEX2; prefix-many ≤ 2 µs; flat ≤ 40 KB |
| B | grammar prose with latency/balanced/compact residual policies; aliasing; snippets | latency-preset render ≤ 10 µs; balanced ≤ slob bytes on every fixture |
| C | axis automata (reversed, normalized overlay, phonetic); term containers; cold bzip3 sections | suffix ≤ 1 µs; flat ≤ 20 KB with terms |
| D | rANS skeletons and columns; page-digest open | open ≤ 100 µs; no size regression versus C |
| E | concept layer, relation algebra, typed values, typed pipeline | rich fixture graph queries equal the reference evaluator; translation cluster bytes ≤ 1/k of pairwise |
| F | real-corpus run (TEI Wiktionary subset, a bilingual dictionary, WordNet) | total ≤ slob/lzma2 of the same projection; structure ≤ 8 B/entry; exact ≤ 0.5 µs; latency render ≤ 20 µs |

Ablations: automaton vs front-coding; explicit-output deltas vs permutation;
grammar vs primer-boosted blocks (v3 §6.4); rANS vs FOR per column; concept
memberships vs pairwise edges; interval planner on/off. Each is a compiler
flag and a report row.

---

## 12. What could invalidate it

- **Re-Pair on real prose may not beat lzma2 after bzip3 residual coding.** Then the balanced preset reverts to v3's blocks over raw text and the grammar remains the latency preset's mechanism; the size gate is decided by the residual codec, not by the grammar.
- **Automaton size on very long or unstructured keys** (multi-word phrases, transliterations) may approach front-coding; the ablation decides per snapshot and the section header records which index the reader gets.
- **rANS checkpoints** cost 10 bytes per 64 rows; columns with entropy close to their width are left packed by the cascade automatically.
- **Concept nodes require alignment decisions at import.** Unaligned senses stay unaligned; the model never invents equivalence. Import profiles say when a source's synonym group becomes a concept.
- **Build cost** rises: Re-Pair and minimisation are offline algorithms with memory proportional to the corpus. That is the compiler's budget, reported separately, and it is the correct place to spend it.
