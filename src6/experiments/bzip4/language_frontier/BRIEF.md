# Language frontier research and experiments — 2026-09-26

The target is the **current** lexical-automaton Bzip4 (`../bz4/v3`, wire v4),
not the older Python grammar/BWT prototype. Read that directory's DESIGN.md,
RESULTS.md, lab/RESEARCH.md and lab/LANE_W2.md before proposing work. Preserve
the production and earlier experimental sources; own only your assigned lane.

## Question

Can a better formulation of lexical identity, productive spelling, and phrase
selection substantially reduce complete compressed size on multilingual word
data, without sacrificing exact reconstruction or practical decoding?

The current codec already has a general static transducer, prior-token buckets,
first-use definitions, and prefix CUT. Rebranding these is not a new experiment.
The current learner's byte >= 128 classification is not linguistic segmentation.
Greedy pair merging, per-entry pruning, sticky field states, isolated context
lists, and naive word/shape side streams have already been tried. Explain the
specific structural difference whenever revisiting one.

## Acceptance rubric

1. Explain a falsifiable mechanism and its expected bit savings, including what
   the decoder knows at each decision. Ground research in primary sources and
   link them. Distinguish published methods from the proposed composition.
2. Count the complete frame: vocabulary/spelling model, rows/tables, IDs,
   exceptions, selectors, headers, restart data and padding. An entropy estimate
   is diagnostic, never a compressed-size result. No free external tokenizer,
   language model, dictionary, permutation or Unicode normalization.
3. Preserve every input byte, including whitespace, casing, invalid UTF-8,
   combining marks and mixed scripts. Learned model cost is charged. Scripts
   must have a deterministic round-trip decoder.
4. Compare the same bytes with the current end-to-end compressor, strongest
   retained v4 parse where available, and bzip3 whole-file plus matched block
   controls. Name distinctions clearly. Use multilingual and untouched inputs;
   word lists and prose are separate workloads. JSON/machine-code regressions
   are acceptable but cannot be silently substituted for language results.
5. One stated corpus-independent policy per candidate. Tuning uses development
   inputs; freeze before held-out confirmation. Preserve losing ablations and
   report sensitivity. Do not select a different hidden method per corpus.
6. Start with bounded screens. Record raw commands, versions, input hashes,
   output hashes, actual byte breakdowns and successful round trips. Parallel
   work may measure storage; trustworthy timings run serially after freezing.
7. Reject decoder hazards: checked sizes/references, output and model budgets,
   finite progress, malformed/truncated input, no unbounded recursive expansion.
   Prototype limitations must be explicit. Estimates of native speed are not
   measurements.
8. Aim for a structural win: a smaller, coherent generative model that replaces
   machinery. Do not accumulate special cases to rescue one benchmark. A clean
   negative experiment is valuable. Never invent or exaggerate improvements.

## Review gates

First return the primary-source synthesis, precise proposal, previous-work
contrast, and a cheap disproof experiment. Then implement in the owned lane,
retain evidence, and iterate according to the rubric. Promotion requires a
complete measured artifact and independent re-decoding. Heavy timing runs must
be coordinated with the root agent.

## Steering after the initial screen design

The user explicitly rejected incremental fixes as the main direction. Reversal,
better thresholds, ordinary DP segmentation and prefix-source selection are
controls only. Main research must challenge the representation itself: latent
derivations and marginal coding; productive lexical programs with reusable
arguments; or tractable learned circuits and a different decoding order. The
old decoder's no-adaptation policy is not an immutable requirement. Preserve
its speed as a measured target, but test a different engine where justified.

In particular, test whether choosing one tokenization/parse pays an avoidable
latent description cost. Under the SAME probabilistic model, measure
`log2(sum_z p(x,z) / max_z p(x,z))` before investing in bits-back or exact
marginal coding. This gap is only available headroom, not saved archive bytes:
model cost, seed bits, probability quantization and restarts must still be paid.
Likewise, information already recovered by v4's implicit first-use numbering
cannot be counted again as an unordered-lexicon or shuffle-coding gain.
