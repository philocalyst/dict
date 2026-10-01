# Working formulation: lexical programs with charged uncertainty

Status: a research hypothesis, not an achieved compression record. This document
is written before the new experiments so that their results can reject it.

## What changed since the earlier Python frontier

The current `bz4/v3` directory implements wire v4: static tANS transitions over
token buckets, first-use definitions, prior-token windows, and prefix truncation.
The decoder already turns most token decisions into a table lookup and a copy.
The saved-parse records on 8 MiB, 64 KiB blocks are 564,416 / 1,276,838 /
330,148 bytes for FreeDict / GCIDE / OMW Japanese. The end-to-end learner is a
different, weaker baseline. Results must state which one they beat.

The architecture is stronger than its learner. The learner makes two independent
greedy grammars: spelling over distinct byte-run atoms, then phrases over the atom
sequence. It fixes segmentation early, measures pair frequency rather than full
representation cost, and defines rare words before knowing whether a productive
relationship is cheaper. Its treatment of all bytes above 127 as letters is
byte-preserving, but is not a model of scripts or word boundaries.

## The missing object

An exact phrase is a cached answer. A productive word family is a cached
**construction**, and a recurring linguistic or record context is a construction
with arguments. Both are smaller descriptions only if their choices cost less
than the spellings they replace.

Represent an emitted string by a bounded lexical program:

```
emit := reuse(identity)
      | materialize(program, arguments, residual)

program := literal | concatenate(children) | slice(argument, interval)
```

This is a conceptual normal form, not three opcodes to add blindly to v4.
An exact cached phrase has no arguments. A suffix change reuses a slice and
concatenates an affix. A circumfix uses two literals around one argument.
An internal alternation uses several bounded slices. A record or phrase with
varying content reuses its surrounding construction. Repeated arguments express
agreement or repeated lexical identity without storing the value again.

The entropy model predicts **which construction and which unresolved choices**,
not an opaque ID for every surface form. When the construction has no uncertainty,
the decoder copies a prepared span. Where it has a hole, only the hole is coded.
The fast exact-phrase path remains the zero-argument case.

This formulation must earn its expressivity. A general interpreter, a huge
transducer, or a source-word ID that costs more than the suffix saved is a loss.
The first experiments therefore test separate restrictions before considering
any combined format: better segmentation on the current wire; shared spelling
relations with all references charged; a bounded spelling predictor; and one-hole
contexts with explicit exact derivations. A successful restriction should replace
an existing mechanism, not justify a growing catalogue of escape modes.

## The objective must include the construction

For input bytes X, choose a model M and exact derivation D to minimise:

```
stored_bytes(M, D)
  = header + model + lexical_definitions + choices + restarts + padding
```

Track preparation work, full decode work, maximum dependency span, resident
model bytes, and one-block cold-read work alongside this objective. Keep a Pareto
frontier rather than silently trading 10x slower startup for 1% storage.

A useful local disproof is:

```
savings = old_spelling_cost
        - program_definition
        - source_identity
        - argument_boundaries
        - per_use_choices
        - exceptions
```

Do not replace the final frame measurement with this estimate. The existing
codec's classes, first-use ordering and recency make local prices interdependent.

## Primary research and what transfers

* [Adaptor grammars, Johnson et al. (2006)](https://proceedings.neurips.cc/paper/2006/file/62f91ce9b820a491ee78c108636db089-Paper.pdf)
  separate a generative grammar from reuse of previously generated subtrees.
  This supports jointly reasoning about lexical productivity and repetition.
  The existing DEF/past mechanism already captures part of that idea; invoking
  the name alone does not improve compression. Bayesian inference need not run
  in the decoder.
* [Unsupervised paradigm clustering, McCurdy et al. (2021)](https://aclanthology.org/2021.sigmorphon-1.9/)
  demonstrates cross-language morphology induction using adaptor segmentation.
  Its clustering accuracy is not a compressed-size result. Here a proposed
  relation survives only if its program and identity costs fit in fewer bytes.
* [Inferring inflection classes with description length, Sagot and Walther](https://jlm.ipipan.waw.pl/index.php/JLM/article/view/184)
  studies local relations between paradigm cells rather than requiring every
  form to share one universal stem. This motivates bounded edit relations over
  exact surface forms, including non-prefix changes, without assuming English
  stemming or normalising Unicode.
* [PCFG compression, Naganuma et al. (2020)](https://arxiv.org/abs/2003.08097)
  charges a grammar and an explicit derivation, allowing related strings to
  share structure. Its demonstrations use noisy Fibonacci strings; they do
  not establish practical natural-language superiority. Our one-hole-context
  experiment is a narrow test of whether that missing kind of sharing pays.
* [Languages through BPE compression, Gutierrez-Vasques et al. (2023)](https://aclanthology.org/2023.cl-4.5/)
  compares typologically diverse languages. It motivates varied morphological
  and script workloads rather than extrapolating from English or token-count
  reduction. Token counts, linguistic segmentation quality, and coded bytes
  remain distinct objectives.
* [Language Modeling Is Compression, Delétang et al.](https://arxiv.org/abs/2309.10668)
  connects predictive distributions with lossless coding. Large pretrained
  model results are not self-contained archive totals. The practical question
  here is how much useful predictability survives in a small charged model.
* [StateSMix (2026 preprint)](https://arxiv.org/abs/2605.02904)
  reports training a small state-space model on the input itself, with roughly
  2,000 tokens/s in its implementation. That makes online learning a research
  comparison, not evidence for preserving Bzip4's hundreds-of-MB/s decoder.
* [Nacrith (2026 preprint)](https://arxiv.org/abs/2602.19626)
  reports strong text payload ratios using a pretrained model and approximately
  500 MB of weights. Those payload ratios cannot be used as complete-frame
  comparisons here. A teacher could suggest compact rules at encode time only
  if the delivered rules and residual are entirely sufficient to decode.

## Decisions the measurements must settle

1. Does a new segmentation actually reduce complete v4 bytes, or merely replace
   dictionary bits with token bits?
2. Are reusable spelling relations common enough outside sorted English lists
   to pay for source identities and transformation descriptions?
3. Does modelling the distinct-type population improve new-word spelling over
   the codec's pooled grammar-body and payload classes?
4. Can parameterised contexts preserve adjacency and avoid the selector costs
   that defeated the previous byte-class separation experiments?
5. Do gains transfer to newly frozen Finnish, Turkish, Arabic and Japanese
   workloads, including text with no whitespace word boundaries?

No novelty, speed or record claim follows from this formulation. The lane reports
and independently decoded frames determine which parts survive.

## Stronger hypothesis: the surface string is an equivalence class of programs

The initial formulation still picks one derivation D. That may pay to describe
decisions that the consumer never asked to recover: a token boundary, latent
paradigm assignment, or arbitrary hidden class. Many programs emit exactly X.
The correct target distribution is therefore

```
p(X | M) = sum over D with emit(D) = X of p(D | M)
```

The ideal gain over the best single derivation is
`log2(sum_D p(X,D) / max_D p(X,D))`. It is zero for a unique derivation and can
be substantial for a productive ambiguous grammar. This is a measurable
quantity, not permission to subtract a guessed parsing entropy from a frame.

Three ways to realise that formulation deserve experiments:

1. **Marginal lexical circuit.** Compile alternative word segmentations and
   productive relations into a weighted acyclic circuit. Exact sums give the
   byte or character CDF; the decoder recovers the surface directly rather than
   a chosen segmentation. Factor shared subcomputations so uncertainty is paid
   once, and keep exact cached phrases as deterministic leaves. The key open
   problem is maintaining compact circuits over variable-length strings while
   sharing enough substructure to outperform a conventional context model.
2. **Bits-back lexical derivations.** Decode a latent program from the current
   ANS stack under a posterior, encode its exact surface under the generative
   model, then encode the program under its prior. The decoder reverses these
   operations and returns the posterior bits. The rate includes posterior
   mismatch, initial seed, quantization, and any loss of chaining at access
   boundaries. Sampling a parse is useful only if these costs are smaller than
   the measured marginalisation gain.
3. **Bidirectional commitment.** Code a small set of informative lexical choices
   first, then reconstruct other positions in a deterministic schedule from the
   revealed context. A compact circuit or program predicts the remaining holes
   in parallel. This challenges left-to-right decoding itself. Position/length
   information and the initial choices must be in the frame; conditioning on
   encoder-only unrevealed words is invalid. It is not enough to rank the true
   token using a model that secretly sees the answer.

[BB-ANS](https://arxiv.org/abs/1901.04866) and
[Bit-Swap](https://proceedings.mlr.press/v97/kingma19a.html) provide the coding
mechanism for latent choices. They do not supply a good language model for this
archive or establish a net gain after its cost is charged.
[Probabilistic circuits](https://arxiv.org/abs/2111.11632) give a route to exact
marginal coding without sending a latent sample. Their reported experiments
are principally images, so applying compact variable-length circuits to words
is the hypothesis here, not a published text-compression result.

[Diffuse to Compress (2026 preprint)](https://arxiv.org/abs/2608.11249) studies
masked models and deterministic commitment schedules. Its transformer/H100
implementation is not the proposed portable decoder. The transferable idea is
choosing which uncertainty to resolve first, with every conditioning value
available identically during decoding.

[Shuffle coding](https://arxiv.org/abs/2408.08837) concerns unordered objects.
Our source text remains ordered. Only actual symmetries of its hidden program
representation may be quotiented out; v4 already avoids explicit first-use IDs,
so blindly subtracting log(N!) would double-count a saving.

## A necessary correction: ambiguity is not the objective

The root's independent exact-rational oracle lives in `oracle/renewal.py`.
It enumerates a tiny universe and checks the forward sum, length partition,
prefix marginals and decoder CDF chain independently. Six tests pass.

It also falsifies an easy but misleading interpretation of the ambiguity gap:
replacing one weighted `ab` rule with eight equal-weight aliases changes no
surface probability at all, but increases the MAP-to-marginal gap for `ababab`
from 0.5098 to 9.5098 bits. The aliases merely make the selected-path baseline
worse. Therefore a large gap is not evidence of useful language structure, and
is not an improvement over v4. A candidate must improve the normalized surface
distribution after the representation of that distribution is charged.

For a bounded piece model, one causal option is to store output byte length N
and condition on it. Let F(X) sum the products of piece probabilities over
exact parses, and let Z(N) sum those weights over **all** length-N strings.
Then P(X|N)=F(X)/Z(N). The recurrence for Z uses piece lengths, not unseen text.
The oracle checks partial-piece prefix marginals, too; normalizing only complete
word leaves would define a different model and charge an unnecessary vocabulary.
The oracle is intentionally slow and is not a compressor.

## The stronger implementation target: compile inference, not just syntax

There is a second commitment in the current architecture: a token gets one
class and therefore one future predictive state. A long-lived latent variable
(language, productive word family, grammatical role) cannot in general be
recovered from the last token alone. Expanding that class into ordinary order-2
states has already been screened. The new target is a **predictive posterior**
state, compiled into a deterministic decoder machine.

The proposed sequence is:

1. Fit a generative source with exact or bounded latent inference at encode time.
   Sum over compatible analyses; do not force a stem, token boundary or donor
   word into the delivered stream merely because training used one.
2. Find a small set of predictive states. Each stores a quantized output CDF;
   each decoded symbol maps the current representative to another representative.
   Crucially, evaluate this closed machine's own rollout. Mapping true teacher
   posteriors at every encoder prefix would leak an unavailable runtime oracle.
3. Share equivalent rows and factor transitions; optionally compile frequent
   deterministic spans into output-copy edges. The archive pays for these
   tables and strings, but need not contain the training teacher if decoding
   never uses it. A big teacher alone is not the contribution.
4. Choose model topology using complete bytes and measured decoder work. The
   v4 transducer already supplies table-driven output; the novel hypothesis is
   a different *learned state space*, not calling an existing table an automaton.

The loss budget is explicit:

```
candidate bytes = compiled model + coded surface + restarts + framing
modeling losses = source-model error + state-merge error + integer quantization
```

State approximation is allowed to hurt prediction, never byte reconstruction.
Both ends use the identical integer model. It must remain total on arbitrary
input bytes, and any budget fallback must be represented in that model.

## A compositional target: fragments that carry predictive state

The next hypothesis unifies the grammar and the predictor, rather than adding
a predictor beside a fixed phrase dictionary. A fragment has two interpretations:

* its exact output bytes;
* a transfer operator on uncertainty about the source.

For an edge-emitting finite-state source, let `M_b[i,j]` be the probability
of emitting byte b and moving from hidden state i to j. Each source state's
mass sums to one across all bytes and destinations. Then

```
M_xy       = M_x M_y
P(w | q)   = q M_w 1
next(q, w) = q M_w / P(w | q)
```

Matrix multiplication sums over internal hidden states. The grammar's existing
concatenation DAG can therefore prepare both bytes and predictive summaries;
a repeated stem or phrase need not replay every byte through the predictor or
reset it to an arbitrary last-word class. This is established weighted-automaton
algebra, not a new mathematical discovery. The research question is whether its
structure can be learned and represented economically enough for this codec.

There are two important constraints. First, an arbitrary bag of overlapping
words is not a normalized emission alphabet. A complete prefix code gives a
valid variable-length alphabet; marginal transduction is another, more expensive
route. Second, a finite block can end inside a macro. Its final partial phrase
needs an explicit coding rule and byte charge, not an assumed word boundary.

The independent exact-rational implementation in `oracle/operators.py` checks
composition, grammar-DAG reuse, fixed-length normalization, prefix-code
normalization, and posterior preservation. Combined with the renewal oracle,
15 tests pass. These tests establish algebra, **not a compressed artifact**.

### The inverse-CDF need not evaluate every phrase

For an ordered complete macro alphabet, prepare

```
r_w = M_w 1
R_k = sum_{w before k} r_w
CDF(k | q) = q R_k
```

Binary search requires `O(H log P)` scalar work for H hidden states and P
phrases, followed by one `O(H²)` update for the selected phrase. It does not
require P matrix-vector products. The cumulative vectors can be derived during
preparation rather than serialized redundantly, but their resident memory and
preparation work must still be measured. `PrefixCDF` tests exact agreement with
the full matrices, including zero-mass intervals and boundary cases.

### Learn where context can safely be forgotten

Some long fragments strongly constrain the destination state. For a positive
operator, write `r = M_w 1` and `P[i,j] = M_w[i,j] / r[i]`. If all rows of P
are close to a shared distribution v, replace the operator by

```
M_hat[i,j] = r[i] v[j]
```

This keeps the probability of the current fragment **exact for every incoming
belief** q, while approximating its outgoing belief. It requires two H-vectors
instead of an H-by-H matrix. Fragments that retain context cannot be collapsed
this way without loss; those retain richer summaries. Approximation changes
future code lengths, never the reconstructed bytes, provided both ends use
the same delivered integer model.

This is a concrete form of an adaptive predictive reset, not a language-specific
rule such as "forget after a space". The `operators/` experiment measures
row dispersion, closed-rollout prediction error, and charged representation
cost. A weak source that is easy to collapse is not a successful compressor.
The resulting model still has to beat v4's complete bytes, not merely its own
uncompressed matrices.

[Exponential stability of HMM filters](https://mural.maynoothuniversity.ie/id/eprint/12732/)
and [memory-decay estimation](https://arxiv.org/abs/1710.06078) motivate checking
contraction rather than assuming every fragment needs an equally rich state.
Their inference results are not text-compression speed results. Exact
diagonal-plus-low-rank byte matrices also do **not** imply fixed-rank phrase
products; the `prediction/` algebra probe explicitly tests that failure mode.

### How current research changes the experiment, not just its vocabulary

[Transducing Language Models](https://arxiv.org/html/2603.05193v1) supplies the
right interpretation for ambiguous token-to-byte maps: sum compatible token
paths, maintain a causal frontier, and enforce finite progress. This supports
the actual weighted-emission experiment rather than storing every observed
surface word and calling that marginalization.

[H-Net](https://arxiv.org/html/2507.07955v1) learns when to spend computation at
a coarser level. The transferable idea is a causal, learned division of work,
not its large neural implementation or a claim that representation downsampling
equals lossless compression. Here the division is decided by a fragment's
predictive summary and measured residual uncertainty.

[IconoCLaSM](https://arxiv.org/html/2103.10150v3) interleaves state-space bits-back
operations so initial seed cost need not grow with sequence length. It corrects
the simplistic objection that an entire hidden path must be sent up front.
It still requires usable posterior conditionals and entropy operations; the
paper itself notes direct marginal coding is more efficient for its HMM test.
We must measure the concrete schedule, not attribute inference-free decoding
to the name "ANS".

[Lossless Tensor Compression as Program Synthesis](https://arxiv.org/html/2608.02162v1)
illustrates moving search to the encoder and delivering a typed, bounded,
self-contained reconstruction program. Its tensor results do not transfer
numerically to words. The relevant test here is whether an expensive learner
can deliver a small fragment machine that needs none of that search at decode.

The remaining hard problem is model quality per delivered byte. Elegant
algebra cannot create linguistic predictability that the learned source misses.
The live experiments therefore separate source error, state approximation,
integer coding, model size, and actual execution, rather than reporting one
favorable entropy estimate as a breakthrough.

### Sources that materially changed this direction

* [Suresh et al., approximating probabilistic models as WFA](https://arxiv.org/abs/1905.08701)
  derive KL-oriented approximation onto a chosen automaton topology. Their
  experiments also show a severe topology bottleneck: distillation is not a
  magic way to fit a rich predictor into an inadequate state graph. This is why
  our experiment changes the reachable predictive states, not only row weights.
* [Liu et al., latent-variable distillation](https://arxiv.org/abs/2210.04398)
  use encoder-side neural representations to initialize tractable latent models,
  then refine marginal likelihood. That suggests an expensive teacher can shape
  a cheap delivered model. Their large benchmark models do not establish that
  a small self-contained dictionary frame will benefit.
* [Chiu and Rush, sparse-emission HMMs](https://arxiv.org/abs/2011.04640)
  bound active hidden states using emission structure. Our relevant question is
  whether lexical output constrains uncertainty enough for a small compiled
  state graph; their large-model perplexity is not a storage or speed result here.
* [Su et al., tensor-train language models](https://arxiv.org/abs/2405.04590)
  motivate compact multiplicative state interactions. Their practical model
  computes normalized conditionals; a tensor contraction alone is not an
  automatically normalized byte distribution. This remains an encoder-model
  option, not evidence for a quantum or exponential compression advantage.
* [Pimentel et al., lexicon optimality](https://arxiv.org/abs/2104.14279)
  distinguish word-form regularity from the heavy-tailed frequency of word use.
  This supports separate training statistics for a form generator and its reuse
  process, rather than assuming English stemming. Their linguistic code-length
  analysis is not a byte-exact archive benchmark.

No current candidate has beaten the retained v4 record. In particular, silent
class transitions in v4 consume many bits but are not all removable overhead:
they convey uncertainty about which class occurs. Merging those decisions into
one lookup can reduce work without removing their information cost.
