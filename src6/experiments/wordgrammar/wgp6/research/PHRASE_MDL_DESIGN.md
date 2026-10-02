# Research phrase-MDL tiler

[`phrase_mdl.hpp`](phrase_mdl.hpp) is a standalone C++17 utility for a native
prepare stage. Its public entry point is
`wgp6_research::add_mdl_phrases(stream, grammar, options)`. It appends phrase
definitions to the supplied grammar and rewrites the stream in place. Token
IDs are opaque `uint32_t` values; IDs at or above `fence_min` are copied
through and stop every candidate span. Ordinary IDs must index the supplied
grammar. New phrases are assigned deterministic appended IDs in lexicographic
token-sequence order and contain only references to the input stream's
existing IDs.

The proposal pass uses suffix-array doubling and Kasai LCP. Every fence is
mapped to a distinct suffix symbol, which prevents a common prefix from
crossing a fence even when the same fence ID repeats. LCP intervals yield
maximal repeated spans, capped at 48 tokens and four or more suffixes. A
bounded heap keeps at most eight times the requested candidate cap before
exact deduplication; final candidates are capped at 32,000 and chosen with a
fixed gross-span upper-bound ordering. That cap controls search size only;
frequency alone never activates a phrase.

The tiler builds an Aho-Corasick matcher for candidate occurrences, then runs
a left-to-right minimum-cost DP. Literal edges use ideal symbol costs from
the current empirical row. Phrase edges use the estimated phrase-symbol cost
plus the full ULEB activation cost—new ID, arity, and every child reference—
amortized across the current support estimate. After each pass it serializes
an ideal order-0 MDL objective: enumerative data cost, a universal count-vector
cost, stream/rule-count headers, and all selected phrase definitions. It
prunes phrases unused by the global tiling, updates the empirical row, and
reparses for two to four rounds. It commits only the best round whose full
ideal MDL cost improves on the unparsed stream. The MDL objective is a parse
selection diagnostic, not the native codec's byte count; the parent pipeline
must still run `plan.fit`/encode and decode.

The utility preserves fences and expands exactly to the original stream in
the smoke fixture. It does not change a decoder or the frozen codec.

Validation command:

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic phrase_mdl_smoke.cpp -o phrase_mdl_smoke
./phrase_mdl_smoke
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic phrase_mdl_property.cpp -o phrase_mdl_property
./phrase_mdl_property
```

The fixture repeated a four-ID phrase across a repeated fence, produced one
definition over three MDL rounds, reduced the diagnostic stream from 161 to 9
symbols, and expanded token-for-token to its original IDs.
The property fixture passed 120 deterministic cases varying phrase shape,
fences, thresholds, candidate caps, and round counts.
