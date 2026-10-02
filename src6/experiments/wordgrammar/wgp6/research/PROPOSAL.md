# WGP6 lexical factor source: stem × class-conditioned tail

Status: implementation is a bounded accounting probe only. It does not emit
or claim a WGP6 frame. `lexical_factor_probe.py` compares a direct,
front-coded letter-atom inventory with an occurrence source that emits stem
and tail symbols directly.

## Falsifiable question

Can reusable surface parts replace enough bytes from the one-record-per-type
spelling inventory to pay for (a) the stem and tail literal tables, (b) a
stem-to-tail-class map, (c) each class's delivered tail support and code row,
and (d) the extra conditional tail information caused by sharing one row
across stems?

The source surface is `prefix + stem + suffix`. A tail signature is the exact
pair `(prefix, suffix)`. The candidate sends the stem ID and a tail ID for
each occurrence. A stem's class selects the tail code row. Each row carries
the union of tail signatures observed among its stems, so every supported
stem/signature combination is decodable whether or not that pair occurred in
the sample. The model has no occupied-pair list, per-word derivation record,
word-ID stream, or first-use permutation. Reconstructing an observed type is
therefore direct string concatenation after two symbol decodes.

This is distinct from the prior PGS1 set generator: PGS1 serialized a finite
generated word set, sparse occupied tuples, and (for first-use order) a
permutation. This source sends paired symbols in occurrence order and allows
class-supported unseen combinations. Its specific tradeoff is measured by
`H(T | class(S)) - H(T | S)` on the observed token stream, plus the complete
serialized tables and coded operands.

## Probe accounting

The scanner extracts WGP letter runs byte-for-byte (`ASCII alphabetic` or
`byte >= 0x80`). Candidate split points are Unicode scalar boundaries for
strictly valid UTF-8 atoms; there is no normalization. Invalid UTF-8 and
atoms longer than 64 codepoints remain identity stems. The fixed split
proposal chooses a repeated proper contiguous core of 2–12 codepoints and
uses the remaining exact prefix/suffix as its tail signature.

The direct control serializes the sorted type inventory with byte-exact
front coding. It then sends each occurrence as a Huffman-coded sorted type
ID. The candidate serializes sorted stem and signature literals, stem-to-class
IDs, each class's supported signature IDs and Huffman lengths, a stem Huffman
row, and per-class tail Huffman rows. The occurrence payload Huffman-codes a
stem ID followed by the tail ID in that stem's class. `raw_uleb_operand_bytes`
is also reported as a plain-ID audit ledger; the charged total uses the
serialized static Huffman tables and exact bit count, rounded to bytes.

The model and payload sizes are diagnostic counts over letter-run inventory
only. XML tags, digits, separators, phrase order, block restarts, and the WGP6
wire are omitted as common or out of scope. These numbers cannot be called
complete compression sizes.

The probe reports 1 MiB and 8 MiB prefixes for the retained development
FreeDict, GCIDE, and OMW samples. A reasonable cheap rejection is a larger
charged source on all three 8 MiB inventories, or a tail entropy penalty that
exceeds the literal-table saving on every corpus. Any capability signal still
needs a byte-exact native frame and comparison through the production entropy
backend before it becomes a codec claim.

## Grounding in prior evidence

The existing v4 learner's spelling delta is 273,038 of 579,677 bytes (47%) on
FreeDict 8 MiB. W2's real-price pruning left full totals within 1% across
morph-count sweeps; changing the morph threshold shifted delta from 258 to
277 KB rather than reducing the total. The prior productive edit-program
screen found 54–121 relations per 65,536-byte dictionary slice and lost its
same-order CUT control in the raw charged frame. PGS1's stem/signature,
sparse-tuple model had 5.7–8.0 KB of stem literals plus 0.7–3.4 KB of
occupancy cost on those slices, and lost the same-order CUT control after a
common backend. The prior binding
lane also saturated its 96-template/512-binding cap and lost its held-out
screens. These results motivate removing the finite-set tuple and
first-use-permutation costs, while making the information penalty explicit.

Useful source anchors already in the repository:

* Creutz & Lagus, *Unsupervised Morpheme Segmentation and Morphology
  Induction from Text Corpora Using Morfessor 1.0* (2005): an MDL/MAP
  segmentation objective jointly accounts for lexicon and corpus cost.
* Janicki, *Finite State Transducer Calculus for Whole Word Morphology*
  (FSMNLP 2019): surface relations can encode alternations and
  non-concatenative morphology without assuming hidden morpheme boundaries.
* Kiraz, *Multitiered nonlinear morphology using multitape finite automata*
  (Computational Linguistics 26(1), 2000): root-and-pattern morphology can
  be represented as a finite relation.
* Pimentel et al., *How (Non-)Optimal is the Lexicon?* (2021): separates
  form generation from occurrence frequencies, motivating a source model
  whose lexical inventory and token stream are priced separately.

These motivate the abstraction; none establishes a win for this exact
source. Every candidate must still pay its model and surface-symbol stream.
