# LEX4: the next architectural experiments

8 September 2026. These are **unimplemented hypotheses**, not claims about
the current format. The completed rewrite and measured limits are in
[lex4-unification.md](lex4-unification.md).

The next step should remove a class of representations or serial work, not
give every section one more bespoke compression strategy. Three experiments
seem large enough to change the architecture while remaining falsifiable.

## 1. Measured programs: one algebra, specialized execution

The grammar answers “how many bytes does this production emit?” The forest
answers “how many nodes of kind K precede this boundary?” The automaton
answers “how many accepted entries precede this branch?” Each navigates a
compressed structure using an additive measure. For concatenated sequences,

```
measure(x ++ y) = measure(x) + measure(y)
```

For an ordered automaton, disjoint outgoing language branches also contribute
additively to accepted-count rank. This is the shared law; it does **not**
mean a grammar production and a language state are interchangeable objects.

The proposal is a compile-time *measure basis*, not a runtime universal graph
interpreter. A typed program declares which measures its operations require.
Its producer proves which coordinates follow from other coordinates and
which independent counters must be serialized. Its reader instantiates the
existing specialized navigation loop with generated measure accessors.

For example, every repetition of a fixed entry/sense/definition skeleton
adds the same vector. Storing every component at every checkpoint is storing
a consequence. Today's constant-forest rewrite already removes that case.
The experiment asks whether a small verified basis can eliminate the same
redundancy across mixed templates and grammar productions without introducing
per-query matrix decoding or a larger descriptor than the counters it saves.

The first prototype should share prefix-measure and inverse-selection laws
between forest and grammar, keeping their wire encodings and hot loops
distinct. Only attempt the automaton after those two consumers expose a
genuine common interface. This ordering tests the abstraction before changing
three independent security boundaries at once.

Acceptance evidence:

- Same irregular mixed-tree and nonrepeated prose inputs, independently
  decoded outputs, and complete files including basis descriptors.
- Explicit independent counters before/after, not just compressed payloads.
- Random boundary/inverse identities; malformed and overflowing measures must
  fail before they can authorize a skip or select an incorrect subtree.
- Dependent rank/select/snippet latency and full-verification work, including
  any basis reconstruction. Reject if saved bytes become a serial decoder on
  every navigation step or require a hidden expanded counter array.

An exact compiler proof or checked wire invariant can authorize derivation;
correlation observed in the input cannot by itself authorize a trusted read.

## 2. Rank-space relational compilation

Current structural queries already carry exact scope, not an enclosing rank
interval. Concept membership is another ordered rank stream. Assertions,
language filters, terms, and derived axes still meet at separate interfaces.

The larger proposal is to describe a query as transformations between typed
rank spaces and compile it to the cheapest supported traversal. A functional
assignment and its inverse are two projections of one fact owner. A qualified
or multivalued assertion is a different relation; the compiler must preserve
that distinction rather than pretending everything is functional.

Consider “definitions belonging to selected senses, translated to language L,
with a claim supported by source S.” A useful compiled plan would preserve
the selected subtree scope, intersect ordered candidate streams before
rendering, and read qualifiers only for surviving assertions. It would not
materialize every join as an array or infer an assertion from membership.

The first experiment should expose typed plan operations over the existing
concept and assertion readers, with explicit ordering, uniqueness, scope,
and cardinality traits. Compile-time facts can erase redundant navigation;
data-dependent cardinality still needs validated runtime evidence. A planner
must not guess that the benchmark's one-sense-per-entry projection describes
all TEI dictionaries.

Acceptance evidence:

- Differential evaluation against a deliberately simple materializing oracle
  on irregular trees, overlapping selections, empty/multivalued memberships,
  conflicting claims, provenance, and zero/negative/sparse application IDs.
- A retained unfused plan on exactly the same file, so fusion has a real
  on/off ablation and does not silently change the query's meaning.
- Source-read traces, touched authentication pages, explicit scratch bytes,
  time to first result, and total enumeration time at varying selectivities.
- Reject traits that exist only to route a growing switch of specialized
  cases. The useful abstraction is a law about a rank stream that several
  producers satisfy, not a new name for each producer.

This would generalize the completed typed descendant plans. It would not
require forcing metadata difference dictionaries into the affine table before
their prefix-sum/random-access tradeoff has been measured.

## 3. Rendering as a bounded copy program

The current renderer is already a continuation machine: sequence state stays
outside the stack; a frame stores only a pending right sibling. The next
question is whether common terminal runs can become checked copy operations
instead of repeated literal emission, without adding a decoded-rule cache.

A prototype could lower a grammar production to a small straight-line program
of literal runs and rule calls. Expansion measures determine output ranges;
independent source/destination calculations might then overlap. The same
program must support a bounded snippet without expanding the entire item.

The difficult part is the byte ledger. Materializing the bytes of every rule
can destroy the very sharing that makes the grammar small. A copy-program
directory can also be more expensive than a packed pair. Try direct execution
of serialized runs first, charge every opcode and directory byte, and keep
the existing packed-pair reader as the exact same-input control. “Cacheless”
is not a win if the cache was merely baked into the file unaccounted.

Acceptance evidence:

- Full-file sizes, compiler time/memory, open and verification work; full
  render, tiny snippet, and late-output snippet at several item lengths.
- Both alias-heavy and alias-free irregular prose; identical decoded bytes
  and traceable authentication of every touched input range.
- Exact-size output buffers, caller stack exhaustion, expansion bombs, cyclic
  or invalid calls, and guard-page checks on short literal-run tails.
- Reject whole-item pre-expansion before a snippet, uncharged startup work,
  and fixture-specific rule choices. If no complete-byte/latency tradeoff
  improves, retain the current four-byte continuation machine.

## The experiment discipline I would keep

Real irregular TEI-derived corpora are the first missing input. Their source
identity, mixed content, multiple senses, qualifiers, and provenance need an
independent round-trip oracle. Publicly redistributable inputs and the exact
projection should accompany any result; generated fixtures stay useful for
hostile edge cases, not as proof of a global compression frontier.

Keep dependency latency separate from throughput. The current four-stream
lookup probe visits only 7–16 distinct keys per lane and did not establish an
instruction-parallelism breakthrough. A next multikey experiment needs broad,
measured key coverage, independent states, misses as well as hits, and a
single shared elapsed-time denominator. It should identify the automaton's
actual load dependency chain before adding vectorization or prefetching.

Finally, retain failed variants, exact compiler modes, original executables,
all structural metadata, verification costs, and resident memory. The earlier
Debug/ReleaseFast flag mistake is precisely why the next experiment must
start from a tested compilation contract rather than trusting a command's
appearance. Elegant reasoning is a hypothesis until the actual reader,
complete file, and independent oracle agree.
