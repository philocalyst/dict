# Deeper structural reform: experiments and acceptance criteria

The frozen WordFrontier comparison is a reference, not the endpoint of this
phase. Its complete size result is 7.01% below whole bzip3 across 22 lanes,
with 13.80% below whole bzip3 for dictionary content. Several prose and
word-list lanes lose. The next phase targets the actual paid representation
and causal event source rather than a smaller uncharged word inventory.

## First-class constructions and direct typed dictionary coding

The additive `lexical_constructions` prototype augments a complete native
Entry with independently qualified construction programs and instances.
Programs have named parameters, exact literals, ordered discontinuous copy
spans, parameter slots, prior-program calls and zero realizations. Instances
retain their independent Analysis reference, bindings, authoritative surface
reference, language/evidence metadata and realization attribution. Arabic
root/pattern copies, Turkish suffix chains, reduplication and decomposed
Unicode are explicit cases; arbitrary byte execution is a separate declared
mode. A storage-discovered copy is not silently asserted as morphology.

The dictionary wire reflects the full native type into typed decisions and
values with direct context rANS. Every probability row, shared lexeme,
construction operand, root rANS state, directory, schema identity and checksum
is delivered. Each root has its own state for direct access after charged
shared lexicon preparation and full semantic admission. The decoded shared
lexeme pool is resident preparation memory, not an uncharged cold-access
shortcut. The experimental codec is separate from the production Entry/archive
reader. Its historical measurements use the frozen packet-v3 core; the
production semantic extension now writes packet v4 inside archive v3.

A separate production reform now appends named construction programs and
evidenced construction occurrences to the native Item vocabulary in packet
schema 4. Existing Entry fields and earlier Item ordinals stay intact; packets
2 and 3 remain readable. Local programs can call forward-declared named
programs, with cycles rejected even when unused. Admission proves exact output
against an authoritative local Representation, and charges shared work,
output, call depth and identity lookup bytes. Explicit external dependencies
remain representable with an `external_unverified` proof state. That state
does not establish executable equality and cannot excuse an entirely local
mismatch. This semantic extension is independent of the experimental codec's
compression results. Historical v3 measurements remain tied to commit
`6f043e245eea265e4a222524443e3ff01e09c3cb`.

Planned ablations isolate packet-byte entropy coding, typed decisions,
surface constructions, their joint representation, frequency ordering and
context use. Comparisons require actual complete outer artifacts with the
same source-root groups, full canonical packet equality and all native fields
equal. Prepared headwords, complete sources and other requested fields have
different work scopes; setup and shared memory are reported separately.

The first direct typed/rANS wire failed its actual cost gate. All eight
variants passed complete native/source/headword/root/outer-seek checks on
the same seven rich pages and thirty Japanese development pages. Its complete
adaptive artifact is 61,718 bytes versus 36,457 bzip3 bytes on rich128
(69.3% larger), and 282,661 versus 136,947 on Japanese dev512 (106.4% larger).
The natural joint representation spends 63,453 bytes on models, 210,058 on
literal streams and only 3,665 on typed root streams. That points to literal
and model reuse across pages, rather than further shrinking root decisions.
The next architecture delivers one global immutable literal/phrase stock and
independent per-root streams, including bounded overlapping copy programs.
Global preparation, memory, directories and models must all be charged;
whole-flat controls will accompany equal-page controls. The
[first negative ledger](../experiments/lexical_constructions/evidence/DEV-1-NEGATIVE-20261001.json)
remains available.

The second wire, `LGB1`, delivers that global stock and keeps independent
per-root ANS states plus the original source-group directory. The fixed ten
complete candidates improve development storage substantially. A typed
candidate with direct headword access is 28,348 bytes on rich128, versus
36,457 for bzip3 with identical page groups (22.24% less). Japanese dev512 is
104,585 versus 136,947 (23.63% less). The complete size-only minima, which
lack typed headword-prefix access, are 23,055 and 104,006 bytes respectively.
Whole-flat bzip3 remains smaller at 12,578 and 66,476 bytes. These are
development results and an access/storage tradeoff, not whole-file victories.

The Japanese typed representation retains 1,460,393 decoded literal bytes,
24,576 lexeme-index bytes, 82,240 model-heap bytes and a 1,320-byte Page value,
in addition to the borrowed 104,585-byte frame. These allocation payloads
exclude allocator capacity, stack state and transient full-admission peak;
they are not RSS. Whole-stock preparation and semantic verification precede
direct root queries. No cold-query or decoder-speed claim has been measured.

Independent review caught a model getter returning a pointer into a by-value
receiver. The corrected getter borrows the actual owner. Debug, ReleaseSafe
and ReleaseFast each pass 15 tests; re-encoding all twenty development
candidate frames, both minima and eight controls preserves exact bytes.
Corrected native/source/root/group gates cover 6,400 roots, with 4,480 direct
typed headword checks. The
[corrected immutable freeze](../experiments/lexical_constructions/evidence/DEV-2-OWNED-FREEZE-20261001.json)
supersedes the earlier ownership capture. The first fixed validation on new
FreeDict Turkish, Arabic and Japanese whole-record sources rejects a general
compression-win claim. Turkish's typed minimum is 43,322 bytes versus 31,195
for matched-page bzip3 and 21,626 for whole-flat bzip3. Arabic and Japanese
hit `WorkLimit` at the first fixed candidate and produce no valid minimum.
All controls, sources and failed admissions remain in the
[first fixed ledger](../experiments/lexical_validation/evidence/FIRST-FIXED-20261002.md).
A separately registered, additive resource-ceiling repair passed every earlier
development frame byte for byte, then admitted all 64,999 registered records
and 991 groups in all thirty candidates. It makes 649,990 full root observations
and 454,993 typed projections. Turkish and Arabic lose both page controls;
Japanese's untyped minimum saves 2.75% against paged bzip3, while its typed frame
loses 3.26%. All three lose whole-flat controls. The
[capacity result and resident-memory ledger](../experiments/lexical_validation/evidence/CAPACITY-RESULT-20261002.md)
retains the original failures. Raising capacity does not improve compression.

## Productive forms entering the native past cache

Initial `structural_wordcodec` experiments used a self-contained surface
lexicon, pair grammar and adaptive rank source. Eleven multilingual
development-prefix screens and an 8 MiB Japanese diagnostic falsified that
flat source: the Japanese diagnostic was about 1.15 MB versus the retained
strong M reference near 330 KB. Smaller lexicon bodies did not offset costly
occurrence ranks. Recent exact copy and joint reparse did not remove the loss.
Those are negative development results, not heldout improvements.

The stronger experiment changes the native grammar event language. `GEN`
reconstructs a surface from a paid donor span and literal prefix/tail, then
enters the ordinary past cache. Repeated generated surfaces can subsequently
use the existing distance tiers without first delivering a permanent named
word definition. This differs from splitting every occurrence into stem/tail
IDs or a standalone prior-word ring, both of which previously lost.

The private backend supports GEN in definitions and payloads. Stable surface
storage, exact slice boundaries, per-page reset, complete sidecar costs and
bounded expansion are part of the format. The first fixed-class 1 MiB
Japanese development result emitted 25 GEN events but grew by 308 bytes.
An early-stop wrapper bypassed the intended complete search; the fourteen
exact development frames remain valid diagnostics for that incomplete
candidate policy. The corrected no-GEN plus three thresholds by seven-class
search selects no GEN: 51,336 bytes versus unchanged M's 51,272. Both full
output and all sixteen original pages match. A separately versioned typed
donor-span wire saves only fifteen bytes under forced GEN (51,623 to 51,608),
and again loses under complete selection. Even deleting all 329 operand bytes
for free would leave 51,279 bytes, still above M. More operand flags cannot
win that fixed source/parse case. The next hypothesis changes the source:
paid, shared surface-construction families amortize one template across many
donor bindings before exact native reparsing. Every trial and family byte is
charged. These results concern original development sources, not reserved PUD.

## Context automata over grammar events

The `grammar_automaton` prototype retains exact forward-DAG material,
first-use definitions and past references. It changes the directly coded
native event probabilities, instead of coding original root IDs with a
weaker source. The paid model selects sparse context rows using causal
decoded-byte suffixes, event families, material lengths and class history.
State resets at each original payload page; the decoder uses transmitted
integer tables and cheap deterministic transitions.

Initial exact predecessor-root screens exposed severe sparse-context
overfitting. Root order-two empirical entropy looked very low largely because
contexts occurred once. After row supports, escape/backoff and table costs
were charged, most rows did not pay. Native event traces first reproduced
original frames exactly; one-byte context splits offered only small optimistic
net savings. The complete WGA1 payload-event implementation saves 1,055 bytes
on the same cached Japanese 8 MiB graph: 330,666 versus untouched M's 331,721
(0.318%). Full output and all 128 independently extracted pages match. Its
160,240-byte model/dictionary section motivates the next native wire, WGJ,
which applies the causal state inside recursive grammar definitions too and
allows several selectors to share one paid row. On three cached 1 MiB graphs,
M → WGA1 → WGJ is 82,176 → 82,040 → 82,023 for FreeDict, 193,523 → 193,488 →
193,408 for GCIDE, and 45,274 → 44,867 → 44,712 for Japanese OMW. Each passes
full and all sixteen original-page checks. These modest development gains
are against identical graph controls, not the differently learned 51,272-byte
Japanese graph used by GEN. No quiet speed improvement is established.
Historical WGA1 retained trial count and winning component ledger, not every
losing trial size. New WGJ telemetry retains all 49 Japanese trial sizes and
reproduces the original winning frame byte-for-byte. It also splits the
21,650-byte section into just 396 probability-model bytes and 21,254 grammar
definition bytes. The 8 MiB WGA1 section similarly contains 11,285 model bytes
and 148,955 definition bytes. A hot-symbol binary-gate screen, even charging
only an optimistic twelve-byte metadata floor per gate, offers at most about
169 bytes on the 1 MiB graph, below WGJ's already measured 562-byte saving.
That hypothesis is rejected before building another wire. The next substantial
experiment targets exact prior-rule splices and structural reuse in the
definition stream, with donor distances, positions, lengths and fallbacks paid.

These experiments apply the practical lesson of neural compression research:
prediction helps only after the delivered model and exact decoder are
accounted for. No external LLM weights or hidden teacher predictions are
assumed. The measured designs are exact construction/event models, not a
benchmark of neural compressors. The [research source review](frontier-2026-research.md)
separates inspected implementations from unverified or unrun leads.

## Evaluation boundary

All deeper designs are tuned on development inputs. The newly restored
[structural holdouts](../bench/structural2026/README.md) reserve seven new PUD
treebanks and three new FreeDict pairs. Their 20 source lanes total
32,609,918 bytes. PUD translations are aligned and not independent samples.
Complete-source selection, licenses, raw hashes and whole-record subset rules
are pinned before observing any new codec results.

Freeze source, binaries, model-selection policy and resource limits before
evaluating these holdouts. Require exact full and original-page reconstruction,
full native dictionary equality, adversarial admission checks, all model and
index bytes, strong M controls, and both whole-file and equal-restart controls.
Timed decoder/access comparisons get separate quiet repeated trials with
their actual API scopes. A loss or quota failure remains visible. A revised
design evaluated again on the same revealed sources is exploratory.

These are finite, falsifiable architecture experiments. They do not establish
an exhausted problem space, field-wide novelty or universal compression records.
