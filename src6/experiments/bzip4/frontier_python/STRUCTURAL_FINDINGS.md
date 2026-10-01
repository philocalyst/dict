# Findings that change the model, not just the tuning

This is a research ledger, not an integration recommendation. The final
replacement gate still requires complete bytes and comparable native decoding
measurements on every required corpus and boundary.

## Grammar reuse is stored fan-in, not execution count

If rule `B` occurs once in the stored definition of `A`, repeating `A` a
thousand times does not create a second stored reference to `B`. Inlining `B`
into `A` preserves the shared expansion while eliminating a definition and ID.
The first builder incorrectly propagated dynamic execution multiplicity when
deciding utility. A reachability pass followed by stored-reference counting
removes such single-owner definitions naturally.

The initial FreeDict screen retained 2,404 rules; the corrected screen builder
retains 1,976. The independent `lead_review/dag_utility_probe.py` finds no
remaining stored-once definitions on any of the three screens. Exact final
wire improvements must be measured separately because probability metadata
was also being simplified during this revision.

This is the same useful distinction as ownership versus use: one owner can
execute an object many times without needing another layer of indirection.

## A definition is not necessarily an encodable symbol

A rule can exist solely because another rule references it. Such an internal
DAG node need not have an entropy code in the root stream. The initial frozen
grammar tokenizer inserted every rule into its match trie and could therefore
emit an internal node with no Huffman code. The preserved training-screen
failure was `symbol 820 has no Huffman code`.

The correct interface separates definition IDs from codeable stream symbols.
Only codeable symbols may be trie terminals; arbitrary bytes retain literal
fallback. A later Zig design should make this distinction explicit through
different ID types or construction APIs, so an internal node cannot silently
become a stream event.

## Store the decoder's sufficient state

Canonical Huffman decoding needs code lengths, not the original frequency
counts as well. Frequencies belong to encoder discovery and diagnostics. The
initial grammar wire redundantly stored symbol IDs, counts and lengths. The
revised wire stores only the code lengths needed to reconstruct the codebook.
Similarly, an alphabet mask already proves which MTF ranks are impossible;
conditioning on that information must not require a second stored selector.

Neither change makes preparation free. The frame must still charge its model,
directories, checksums and padding, and measurements must include codebook or
conditioned-table construction before a first query.

## A measurement can hide a model mistake

An early final-harness draft prepared the candidate before starting its model
preparation timer, then timed only assigning the prepared object. That would
have made an expensive startup look almost free. It was rejected in review.
Final captures must time a fresh preparation from the saved frame, separately
from retained decode trials, and keep process-wide RSS distinct from decoder
scratch because corpus loading and encoder work also contribute to RSS.

The source of these findings is direct code review and reproducible local
probes, not a claim that these established grammar or entropy principles are
new compression algorithms.

## Consistency matters more than one locally popular pair

An arbitrary batch of frequent pairs can contain both `AB` and `BC`. A
left-to-right replacement then changes how the same fragment is parsed based
on a preceding neighbor. That weakens the repeated structure available to
later grammar levels and to a block-sorting transform. The selected pair
family now forbids any symbol from being both a left and a right member in
the same round. This is a structural invariant, not a corpus-specific switch.

With the same 8,192-rule / 24-pass budget, the complete 8 MiB frames at 16 KiB
boundaries changed as follows (input-fit model fully stored):

| Pair selection | FreeDict | GCIDE | OMW Japanese |
|---|---:|---:|---:|
| Arbitrarily overlapping batches | 925,108 | 2,162,795 | 1,806,370 |
| Non-overlapping pair family | 864,918 | 1,963,188 | 1,365,376 |

Increasing the pass ceiling to 64, with the same bounded model, yielded
849,886 / 1,935,401 / 1,334,367 bytes. Builders naturally stop before the
ceiling. These are complete-wire storage observations, not quiet decode
measurements. The relevant older grammar/BWT work is cited in `RESEARCH.md`;
this program does not claim to have invented consistent pair replacement.

## Transform the shared program, not every expanded byte

A grammar rule represents a short reusable byte string. A stream of rule IDs
can be sorted and entropy-coded before expansion. In the symbol-BWT prototype,
the inverse sorting transform operates on this shorter root stream, and each
restored ID expands through a bounded table. The output still contains every
original byte; the benefit is reducing the number of expensive entropy and
inverse-transform steps per output byte.

The first full FreeDict result has 531,866 root tokens for 8,388,608 raw bytes.
Its complete frame is 814,375 bytes, including 45,666 bytes of model and 18,432
bytes of directory. This is not evidence of universal superiority, and no
Python-to-native speed equivalence is assumed. The final serial matrix must
show where this structural reduction survives on the other corpora.

One nuance is explicit: the prototype learns a consistent-pair vocabulary,
then retokenizes by longest matching stored expansion. It does not preserve
the builder's exact replacement parse. Comparing those two encoder parses is
a clean future causal experiment with an unchanged decoder, not a hidden
implementation equivalence.
