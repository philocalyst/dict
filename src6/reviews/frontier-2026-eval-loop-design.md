# Lossless-compression eval loop: design and scoring review

This review adapts Lance Martin's 2026-09-28 article, “Automating eval design
and hillclimbing with Claude,” to the Luna dictionary/book codec program. The
original blog host was denied by the current proxy. Two independently
archived copies were inspected in full and are locked in
`/workspace/scratch/compression-eval-loop/article-lock.json`:

- `anthropic-mirror.md`, 23,022 bytes, SHA-256
  `374c9b772ff28d1b32d24ec206b7cb1429cad75f3369e37c1c7b831aa8756ea5`;
- `ai-topics.md`, 22,011 bytes, SHA-256
  `01cebd392b76075ee4f5af80b7fe5261da0a742c966ff8c0ea2c6c2548bc1e0d`.

The article's useful principles are representative cases, a programmatic
grader, headroom, low variance, adversarial case selection, one attributable
change per round, a test set that stays unseen, plumbing checks, root-cause
reflection after stalled rounds, and stopping when measured gains are within
noise. This domain can make grading stricter: successful output must reproduce
the exact original bytes, so a language-model judge is unnecessary and
dangerous.

## What counts as success

### Non-negotiable correctness gates

Every candidate frame must:

1. pass a fresh-process full decode and byte-for-byte compare with the exact
   source SHA-256;
2. pass every original independent-page/restart extraction for a random
   access format, with exact per-page source hashes and boundary counts;
3. for dictionary/native projections, pass native structural validation,
   all entries/fields/senses/forms/metadata/duplicates/order/IDs, and the
   independent source-projection oracle;
4. reject the tested malformed/truncated/oversized frames without publishing
   partial or incorrect output;
5. stay within the frozen decoder resource/work budgets.

Failure of any gate makes the candidate ineligible regardless of its size or
speed. An infrastructure interruption is recorded separately and retried
only under the same fingerprint; an unsupported-format, corruption, memory,
or work-budget rejection is a codec result, not an infrastructure retry.

### Primary storage metric

For each source lane `i`, define:

`r_i = complete_candidate_bytes_i / complete_whole_bzip3_bytes_i`

using the identical raw source bytes and the same declared archive scope. A
value below one is a size win. The numerator includes every model, lexicon,
transform, selector, directory, padding, checksum, and frame byte. The
denominator is the actual whole-file bzip3 frame, including its wrapper when
the candidate uses one. Never compare a page-framed candidate only with a
whole-file control or compare a whole-file candidate with a page payload.

For an archive with one shared model, score
`(shared_model_bytes + Σ per-file bytes) / Σ whole_bzip3_file_bytes`; do not
divide the model by an undocumented number of files. A pre-trained model,
tokenizer, external dictionary, or executable runtime needed to decode is
either included once in the declared archive scope or explicitly labeled an
external-model upper bound and excluded from promotion. This requires a
trusted source audit: hashing every binary dependency proves what ran, but
does not charge learned tables compiled into that binary. Specs must declare
trained data/model dependencies separately from universal algorithm code,
and complete side-information size is charged once at the stated archive
scope. The runner is an integrity/evaluation harness for reviewed candidate
code, not a sandbox against a malicious codec that hides a model in executable
instructions.

The primary book/prose score is the language-balanced geometric mean of
equal-work ratios. The aspiration is at least **35% below** whole-file bzip3
overall (`ratio ≤ 0.65`), at least **20% below** in every language
(`ratio ≤ 0.80`), and no individual book/prose case may lose to bzip3
(`ratio ≤ 1`). Report the median ratio, worst ratio, fraction of works below
one, and each language's aggregate. A large English book must not swamp
small Arabic, Chinese, Finnish, or Turkish cases. Dictionary content, word
lists, forms, and typed-access layouts are separate scorecards. Wins in those
lanes cannot offset book/prose losses.

The runner separates incremental promotion from goal completion. A fully
correct self-contained development candidate can seed or improve the
incumbent only if it beats the current incumbent by the registered margin
and has no per-language or per-book regression; the 35% threshold remains the
terminal target for validation/final acceptance. This allows attributable
hillclimb steps without calling an intermediate win a completed result. The
stop rule requests root-cause reflection after two non-promoting rounds, not
after two candidates that merely fail to reach the terminal 35% target.

As of this review, the recent whole-book screens have not met the target:
exact-word, byte PPM, paid-match, global and conditional bit-mixer estimates
all remain larger than matched whole-file bzip3 before a native frame. The
fixed WordFrontier and dictionary-access results are separate scorecards and
do not establish a book/prose win.

For any random-access candidate, report a second access score against matched
page controls at the same original restart boundaries. Include cold prepare
time, memory, and first/middle/last independent read cost. This access score
does not change the whole-file compression score. A format that wins only
matched-page bzip3 but loses whole-file bzip3 is a page-access tradeoff, not a
general compression win.

### Speed and resources

Size is deterministic for frozen source/config; repeating it does not create
statistical evidence. Timing varies with process startup, cache state, thermal
load, and scheduling. Keep timing in a separate quiet stage: one warm-up,
then at least five paired serial trials with forward/reverse candidate order.
Retain every raw invocation, stdout/stderr, exit status, source/binary/runtime
fingerprint, and exact clock scope. Compare only the same measurement boundary
(native codec clock to native codec clock, or full command wall to full command
wall). Report medians and all paired ratios, never choose or discard runs by
appearance. Peak RSS from a process with a prior high-water mark is not a
per-candidate memory measurement; use codec-owned allocations or fresh
processes.

Record size, encoder work, decode throughput/latency, peak decoder allocation,
and process RSS as distinct axes. A large encoder-only search is not “free”:
its complete search runtime is an encoder cost. Likewise, a static learned
table is a delivered-byte cost while an adaptive table trades those bytes for
decoder updates and growing state.

## Sampling and leakage prevention

The article's random split is too weak for books and authors. Adjacent
paragraphs and chapters share names, phrases, formatting, and vocabulary. Split
by the complete work and author/translation lineage, and stratify by language
and text type. The optimizer may see the fixed development set; the validation
set must come from different works, with a separate language source where
available. Keep the final set under coordinator control until candidate source,
binary, tokenizer, model, policy, and limits are frozen and independently
hashed. Do not send held-out sizes, failure rows, or source text to candidate
owners while they are designing a codec.

Before each round, write one short hypothesis with a predicted mechanism and
a stop condition. Example: “A class-factored word model should lower the
conditional class-stream cost more than it adds class map, within-class rank,
and class-history tables; stop if its exact paid 1 MiB frames are not at least
5% below whole bzip3 on two prose dev sources.” Search parameters are part of
the hypothesis and must be finite and declared up front. Candidate arrays
must be fully charged and fully decoded. Keep all negative candidates and
failed experiments in the ledger; a failure can be excluded only when the
raw process evidence proves an infrastructure fault.

The article recommends one attributable change per hill-climb round. For this
codec search, one round should change one representation or model family,
while its pre-registered small finite hyperparameter grid is counted as one
search. Do not simultaneously change tokenization, entropy model, and outer
framing, because a measured gain then has no usable cause. Once a policy is
selected on development data, validation is an admission test only; if it
fails, record the failure and choose a new validation cohort rather than
repeatedly adapting to the same held-out examples.

## Search loop and stage gates

1. **Source audit.** Verify source locks, licenses, extraction/projection
   hashes, and group/work split. Write the exact workload the user cares about.
2. **Baseline.** Run current native bzip3 on every development lane and freeze
   complete whole-file frames plus matched-page controls when applicable.
3. **Tiny correctness gate.** Run empty, repetitive, random, Unicode,
   malformed-byte, long-distance, oversize, truncation, mutation, and every
   restart tests. It is a correctness gate, not a performance trial.
4. **Cheap screen.** Use small fixed prefixes only to reject candidates with
   obviously excessive model/header cost or a decoding failure. Never call a
   prefix result a full-work size result.
5. **Full development round.** Encode complete pre-registered development
   sources, retain all trial frames/results, fresh-decode every complete
   frame, and compare against whole-file and matched-access controls.
6. **Root-cause review.** If two rounds do not materially change the book
   score, classify remaining losses by mechanism (token inventory, model,
   literals, context, restart directory, decoder budget). Add a new round only
   when a falsifiable change attacks that cause. If estimated maximum savings
   are below fixed table cost, stop the family.
7. **Freeze and validation.** Freeze every source/runtime/model/config hash.
   Coordinator runs the untouched work-level validation once, after all codec
   owners are quiet. Report every lane and exact artifacts. A new policy or
   source change is a new candidate and requires a new validation set.
8. **Final sealed capture.** Only after validation accepts a candidate, use a
   separately quiet paired timing run and frozen final source cohort. No
   learning or corpus-specific model selection may use final results.

## Metric gaming and benchmark failure modes

| Failure mode | How it inflates the result | Required guard |
|---|---|---|
| Dictionary/page gains hide prose regressions | A pooled byte total is dominated by the largest lexicon. | Separate book/prose and dictionary scorecards; equal-work geometric mean and per-language rows. |
| Model or tokenizer is free | External weights/codes make payload look implausibly small. | Charge exact files once at documented archive scope, or mark as upper bound. |
| Search overfits validation | Trying many tokenizers/caps and reporting the minimum selects noise. | Hash/freeze validation; count every attempted candidate; finite grid; final cohort remains unseen. |
| Random paragraph split leaks style | Train and test share vocabulary/author conventions. | Split by work, author, and translation lineage, not random lines. |
| Page payload compared to whole bzip3 | Candidate or baseline has different access constraints. | Publish two separate scorecards with identical declared boundaries. |
| Output parser silently drops data | A smaller frame decodes a projection instead of the full source. | Independent full-byte hash oracle and native semantic/cardinality gates. |
| Prefix screens called full-frame evidence | Model/header overhead changes with input size. | Mark prefixes as screening; re-encode whole registered sources before any win. |
| Encoder searches free | Auto policies test many complete candidates but report only the selected frame. | Frame objective pays only selected bytes; encoder-time objective reports all search work and every candidate trial. |
| RSS is inherited/floored | A worker reports a previous process's maximum. | Fresh-process per-candidate measurements or allocator-owned peaks; do not rank floors. |
| Clock scopes differ | Native CPU excludes I/O while another command includes writes. | Preserve scope labels and compare only matched boundaries; keep full-wall as an end-to-end view. |
| Flaky environment appears as codec failure | CPU contention, disk errors, or transport loss are mistaken for algorithm behavior. | Preserve raw stderr/exit/PID/resource event; retry only identified infrastructure faults with same hash. |
| Quiet timing is contaminated | Parallel encoder builds skew throughput. | Explicit coordinator quiet token, process census, sequential paired run; no builds during timing. |
| Format is unsafe but small | Invalid frames exploit parser limits or semantic bypass. | Correctness/resource gates precede all size ranking; a safety failure disqualifies the candidate. |

## Recommended stop and promote rules

- Stop an architecture when its optimistic lower bound plus unavoidable
  complete model/index cost cannot meet the prose target.
- Stop after two architecture rounds with no material change in the held-out
  development-work score unless a new measured failure mechanism is found.
- Promote only after exact full-source and every-restart validation succeeds,
  the complete-file book/prose score clears the pre-registered target, and
  memory/work limits hold on the largest supported input.
- Preserve weaker Pareto points as specialized results (e.g. random-access
  dictionary) without relabeling them as whole-file compression wins.
- Never tune to validation or final after a failed trial. A failure can inform
  a new hypothesis, but that hypothesis needs new unseen validation material.

## Review of the article's transfer limits

The source article assumes a stochastic application and an often-subjective
grader. This project has a deterministic lossless correctness oracle, so pass
rate and LLM judges should not enter the storage score. The article's example
of a random train/test split and a hillclimber that reads error transcripts
also needs stronger control here: repeated views of one book, title, sentence,
or entry are correlated, and source-projection artifacts can leak exact text.
The appropriate equivalent of a grader audit is dual independent source
reconstruction, exact SHA/cardinality checks, control re-encoding, and source
manifest verification. Its principles of attributable changes, sealed test
data, low timing variance, explicit cost objective, and a stop after stalled
rounds transfer directly.
