# Complete-frame result: negative

All three frozen GSG2 policies lose on all seven16KiB development prefixes
against both real native Bzip3 and current end-to-end Bzip4 wirev4. No policy
is promoted. Production, build sources and other experiment lanes are unchanged.
There is no native speed claim.

The [authoritative quickbench capture](quickbench-runs/20260926T164237Z-026b9da8/results.json)
contains42 verified codec rows and zero failures, with input/output hashes,
source-closure fingerprints, exact commands and independently decoded artifacts.
The [compact summary](results/summary.json) retains all input hashes and sizes.
Every input is exactly16384 bytes. Filename stems containing `prefix65536`
identify source containers, not the tested length.

| 16KiB input | B3PY native | currentv4 | grammar64 | grammar768 | grammar768 + paid root adjacency |
|---|---:|---:|---:|---:|---:|
| web2 | 5053 | 4771 | 7025 | 7779 | 8105 |
| FreeDict | 2358 | 2725 | 6041 | 4020 | 4174 |
| GCIDE | 4052 | 4751 | 7932 | 6505 | 6679 |
| OMW Japanese | 1575 | 2027 | 6261 | 4267 | 4482 |
| Finnish forms | 6245 | 7710 | 8402 | 9549 | 9765 |
| Turkish forms | 6247 | 7531 | 8694 | 9514 | 9841 |
| Arabic forms | 3968 | 5445 | 6020 | 6971 | 7457 |
| Total | 29498 | 34960 | 50375 | 48605 | 50503 |

Bzip3 is the actual vendored native1.5.1 compressor in the B3PY research
envelope:32 fixed bytes plus16 per block. It is not Pythonbz2 or an entropy
estimate. Matched-block and whole-prefix controls are identical here because
each tested prefix occupies exactly one16384-byte block. Currentv4 uses its
real end-to-end learner and `plan.fit`; retained8MiB saved-parse records are
not substituted for these matching-prefix controls.

The large grammar delivers useful long exact fragments, reaching240 bytes
on OMW and189 bytes on FreeDict. It lowers FreeDict's frame from6041 to4020
and OMW's from6261 to4267, but larger inventory cost regresses web2/Finnish/
Turkish/Arabic. These are separate globally frozen policies, not a claimed
per-file best-policy encoder. No adaptive selector is used.

The genuinely stronger paid-root source fixes the grammar-join interpretation:
its edge counts measure actual final-token adjacency. It still loses because
the delivered triples do not save enough payload. [Exact root decomposition](results/root-frozen.json):

| Input | Delivered grammar + root model/header | Surface payload | Framing | Peak live frontier |
|---|---:|---:|---:|---:|
| FreeDict | 2249 | 1923 | 2 | 67 |
| GCIDE | 3108 | 3569 | 2 | 86 |
| OMW Japanese | 3619 | 861 | 2 | 204 |
| Arabic forms | 3345 | 4110 | 2 | 316 |
| Finnish forms | 3562 | 6201 | 2 | 88 |
| Turkish forms | 3632 | 6207 | 2 | 81 |
| web2 | 3019 | 5084 | 2 | 208 |

On OMW, adding actual adjacency lowers payload by87 bytes relative to
grammar768, while model/header grows302 bytes: current GSG2 totals4267
versus4482.
Thus the stronger source buys a215-byte full-frame loss. Its3619-byte header
alone exceeds B3PY's1575-byte complete frame and currentv4's2027 bytes.
The arithmetic payload is never presented as the archive size.

The [original12-policy grid](results/grid.json) measured48 complete frames:
three boundary projections,64/192-rule budgets and half/7-eighths topology
weight, each on2KiB FreeDict/OMW self-fit and disjoint held-development slices.
All48 round-trip. Aggregate winner:64 rules, final-two-byte exit key, half
grammar-edge mixture4643 bytes, versus exact-token4660, last-byte4698 and
the corresponding192-rule5220. Greater7-eighths confidence worsens every
matching aggregate. The last-byte control is deliberately depth-weighted,
not a set of distinct right-spine contexts.

The [subsequent paid-root grid](results/root-grid.json) adds16 meaningful
complete-frame controls. Root-only64-edge policy totals5869 bytes; mixing
grammar edges totals5884. A256-edge cap costs5947/5968. Root statistics
improve source likelihood but lose full-frame bytes on this small screen.
[The original policy freeze](results/freeze.json) and [root freeze](results/root-freeze.json)
precede the seven16KiB evaluation rows. The768-rule test is a declared
scaling control, not a claim that a maximum-possible-savings header bound
predicts success.

A [repeated156-byte-fragment diagnostic](results/repeat.json) confirms that
the mechanism can actually use long reuse and marginalize compatible paths:
same grammar/header, no-edge marginal542 bytes, half-edge marginal502,
7-eighths marginal493. The committed greedy path costs545 bytes. This
constructed fixture does not replace the language results or establish a
gain over either native baseline.

Four tests pass, including a separate Fraction oracle that enumerates token
IDs/offsets rather than sharing the implementation's suffix frontier. It
checks exact normalization and byte marginals. Additional tests cover all
boundary policies, paid-root models, committed/marginal paths, empty input,
arbitrary/invalid UTF-8 bytes, output/model budgets, forward/cyclic references,
bad counts and truncated/trailing payload. Fresh decoders recover every
reported GSG2 frame using only delivered grammar/counts/rows/length.

The original GSG1 committed/no-edge experiment was already imported while
the separate GSG2 extension was added. Its saved frames independently decode
with the explicitly compatible current decoder, but its original imported
encoder snapshot was not retained. [Provenance records this limitation](results/provenance.json)
instead of assigning the current GSG2 source hash to that process. Current
quickbench GSG2 fingerprints are authoritative; legacy controls are supplemental.

All42 [legacy frozen control frames](results/frozen.json) completed fresh
round-trips. In that unchanged GSG1 wire, grammar64 totals50361 marginal,
54711 committed and50362 with no grammar edges. The marginal saves4350 bytes
against its same-source committed greedy path, but the predictive edges save
just1 aggregate byte against the no-edge source and help only3/7 inputs.
Grammar768 totals48591 marginal,51776 committed and48954 without edges:
3185 bytes of marginal/committed separation, but only363 bytes saved by the
grammar-derived prediction, which helps6/7 inputs. These are actual full
frames; their gaps are not global MAP gaps or bytes to subtract from a native
baseline. The GSG2 empty-topology extension adds exactly2 header bytes per
frame, so it does not change those within-policy differences.

Floating inference can underflow tiny root paths, and cross-architecture
bitwise portability is unverified. Mathematical singleton support does not
establish universal byte support for that floating rollout. Both are explicit
prototype limitations. The normalized source, rule reuse and latent summation
are mathematically coherent, but this delivered representation does not
pay for itself on the frozen development screen. This rejects these bounded
policies, not every possible shared grammar/predictive-state formulation.
