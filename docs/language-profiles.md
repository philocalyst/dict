# Language tags and text profiles

`src/language.zig` is the small, borrowed view used when a caller wants
validated language metadata around the existing `semantic.Text` value.  It is
deliberately opt in: `semantic.Text` still stores the exact source bytes in its
`language`, `script`, and `notation` fields, so an importer can preserve an
invalid or not-yet-understood source value and report validation separately.
The module never allocates, copies, mutates, or normalizes those bytes.

## What is validated

`LanguageTag.parse` implements the RFC 5646 ABNF well-formedness grammar:

- 2–3, 4, or 5–8 letter primary language subtags, including up to three
  structurally valid 3-letter extlang subtags;
- optional four-letter script and two-letter or three-digit region in their
  position-sensitive slots;
- 5–8 character variants, or four-character digit-leading variants;
- extensions introduced by a unique alphanumeric singleton other than `x`,
  with at least one 2–8 character extension subtag;
- a final private-use sequence introduced by `x`, including tags consisting
  solely of private use;
- the fixed RFC 5646 irregular and regular grandfathered tag list; and
- duplicate variant and extension-singleton rejection, as required for a
  valid BCP 47 tag.

The parser recognizes the structure from ASCII shape and position.  It does
not claim that `zzzz`, `Qaaa`, `QQ`, or `zzzzz` are assigned values.  That
requires a dated IANA Language Subtag Registry snapshot and, for an extension,
the extension's own rules.  There is intentionally no hidden registry,
preferred-value mapping, locale, or host-platform dependency here.  The
module also does not implement Unicode normalization, collation,
transliteration, tokenization, or morphology.

Input and range strings are capped at 4096 bytes.  This is an explicit parser
resource limit for hostile input, not a BCP 47 grammar limit.  A builder that
needs longer source metadata must choose an outer archival policy or raise this
bound deliberately; it must not silently truncate.  The parser uses bounded
iteration and no recursion.  Duplicate variants are checked by a source scan,
which keeps the common representation tiny and allocation free under that
bound.

## Provenance and compact comparison

`LanguageTag.original` and `source()` borrow the supplied bytes byte-for-byte,
including case.  BCP 47 case has no semantic meaning, so
`comparisonKey().eql(...)` and `comparisonKey().hash()` use locale-neutral ASCII
folding only.  `writeComparisonKey(out)` writes the same lower-case key into a
caller-owned buffer.  The key preserves subtag order and spelling content
apart from ASCII case; it does not apply registry preferred values, remove
redundant subtags, reorder extensions, or perform Unicode normalization.

This distinction is important for exact lexical data:

```zig
const raw = try language.LanguageTag.parse("MN-cYRL-mn");
try std.testing.expectEqualStrings("MN-cYRL-mn", raw.source());

var key_storage: [32]u8 = undefined;
const key = try raw.writeComparisonKey(&key_storage);
// key is "mn-cyrl-mn"; raw.source() remains the original bytes.
```

`language()`, `script()`, and `region()` expose borrowed subtag slices.  The
script result is a typed four-letter `Script`, while its supplied case remains
available in `Script.original`.  A script-shaped value is not treated as an
ISO 15924 assignment unless a separate registry-aware layer verifies it.

## Direction, notation, and analysis are separate

`TextProfile` keeps these dimensions independent:

```zig
const profile = try language.TextProfile.fromText(text, .rtl, .{
    .kind = .morphology,
    .name = "my-analysis-pack",
    .version = 3,
    .digest = 0x1234,
});
```

The current `semantic.Text` can therefore remain compact and source-oriented,
while a caller that needs typed query behavior can derive a profile.  The
profile carries a typed `Direction` (`unspecified`, `ltr`, or `rtl`) and an
opaque, source-preserving `Notation`; notation names such as `ipa`,
`orthographic`, or a project-defined identifier are not conflated.  Direction
is never guessed from script or language.  An analysis identity's version and
digest identify external behavior; the presence of `.morphology` does not
pretend that morphology is implemented by this core module.

Use `TextProfile.init` when the source fields are already available, or
`TextProfile.fromText` with the current `semantic.Text`.  Both reject invalid
typed metadata without modifying the original model.  `TextProfile` stores
borrowed views, so its lifetime cannot exceed the source text and any supplied
analysis/name/notation bytes.

## RFC 4647 matching

`LanguageTag.matchesBasic` implements basic filtering: a range matches an
exact tag or a tag prefix ending at a hyphen, and `*` matches every tag.
`matchesExtended` implements extended filtering, including wildcard subtags
and the singleton stop rule.  `filterBasic` and `filterExtended` write matching
input indexes into caller-owned output storage.  These operations compare
ASCII subtags case-insensitively and do not infer language relatedness,
macrolanguage membership, script similarity, or dialect fallback.

Examples covered by tests include `zh-Hant-TW`, `sr-Latn`, Arabic with a
separate `Arab` script and `rtl` direction, private-use tags, grandfathered
`i-klingon`, extension ordering, repeated variants, repeated extension
singletons, missing extension payloads, malformed separators, non-ASCII input,
and long hostile input.  The tests run in both Debug and ReleaseSafe with the
pinned Zig toolchain.

## Standards boundary

The syntax and matching rules follow:

- [RFC 5646, Tags for Identifying Languages](https://www.rfc-editor.org/rfc/rfc5646.html), especially Sections 2.1, 2.1.1, and 2.2.9;
- [RFC 4647, Matching of Language Tags](https://www.rfc-editor.org/rfc/rfc4647.html), especially Sections 3.3.1 and 3.3.2; and
- [Unicode UTS #35, Unicode Locale Data Markup Language](https://www.unicode.org/reports/tr35/) for the boundary between language identifiers and locale/analysis data.

Registry validation and canonicalization should be a versioned importer or
analysis pack.  Such a layer must retain both the supplied `LanguageTag.source()`
and its registry-versioned preferred-value result, because canonicalizing only
the range or only the tag can change RFC 4647 selection behavior.  Unicode
normalization and grapheme behavior belong in a separately identified Unicode
data profile, never in this ASCII syntax key.

