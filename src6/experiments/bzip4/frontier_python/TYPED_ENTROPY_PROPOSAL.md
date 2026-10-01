# A separate schema-derived entropy experiment

This proposal is not the byte-codec result. The fair Bzip4 lane must reconstruct
the exact normalized-content bytes given to bzip3, at identical raw restart
boundaries. This proposal instead changes how canonical LEX6 packets are
encoded, and needs its own artifacts and comparison.

## Observation

`packet.encodeValue(T, ...)` already knows which field, union arm and collection
element is being written. A byte-class transform must serialize selectors to
explain where regrouped bytes came from; a schema-specialized decoder can often
derive those contexts from its current type and previously decoded lengths and
tags. This makes the type-directed packet program a possible compression model.

The smallest useful prototype would keep the public lexical model unchanged,
replace packet's byte writer/reader with a bounded symbol sink/source, and use
one regular entropy backend. A context identifies the semantic wire operation
(tag, presence, length, signed magnitude, text byte or text phrase). The compiled
schema supplies operation order. Context clustering is an encoder concern;
every archive-specific probability table and context-to-table mapping is stored.
Enum/union identities and literal values remain exact; there is no vocabulary
normalization or merging of repeated claims.

The encoding program emits events as it traverses the typed value. The decoding
program reconstructs the same typed value into final storage, consuming events
in the same order. A shared phrase vocabulary can serve byte-valued fields,
while primitive tags and lengths use the same entropy interface. The model is
one typed program with one entropy service, not one special codec per field.

## Fidelity and fair comparisons

For values admitted by the canonical packet codec, decoding the candidate and
re-encoding with unchanged packet version 2 should reproduce packet bytes
exactly. This is an explicit test: it follows only if the canonical value codec
has unique spelling and all source strings, float/decimal spelling, tags,
ordering and repeated occurrences are retained. Arbitrary noncanonical packets
must be rejected by the same admission rules, not normalized silently.

This does not imply reproduction of an XML source serialization from its
semantic projection. Verbatim source bytes require their existing Source/Inline
representation or separate source storage, with all bytes charged. Therefore
report the current byte-codec projection, the current canonical packet archive,
and the changed packet representation in separate lanes with matching semantic
workloads.

## Decode, admission and ownership

`decodeInto(T, slot, observer)` can combine event decoding and typed construction.
Only notify the admission observer after a value is structurally complete. The
slot must be final arena or root storage: a temporary return-by-value struct is
not a stable identity owner. Resolve deferred local references and source-anchor
obligations after all identities/source bounds are known. Finish admission
before moving the root, and retain no temporary observer pointer afterward.

The observer supplies the same semantic rules to in-memory admission and
decoded admission. Bounds still cover decoded allocation requests, work,
nesting, symbols, model preparation and pending obligations. Decoder failure
destroys the arena and partial model state. Differential malformed-model and
allocation-failure tests must compare both admission routes.

## Restart cost and selective access

The current archive independently addresses pages and packets. The first
prototype should preserve that boundary and reset entropy state at every page.
An immutable archive-wide model may be shared after explicit preparation. A
page decoder cannot assume schema context at an arbitrary middle-of-packet
byte boundary; either page boundaries align complete packets, or a continuation
record must carry the necessary bounded type/collection state and its full cost.
Large packets and empty pages must have a specified representation.

This alone does not provide field-level lazy queries. Selective text or metadata
decoding would require independently addressable event ranges and explicit
dependencies, with their offsets, restart states and integrity boundaries
charged. Preserve independently owned public results until a lifetime-safe
borrowed representation has separate evidence.

## Acceptance experiment

Build one prototype using the current schema, exact canonical-packet oracle,
three real adapters plus richness fixtures. Charge schema/version metadata,
probability models, vocabulary, model mappings, page/document directories,
continuations, checksums, padding, cold initialization and all resident state.
Measure archive bytes, metadata-ready startup, first page, random page, full
decode, admission, render and snippet. Preserve old artifacts byte-for-byte.

This opportunity is worth considering because it could remove a stored
explanation of structure that the decoder already possesses. Its size and
latency benefits remain unmeasured. It must not replace a failed byte-codec
acceptance result with a different comparison.
