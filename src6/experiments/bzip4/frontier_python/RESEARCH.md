# Research direction and falsifiable hypotheses

The relevant objective is not bytes per token in isolation. For a charged
language model, minimize `model + restart metadata + coded events`, while
keeping the number of serial decoder decisions small. Longer inferred phrases
can reduce both entropy events and decode decisions; a phrase dictionary that
grows faster than those savings reverses the benefit.

Three distinct costs should remain visible:

* **Prediction:** probabilities of the next event. A neural model can improve
  this term but introduces inference and parameter-distribution cost.
* **Representation:** choosing events that already explain many output bytes.
  Grammar, word, phrase and template methods act here; the decoder can expand
  them without repeating the encoder's expensive discovery.
* **Addressability:** how much of that representation must be initialized or
  decoded for one query. A globally trained model does not require globally
  dependent payloads if each payload restarts against an immutable model.

This suggests compiling an expensive encoder's learned regularities into a
small immutable expansion vocabulary, with a regular integer-coded event
stream. This is an engineering direction in the established dictionary/grammar
family, not a claim of a new algorithm. It must be compared with the simpler
BWT/rANS and relative-LZ controls before adding template argument machinery.

## Primary sources informing experiments

[Language Modeling Is Compression, ICLR 2024](https://proceedings.iclr.cc/paper_files/paper/2024/hash/3cbf627fa24fb6cb576e04e689b9428b-Abstract-Conference.html)
connects prediction and lossless coding and discusses tokenization. It motivates
counting a token vocabulary as part of the compressor rather than treating
tokenization as a free preprocessing step.

[Compression via Pre-trained Transformers, ICML 2025](https://proceedings.mlr.press/v267/heurtel-depeiges25a.html)
explicitly accounts for parameters and evaluates out-of-distribution data. Its
competitive experiments still use millions of parameters; this does not prove
that running a transformer is suitable for a portable low-latency dictionary
reader. Our experiment tests whether useful learned structure can instead be
stored as directly expandable fragments.

[Stable Local Consistency and Parallel Grammar Processing, SEA 2025](https://drops.dagstuhl.de/storage/00lipics/lipics-vol338-sea2025/html/LIPIcs.SEA.2025.14/LIPIcs.SEA.2025.14.html)
constructs grammars from local parsing and merges independently constructed
grammars. Its grammar simplification and repeated-rule postprocessing suggest
that block independence and global sharing can coexist. Its genome results
cannot be transferred to dictionary language without measurement.

[Grammar Compression with Probabilistic Context-Free Grammar](https://arxiv.org/abs/2003.08097)
separates grammar structure from probabilistic choice. It motivates testing a
small grammar plus entropy-coded choices, but richer parse choices also create
more decoder state and require explicit serialized probabilities.

[RLZ-RePair reference implementation](https://github.com/rvarki/RLZ-RePair)
is a useful baseline for combining relative factorization with grammar
compression. A shared-reference-plus-grammar combination is established prior
art; our novelty assessment must not relabel it as an invention.

[Frequency-Ordered Tokenization, February 2026](https://arxiv.org/html/2602.22958v1)
tests BPE IDs ranked by frequency before conventional compression. Its reported
overhead explicitly describes the frequency mapping while its decoder assumes
an existing tokenizer; that does not establish a self-contained vocabulary
charge for our setting. Its own Python decoding table also reports slower
end-to-end decoding, and its BWT control does not improve. We use this as a
baseline hypothesis, not evidence that tokenization automatically solves the
storage and latency problem. Our prototype must carry every expansion byte.

## What would falsify the direction

If dictionaries, escape literals, entropy tables and independent block framing
consume the supposed savings on all three corpora, a larger vocabulary alone
is the wrong model. If speed requires pre-expanding a huge dictionary, charge
startup and resident memory, and test a cold block. If only the duplicated OMW
projection improves, retain it as a repetition-specific result. If a diagnostic
standard-codec backend supplies all improvement, the transform has not yet
established an independent decoder.

## Follow-up: preserve repetition while changing the alphabet

[Kärkkäinen, Mikkola and Kempa, 2012](https://www.cs.helsinki.fi/u/tpkarkka/publications/spire2012.pdf)
study grammar precompression before BWT to reduce transform/inverse work. Their
pair-selection invariant matters for our builder: simultaneously selected
pairs must not overlap. Otherwise greedy substitutions can encode repeated
substrings inconsistently and remove the redundancy the next stage needs.
They construct a nonoverlapping family greedily, assigning symbols disjoint
left/right roles. Their timings excluded entropy coding and used whole-file
blocks, so their speed figures are not evidence for our full framed codec.

[Moffat and Isal, 2005](https://doi.org/10.1016/j.ipm.2004.08.009)
already studied word IDs followed by BWT, recency ranking and entropy coding,
including the cost of transmitting the dictionary. Therefore the root-symbol
BWT experiment is an evidence-driven application of prior art, not a newly
invented compression principle. Our measured questions are bounded independent
blocks, a shared byte-exact grammar, complete state costs, and decoder work.
