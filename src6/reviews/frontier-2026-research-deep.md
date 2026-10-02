# Compression architecture research for book and prose gains

Research note for the 2026 frontier experiments. This is a design survey, not
a claim that any listed approach beats bzip3. The acceptance objective is the
complete delivered file (including model, tokenizer, selector, restart/index,
and checksums), with full lossless decoding from a fresh process. Source-byte
identity, UTF-8 validity, and Unicode normalization are never assumed.

## Evidence labels

- **Local implementation/evidence** means source, executable, or report is
  present in this workspace and can be inspected. It does not mean every
  historical measurement is independently reproduced.
- **Primary citation** means the original paper or official implementation is
  identified. Where network access prevented opening the source during this
  pass, this is bibliographic guidance rather than a fresh verification.
- **Paper/repository claim** is not a benchmark result for this project.

The configured network proxy returned HTTP 403 for the original BWT report,
publisher DOI endpoints, and Princeton-hosted material during this pass. I
therefore separate the directly inspectable local evidence from bibliographic
references; I do not report the inaccessible papers as newly verified.

## Architecture families and what their delivered model costs

| Family | Primary reference or implementation | Decoder-side burden and actual cost | Useful experiment / falsifier |
|---|---|---|---|
| Byte BWT + MTF + run coding | Burrows & Wheeler, *A block-sorting lossless data compression algorithm*, DEC SRC RR-124 (1994); local `src6/experiments/bzip4/results/README.md` | BWT inverse needs a suffix/rank structure; MTF needs a rank-update structure. The model is algorithmic, but every restart and payload is paid. Existing local byte-BWT/MTF/rANS frames lost to matched bzip3 in all six rows, including +22.35% on OMW Japanese at 64 KiB. | Do not rerun byte BWT. Test an integer surface-token alphabet or a field-aware reversible transform only if table+index bytes are included and a lower-bound screen predicts a material whole-file margin. |
| PPM / escape models | Cleary & Witten, “Data compression using adaptive coding and partial string matching,” IEEE Trans. Communications 32(4), 396–402 (1984), DOI 10.1109/TC.1984.1676474 | Adaptive PPM stores no learned corpus model, but decoder reproduces every update and escape decision; update cost and context memory can dominate. Static PPM transmits its counts. Sparse resets and restart checkpoints cost bytes. | Build a byte/word PPM-D order-4/6 contender only as an actual whole-file codec, with bounded hash/trie context state, deterministic integer rescaling, and resets only at charged boundaries. Falsify if memory or per-symbol decode work exceeds the target, or whole bzip3 remains smaller. |
| Context-tree weighting (CTW) | Willems, Shtarkov & Tjalkens, “The context-tree weighting method: basic properties,” IEEE Trans. Information Theory 41(3), 653–664 (1995) | Online mixture prediction is decoder-reproducible with no trained model bytes, but each bit updates a context tree and requires identical integer probability arithmetic. A byte alphabet needs a decomposition (e.g. bitwise tree) and can multiply work by eight. | Compare byte-bit CTW against PPM and bzip3 on held-out book prose; freeze a maximum depth, node budget, and integer update law. Count all nodes/allocations and measure decode. No external learned weights. |
| Context mixing / PAQ / CMIX | Byron Knoll, `cmix` v21 release; local review in `src6/reviews/frontier-2026-research.md` | The reviewed PAQ/CMIX implementations combine match, order-N, sparse, and word contexts, and their decoders reproduce predictor and mixer updates. The measured configurations have substantial RAM and decode costs, but those costs are implementation- and profile-specific rather than inherent to context mixing. Arithmetic in the reviewed CMIX build is sensitive to floating-point/compiler details; any reproducible integer format must specify its arithmetic. | Use these implementations as reference comparisons if runtime permits, not as upper bounds on a different self-contained codec. A low-cost subset test should ablate each context on book prose and retain it only if full encoded bytes improve after model-state work is bounded. |
| LZ77/LZSS sliding matches | Ziv & Lempel, “A universal algorithm for sequential data compression,” IEEE Trans. Information Theory 23(3), 337–343 (1977); “Compression of individual sequences via variable-rate coding,” IEEE TIT 24(5), 530–536 (1978) | No delivered dictionary is needed for online LZ77, but decoder must execute match copies; distance/length coding and window size are format parameters. Larger windows help book-wide repetition while increasing memory and match search costs. | Compare a 1–8 MiB exact-byte rolling match backend plus a small entropy-coded literal stream to bzip3. For dictionaries, reset only at the actual desired random-access boundary; for whole-book goals, long history is a plausible source of >20% gains. |
| LZMA-style match + literal contexts | LZMA SDK / XZ format documentation and source; `xz` command is an available control | Decoder carries probability states for literal/match/length/distance, usually with a large range of model memory. The format parameters may be compact, but RAM/window cost is substantial. | Existing xz9 is a whole-stream control. A native equivalent is only useful if it improves size and bounded decoder cost; do not infer a “new word codec” win from xz. |
| Grammar compression (Re-Pair / Sequitur) | Larsson & Moffat, “Off-line dictionary-based compression,” Proc. DCC 1999, 296–305; Nevill-Manning & Witten, “Identifying hierarchical structure in sequences: a linear-time algorithm,” JAIR 7 (1997), 67–82 | Each rule costs a definition, symbol widths, ordering, and expansion work. Re-Pair parse choice may be cheap to decode but naive rule IDs/large inventories are costly. Adaptive grammars need serialized deterministic choices or a decoder-reproducible pair queue. | Keep grammar only where exact full-frame MDL selects it. For prose, test byte/word sequence grammar against bzip3 and charge rule table, selector, expansion work, and restarts. Existing local result: grammar+symbol-BWT has wins on some long 8 MiB blocks but loses on multilingual prose and whole-file bzip3. |
| BPE / pair merges | Sennrich, Haddow & Birch, “Neural machine translation of rare words with subword units,” ACL 2016, P16-1162 | A merge table and token-to-byte expansion are part of the model. Decoder work is small, but a tokenization model trained on the corpus must be sent unless shared externally. Greedy BPE tokenization is not generally minimum-cost under an entropy coder. | Use BPE as a candidate alphabet, not as a claim of compression: search merge count by complete encoded size, compare merge-rank vs optimal DP parse, and retain exact byte fallback. Stop when dictionary+merges exceed savings. |
| Unigram-LM segmentation | Kudo, “Subword regularization: Improving neural network translation models with multiple subword candidates,” ACL 2018, P18-1007; SentencePiece official implementation | Unigram token probabilities/vocabulary are model bytes; Viterbi segmentation is cheap. Marginalizing multiple parses is useful for neural training, but a deterministic lossless wire must transmit the selected parse or reproduce a deterministic exact coder. | Fit a compact unigram segmentation lexicon on the encoder data, transmit it, then actually entropy-code tokens. Compare Viterbi-best with exact DP under the final static model; no entropy-estimate-only acceptance. |
| Morphology-aware segmentation | Creutz & Lagus, Morfessor Baseline (2005) and Morfessor 2.0 (2013) | Stem/affix inventories and each boundary/feature are side information. A decoder-side morphological analyzer is an uncharged external model unless embedded. Orthographic allomorphs, clitics, diacritics, and Unicode byte preservation are difficult. | Use analyzers/UD lemma-features only as encoder proposals; turn accepted segmentation into literal source spans plus paid IDs/residuals. Compare exact complete frames on Finnish/Turkish/Arabic dev. If affix tables do not repay bytes versus bzip3, reject the linguistic prior. |
| N-gram LM with quantized probabilities | Heafield, “KenLM: Faster and Smaller Language Model Queries,” Proc. EMNLP 2011, 187–197; official `kpu/kenlm` | Trie/probing layout and quantized probability/backoff values trade bytes for lookup speed. A language model trained elsewhere is uncharged for compression unless serialized. Decoder-side forward scoring may need unbounded history or explicit state reset. | Use KenLM-style quantized trie as a reference for compact predictive tables, not as a codec. A promising codec needs a transmitted/static suffix table and a canonical integer entropy coder, then must beat full bzip3 with all tables included. |
| Neural byte/token LM coding | Delétang et al., “Language Modeling Is Compression,” ICLR 2024, arXiv:2309.10668; official Google DeepMind repo inspected in existing `frontier-2026-research.md` at commit `b5c8f8a63349d0a2604367d47df4a7c79db52890` | The model weights/tokenizer are generally assumed shared. Exact autoregressive prediction requires identical tokenizer, weights, runtime, logits, and probability quantization. Encoder can batch logits; lossless decoder is sequential and expensive. | Treat it as a reference point for prediction quality and report model bytes, runtime, and decoder cost. It is not an upper bound on a self-contained codec unless its weights, tokenizer, runtime requirements, and exact probability decisions are all charged. Distill only selected decisions into compact tables/automata embedded in the file. |
| LLM-based compression (`llama-zip`) | Official `AlexBuz/llama-zip` repo, pinned in the existing review at `d682e5edc73cee3535a22f3699cf62e5ca6f6264` | Large GGUF weights, tokenizer and model execution are required at both ends but are not included in the compressed stream. It uses deterministic token prediction and arithmetic coding; decoder cost is model inference per token. | Use only as a model-assisted reference for book prose, and report model bytes/RAM separately. It is not a bound on a self-contained codec unless quantized weights, tokenizer, runtime requirements, and exact decoder behavior are charged. An embedded-model experiment must include quantized weights and tokenizer bytes in its actual frame. |
| Learned probability table / tiny distilled predictor | Derived from CTW/PPM and neural LM coding; no external model needed in the wire | Encoder may use a teacher, but decoder receives a compiled decision tree or sparse context table of integer frequencies. Every node, feature, exception, fallback and quantized probability is paid. Decoder work is table lookups plus rANS/range decode, not neural inference. | Most promising near-term direction: distill teacher/proposal contexts into a bounded integer context trie; prune each branch by exact frame MDL, serialize the remaining model, and compare to bzip3. Evaluate on unseen book chapters after frozen dev-derived policy. |
| Corpus-trained Zstandard dictionary | Zstandard CLI/API official documentation and local native controls | Dictionary is a separate model; its bytes are often omitted from one-shot comparisons. Trained dictionary helps small related samples but may overfit the training corpus; dictionary ID alone is not the dictionary. | Already use zstd19 controls. Where a shared archive dictionary is permitted, count dictionary once in the archive and test held-out chapters from the same declared collection. Keep whole-stream and random-page layouts distinct. |
| Bidirectional / sentence orientation | Reversible sequence reversal is an algorithmic transform; no universal win is implied | Reverse-before-coding changes which side becomes causal. A global orientation costs a selector; per-sentence orientation costs at least one decision per sentence plus sentence boundaries/index. A noncausal backward predictor cannot be queried without a second pass or transmitted parse. | Compare whole-file forward, reverse, and fixed interleaving. Then test independently parsed sentences with per-sentence orientation, including boundary/index cost. Require exact punctuation/whitespace and a selector that is independent of held-out results. |

### Recent source-level neural evidence (not a codec result here)

The `ayaan-cs/neuralzip` repository at immutable commit
[`e3dc12e8`](https://github.com/ayaan-cs/neuralzip/tree/e3dc12e86f7d3cf621222cbfae34538f1ccbcabc)
is more useful as an architecture than as a performance claim. Its inspected
`neural.py`, `models.py`, `mixing.py`, `codec.py`, and CLI show a byte GRU
initialized from a fixed seed and trained online on already-coded bytes, a
Witten–Bell/PPM-C context ladder, an exact-context match expert, online
geometric expert mixing, integer CDF quantization, and arithmetic coding. No
trained weights are sent: decoder updates after each decoded byte. The GRU
does truncated BPTT and Adam after 16 bytes; the coder assigns every byte
frequency at least one. Its README reports 1.262 bits/byte on a 517,537-byte
English sample, but also reports about 2.2 KB/s, roughly 200 MB growing
context state for that 517 KB sample, and 32 MB for its match table. Those
are repo-reported, not independently reproduced, figures. Its README/source
also warns about same-hardware/software determinism because GRU training uses
floating-point operations. This is a strong proof-of-possibility for causal
online learning without trained-weight bytes, but not a ready codec or a
portable implementation.

The pinned `zhubinghui/LLM_Compression` README at
[`48a37740`](https://github.com/zhubinghui/LLM_Compression/tree/48a377407e442fbf433dedff6064282262598524)
claims about 0.94 bpb on Enwik8 using SmolLM2-135M and a five-model mixture.
The same README says the GGUF model is about 538 MB and is loaded by both
compressor and decompressor. Its headline output ratio therefore excludes a
model much larger than the 95 MB input; classify it as an external-model
external-model reference point, not a self-contained codec or an upper bound on an archive that must carry its model. The README's 0.76-bpb claim
below its own trigram entropy bound is internally inconsistent with a
lossless coder on the same source, so discard that claim pending source and
measurement audit. A separate 2025/26-looking `gbrova/llm-text-compression`
repo explicitly warns that its content is AI-generated; its token-rank
proposal is not evidence until the implementation and accounting are
independently checked.

The pinned `jacobvm04/llm-compression` repository at
[`ed278291`](https://github.com/jacobvm04/llm-compression/tree/ed2782918eab2534a2972f621c0014f07f74bbfa)
is a useful negative implementation audit. Its source loads Qwen2-0.5B and a
Hugging Face tokenizer by model name, repeatedly retokenizes the growing
prefix and recomputes a next-token distribution at each position, then
Huffman-codes token IDs. The README calls it a proof of concept and its sample
run takes minutes for roughly 600 tokens. The probability model, tokenizer,
token-sequence assumptions and inference runtime are all external; repeated
prefix recomputation is quadratic in sequence length. It is not a self-
contained compression result. The token-rank idea is still useful if ranks
come from an explicit transmitted distribution or deterministic adaptive
model and the complete tokenizer/model costs are included.

The current `LuRenJiasWorld/RWKZ` source at
[`b4a42463`](https://github.com/LuRenJiasWorld/RWKZ/tree/b4a4246353391c1a621bd6ac292edd2ce29e20ca)
describes a next-token arithmetic coder around a quantized RWKV-7 0.1B
checkpoint. Its README's recommended Q4_K_M model is 127 MB; it is downloaded
separately and is not counted in the `.rkz` output. Its table is based on
2,000 bytes of English prose, where Q4_K_M reports 3.02 bits/byte. That is
not a whole-file result or a fair bzip3 comparison, and its README's claim
that “full-file bpb is lower” than short-file bpb due to fixed header
overhead has the overhead direction backwards. Treat it as evidence that a
recurrent LM still needs large shared weights and can have weak short-file
prediction—not as a compression win. The source claims 32-bit integer coding
with F32 model inference and cross-machine determinism; exact cross-hardware
prediction identity still needs independent validation.

The `neuralzip` GRU source demonstrates a different and more transferable
principle than “compress with an LLM”: the state can be learned online from
already-decoded bytes. The wire then needs only a model identifier/parameters
that are fixed by the format, and the evolving weights are reconstructed by
the decoder. But the model is causally synchronized only if every update is
bit-identical. Its source uses floating point, NumPy, Adam, and platform BLAS;
it explicitly warns that different BLAS rounding can desynchronize the file.
Its costly learned state also grows with input. So the technically defensible
small-codec abstraction is to retain online adaptation while replacing the
float GRU with exact integer state and a deterministic bounded memory policy.
That is an experiment to build, not a result established by `neuralzip`.

#### Integer online mixture budget

For synchronized experts with integer CDFs `F_j(x | h)` and a common total
`Q`, a normalized integer mixture uses
`F_mix(x | h) = round(Σ_j w_j F_j(x | h))`, followed by monotone repair so
every symbol has frequency at least 1 and the total is exactly `Q`. The
arithmetic coder uses `F_mix`; after the symbol is decoded, each expert and
the mixer update deterministically. For a Bayesian mixture with fixed prior,
ideal real-valued log loss is at most `log2(K)` bits above the best fixed
expert over the entire stream. A discounted/gradient mixer can follow drift,
but forfeits that exact static-regret statement. Real coded length also pays
CDF rounding, termination, framing and checksum bytes. This gives a clean
ablation target: keep the same byte/token models and compare a fixed-prior
integer mixture against the current static model, while reporting model-state
RAM and per-symbol work. It does not permit subtracting a teacher's external
model loss from bzip3 output.

## Source audit: what PAQ/CMIX offers and what to borrow

I inspected CMIX v21 at pinned commit
[`194af9cd`](https://github.com/byronknoll/cmix/tree/194af9cd133b8b741d2a53afca13ed0ca453c276),
including `src/predictor.cpp`, `src/context-manager.cpp`,
`src/mixer/mixer.cpp`, and `src/coder/encoder.cpp`. This is a source audit,
not a compression result on our books. `Predictor::AddMixers` wires word
contexts, byte-prefix contexts, indirect tables, PPMD, PAQ8/FXCM, and multiple
match models into several layers. `ContextManager::UpdateContexts` updates
their states after each decoded bit and byte; this adaptive state is causal
and does not require a transmitted corpus model. The range coder derives a
16-bit split from each predicted bit probability and then both sides update
the same models.

The useful mechanism is conditional specialization: separate learned weight
vectors for distinct observed contexts combine word, byte, match, and
auxiliary predictions. The costs explain why copying CMIX is not practical.
`mixer.cpp` uses floating-point dot products and logistic-error gradient
updates, `pow` for learning-rate decay, plus AVX/FMA and scalar arithmetic
paths. CMIX's README warns that `-Ofast -march=native` may break
cross-computer compatibility. The configured `ContextManager` allocates a
100,000,000-byte history and a `256*8,000,000`-byte shared map before
per-context state; its README recommends at least 32 GB RAM. PAQ8 contains
15-bit integer SSE tables, but its public model interface emits floats into
the CMIX float mixer, so this is not a drop-in integer wire design.
The PAQ8 source's `APM1` is a more direct calibration precedent: it keeps 33
U16 probability cells, selects adjacent cells from the stretched predictor
probability, linearly interpolates, then shifts both cell values toward the
observed bit using an integer learning-rate update. Its larger `APM` maps
24 probability bins per context and stores a 32-bit prediction/count state.
More exactly, APM1 stretches `pr` into a signed-logit range, uses
`((pr+2048)>>7) + context*33` for the lower knot and `pr & 127` as the
interpolation weight, then returns
`(t[i]*(128-w)+t[i+1]*w)>>11`. On the next call it updates those two prior
U16 cells toward `g=(y<<16)+(y<<rate)-y-y` using `(g-t)>>rate` (default rate
7). Initial rows copy a shared 33-knot logistic curve. CMIX's source mixer
selects a separate learned weight vector by the current context key for each
first-layer mixer, then passes those outputs through higher mixer layers.
However, the stretch/squash lookup table is generated with double math in
`src/mixer/sse.cpp`; a portable codec must freeze exact integer tables and
signed-shift semantics rather than assume cross-platform determinism. This
mechanism audit is pinned to CMIX v21; `src/models/paq8.cpp` SHA256
`8d902a7f07b817b3940597d33c807636ca55debbfe9e05b9351defb138e7ba95`,
`src/mixer/sse.cpp` SHA256
`843b10a1fa5037238f50289abe7375b8b1a2ebc9432317a3cc875bd8f356046d`.

An inexpensive portable falsifier should keep only the mechanism:

1. Use four causal integer predictors for each MSB-first source bit: short
   byte-prefix KT, bounded exact-word-ID context, punctuation/script/boundary
   class, and prior exact-match bit with confidence indexed by match length.
   Invalid UTF-8 remains literal; each bit update happens only after that bit
   is decoded.
2. Give these predictors fixed-prior online Bayesian weights. For outcome
   `y`, update `w_i' ∝ w_i * (p_i if y=1 else 1-p_i)` on a specified integer
   scale with deterministic right-shift rescaling. Predict with the normalized
   integer weighted average. The `log2(K)` static-regret guarantee belongs to
   exact real-valued Bayesian mixing; integer approximation must be measured.
3. Test a small probability-calibration table after mixing: 4,096 contexts ×
   32 bins × 2-byte Q15 estimates costs 256 KiB of deterministic decoder
   state. Context can combine a quantized base-probability bin with one compact
   causal category. Update estimates with a specified signed integer rule,
   e.g. `p ← clamp(p + ((y·Q-p) >> r), 1, Q-1)`. Fix row caps, collision,
   initialization, and all eviction behavior. This state is reconstructed
   from decoded input, not transmitted, but its peak memory and per-bit work
   still count against decoder constraints.
4. Convert probability to a frozen integer range split with nonzero
   frequencies, exact rounding/remainder convention, byte order, termination,
   raw length and checksum. First compare measured ideal bits to matched
   whole-file bzip3 on all six DEV sources; reject if the headroom does not
   cover coder/frame costs. Then encode complete files and verify fresh exact
   decode before claiming a result.

This tests a gap left by the current fixed integer mixture: whether expert
reliability changes with recent causal context and can be calibrated cheaply.
Do not infer CMIX's compression ratio from this reduced design; it omits the
large expert inventory and floating-point runtime deliberately.

## Candidate architecture to test for large whole-file prose gains

The historical results make another phrase inventory alone an unlikely route
to a 20% whole-file win. In the frozen WordFrontier quality profile, complete
frames beat whole-file bzip3 on OMW Chinese (−35.36%), OMW Japanese (−19.89%),
and GCIDE (−2.26%), but the prose lane remains 7.66% larger. The outcome is
substantial in some dictionary lanes and still short of the book/prose goal.
The initial LXB1 whole-file screen also rejects a simple integer token-BWT
route at 128 KiB: all 126/126 candidate frames fresh-decoded exactly, but the
best complete frame remained larger than whole bzip3 on English/French
(5,901 vs 5,499 B), GCIDE (31,821 vs 26,861 B), and Japanese (12,282 vs
10,487 B). It charged vocabulary, model, LXB framing, zstd-9 payload, and
used a fresh bzip3 1.5.1 whole-file control. It covered byte, capped word,
and UTF-8-scalar subword alphabets; lexical/frequency/first-use IDs; forward,
reverse and line-reverse directions; and direct versus integer-BWT/Fenwick
MTF/zero-run coding. The frozen protocol and source/binary hashes are in
`/workspace/scratch/lexical-bwt-initial-128k-20261001/protocol.json`;
these are DEV storage results, not speed rankings. That negative makes a
dynamic predictive model or a stronger long-range match model a more
promising next step than another vocabulary/order/byte-BWT grid.
An independent 1 MiB scale gate on the same-source integer-BWT architecture
had only small isolated wins: English/French byte-BWT 34,270 vs35,571 B
(−3.66%), Japanese subword-direct 47,888 vs48,022 B (−0.28%), while GCIDE's
best transformed row still lost by 1.31%. It tested 12 exact full frames and
is frozen at `/workspace/scratch/lexical-bwt-scale-1m-20261001`. The result
does not justify an 8 MiB BWT expansion; the remaining owner screen changes
the alphabet to whole-word IDs and exact separators, a distinct representation
to be evaluated separately.
The proposed causal word-context route has an even earlier lower-bound
diagnostic. A Unicode-exact 1 MiB screen over FreeDict/GCIDE/OMW modeled
word-and-separator token entropy with first-use spellings paid. Best ideal
estimates were 167,614 B, 306,048 B, and 118,501 B respectively—already far
above the known native M frames. It omits arithmetic-coder rounding, frame,
terminator, checksum and decoder work. These are model-specific idealized
estimates, not encoded sizes or rigorous lower bounds on every possible codec.
Policy used context orders
1–4, 32,768 LRU rows/order, at most 16 successor types/row, prior mass 8,
integer weight grid 1/2/4/8; source IDs, policy and results are recorded by
Sol6's `word_order_screen.py` (`f9bc3bdb…` results). The sparse context-only
route should not get a native implementation slot on these corpora unless a
verified match expert or another evidence-backed model changes the bound.

The same ideal screens now cover six complete-book development sources or
fixed 1 MiB prefixes (manifest SHA256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`).
For the exact-word model, per-source minima were 185,580 B (Pride and
Prejudice), 284,007 B (War and Peace prefix), 299,386 B (Don Quijote prefix),
224,279 B (Madame Bovary), 41,783 B (Die Verwandlung), and 190,095 B
(Kokoro). For the separate byte model with causal PPM plus an exact-match
expert, minima were 174,504, 270,451, 276,281, 191,696, 36,559, and 102,436 B
in the same order. The word-model evidence is
`src6/experiments/grammar_automaton/evidence/word-order-ideal-books6.json`
(model SHA256 `1d01c0278e90b7ab37474f10f58248ceb59d0ccc1f0859106a6c902e807b6b25`);
the byte evidence is
`src6/experiments/grammar_automaton/evidence/byte-ppm-ideal-books6.json`.
These are ideal probability scores, not frames. The byte mixture essentially
ties the best PPM order, while exact-match alone loses; that weakens the case
for implementing the mixture before a sharper bound or a small true-frame
screen. Exact-source bzip3 controls now cover all six inputs: whole books for
Pride and Prejudice, Madame Bovary, Die Verwandlung, and Kokoro, plus matched
1 MiB prefixes for War and Peace and Don Quijote. The PPM ideal estimate
already exceeds those controls on every input: respectively 174,504 vs
161,119 B (+8.31%); 270,451 vs 247,364 B (+9.34%); 276,281 vs 252,940 B
(+9.23%); 191,696 vs 179,597 B (+6.74%); 36,559 vs 35,251 B (+3.71%); and
102,436 vs 97,505 B (+5.06%). Whole-book and prefix controls are kept
separate in
`/workspace/scratch/books2026-dev/controls/controls.json` and
`/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json`.
These model scores still do not establish that a finite
arithmetic/range-coded codec will beat bzip3.

A distinct class-factored bigram estimator used the same six-book manifest,
paid separator and rare-word sidecars, grouped front-coded vocabulary,
bigram count rows, and a 64-byte nominal header. Its K=32, 8,192-word
vocabulary estimate exceeded whole-file bzip3 on all six sources:
Pride and Prejudice 174,253 vs 161,119 B; War and Peace 806,885 vs 732,272 B;
Don Quijote 548,762 vs 500,612 B; Madame Bovary 209,810 vs 179,597 B; Die
Verwandlung 39,587 vs 35,251 B; and Kokoro 105,500 vs 97,505 B. The largest
individual cost is Kokoro's 101,124 B rare-word escape sidecar. This is a
development estimator, not a bitstream or guaranteed entropy lower bound;
the exact per-event scores and paid sidecars are at
`/workspace/scratch/books2026-dev/class-factor-estimate-k32-v8192.jsonl`
(SHA256 `b41c972d277b9d75999b9403667ee1d57f69dbac21bd21153ea9b29a2157ecd0`).
Because it already loses before native decoder engineering, building this
specific K32 design is not justified. A different class-history depth or
assignment criterion would be a new hypothesis and must recompute every table
and byte cost on the same frozen sources.

The next bitwise expert-mixture ideal scorer is also negative. It quantized
probabilities to Q=4096 and mixed seven causal experts: partial-byte KT,
direct-mapped previous-byte contexts of orders 1/2/4/8, a current-word-byte
signature, and an exact prior-8-byte match expert. Bayesian posterior expert
weights were shrunk by 1/1024 toward uniform after each bit. The best
individual expert was byte-order 8 on all six files, while the mixer was
larger than matched bzip3 everywhere: 191,205 vs 161,119 B for Pride and
Prejudice, 292,908 vs 247,364 B for the War and Peace prefix, 293,741 vs
252,940 B for the Don Quijote prefix, 208,866 vs 179,597 B for Bovary,
37,928 vs 35,251 B for Kafka, and 110,165 vs 97,505 B for Kokoro. The
order-4/8 direct maps had high collision counts; for example the Pride
order-8 context reported 4,172,317 collisions. This is a quantized ideal
score, not a serialized codec. It rejects this fixed table/weight policy; a
context-conditioned APM is a distinct follow-up, not evidence that the current
mix can beat bzip3. A controlled Austen precision ablation moved Q from 4096
to 65,536: byte-order-8 improved only 29.62 B, while the mixture worsened
15.01 B, leaving the roughly 16.7 KB mixture gap attributable to model
structure rather than CDF precision. The match expert improved 28,413 B with
finer quantization but still trailed byte-order-8 by about 21 KB. Evidence is
`src6/experiments/grammar_automaton/evidence/bitmix-q-precision-austen.json`
(SHA256 `87c6f4a3aeff444b44694c6cd4b081251633022cedeffc00104ac27522464231`).
Frozen six-book evidence is
`src6/experiments/grammar_automaton/evidence/bitmix-ideal-books6.json`
(SHA256 `3a281c25b5918cd9ab5b6e89f7fd163eb335cf035b9f95e573f4a3545174c32e`).

The follow-up source-only CCM1 tested a Q15 causal conditional-logit mix and
PAQ-style probability calibration. Its best mixed ideal bytes still exceeded
matched bzip3 on every 1 MiB-prefix/complete-book input: Pride and Prejudice
168,763 vs 161,119 B; War and Peace 260,146 vs 247,364; Don Quijote 263,843
vs 252,940; Bovary 187,541 vs 179,597; Kafka 36,453 vs 35,251; Kokoro
102,973 vs 97,505. Conditional logits improved the six-book aggregate
relative to its global predecessor on five of six cases, but adding APM
degraded every case. The bounded exact-tag table had 0.54–6.30 million
replacement events per file and ~57–58 MiB fixed state plus source, so
capacity pressure is also material. It stopped at the pre-registered headroom
gate; no frame or decode speed was measured. Evidence is
`src6/experiments/grammar_automaton/context_mixer/evidence/ccm1-six-prefix.json`
(SHA256 `3a598ad8c1260a8d8f6e292a4397f24a8971bfb7fff16668719a0bd2919f0097`).
Together the global, conditional-logit, and APM ablations show that directly
transferring a bit mixer has not created sufficient information gain on this
corpus; the next hypothesis needs a representation or predictor that changes
the residual structure, not another mixer grid.

Two further fixed headroom probes were negative. A depth-0–3 class-history
extension on the same six sources still lost whole-file bzip3 by 13,162,
74,644, 48,180, 30,246, and 4,367 B on the Latin works; Kokoro's best was
depth 0 and lost by 7,954 B. War and Peace depth 3 spent 18,712 B on rows,
162,537 B on the model, and 227,243 B on oracle class bytes; even granting the
row table for free left a 39,786 B loss. This was a source-only estimator, not
a native frame (`/workspace/scratch/books2026-dev/class-factor-depth-k32-v8192.jsonl`,
SHA256 `d2c3875a58336573559d053ab7c955f87892e9a26b50beb391c165d95df83595`).

A two-whole-word-hole phrase-template probe searched complete DEV books for
repeated fixed-token skeletons with two word slots. It gave War and Peace the
largest proxy saving, 10,388 B (1.42% of its 732,272 B bzip3 frame), then Don
Quijote 4,726 B, Pride and Prejudice 347 B, and Bovary 636 B; Kafka and Kokoro
were each −129 B. These are not frame costs: the score subtracts a 12-bit
template event from a static-unigram anchor, assumes the two slot costs
cancel, and charges only 128 B of model plus one mode byte. Even the largest
proxy is too small to justify a wire implementation under that optimistic
accounting. Evidence is
`src6/experiments/structural_wordcodec/evidence/phrase-books-six-two-slot.jsonl`
(SHA256 `591c8ab2fb2764e0bd4fe84377e3e72df8084ad82e3cb74df447aac45bb2d416`).

A separately frozen source-only PPM8 plus exact-prior-span LZ probe charged
copy-site flags, donor distance/rank, length, and literal costs. On six book
prefixes, adding this match expert changed estimated size from 174,504 to
174,505 B (zero copies) for Pride and Prejudice; 270,451 to 270,357 B (16
copies, 5,769 copy-eligible source bytes) for War and Peace; 276,281 to
276,282 B for Don Quijote; 191,696 to 191,697 B for Bovary; 36,559 to
36,590 B for Kafka; and 102,436 to 102,437 B for Kokoro. The only useful
residual is 94 B on the War and Peace prefix, before a frame or range coder.
The exact-span expert does not rescue the rejected PPM estimate. Evidence is
`src6/experiments/grammar_automaton/evidence/lz-ppm-ideal-books6.json`
(SHA256 `75fa2e26e85090ce5e5eb4d266c735c12e790c3478d87fc40f98879b94a121ff`).
This excludes the byte-PMM-plus-context-mixer follow-up, which is a different
predictor architecture and remains only a candidate until its integer
probability state and full-file frame are implemented.
The most plausible high-upside route is a **two-level predictive codec**:

1. Tokenize losslessly into lexical spans, punctuation/space runs, and exact
   byte fallback. The tokenizer is a reversible transform; it may propose
   Unicode scalar/word boundaries but never normalize, delete, or infer bytes.
2. Assign each first-seen token its next ID and emit its exact source bytes
   under an escape. Later occurrences use that ID. This is a causal dynamic
   lexicon: the spelling is already present in the original source, so there
   is no second learned-lexicon copy to transmit. The vocabulary grows
   identically at encoder and decoder.
3. Use a bounded order-4/6 word-and-byte context predictor with sparse
   backoff (PPM/CTW-like) and a long-distance exact-match lane. The model is
   adaptive, so its counts are learned from the shared prefix rather than
   sent as a static table. Context keys may include previous lexical IDs,
   byte-class/script tags, and a boundary marker; all updates remain causal.
4. For expert distributions `p_j(x|h)` and fixed prior weights `w_j`, code
   with `p(x|h)=Σ_j w_j p_j(x|h)`. A normalized Bayesian mixture pays at most
   `log2(K)` ideal bits more than the best one of K fixed experts over the
   stream. Quantize this distribution to a canonical integer CDF of total Q,
   give every symbol frequency at least one, and use one specified remainder
   allocation at both ends. If weights adapt or discount old observations,
   measure actual bytes: the fixed-prior regret guarantee no longer applies.
   Rescale adaptive counts at a fixed threshold.
5. If an offline teacher is used, let it rank contexts/tokens on training
   data, then transmit only a sparse explicit integer context table whose
   realized byte savings beat its complete table cost. The decoder must not
   load the teacher, invoke a tokenizer package, or depend on float logits.
6. Optimize the complete frame objective directly: header + model or reset
   policy + literal first occurrences + selector + sentence/block boundaries
   + coded data + checksums. Candidate pruning may use estimated cross
   entropy, but final selection must encode the entire file with each model.

### Falsifiable first screen

Use fixed, previously explored development material only; do not inspect the
reserved PUD structural holdout. Start with the same 8 MiB content/prose slices
already used for controls, then add book chapters once root restores/pins them.
For each lane compare:

- whole-file native bzip3, bzip2, zstd19, xz9;
- current WordFrontier full-file quality frame;
- causal word PPM/CTW without teacher;
- teacher-proposed, table-distilled version with exactly the same wire and
  complete source/table charging;
- direction variants only as separately recorded full frames.

Freeze token rules, max context count, context depth, count quantization,
minimum branch gain, reset rule and resource cap before final data. Reject the
predictive model if it fails to beat whole-file bzip3 by at least the agreed
margin on book/prose DEV after all model bytes, or if decoder memory/update
work exceeds the production budget. A compression-size success on one
language does not establish multilingual robustness.

## Highest-information experiments, in order

1. **Model-cost curve, not a single teacher point.** Serialize progressively
   pruned tables (e.g. 1K/4K/16K/64K contexts) and plot full bytes against
   decoder memory and symbols/s. This exposes the actual model-size Pareto
   frontier and whether the teacher's gain survives distillation.
2. **Causal hybrid context.** Compare previous words only, previous bytes
   only, and a mixed word/byte context. Keep an explicit unknown-word escape
   and exact fallback. Charge lexical inventory. Natural prose tests whether
   longer repeated phrase context adds more than its IDs cost.
3. **Direction and boundary ablation.** Global forward vs reverse; exact
   sentence resets vs no resets; global orientation vs per-sentence choice.
   A per-sentence choice is accepted only when saved payload exceeds selector
   and boundary bytes on multiple dev corpora.
4. **Adaptive versus static.** Adaptive counts remove a transmitted frequency
   table but pay update work; static tables pay model bytes but may decode
   faster. Test both complete formats with the same context definition.
5. **Teacher reference, correctly accounted.** Run a pretrained neural compressor
   as a model-assisted reference and list model footprint and execution cost.
   Then distill only its high-value context decisions into the bounded integer
   model. Never subtract an external-model estimate from a native codec output.

## Joint segmentation and probability selection

For a tokenizer vocabulary `V`, merge/segmentation program `G`, token path
`z`, and downstream context model `M`, the actual objective is

`L(frame) = L(V) + L(G) + L(boundaries/selectors) + L(M) + L(z | M,G) + L(exact residual bytes) + L(frame/index/checksums)`.

This explains why fixed-count BPE is a poor codec objective: a high-frequency
merge may reduce the number of tokens while making `V`, `G`, or the token
entropy table larger. It also explains why unigram EM's token likelihood is
not itself the answer. The tokenizer's EM objective is a marginal likelihood
under a fitted segmentation model, while the codec must send a particular
parse, the learned model, and all residual/source-boundary information.

For a **static** model with integer token costs `c(t,context)` derived from
the exact final CDF, a unigram tokenizer admits an exact DP over byte
positions: `D[j] = min_i (D[i] + c(token(x[i:j])) + residual_cost)`. Add model
description length and framing outside that DP, enumerate a fixed candidate
inventory/merge set, and actually encode every complete frame. With an
order-k model, the parse's last k token IDs become DP state; exact search can
grow exponentially, so use a bounded beam only as a parse proposer, then
report the actual complete frame. With an **adaptive** model, each parse
changes future counts and context states; independent local Viterbi decisions
do not minimize final code length. The honest first use is to let BPE/Unigram
propose a small lattice, select under a frozen static integer model, and
verify with the real encoder.

An MDL merge admission test can cheaply reject obvious candidates. Let
`S_merge` be the sum of measured downstream byte savings for occurrences
under the current exact integer model, and let `C_merge` include the spelling,
merge ID/order, token-map change, every parse selector, and table/index change.
Only test `S_merge > C_merge + margin`; then recompute the model and whole
frame because merges alter context counts globally. Do not greedily freeze a
merge from cross-entropy alone. The actual outer-loop screen should consider
the complete original bytes and reject any result that depends on a trained
tokenizer not included in the frame.

## Word classes: what a class model can and cannot save

Brown, Della Pietra, deSouza, Lai & Mercer, “Class-based n-gram models of
natural language,” *Computational Linguistics* 18(4), 467–479 (1992), is the
primary class-clustering source. Brown's adjacent-class mutual-information
criterion is a way to propose clusters; it is not itself a compressed-frame
objective. A codec must also code the class map, class-history model,
within-class word rank, and every selector/table byte.

The information-theoretic headroom makes an early screen possible. Let `W_t`
be a word ID, `H_t` its previous `d` exact word IDs, `C_t=g(W_t)` a
deterministic class assignment, and `C_H=g(H_t)` the previous class IDs. A
class-history factorization that codes class then word rank as
`P(C_t|C_H) P(W_t|C_t,C_H)` has ideal data code length:

`H(C_t|C_H) + H(W_t|C_t,C_H) = H(W_t|C_H)`.

The equality follows from `C_t` being determined by `W_t`. Relative to a full
word-history conditional model, the class abstraction loses
`H(W_t|C_H) - H(W_t|H_t) = I(W_t;H_t|C_H) ≥ 0` bits per token. If the
within-class word rank is simplified further to `P(W_t|C_t)` with no prior
class context, its ideal excess is

`I(W_t;H_t|C_H) + I(W_t;C_H|C_t) ≥ 0`.

Classes do not create information-theoretic savings over an ideal full
word-history model. Their possible win is finite-model engineering: fewer
history rows and smaller context alphabets may reduce serialized table size,
generalization error, or lookup cost enough to pay for approximation loss,
the class map, and within-class rank. Before implementing a native codec,
compute these held-development cross-entropies and the exact byte lengths of
the planned assignment/rank tables. If `map + tables + selectors +
N·H(W|C_H)` already exceeds the target by more than the remaining model
coding or match savings, reject the architecture.

For a neural teacher, use it only to propose cluster assignments: group words
with similar outgoing next-token probability vectors or hidden states, then
encode the class map and estimate `H(W|C_H)` on disjoint development works.
Teacher scores/embeddings are not delivered decoder dependencies. A small
sparse quantized table is the student model; its measured loss and all table
bytes decide. Brown's co-clustering can seed the same optimizer, but final
cluster selection should minimize the full frame objective, not class bigram
mutual information alone. Goodman, “A Bit of Progress in Language Modeling,”
*Computer Speech & Language* 15(4), 403–434 (2001), reviews class-based
language models alongside other factorizations.

## Reproduction and citation notes

Locally inspectable project evidence includes `src6/experiments/bzip4/results/README.md`,
`src6/experiments/wordgrammar/RESULTS.md`, `src6/reviews/frontier-2026-research.md`,
`src6/reviews/frontier-2026-results.md`, and the primary codec source files.
The DeepMind and llama-zip commit pins above are from the existing source audit.
The classic primary citations are included to anchor mechanisms; due to the
current HTTP 403 egress failure, check DOI/page details against publisher or
official archives before copying this section into a formal publication.

During this follow-up, GitHub's explicitly allowed raw-content and git
endpoints were reachable. I fetched the following **official README/source
files at immutable commit IDs** (these verify repository behavior, not paper
claims or compression gains):

- [SentencePiece README at `6f38173d`](https://raw.githubusercontent.com/google/sentencepiece/6f38173d30bf84f83cf68ddda027f731a248f06f/README.md): describes BPE and unigram models, raw Unicode input, whitespace escaping as `▁`, and model training/storage. Thus its model is real side information; tokenizer runtime is small, but the trained model is not free.
- [subword-nmt README at `92d6139d`](https://raw.githubusercontent.com/rsennrich/subword-nmt/92d6139d07d30e12735a0af9e7f7f925ebe62c54/README.md): the basic pipeline writes merge codes to a separate `codes_file`, later passed to `apply-bpe`. This directly confirms the merge list must be charged or shared explicitly in a codec.
- [KenLM README at `4cb443e6`](https://raw.githubusercontent.com/kpu/kenlm/4cb443e60b7bf2c0ddf3c745378f76cb59e254e5/README.md): `lmplz` estimates modified Kneser-Ney models and the query implementation supports distinct binary data structures. This makes KenLM useful as a model/query design reference, not a delivered lossless frame by itself.
- [Zstandard README at `01b7154f`](https://raw.githubusercontent.com/facebook/zstd/01b7154f1172432f8abe9b3bb9909e14a1176b7d/README.md): explicitly says a trained dictionary is stored as a separate file and must be loaded on both sides. Dictionary gains primarily affect the initial data, with ordinary LZ history taking over later. Any trained-dictionary comparison must count that file.
- [cmix README at `194af9cd`](https://raw.githubusercontent.com/byronknoll/cmix/194af9cd133b8b741d2a53afca13ed0ca453c276/README): identifies version 21, recommends at least 32 GB RAM, and warns that `-Ofast -march=native` can break cross-computer compatibility through floating-point differences. This supports treating CMIX as a strong resource-heavy whole-file reference, not as a small deterministic decoder design.
- The previously inspected [DeepMind implementation](https://github.com/google-deepmind/language_modeling_is_compression/tree/b5c8f8a63349d0a2604367d47df4a7c79db52890) and [llama-zip](https://github.com/AlexBuz/llama-zip/tree/d682e5edc73cee3535a22f3699cf62e5ca6f6264) remain pinned in the earlier research note. Their external pretrained weights/tokenizers explain why their reported compressed streams do not include model cost.

These source checks sharpen the practical boundary: BPE/unigram/LM models can
give the encoder a useful segmentation or probability prior, but a native
codec has to embed their effective tables/merges or use a deterministic
adaptive update. A model name or small ID in the frame does not carry the
model's information.
