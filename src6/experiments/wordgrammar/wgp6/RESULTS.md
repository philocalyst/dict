# Native spelling-DAG development results

These are complete archives on retained development input, not held-out
results. Each compressed frame was decoded in a fresh native process and
compared byte-for-byte with its input. Raw JSON in `evidence/` records input
and encoder fingerprints, complete framing/model/payload ledgers, and every
reparse round. Concurrent development invalidates comparative clock claims;
the reported times are provisional diagnostics.

The native control is the unchanged `bz4.compress` with its automatic class
planner and both once-used-word policies, invoked through
`/tmp/frontier2026-bzip4-v3`. The experimental graphs use the same native
compiler, archive format, decoder, exact bytes, and requested 64 KiB restart
fences. Old word-aligned fencing can extend to the end of an atom, so these
are the native control's access boundaries rather than WGP5's strict byte
limit. Archived old results obtained from externally supplied byte-MDL
parses are a different comparison and are not claimed as beaten here.

| Exact 8 MiB development input | Native old compressor | Direct spelling DAG, initial | Best maximal DAG + compiler-state reparse | Change from native old |
|---|---:|---:|---:|---:|
| FreeDict | 579,202 | 574,634 | 569,164 | −1.73% |
| GCIDE | 1,324,034 | 1,326,409 | 1,315,835 | −0.62% |
| Japanese OMW | 374,217 | 354,166 | 344,357 | −7.98% |

The last column uses one global research policy: direct maximal repeated
substring proposals up to 128 bytes, minimum support three, a 200,000
proposal budget, two initial surrogate parse/refit rounds, then four rounds
using the fitted native compiler's conditional reference-price estimates. Complete
frame size selects the initial or any reparsed graph. Every model-fit and
parse is part of the encoder search cost. Keeping the best trial does not
change decoder operations or add an uncharged selector: the selected graph
is completely represented in the old frame.

This is a spelling-frontier result. It remains a small improvement on the
English dictionaries and a stronger improvement on Japanese. It does not
yet establish a new held-out codec policy or a whole-file bzip3 record.

## What the ablations established

* Direct constant substrings avoid CUT's requirement to retain both donor
  and receiver identities. Adding old recent-word CUT sharing to the same
  1 MiB FreeDict spelling candidate worsened its complete frame.
* Native finite-state successor price estimates help beyond scalar fragment prices.
  On 1 MiB, four rounds lowered FreeDict 82,374→81,462 and GCIDE
  197,969→195,464. The native old controls were 82,873 and 197,039.
* Maximal repeated substring proposals remove redundant overlapping
  candidates from the bounded dictionary. Increasing their maximum length
  from 32 to 128 changed no tested 1 MiB archive, but the broader proposal
  policy helped on complete 8 MiB data.
* Keeping all once-used word identities worsened all three 1 MiB corpora.
  Adding additional generic activation charges to native conditional costs
  also worsened all three.
* Exposing hapax spellings before phrase learning helps Japanese, but hurts
  the English dictionaries. Extending that exposure to words occurring up
  to four times worsened every tested 1 MiB corpus. This order change is an
  isolated research variant, not a language-specific default.
* More class-clustering sweeps produced small mixed improvements, at a
  substantial extra encoder cost. They remain a separate ablation.
* Luna's direct stem × conditional-tail source loses when broadly applied.
  An MDL-gated hybrid is nearly tied and offers less than 0.3% idealized
  inventory headroom. Neither is credited as a native-frame gain. Its full
  ledgers are in `research/`.
* Direct whole-word phrase proposals with an order-zero entropy/definition
  surrogate lose on all three 1 MiB native frames: best FreeDict 83,807,
  GCIDE 205,574, OMW 55,416. The corresponding native controls are 82,873,
  197,039, and 49,619. This is a useful distinction between lowering a
  surrogate and lowering the actual class-conditioned, past-copy source.
* Running that phrase tiler after native-style greedy pair construction
  activates no useful phrase. All four 1 MiB frame sizes on each corpus are
  byte-identical to the maximal spelling baseline. The complete negative
  matrix is retained in `evidence/phrase-after-greedy-1m-negative.jsonl`.
* Exact finite-set DAWG inventory serialization loses against the same
  byte-Huffman front-coded table on all six 1/8 MiB probes. Path compaction
  does not rescue it; restoring native first-use word order adds another
  charged rank map. See `research/DAWG_RESULTS.md`.

`compile_combined` reuses the fitted native planner when exporting the next
price matrix. It verifies that reconstructing the fitted plan emits the
identical frame. The combined 1 MiB FreeDict sequence exactly matched all
four separately fitted frame sizes, while removing a duplicate automatic
model fit from each iteration.

The negative phrase experiments indicate that a replacement phrase learner
must price native successor states and bounded past-copy recurrence. An
order-zero reference source is not a sufficiently accurate proxy. The
maximal spelling policy is retained as the word-bounded control. The later
byte-MDL inventory and complete-block parsing experiments below test a
different construction order.

## Stronger historical reference and whole-block composition

The historical v4 report also compiled a Lane M byte-MDL parse rather than
the native word learner's parse. That stronger reference must be paid and
reproduced before a frontier claim. `m_reference` now regenerates the exact
Lane A best-seed recipe from `gramlab.zig`, runs the unchanged Lane M
learner, retains its original symbol IDs and forward acyclic references,
then uses the unchanged v4 compiler. Both learners, all five seed trials,
and every native class trial are included in its encoder clock.

| Exact 8 MiB development input | Historical byte-MDL + v4 | Fresh faithful reference | Joint spelling + whole-block DP, one pass |
|---|---:|---:|---:|
| FreeDict | 564,416 | 564,416 | 560,852 |
| GCIDE | 1,276,838 | 1,279,033 | 1,277,062 |
| Japanese OMW | 330,148 | 331,721 | 330,282 |

FreeDict matches the historical reference exactly. GCIDE and OMW differ
by 0.17% and 0.48%; their learned inventories also differ slightly from
the historical notebook. These small differences remain explicit. The
first new joint pass beats the documented FreeDict record by 0.63%, and
comes close to the other two historical records. It is not credited as
beating those two records or whole-file bzip3.

The joint pass prices exact byte strings using the fitted native successor
states and bucket widths. It tiles each definition with strictly shorter
strings and tiles entire original restart blocks with the same inventory.
This permits learned phrases crossing word and markup boundaries to
compete with smaller spelling units. Existing macros longer than the
bounded 256-byte proposal trie retain their original edges, so the prior
parse is admissible. The initial probe omitted those edges and badly
worsened Japanese payloads; that rejected screen remains in the ledger.
The proposed score still omits exact first-definition and bounded-past
cache costs. Every proposed graph is accepted or rejected using the actual
complete frame, with all model and framing costs paid.

Every one-pass selected 8 MiB frame was freshly decoded and all 128
restart payloads were independently extracted in fresh processes. The
follow-up four-pass policy uses the same joint/no-pruning parameters on
every corpus and pays all intermediate model fits; its complete curve is
recorded separately rather than choosing a language-specific policy.

| Exact 8 MiB development input | Best complete frame among baseline + four joint passes | Selected pass | Change from historical strongest |
|---|---:|---:|---:|
| FreeDict | 558,643 | 4 | −1.02% |
| GCIDE | 1,273,132 | 4 | −0.29% |
| Japanese OMW | 330,282 | 1 | +0.04% |

All three selected frames passed every fresh restart extraction. The
nonmonotone GCIDE curve (1,277,062 → 1,278,033 → 1,274,919 → 1,273,132)
shows why one greedy stopping step would miss later gains. The Japanese
curve instead keeps the first pass. The selection rule is the same complete
frame objective on each corpus; all four trial costs are paid. These frames
remain above the historical whole-file bzip3 controls, so these modest
word-grammar gains are not described as whole-file compression records.

## Separating training roles and naming costs

Two independent class-training orders were screened at 1 MiB. The first
fit spelling classes from distinct definition bodies and lexical classes
from the original pre-phrase word sequence. The second fit lexical classes
from the actual coded root sequence after phrase construction. Both use a
fixed half/half split of the native class budget and pay all resulting
rows and buckets in the frame. The first produced best frames
85,068/204,689/46,305 bytes (FreeDict/GCIDE/OMW); the second produced
83,922/200,895/47,401. Both lose on the European dictionaries, and the
second loses everywhere. Neither advanced to 8 MiB. Forced separate
whole-word identities also have a cost; the same-graph original-planner
control isolates that cost from the separate-row allocation.

Adding fitted NAME terminal-row costs to spelling DP produced small mixed
8 MiB changes: 568,560/1,315,123/344,664 bytes versus the maximal spelling
control 569,164/1,315,835/344,357. ARITY and first-use activation remain
outside that proposal score. This is retained as an ablation, not a new
global default.

## Shared leading model and encoder lifetimes

The native v4 library already supports `hoist=true`: all reachable
definitions appear in a leading payloadless block. Each later payload
then uses that one shared model. This is a distinct access profile with
its full cost charged. On the same maximal spelling graphs, hoisted
8 MiB frames are 612,127/1,391,974/369,721 bytes, 6–8% above their
interleaved counterparts. On the faithful M graphs they are
581,487/1,309,827/349,137 bytes. All fresh payload extractions passed.
Interleaved whole-frame argmin results are not described as leading-model
independent frames.

The original research adapter retained temporary seed candidates,
learner-round scratch, and every class trial in one arena. Enforcing a
4 GiB limit exposed this accumulation even at 8 MiB. The private adapter
now releases per-candidate, per-round, and per-class scratch while copying
only accepted live state and retaining only the winning encoded frame.
Independent Sol tests verified byte-identical frames. Peak live allocated
bytes are 1.35/3.64/0.76 GB on the three 8 MiB references. A real 22 MiB
Japanese **development** text projection fresh-roundtripped in both profiles
with a 2.34 GB peak, below the unchanged 4 GiB cap. Allocation accounting
is not process RSS. The raw input cap is 64 MiB; exceeding a work or
allocation budget is a reported failure, not a truncated encode.

A separate natural GCIDE development projection of 12 MiB also passed
complete encode and fresh decode at a 3.47 GB allocation peak. This checks
a larger, different source under the same immutable backend and cap.
`reclaim_scope.zig` is an independently tested, unintegrated allocator
prototype for honoring temporary frees inside legacy seed helpers. It is
not part of the frozen reference or any credited compression result.

Evidence is in `evidence/lane-m-*.jsonl`, `evidence/m-epochs-*.jsonl`, and
`research/LIFETIME_FIT_EVIDENCE.md`. No held-out result guided these choices.
