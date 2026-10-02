# Grammar automaton: development evidence

This directory is an additive research codec. All numbers here use development
prefixes; no final evaluation content was read for model selection. The strong
comparison is the original native-v4 M grammar, with complete header, grammar
deltas, payloads, and framing paid.

## Falsified first representation

`screen.py` reads exact P6F1 forward grammar graphs and tests deterministic
sparse context rows on **root IDs**. Its ideal entropy estimates were already
weak after a deliberately cheap row-description charge. On 8 MiB Japanese OMW,
an exact predecessor-root context selected only two rows and had about eight
bits net ideal benefit; last decoded byte selected 23 contexts for about 658
bits. The graph's varint rule bodies alone cost 261,280 bytes (218,672 after
zlib 9), while a complete strong native-v4 frame cost 331,721 bytes, including
its own much better first-use names and PAST token ring. A static root-ID
decoder would duplicate paid mechanisms and lose. Similar root-context
failures appeared on FreeDict and GCIDE development prefixes.

The corresponding first-order root entropy estimates were much worse than a
true native payload coder because they excluded dictionary naming and first
use. They are *not* archive-size measurements. No root-only result is claimed
as a codec win.

## Native event hypothesis

`native_v4` is a private, initially byte-identical copy of the original native
transducer with trace-only instrumentation. WGT3 records exactly one first
coding decision for each payload token, its previous 0–4 decoded bytes, the
previous token event family, token length, and base-row transition. It does
not alter the original first-use, NAME, PAST, ARITY, CUT, class, or bucket
planner. The diagnostic encoder compares its full frame with an untraced fit
byte for byte before writing a trace.

The first WGT1 one-byte screen with intentionally underpriced context rows
selected only 2 contexts / 123 net ideal bits for FreeDict 1 MiB, 4 / 164
bits for GCIDE 1 MiB, and 8 / 2,285 bits for Japanese OMW 1 MiB. These are
optimistic entropy differences, not wire savings. The weak simple suffix
effect motivated a richer causal feature set and actual full-frame trials.

## First complete native-event archives (ReleaseSafe, development only)

All rows below compare the **same P6F1 graph** with the immutable original
native-v4 `native_forward` compiler. The WGT3 trace compiler's unchanged-v4
frames were byte-identical to those immutable controls. `WGA base` is the
private new magic plus its empty-selector model; it is a separate control.

| Development prefix | Original native-v4 | WGA base | Best complete WGA | Selected feature / keys | Change against original |
|---|---:|---:|---:|---|---:|
| FreeDict 1 MiB | 82,176 B | 82,178 B | 82,040 B | prior base row / 1 | −136 B |
| GCIDE 1 MiB | 193,523 B | 193,526 B | 193,488 B | last byte / 4 | −35 B |
| Japanese OMW 1 MiB | 45,274 B | 45,276 B | 44,867 B | last byte / 8 | −407 B |
| Japanese OMW 8 MiB | 331,721 B | 331,724 B | 330,666 B | previous event kind + length bin / 16 | −1,055 B |

All three 1 MiB WGA frames decoded their complete source byte-for-byte and
selected original 64 KiB pages exactly. The 8 MiB Japanese frame passed
`verify_archive.py`: full 8,388,608-byte exact decode, **all 128/128**
independent page extracts, and an exact component ledger sum. Its complete
archive includes 6 header-prefix bytes, 1,718 directory bytes, 160,240 model
and grammar-dictionary bytes, and 168,702 payload bytes. The immutable
original has 159,836 model/dictionary bytes and 170,161 payload bytes; the
new row tables therefore cost 404 extra bytes and reduce the payload by
1,459 bytes, yielding the 1,055-byte net gain. The 8 MiB graph fit evaluated
35 complete candidate archives in 77.257 seconds (ReleaseSafe diagnostic
clock; other agents were active, so it is not a decode-speed benchmark).

8 MiB Japanese exact identities:

* Source SHA-256 `d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261`
* P6F1 graph SHA-256 `1f7c356cdacbc82adb7b4ad8bcb0571580feb9b0f0706220147e1b22a393d82a`
* Immutable original native-v4 SHA-256 `96d9cb80ebfa39331cae101ae96fd693e8b6e12e1e4ef029b4f6083fe07544c1`
* WGA archive SHA-256 `01cfb51dc742c5d07d20f4ba7717dabfb3e3b616ba4a2d3e1959570a01d5ca8c`

The Safe `context_forward` binary SHA-256 was
`407956175bbbf9167eafbfe6b03b9e7b51590fa257b2ea4c53b78bce15d0153f`.
The exact source snapshot of its core is recorded by the hashes of
`automaton_fit.zig` (`e60fb94f…`), `native_context/model.zig`
(`13a9ef2a…`), `encode.zig` (`05d5e349…`), `decode.zig` (`9b2c0f40…`),
`frame.zig` (`22f55cd3…`), and `context_forward.zig` (`cc2211b8…`).
No allocator peak was sampled for these graph-level runs; the encoder and
decoder exited successfully with no resource error. Final evaluation corpora
have not been opened or used for modeling decisions.

`event_screen.py` checks twelve causal feature families, including suffix
lengths 1–4, previous native event kind, prior symbol, length bucket, and
class history. It charges each selected key and a deliberately cheap lower
bound for the symbol table and also reports odd/even page generalization.
Surviving hypotheses must pass the actual native frame test.

## Private context wire in progress

`native_context` extends the native transducer with sparse payload-only clone
rows. The model header serializes the feature family, each `(base row, key)`
selector, every normalized tANS table and successor, and all original grammar
delta and payload material. The decoder recomputes context from exact prior
decoded tokens, resets context and PAST on each original 64 KiB payload page,
and follows original first-use/NAME/PAST semantics. A complete-frame minimum
includes the untouched planner as its control. `automaton_fit.zig` tests
bounded selector counts per feature; encoder trials and selected program are
part of encoding cost. `context_forward.zig` exposes this independent wire.

The new wire now has genuine but modest development storage gains. It still
needs invalid-byte, malformed-input, resource, and cross-configuration gates,
plus larger FreeDict and GCIDE development results. The current decoder uses
the inherited sequential grammar-delta preparation before a chosen payload;
the all-page result is an exactness gate, not a random-access timing claim.

## WGJ: causal context in grammar definitions and payloads

`native_joint` is a second, separately versioned native wire, `wgj\x01`. Its
encoder and decoder mirror a persistent context across grammar-definition
events, including recursive definitions, and reset that context after `CUT`.
Payload context still resets at each original 64 KiB source page. A selected
row may serve several distinct paid `(base row, context key)` selectors; its
target index is also encoded. The features include preceding output bytes,
native event family and length, base row history, and the definition/payload
stream. The complete candidate policy considers 13 feature families, selector
caps 1/4/16/64, and ordinary or merged row tables. Every candidate is a full
frame with all model tables, grammar, directory, and payload bytes included.

| 1 MiB development source | Untouched native M | WGA1 | WGJ | Selected feature / selectors | Complete WGJ trials | Full / pages |
|---|---:|---:|---:|---|---:|---|
| FreeDict | 82,176 B | 82,040 B | 82,023 B | prior base row / 1 | 18 | exact / 16 of 16 |
| GCIDE | 193,523 B | 193,488 B | 193,408 B | suffix2 + prior event kind / 8 merged | 22 | exact / 16 of 16 |
| Japanese OMW | 45,274 B | 44,867 B | 44,712 B | prior byte / 11 | 49 | exact / 16 of 16 |

These frames use the same cached P6F1 graph as their immutable native-M and
WGA1 comparator. The no-selector WGJ control is two to three bytes larger
than untouched native M, reflecting the new wire. The WGJ ReleaseSafe native
module passed all seven tests, including round trips and corruption errors.
The independent `verify_archive.py` decoded each entire source and extracted
all original source pages separately. It also checked each full-frame ledger.
All timings so far are diagnostic under shared machine load. The inherited
reader replays the grammar deltas before selected-page decoding.

WGJ is still a modest standalone native-event result. Its row tables did not
approach the roughly 160 KiB model-and-grammar component of the larger
Japanese case. Larger development corpora, arbitrary-byte full-codec tests,
and hostile-frame resource tests are outstanding. No final corpus was opened
or used to choose the context features or caps.

## Definition-splice falsifier

Splitting the exact Japanese OMW 8 MiB WGA1 frame reveals 11,285 bytes of
entropy model and **148,955 bytes of grammar-definition deltas**, plus
168,702 payload bytes and 1,724 framing/directory bytes. The larger target
is grammar construction. `rule_splice_screen.py` therefore examined exact
P6F1 rule reuse on the cached OMW 1 MiB graph, without refitting M.

The graph has 3,436 demanded rules and 17,463 child events; their summed
expansions total 386,453 bytes. WGJ's actual compressed definition delta is
21,254 bytes. A superficial prior-rule byte-substring screen reported
6,849 optimistic bytes, but its largest repeated byte spans crossed thousands
of bytes while replacing only one or two cheap grammar children. A stricter
screen required copied spans in the current rule to start and end at whole
child boundaries, preserving already demanded definitions even when the
donor used different child IDs. It found 214 positive proposed splices and
only **301.56 optimistic bytes** after gamma-coded donor distance, offset,
length, and a three-bit opcode floor, using a generous gross 9.7367 bits
per skipped child. Adding eight bytes of realistic per-splice metadata leaves
60.38 bytes; 16 bytes leaves 44.38 bytes, before any fixed new-wire model
or frame cost. Exact repeated child-ID sequences yielded 390.26 optimistic
bytes with the same weak charge. These are diagnostics, not archive sizes;
actual native marginal event costs may be lower. There is no credible
complete-frame margin, so no splice wire was built.

The full screen and top candidates are saved in
`evidence/omw1-rule-splice-negative.json` (SHA-256
`dcdf44849e7e79a40174b9dc92e29810caf1ee202082f45075785b4fe6decab1`).
Its exact source, graph, untouched M, and WGJ SHA-256 values are respectively
`541e802f3112fb96a823219ffa4eb9102d0c4125e9eed6292f524ab8154a4502`,
`ab6545a5b3345ba8e4c6f3401f3189f87fa681100f10fdef2512b9b78e7045eb`,
`d25cc0c9b19545d610eeed90bc902408cc9f509cbeb99d9cfdee64bb541dcd61`,
and `be7b57e54d9b2caf35403d257f164679b168a3d3b99836f52f63133fe0466e4d`.

## Six-book prose gate: causal word, byte and bit models

The six fixed development books use the UTF-8 body projections in
`/workspace/scratch/books2026-dev/manifest.json` (SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`).
The 1 MiB prefix of a shorter book is its entire book. Matched bzip3 1.5.1
single-block complete frames and independent exact decodes are recorded in
`/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json`
(SHA-256 `640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`).
No raw Latin-1, Shift-JIS, Project Gutenberg header, or sealed final source
was used. The model values below are **ideal entropy estimates, not archives**.

| Fixed development input | Raw bytes | Complete bzip3 | Best word-order ideal | Best bounded byte-PPM ideal | Integer bit-mix ideal |
|---|---:|---:|---:|---:|---:|
| Austen, entire book | 705,012 | 161,119 | 185,580 | 174,504 | 191,205 |
| Tolstoy, 1 MiB prefix | 1,048,576 | 247,364 | 284,007 | 270,451 | 292,908 |
| Cervantes, 1 MiB prefix | 1,048,576 | 252,940 | 299,386 | 276,281 | 293,741 |
| Flaubert, entire book | 716,472 | 179,597 | 224,279 | 191,696 | 208,866 |
| Kafka, entire book | 126,200 | 35,251 | 41,783 | 36,559 | 37,928 |
| Sōseki, entire book | 486,098 | 97,505 | 190,095 | 102,436 | 110,165 |

The word-order screen uses Unicode letter/mark/number runs with exact
separator bytes, first-use spelling, and bounded sparse word-ID contexts.
Script SHA-256 `1d01c0278e90b7ab37474f10f58248ceb59d0ccc1f0859106a6c902e807b6b25`;
evidence `evidence/word-order-ideal-books6.json` SHA-256
`9c2cdf902b7caa7680a3363aa9df2463966e245d2c151ad48777f7b830113124`.

The byte screen uses exact raw bytes, bounded Witten–Bell PPM orders
0/1/2/4/8/16/32, exact last-successor match experts, and a Bayesian fixed
prior mixture. Script SHA-256
`d89c49f80bca11c2a973cc2e074b24002db32e9c8015c26b8da598cc83d36d55`;
evidence `evidence/byte-ppm-ideal-books6.json` SHA-256
`b48ea5aaecd4ec89de1bbef6a25c06f7235a80bcbc19f4f6749758a7f20980a7`.
It loses to bzip3 on **all six** before paying a frame. The Bayesian mixture
tracks PPM8 within roughly one byte but the match experts individually lose.

An exact prior-16-byte-context LZ channel over PPM8 was checked with at most
four donors/context and 65,536 contexts, charging gamma donor distance and
copy length, a two-bit donor rank, and KT copy/literal flags at every eligible
site. It changes six ideal costs by only +0.95, −93.51, +0.97, +0.90,
+0.78, and +0.98 bytes in the displayed order. Tolstoy has just 16 useful
copies, covering 5,769 bytes. Its 1,559 saved PPM bits paid 608 copy-operand,
90 copy-flag and 113 literal-flag bits. Source SHA-256
`ca2e5d82d115f323975d93d5afc6d2b58e8d13bb312a09e52686592b47993f20`;
evidence `evidence/lz-ppm-ideal-books6.json` SHA-256
`75fa2e26e85090ce5e5eb4d266c735c12e790c3478d87fc40f98879b94a121ff`.

The native bitwise scorer has seven online integer experts: partial-byte,
prior 1/2/4/8 bytes, capped word-byte signature, and verified exact-match
continuation. It quantizes probabilities at 1/4096 and uses a deterministic
integer discounted mixture with bounded direct-mapped context tables. C++
source SHA-256 `0a3043a828428770337e381b4bb7ae2e4ecf430e54f0c5d2a40f463ebdfa2abd`;
binary SHA-256 `1d347c81e6a1221654f282f2baa675f0bc777e1b7d9daec72ce3a8ad8be9a12a`;
evidence `evidence/bitmix-ideal-books6.json` SHA-256
`3a281c25b5918cd9ab5b6e89f7fd163eb335cf035b9f95e573f4a3545174c32e`.
The best individual expert is prior-8-byte context in all six books, and the
mixed result still loses bzip3 everywhere. A controlled Austen precision
ablation raises its quantizer from 4096 to 65,536 units with every context
and update unchanged: prior-8-byte ideal cost improves only 29.6 bytes and
mixture cost worsens 15.0 bytes. That identifies predictive modeling, not
CDF precision, as the main gap. Evidence `evidence/bitmix-q-precision-austen.json`
SHA-256 `87c6f4a3aeff444b44694c6cd4b081251633022cedeffc00104ac27522464231`.

The simple word, byte-PPM, LZ and bitwise designs are stopped before native
archive work. On Austen, bzip3 uses 1.828 bits per raw byte. A 20% smaller
complete frame would need at most 128,895 bytes or 1.463 bits per raw byte;
the best tested byte-PPM model is already 174,504 **ideal** bytes, so it would
need to remove at least another 45,609 bytes before framing. This is a
useful minimum effect size for any future prose model.
