# Productive paradigm spelling: a charged, byte-exact screen

Status: design and bounded screen, 2026-09-26. This lane owns this directory
only. `screen.py` is an isolated wire-format experiment; it does not silently
claim to be the current `bz4` format.

## Hypothesis

The current v4 representation can copy one contiguous prefix (`CUT`) from a
recent definition, and its learner grows adjacent byte pairs. A dictionary
has a different kind of repeated identity: several whole word types can be
related by the same finite edit pattern even when their shared material is
not one prefix. Examples include a stem alternation, a circumfix, an infix,
or a root-and-pattern relation. If these relations recur, spelling a new
type as a checked edit transduction of an earlier type can pay for the parent
ID and edit program with fewer bytes than spelling the new type.

The candidate is deliberately a whole-word relation, not a claim that the
input has gold morphological analyses. It discovers relations from exact
bytes and charges false or accidental relations just like real ones.

For a parent byte string `p` and target `t`, an accepted relation is a finite
program over `p`:

```
COPY(n)       copy the next n bytes from p
INSERT(bytes) append literal bytes
DELETE(n)     skip n bytes of p
SUB(bytes)    replace the next |bytes| bytes of p
END
```

The program is acyclic and non-recursive. It has a checked source cursor,
target length, operation count, and output budget. A target's parent must
already be decoded in the selected lexicon order. Thus the decoder knows the
parent bytes and every operation before producing output; it never calls an
external dictionary, tokenizer, Unicode normalizer, or language model.

The first implementation works on bytes rather than Unicode scalar values.
That is intentional: invalid UTF-8, combining marks, mixed scripts, and
embedded NULs remain representable and round-trip exactly. The scanner uses
the current v4 learner's byte policy (ASCII letters or bytes `>= 0x80` as a
letter run, ASCII digits as a digit run, all other bytes as literal
separators). A later variant may expose UTF-8 code points as an optional
candidate, but it must retain this byte path and can only win after charging
its validation/side data.

This policy is deliberately comparable across the English and OMW slices, but
it is not a Japanese morphological tokenizer: whitespace-free CJK text can
become a long high-bit run, reducing the chance of discovering useful
word-family edges. OMW results therefore test byte-exact multilingual
robustness and the cost ledger, not coverage of Japanese lemmas. A code-point
or language-aware segmentation variant must be evaluated as a separately
charged candidate and must preserve the original byte stream.

## Decoder and cost model

The screen's independent, deterministic wire format is intentionally simple
enough to audit and re-decode:

```
frame := magic/version/raw_len/type_count/order/model_len/payload_len
         dictionary records
         payload records
dictionary record (independent): tag, byte_length, bytes
dictionary record (CUT):         tag, parent_delta, keep, suffix
dictionary record (EDIT):        tag, parent_delta, template_id, op params
dictionary record (PROGRAM):     tag, parent_delta, template_id, exceptions
payload record (literal):        tag, byte_length, bytes
payload record (word):           tag, word_id
```

Every integer is an unsigned LEB128 value and every tag/opcode is one byte.
The frame includes a header and a four-byte payload CRC. The CRC is not
security; it catches accidental round-trip mistakes. The prototype's
`frame_bytes` therefore includes the header, dictionary record tags and
lengths, relation parent IDs, template table, literal op bytes, payload tags
and IDs, CRC, and any alignment padding (none is omitted). The unchanged
separator bytes are encoded as literal payload records. The independent and
`CUT` controls use the same type order and payload representation.

The source order is a policy, not a free oracle:

* `first`: types occur in first-appearance order; an edge can only point to
  an earlier type and the parent delta is charged.
* `lex`: types are byte-lexicographic; an edge can only point to an earlier
  lexicographic type. Payload IDs are lex ranks, so there is no hidden
  permutation; if a caller asks for first-use IDs, the explicit permutation
  is charged.

The screen's frozen admission policy is: candidates come from a deterministic
length/first-byte index, edit distance is bounded by four edits, ties prefer
`COPY`, then `SUB`, then `DELETE`, then `INSERT`; an edge is retained only if
its complete record is smaller than the independent record. Edit-operation
shapes that occur at least twice share a template. The template table is
charged once before any edge gets credit. No candidate is selected by looking
at the measured result after the fact. The output reports both an unshared
script upper bound and the shared-template result. `screen.py` also has a
`program` mode: it turns recurring edit geometry into a reusable template
(`COPY` lengths, `DELETE` lengths, fixed `SUB` lengths, or a parameter-free
`COPY_REMAINDER`) and charges only exception literals and the parent ID per
edge. A variable `INSERT` still carries its length and literal bytes. This is
the productive-program candidate; `edit` is the less aggressive opcode-shape
control.

The complete size is reported as

```
header + dictionary records + template/model table + payload + CRC + padding.
```

The relation ledger also reports the number of edges, parent-ID bytes,
opcode/parameter bytes, literal insertion/substitution bytes, template bytes,
and payload bytes. A reduction in a lexicon-only estimate is not promoted as
a compressed-size result.

## Why this is structurally new here

`CUT` can only retain the first `k` bytes of one child and then continue with
the suffix. It cannot copy a second span, substitute an internal byte, delete
a medial span, or share a relation program across unrelated stems. The v4
BPE spelling grammar merges recurring adjacent byte pairs; W2's real-price
pruning showed that this does not remove the hapax spelling floor.
The proposed relation is a parent-word DAG with a bounded edit transducer and
explicit source-ID pricing. A plain prefix relation is retained only as a
control and is reported separately from novel multi-span/substitution
relations.

An optional second representation is a minimal acyclic word automaton
(DAFSA/MAWA) for the exact word-type set. It is built from the frozen byte
lexicographic order and minimized bottom-up. It replaces independent word
labels only if `graph + edge labels + terminal/order data` is smaller than
the explicit dictionary records. The automaton cannot be treated as a free
oracle: graph topology, labels, terminal bits, and any mapping from payload
IDs to enumeration order are all charged. The screen therefore compares the
DAFSA spelling model and its payload-ID costs separately; it does not combine
the graph with edit edges until a measured model proves that composition is
cheaper.

## Shared generative-set candidate

The parent-ID tax in a per-word edit forest is not the only possible
factorization. `generative_screen.py` implements a separately framed PGS1
candidate whose lexicon model is a set of generated forms:

* a signature is a fixed byte template with one contiguous stem
  (`prefix + stem + suffix`), one repeated stem argument, or two independent
  stem holes separated by fixed bytes;
* stems and signatures are transmitted once, and only occupied argument tuples
  are transmitted as sorted sparse deltas; unselected words are exact raw
  exceptions;
* the decoder generates the form set, sorts it canonically, and verifies the
  expected count and uniqueness; this is not a free Cartesian-product oracle;
* lexicographic order has no hidden permutation, while first-use order pays an
  explicit bijection from first-use ranks to canonical lexicographic ranks;
* occurrence payload records still carry every literal separator and word rank.

The candidate policy is frozen by support count, signature kind/literal size,
and byte-lexicographic ties, before complete model sizes are compared. The
screen first checks whether this set model can beat the charged independent or
CUT controls. Only if that capability gate shows a signal does
`generative_backend_screen.py` wrap the complete PGS1 frame (including all
metadata and CRC) through common zlib/bz2 backends. Neither generic backend is
called bz4 or tANS.

## Primary-source basis

These are the relevant published mechanisms, not claims that the composition
below is published:

* Daciuk, Mihov, Watson & Watson, “Incremental construction of minimal
  acyclic finite state automata,” *Computational Linguistics* 26(1), 2000.
  It gives an incremental lexicographically ordered construction of a
  minimal deterministic acyclic automaton for a finite word set:
  <https://aclanthology.org/J00-1002/>.
* Cognetta, Allauzen & Riley, “On the Compression of Lexicon Transducers,”
  FSMNLP 2019. It separates graph topology from arc labels and measures
  charged compact encodings and lookup cost, including a 500k-word Russian
  lexicon experiment:
  <https://aclanthology.org/W19-31.pdf>.
* Janicki, “Finite State Transducer Calculus for Whole Word Morphology,”
  FSMNLP 2019. It models surface-word relations directly, extracts
  candidate alignments with edit-distance dynamic programming, and covers
  vowel alternation/non-concatenative relations without assuming hidden
  morpheme boundaries:
  <https://aclanthology.org/W19-3107/>.
* Ristad & Yianilos, “Learning String-Edit Distance,” *IEEE TPAMI* 20(5),
  1998. This is the primary probabilistic edit-transduction reference; the
  prototype uses a deterministic byte alignment and charges its program
  instead of importing their learned probabilities:
  <https://arxiv.org/abs/cmp-lg/9610005>.
* Mohri, “Weighted Finite-State Transducer Algorithms: An Overview,” 2004,
  and the related finite-state edit-distance algorithms. Composition,
  determinization, minimization, and weight pushing motivate a future packed
  transducer, but every packed graph would still be charged:
  <https://doi.org/10.1007/978-3-540-39886-8_29>.
* Kiraz, “Multitiered nonlinear morphology using multitape finite automata:
  a case study on Syriac and Arabic,” *Computational Linguistics* 26(1),
  2000. It demonstrates finite-state representations of root-and-pattern
  relations; this lane only borrows the finite, checked relation idea and
  does not assume an Arabic analyzer:
  <https://aclanthology.org/J00-1006/>.
* Pimentel, Nikkarinen, Mahowald, Cotterell & Blasi, “How (Non-)Optimal is
  the Lexicon?” 2021. Its form-generator/token-frequency-adaptor separation
  motivates evaluating a lexicon-set generator separately from occurrence
  order and frequency ranks; this lane uses no learned neural probability:
  <https://arxiv.org/pdf/2104.14279>.
* Reznik, “Codes for Unordered Sets of Words,” ISIT 2011. It constructs a
  canonical tree order and transmits a set rank plus suffixes, while deriving
  an unordered-set gain that is unavailable when the original sequence order
  must be recovered. The generative screen therefore charges first-use
  permutations and occurrence ranks instead of subtracting an implicit
  `log(m!)`:
  <https://www.reznik.org/papers/ISIT11_codes4sets.pdf>.

Kudo's unigram segmentation and Morfessor's MDL segmentation are useful
controls for later spelling inventory work, but are not substituted for the
current codec in this lane. In particular, a BPE or unigram lexicon result
must not be relabeled as a paradigm result.

## Cheap disproof gate

Before any full-corpus timing, run `screen.py` on bounded exact slices of the
OMW Japanese, FreeDict/GCIDE, and (when available) `/usr/share/dict/words`
word list. The raw PPL1 gate is rejected when its complete frame loses CUT;
the bounded measurements here show that loss on all dictionary and word-list
rows. The generic-backend adapter is a separate mixed-sign diagnostic: the
program wins first-use CUT but loses lexicographic CUT on all three dictionary
slices. The PGS1 set gate beats raw independent lex order on all three
dictionaries and beats raw CUT only on FreeDict/GCIDE lex order, then loses
same-order CUT after zlib/bz2 wrapping on every row. These signs are retained
in `EVIDENCE.md` and machine-checked by `evidence_check.py`.

The bounded v4 comparison is a fixed external-harness reference (`w_parse
--share 32 --lcp 3`, then `lab --classes 64`), not an autofit/current-CLI
record. No v4 source or decoder is modified by this lane.
