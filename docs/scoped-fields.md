# Scoped fields

`src/scopes.zig` is a schema-driven view over `semantic.Model` assertions. It
provides compact inherited defaults for language, script, orthography,
grammar, usage, and similar fields without making an attribute copy or a
second parent graph. A schema names the parent predicate, participant roles,
field predicates, value roles, scope kinds, cardinality, ordering, and
inheritance. Nothing is inferred from predicate names, participant positions,
entity kinds, or generic attributes.

The storage unit remains the existing n-ary assertion:

```
parent(child = sense-7, parent = entry-2)
field(owner = lexicon-0, value = ValueId(fr))
field(owner = entry-2, value = ValueId(en))   // one exception
```

The repeated default is one `ValueId`; an exception is one assertion that
points at a different, already interned value. There is no shadow graph, no
expanded per-sense row, and no copied text. `ResolvedValue` is three dense
IDs: the origin scope, assertion identity, and value identity. The value still
has the full semantic tag, including text language/script/notation, bytes,
sequences, uncertainty, `unknown`, and explicit `absent`.

## Resolution contract

Create a `View` with a caller-owned `Schema` and a caller-selected allocator
and `Limits`:

```zig
const fields = [_]scopes.FieldSchema{
    .{
        .predicate = language_predicate,
        .owner_role = "owner",
        .value_role = "value",
        .inheritance = .nearest,
        .cardinality = .one,
        .ordering = .ordered,
        .value_kind = .text,
    },
};
const view = try scopes.View.init(&model, .{
    .scope_kinds = &.{ .lexicon, .entry, .scope, .sense },
    .parent = .{
        .predicate = parent_predicate,
        .child_role = "child",
        .parent_role = "parent",
    },
    .fields = &fields,
    .source_boundary = .same_known,
}, allocator, .{});
const maybe = try view.lookup(sense, 0);
if (maybe) |*field| {
    defer field.deinit();
    // field.items contains zero-copy IDs into model.
}
```

`lookup` first examines the requested scope. If it has one or more assertions
for the field, that scope wins completely. A field assertion is present even
when its value is `semantic.Value.absent`, `unknown`, or an empty sequence;
those values stop fallback. Only an omitted field continues to the declared
parent, and `.none` never traverses a parent. With `.nearest`, the first
ancestor containing the field wins. A missing field returns `null`.

`cardinality = .many` returns every assertion in model order, preserving
duplicates and parallel evidence. `cardinality = .one` requires exactly one
assertion at the winning scope and returns `Ambiguous` for two rows, even when
their values happen to compare equal. Parent rows are equally strict: two
parents for one child return `ParentAmbiguous`; revisiting a scope returns
`ParentCycle`. This prevents a compiler or reader from silently selecting an
arbitrary language, grammatical feature, or source claim.

`ordering` is a declaration of the consumer contract. The implementation
keeps assertion order for both values of the enum and never sorts or
deduplicates. A producer may use `.unordered` when order has no meaning, while
an ordered lexical field can use `.ordered` and retain source order exactly.

## Validation and limits

`View.init` validates every assertion whose predicate is declared by the
schema before a result can be returned. It rejects missing or duplicate named
roles, wrong target kinds, dangling entity/value IDs, disallowed scope kinds,
wrong value tags, and source-boundary violations. A field owner must be an
entity and a field value must be a `ValueId`; an entity-valued relation belongs
in a separate assertion schema. Extra participants are retained and ignored
by this field view, so qualifiers and evidence stay available through the
underlying model.

The default `.same_known` source policy requires every pair of known source IDs
to agree. A null source means an intentional global scope and is compatible
with a known source, which permits a lexicon default to flow into a source
entry. Set `.allow_cross` only when a profile explicitly defines
cross-document inheritance. Source records are compared by `SourceId`, not by
external ID, so equal external IDs in two documents remain separate.

Validation, parent walks, and field scans consume `max_work_items`. Parent
depth, result count, and the result byte budget are independently bounded.
Allocation failures propagate as `OutOfMemory`; no partial result is returned.
The only allocated result storage is the compact array of triples (and the
bounded temporary parent path), so text bytes and all semantic values remain
zero-copy. A malformed row is rejected before any successful result is
returned.

The view intentionally does not factor assertions, invent parent edges,
expand values, merge language tags, interpret retracted assertions, or claim
that an importer/compiler has chosen these predicates. Those choices belong
to the caller's schema/profile; this API only supplies checked effective
lookup over the authoritative n-ary model.

