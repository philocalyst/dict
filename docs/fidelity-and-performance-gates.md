# Fidelity and performance gates

The raw payload codec and raw payload placement are the control configuration.
Snapshot minor 2 also supports independently addressable pinned-upstream-bzip3
blocks, but no compression or latency claim is made until the measurements
below are run. The following gates turn the ambitions in `plan.md` into claims
that can be disproved.

## Fidelity first

The semantic model follows the distinction between source dictionary structure
and lexical analysis used by [OntoLex-Lexicog](https://ontolex.github.io/lexicog/)
and preserves the flexible, mixed-content structures permitted by [TEI
Dictionaries](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html).

It has six separate concepts: immutable typed values; identity-bearing
entities; identity-bearing assertions; ordered document nodes; scope/default
contexts; and resolved, unresolved, or ambiguous references. An assertion is a
first-class occurrence with ordered role-labelled participants, attributes,
evidence, state, certainty, and temporal metadata. This is necessary for
n-ary etymologies, evidence-bearing translations, duplicate parallel claims,
and conflicting claims. It follows the rationale of the [W3C n-ary relation
pattern](https://www.w3.org/TR/swbp-n-aryRelations/) and avoids RDF-star's
quoted-triple identity collapse for editorial occurrences; [RDF 1.2
Concepts](https://www.w3.org/TR/rdf12-concepts/) remains a useful interchange
reference.

Acceptance requires semantic round trips that preserve exact source text,
original language-tag spelling, occurrence and assertion multiplicity, child
order, list/set/bag semantics, qualifiers, evidence, unresolved-target bytes,
and status. Derived Unicode keys never replace source values. Unicode
normalization and segmentation must be explicitly profile/versioned under
[UAX #15](https://www.unicode.org/reports/tr15/) and [UAX #29](https://www.unicode.org/reports/tr29/).

## Measured 10x stretch gates

No current result satisfies these gates. A future claim of an order-of-magnitude
improvement needs the same semantic corpus, profile, process/cache regime, RAM
ceiling, and artifact accounting for both systems.

- Exact/prefix ID-only throughput: at least 10x geometric-mean speedup against
  the fastest equal-semantics baseline, with no required corpus cell below 5x.
- Index traffic: at least 10x fewer indexed bytes read per returned ID under
  the same instrumented backend.
- Rich relation access: at least 10x lower CPU time or bytes read than an
  equal-semantics explicit-column baseline for the same assertion/evidence
  query.
- Rich compactness: at least 10x smaller than a pointer-heavy semantic
  reference. Flat legacy artifacts are a separate comparison, never folded
  into this result.
- Payload materialization: no universal 10x target; returned bytes are a lower
  bound. The gate is equal-or-better cold p99 plus reported decode
  amplification.

Every trial must report final artifact bytes including headers, directories,
indexes, alignment, codec state, checksums, and sidecars; p50/p95/p99 latency;
bytes read and decoded; block/codec calls; peak memory; build time and temporary
space; a canonical semantic-output digest; exact revisions; and corpus/profile
digests. Independent bzip3, zstd, lz4, raw, and dictzip controls must include
their independent-frame and directory overhead. The seekable-frame tradeoff is
documented by the [Zstandard seekable format](https://github.com/facebook/zstd/blob/dev/contrib/seekable_format/README.md);
bzip3 limits and scratch requirements come from the [upstream API](https://raw.githubusercontent.com/iczelia/bzip3/master/include/libbz3.h).

Results are rejected when one side drops provenance, document order, unknown
extensions, assertion identity, or unresolved references; when cache states or
memory ceilings differ; when index metadata is omitted; or when a different
profile supplies size and latency figures.
