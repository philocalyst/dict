# Native lexical and word-part views

`src/lexical.zig` is a query-time view over `semantic.Model`. It does not add
another lexical graph, copy strings, or assign a hidden meaning to an
assertion. The caller supplies the predicate entity and participant roles for
each relation. This is necessary because a TEI import profile, an OntoLex
profile, and a local resource can use different predicates for ownership,
form, sense, decomposition, or surface realization.

The view keeps three identities separate:

* a value is a `semantic.ValueId` and remains in the model's interned value
  table;
* an entity is a lexical/form/sense/part occurrence identified by
  `semantic.EntityId`;
* an assertion is an occurrence of a relation identified by
  `semantic.AssertionId`.

Equal strings may share a `ValueId`, while equal-looking forms from two
sources keep their entity and assertion identities. Every returned edge carries
its assertion ID, participant positions, entity source scope, and assertion
source scope. No inverse translation, transitive relation, language fallback,
or source inheritance is performed.

## Relation shapes

```zig
const ownership = lexical.RelationSpec{
    .predicate = has_form_predicate,
    .source_role = "owner",
    .target_role = "form",
    .target_cardinality = .one,
};
var forms = try evaluator.formsOf(lexeme_id, ownership);
defer forms.deinit();
```

`related` returns entity-valued edges for any caller-defined relation. `formsOf`
and `sensesOf` add a kind check (`.form` and `.sense`) while retaining the same
assertion occurrence. A source role must occur exactly once. A target role is
either exactly one participant or one-or-more participants. For a multi-target
assertion, `order` is the ordinal among target-role participants and
`target_participant` is the original participant index, so interleaved
qualifiers do not destroy source order.

Invalid IDs, malformed selected assertions, duplicate source roles, wrong
target kinds, and over-budget scans return errors. Results are never silently
truncated. The scan and result limits are part of `lexical.Options` and are
checked before allocation or traversal.

## Surfaces and spans

Surface realization is an explicit entity-to-value relation:

```zig
const surface = lexical.SurfaceSpec{
    .relation = .{
        .predicate = has_surface_predicate,
        .source_role = "form",
        .target_role = "surface",
        .target_cardinality = .one,
    },
    .require_anchor = true,
};
var occurrences = try evaluator.surfacesOf(form_id, surface);
defer occurrences.deinit();
```

Every result contains the explicit `ValueId`; the view never flattens the
value into a new string. If the assertion has several retained
`AssertionAnchor`s, each is returned. That is how a discontinuous segment is
represented: one surface value plus multiple anchored occurrences. Separate
parts can point at overlapping spans, and those spans remain separate
occurrences.

The span unit is always carried by `semantic.SourceSpan`:

* byte spans are bounded by the UTF-8 value and must begin/end at UTF-8 scalar
  boundaries;
* UTF-8 codepoint spans count decoded scalar values;
* UTF-16 spans count code units and cannot split a surrogate pair;
* grapheme spans are rejected unless the caller explicitly sets
  `allow_unvalidated_grapheme`. The core does not pretend that one scalar is
  one grapheme; combining marks, Indic clusters, emoji sequences, and
  language-specific segmentation require a pinned Unicode/profile component.

Anchors preserve their source and document IDs. The source of an assertion and
the source of an anchor are both retained; neither is guessed from the other.
`require_anchor` means each matching surface assertion must have at least one
anchor. A part with no surface assertion is valid and yields zero surface
occurrences, which preserves zero morphs and incomplete analyses without
inventing text.

## Recursive decomposition

`decompose` walks a caller-supplied ordered relation and returns a flat bounded
tree of `WordPartView` records. Each child occurrence records its parent
occurrence, depth, decomposition assertion, target participant, target ordinal,
and source scope. Two decomposition assertions for the same parent are
alternative analyses; they are both returned. The same entity may occur more
than once in one analysis, and no global visited set collapses it. This retains
parallel, overlapping, and repeated parts.

Surfaces are a second flat array keyed by the part occurrence. The
`surfacesFor` helper gives the contiguous range for one part. This avoids a
per-part allocation while preserving multiple anchors and source occurrence
identity. A cycle edge is retained with `cycle = true` and is not expanded;
finite input cannot turn into an unbounded traversal. `max_depth`, `max_nodes`,
`max_scan_items`, `max_results`, `max_result_bytes`, and
`max_surface_occurrences` bound work and output.

The representation covers the descriptive part of OntoLex-Morph: roots,
stems, affixes, zero morphs, ordered constituents, alternatives and
grammatical assertions already represented by the semantic graph. It does not
silently invent a generative rule, allomorph, morpheme identity, language
analysis, or concatenated spelling. A rule or grammatical meaning can be
exposed by a separate caller-defined assertion view when it exists in the
model.

## Adversarial coverage

The tests in `lexical.zig` exercise:

* source-distinct form/sense ownership and parallel assertion identity;
* Arabic text with alternatives, an unordered zero-surface part, overlapping
  and discontinuous anchors;
* combining-mark text with scalar validation and explicit rejection of guessed
  grapheme boundaries;
* malformed byte spans, invalid IDs, and scan budgets.

The same APIs are script-neutral: Japanese text, German compounds, Hebrew
non-concatenative analyses, and any other language remain values/entities with
explicit profiles and assertions. A language pack may add a grapheme segmenter
or analyzer later, but this view does not claim that a tokenizer or one
concatenation rule supports every language.

## Standards grounding

The shape follows the distinctions made by the primary references:

* [TEI P5 `gramGrp`](https://tei-c.org/release/doc/tei-p5-doc/en/html/ref-gramGrp.html)
  allows grammatical information to be grouped, repeated, and nested, while
  its meaning depends on whether it is attached to an entry, sense, or form.
* [TEI P5 dictionary guidance](https://tei-c.org/release/doc/tei-p5-doc/en/html/DI.html)
  distinguishes headword-level grammar from grammar applying to a particular
  alternate form.
* [OntoLex-Morph](https://ontolex.github.io/morph/) separates lexical-entry
  and form decomposition, allows roots/stems/affixes/zero morphs, and notes
  that an unordered decomposition can be insufficient when order matters.
  It also permits multiple morphs for a form and separate reified word
  formation relations.

These references motivate the explicit relation schema, ordered participant
indices, occurrence preservation, and the refusal to manufacture a universal
string concatenation model. They do not define this snapshot's predicate IDs
or replace the semantic model's source/provenance contract.
