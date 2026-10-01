# Segmentation lane proposal (v0, 2026-09-26)

> Historical first proposal.  The requested bleeding-edge lane superseded
> this best-path control with the weighted-emission marginal coder described
> below; `unigram_interval.zig` remains only as a baseline artifact.

## Scope and falsifiable claim

This lane owns only this directory.  It will prototype a replacement for the
two `grow()` loops in `bz4/v3/src/learn.zig`: a lexical unigram parse followed
by a phrase parse.  The proposed mechanism is a **fixed-policy candidate
unigram inventory + deterministic Viterbi resegmentation + weighted interval
phrase parse**.  It emits the existing `bz4.Parse` shape and therefore does not
change the decoder or wire format.

The claim is deliberately modest: on at least one untouched 64--256 KiB
dictionary slice, lexical Viterbi should reduce the *complete* v4 frame by
>=1% versus `learn.learn` at the same `plan.fit` policy, after charging the
entries, rows, selectors, definitions, padding, and headers.  If it does not,
the lexical stage is rejected.  Phrase interval parsing is tested as a second
ablation; it is rejected if it cannot improve a frozen lexical parse on a
held-out slice.  Synthetic multilingual/mixed-script and random/no-repeat
controls must round-trip exactly; no model may be selected per corpus.

## What is structurally new here

The current learner and W2 use bottom-up pair counting: choose a frequency
threshold, merge a batch of adjacent pairs, and repeat.  Lane M's earlier
experiment is a generic byte-seeded n-ary MDL grammar with its own codec; Lane
Z1 adds a separate class model.  This lane instead does the following:

1. Keep the existing lossless atomization (maximal same-kind runs for
   letters/digits, singleton other bytes; bytes >= 0x80 remain data, never
   Unicode-normalized).  The atom boundaries are only candidate fences; all
   bytes are preserved.
2. Enumerate bounded substrings (byte spans inside an atom and bounded atom
   n-grams inside a block) before any merge decision.  A candidate is retained
   by one corpus-independent policy: maximum span, minimum type/occurrence
   count, and a deterministic first-occurrence tie break.
3. Fit a unigram inventory by coordinate descent.  Given piece costs, each
   atom is segmented by a left-to-right Viterbi DP; counts are re-estimated
   from those paths, and candidates whose explicit model-plus-corpus MDL gain
   is negative are removed.  Repeat a fixed number of rounds and freeze the
   best objective round.  There is no greedy pair merge and no hidden
   dictionary/tokenizer.
4. Convert each frozen atom path into one `Parse` entry.  For phrase candidates,
   run weighted interval DP over non-overlapping occurrences in each block,
   scoring a span against its component-token costs plus a fixed definition
   charge.  This is a global parse of the candidate forest, not Re-Pair's
   locally most-frequent merge.
5. Send the exact parse through current v4 `plan.fit`/`encode`; this actual
   frame is the acceptance score.  Entropy/MDL scores are diagnostics only.

The decoder knows only the resulting normal v4 model and `Parse` definitions:
it does not know candidate counts, Viterbi scores, language/script labels, or
the training corpus.  Model cost is paid by normal `ARITY`/`NAME`/`DEF`, rows,
bucket IDs, and references.  Existing bounded decoder checks remain in force.

## Expected mechanism and savings

Greedy pair merging cannot revisit a locally attractive pair after the pair's
children acquire new counts, and it creates intermediate one-use rules.  A
unigram inventory can choose a 6-byte piece over three separately frequent
pairs, or reject that piece when its spelling/definition charge dominates;
Viterbi can also choose different coverings of the same word.  The phrase
interval pass can select a long repeated span without paying all intermediate
binary rules.  A 1--3% frame reduction is the screen target, with the largest
expected effect in dictionary spelling (`delta`) and repeated short phrases;
JSON/random controls may regress and are reported, never substituted for
language results.

Front coding (`CUT`) is optional but deterministic: when enabled, a new atom
entry may reference the longest prefix among the previous fixed window of
already-defined entries only when the same frozen MDL price policy says it
pays.  The no-CUT ablation is retained so a gain cannot be attributed to
rebranding existing CUT machinery.

## Primary sources (method anchors)

* Creutz & Lagus, *Unsupervised Morpheme Segmentation and Morphology
  Induction from Text Corpora Using Morfessor 1.0* (2005 report):
  [PDF](https://users.ics.aalto.fi/mcreutz/papers/Creutz05tr.pdf).  Sections
  3--4 make the MAP/MDL equivalence explicit and use a split-tree search with
  Viterbi-style best segmentation; this lane borrows the global objective and
  deterministic DP but prices the final v4 frame separately.
* Kudo & Richardson, *SentencePiece* (EMNLP 2018):
  [ACL PDF](https://aclanthology.org/D18-2012.pdf), and Kudo,
  *Subword Regularization* (2018):
  [arXiv](https://arxiv.org/abs/1804.10959).  Their unigram LM keeps a
  candidate vocabulary and chooses segmentations by path probability rather
  than pair merges; this lane uses deterministic MAP/Viterbi, not sampled
  segmentations or an external model.
* Goldwater, Griffiths & Johnson, *A Bayesian framework for word
  segmentation: Exploring the effects of context* (Cognition 2009):
  [author PDF](https://sites.socsci.uci.edu/~lpearl/courses/readings/GoldwaterGriffithsJohnson2009_ContextBayesianWordSeg.pdf).
  The unigram/bigram comparison motivates treating the phrase stage as a
  context-aware parse, while the current v4 past buckets supply the deployed
  recurrence model after parsing.
* Brent, *An Efficient, Probabilistically Sound Algorithm for Segmentation and
  Word Discovery* (Machine Learning 1999):
  [arXiv](https://arxiv.org/abs/cs/9905007).  Its corpus-level probabilistic/MDL
  objective supports charging lexicon and segmentation jointly without a
  language-specific tokenizer.

These papers do not claim the composition used here.  Their published model
costs are not substituted for the actual v4 frame size.

## Cheap falsification experiment (run before broad implementation)

1. Build the isolated harness against Zig 0.16 and the existing v4 sources.
2. On each 64 KiB and 256 KiB untouched slice, produce four parses under one
   frozen policy: current `learn.learn`; lexical Viterbi only; phrase interval
   only over the current lexical parse; and both stages.  Run each through
   `plan.fit` and real `encode`, then decode and byte-compare.
3. Record command line, Zig/compiler version, input/output SHA-256, frame
   length, and `Stats`/entry counts.  Reject the mechanism if lexical-only is
   not >=1% smaller on a held-out dictionary slice or if its apparent MDL gain
   vanishes in complete-frame bytes.  Preserve all losing rows.
4. Run a held-out mixed byte fixture containing UTF-8 (including combining
   marks), CJK/Arabic/Cyrillic, ASCII casing, invalid UTF-8, NULs, all
   whitespace classes, and random bytes.  Require exact round trips and no
   unbounded recursion/candidate growth.  A deterministic no-repeat fixture
   is a negative control and must not gain by inventing a large vocabulary.

No timings are used for promotion in this bounded screen; long timing runs
require coordination with the root agent.

## Superseding marginal-emission design

The current headline experiment is `weighted_emission_coder.py`, not the
unigram interval parse above.  A bounded vocabulary of unique byte pieces is
serialized with positive integer weights.  The latent source is an iid token
renewal stream, truncated at a decoder-visible raw length.  A trie frontier
represents every token start that can still cross the observed prefix; terminal
mass becomes a boundary/root mass and descendant mass stays on the frontier.
This is the finite piece-emission specialization of the exact transformed-LM
frontier in Snæbjarnarson et al., *Transducing Language Models* (2026,
[arXiv:2603.05193](https://arxiv.org/abs/2603.05193)).

The charged wire has two comparison modes: prefix-MAP token IDs and exact
surface-byte marginal arithmetic coding from the merged frontier.  It stores
no observed surface-atom dictionary.  A 64-bit E3-safe arithmetic coder,
header parser, independent decoder, exhaustive tiny-prefix oracle, and
multilingual/invalid-byte controls are all isolated here.  The complete
64-KiB web2 result is MAP 34,415 bytes versus marginal 33,138 bytes with the
same 3,761-byte header; this is a new-wire result, not a v4 `plan.fit` claim.
The fixed two-round EM ablation (`--max-vocab 256 --em-rounds 2`) fits expected
piece usages including a final partial piece and charges the resulting integer
weights in the header.  Full commands, hashes, exact-vs-quantized costs, and
negative controls are in `MARGINAL_GAP.md`.
