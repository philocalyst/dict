# Primary-source synthesis

The design question is not whether a large language model predicts text well;
it is whether a small, charged, static machine can retain enough of that
predictability to improve first-use lexical spelling while keeping decoding
bounded and deterministic.

## Prediction/compression frontier

Delétang et al., *Language Modeling Is Compression* (2023), establishes the
prediction/compression equivalence and measures the very strong compression of
large neural models.  It is an upper-bound/failure-mode reference here: an
uncharged or unavailable neural predictor cannot be used by this codec, but
the result motivates measuring bits per byte rather than token counts alone.
The proposed generator is a deliberately tiny, static approximation, and its
serialized model cost must be paid in the frame.

Primary source: [Delétang et al. 2023](https://arxiv.org/abs/2309.10668).

## Type segmentation and productive spelling

Kudo's unigram language-model tokenizer chooses a vocabulary and uses a
shortest-path segmentation rather than greedily merging the most frequent
adjacent pair.  SentencePiece makes this approach language-independent and
reversible at the raw-sentence interface, including scripts without spaces.
Those papers are not lossless-compression formats, and they normally optimize
token prediction rather than a charged archive.  The transferable mechanism
is the *global segmentation objective*: choose a type segmentation under a
frozen inventory, then price the inventory and boundary stream.

Primary sources:

- [Kudo, “Subword Regularization” (ACL 2018)](https://aclanthology.org/P18-1007/)
- [Kudo & Richardson, “SentencePiece” (2018)](https://arxiv.org/abs/1808.06226)

Morfessor 2.0 is an explicit MDL-style morphology learner.  The current W2
lane's pair-merging threshold is not equivalent: it optimizes local pair
counts and then repairs the parse, whereas an MDL/unigram objective prices a
shared segment's inventory cost and all uses jointly.  Smit et al. describe
the toolkit; Creutz/Lagus' recursive MDL model is the earlier formulation.
The prototype borrows only this objective and uses no language dictionary or
external analyzer.

Primary source: [Smit et al., “Morfessor 2.0” (EACL 2014)](https://aclanthology.org/E14-2006/).

Morphology is not uniformly helpful across languages.  Mielke et al.,
*Morphology Matters* (TACL 2021), compare character, BPE, Morfessor, and
finite-state segmentations across 92 languages: Morfessor improves over BPE
for most languages, but not all.  This supports an explicit multilingual
held-out matrix and a script-safe byte fallback rather than assuming Latin
stems generalize.

Primary source: [Mielke et al., “Morphology Matters” (TACL 2021)](https://aclanthology.org/2021.tacl-1.16/).

## Byte/script safety

ByT5 demonstrates that byte-level modeling avoids language-dependent
pre-tokenization and is robust to noise, while paying a longer sequence cost.
SentencePiece likewise emphasizes non-segmented Japanese and a self-contained
model.  For this lane the consequence is strict: the scanner may use only
deterministic byte classes for candidate boundaries; it must preserve invalid
UTF-8, combining marks, mixed scripts, casing, whitespace, and NUL exactly.
Unicode normalization is neither free nor permitted.

Primary source: [Xue et al., “ByT5” (TACL 2022)](https://aclanthology.org/2022.tacl-1.17/).

## Static finite-state prediction

Willems, Shtarkov, and Tjalkens' context-tree weighting (1995) formalizes the
model-cost/coding-cost tradeoff for bounded-memory sources.  CTW is sequential
and adaptive, so it is not copied directly.  Its useful lesson is to charge
model redundancy and prune contexts by a held-out/MDL objective.  H2 uses a
frozen context tree and merges states with the same quantized continuation
row; no probability counts change during decoding.

Primary source: [Willems, Shtarkov & Tjalkens, “The context-tree weighting method” (IEEE TIT 1995)](https://www.cs.cmu.edu/~aarti/Class/10704_Spring15/CTW.pdf).

Duda's ANS paper describes entropy coding as a finite-state automaton whose
table can be stored once and approaches arithmetic-coding rates without a
per-symbol adaptive distribution.  The current v4 tANS rows already use this
kind of frozen entropy table; the new idea is to give a separate, type-weighted
spelling transducer its own rows, not to rebrand tANS as a new predictor.

Primary source: [Duda, “Asymmetric numeral systems” (2013)](https://arxiv.org/abs/1311.2540).

For a stronger but impractical reference, Lacroce, Panangaden, and Rabusseau
study approximate minimization of weighted finite automata for language models.
Their spectral/Hankel method is far beyond this bounded lane, but it supports
the principle that a finite-state approximation should be chosen against an
explicit distance/size budget, not by adding context states ad hoc.

Primary source: [Lacroce et al., “Extracting Weighted Automata for Approximate Minimization in Language Modelling” (ICGI 2021)](https://proceedings.mlr.press/v153/lacroce21a.html).

## Latent-state distillation and exact Markov inference

Liu, Zhang, and Van den Broeck show a practical way to initialize tractable
probabilistic circuits by distilling latent assignments from a stronger
teacher, then fitting and fine-tuning the PC.  Their HMM language-model
example is directly relevant to a future spelling state machine: useful
structure can be compressed into finite hidden states while the decoder only
needs the resulting tables.  The teacher is not part of this lane and cannot
be queried during decoding; any distilled state transitions/emissions would
have to be serialized and charged.  In particular, a final-position or script
label supplied from the source would be side information, not a latent state.

Primary source: [Liu, Zhang & Van den Broeck, “Scaling Up Probabilistic Circuits by Latent Variable Distillation” (2024)](https://arxiv.org/html/2210.04398v2).

Chiu and Rush revisit HMM language models with sparse/block emissions and
exact forward inference.  Their blocked-emission constraint bounds the number
of states that can emit each observed symbol, making exact marginalization
cheaper.  The reported models still use tens of thousands of states and
neural parameterizations, so this is a mechanism reference rather than a
claim that a charged small codec can copy their scale.  The next tractable
experiment would share transitions across spelling positions and account for
the transition table explicitly, rather than adding independent per-position
character rows.

Primary source: [Chiu & Rush, “Scaling Hidden Markov Language Models” (2020)](https://arxiv.org/pdf/2011.04640).

## ANS, variable-to-fixed coding, and latent state

Baer's generalized Tunstall construction is the relevant variable-to-fixed
reference.  For Markov sources it builds multiple parsing trees for source
states; a hidden boundary belief is not automatically one of those finite
states.  A complete prefix-free macro inventory can cache matrix products, but
the phrase CDF remains belief-dependent unless finite context rows are
compiled.

Primary source: [Baer, “Efficient Implementation of the Generalized Tunstall Code Generation Algorithm” (2009)](https://arxiv.org/abs/0809.0949).

Townsend, Bird, and Barber introduce BB-ANS: the ANS stack can recycle bits
used to sample a latent from an approximate posterior, but the first item
needs clean seed bits and the coder needs prior/likelihood/posterior CDFs.
Townsend and Murray extend this to state-space models by interleaving
bits-back steps (IconoCLaSM), avoiding the naive requirement to sample an
entire latent path before coding.  For a finite HMM, ordinary predictive ANS
with a forward belief filter is already tractable; state-space bits-back still
requires conditional posterior CDFs and does not make the belief vector free.

Primary sources: [Townsend, Bird & Barber, “Practical Lossless Compression with Latent Variables using Bits Back Coding” (2019)](https://arxiv.org/abs/1901.04866), [Townsend & Murray, “Lossless compression with state space models using bits back coding” (2021)](https://arxiv.org/abs/2103.10150).

Snæbjarnarson et al. formalize exact marginalization through finite-state
transducers and show why transformed-prefix frontiers can grow without finite
quotients or pruning.  This supports the oracle's operator-cache algebra but
does not provide a free static decoder model.

Primary source: [Snæbjarnarson et al., “Transducing Language Models” (2026)](https://arxiv.org/abs/2603.05193).

## What is and is not claimed

These sources motivate the composition, not a claim that the composition is
published.  The lane uses no pretrained model, dictionary, neural network,
Unicode normalization, or free tokenizer.  Cross entropy is diagnostic only;
promotion requires complete frame bytes and independent decoding.
