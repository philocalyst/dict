# MDL-gated stem × tail hybrid — development result

Status: **small diagnostic headroom; no material source win**. The fixed
family gate activates regular classes and falls back to exact identity stems
for other forms. The aggregate source has a slight static-Huffman win only
on OMW. The fully charged model plus ideal conditional-entropy budget is
positive on each sample, but its upper-bound saving is below 0.3% of the
letter-inventory diagnostic. No native WGP6 frame or speed claim follows.

## Fixed source and gate

The scanner, exact byte inventory, and development inputs are those described
in [`PROPOSAL.md`](PROPOSAL.md). The hybrid's fixed policy is in
[`mdl_gated_hybrid.py`](mdl_gated_hybrid.py):

* Candidate stems are repeated codepoint-boundary substrings up to 12
  codepoints, including a whole-word stem when that exact word also occurs
  inside another type. This allows a bare form and its inflected forms to use
  one stem with an empty or nonempty tail.
* Cores are assigned to the class of their most frequent observed
  prefix/suffix signature. A class receives at most four signatures: its
  modal signature and the three highest-mass signatures supported by at least
  two stems. A stem participates only if at least two of its forms use the
  selected support. A class requires at least two participating stems.
* Each proposed family is priced against its exact direct front-coded type
  inventory. Its factor source pays front-coded stem/signature strings,
  class support, stem-to-class activation rows, Huffman tables, and occurrence
  symbols. Accept the family iff
  `8 × (direct model bytes − factor model bytes) − [H(T|class(S)) − H(T|S)] > 0`.
  Every family failing that rule is retained in the JSON as rejected.
* All other forms become identity stems in class 0 with the empty tail. They
  need no explicit activation map entry. The serialized model carries only a
  sparse active-stem-ID-to-class map, plus each class's supported signatures.
  Occurrences emit stem and class-local tail symbols; no occupied stem/tail
  pair list or word-ID permutation is delivered. Unseen pairs inside the
  class support remain decodable and are included in the generated-pair
  ledger.

The delivered full-model screen uses exact byte counts for its front-coded
stem and tail tables, sparse activation map, class support/code rows, stem
code lengths, and static-Huffman occurrence payload. A singleton tail row is
implicit and costs zero payload bits. The separate conditional-entropy
penalty is the coder-independent part of the source comparison. Static
Huffman redundancy is reported as diagnostic and is not called native rANS.

## Results

The input is letter-run type inventory only; the full dictionary stream,
separators, restart blocks, and WGP framing are omitted. “Net MDL bits” is
`8 × model saving − conditional penalty`; positive values give an optimistic
headroom bound before a production coder. “Static total Δ” includes the
delivered model and the measured static-Huffman payload.

| sample | types / occurrences | accepted / priced-rejected / structural rejects | factored types | unseen supported pairs | direct bytes | hybrid bytes | static total Δ | model saving | conditional penalty bits | net MDL bits |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| FreeDict 1 MiB | 9,843 / 140,956 | 34 / 27 / 1,224 | 695 | 487 | 176,474 | 176,718 | +244 | 462 B | 1,316 | +2,380 |
| GCIDE 1 MiB | 16,960 / 178,239 | 77 / 59 / 1,084 | 2,361 | 1,751 | 296,409 | 298,710 | +2,301 | 2,004 B | 10,411 | +5,621 |
| OMW 1 MiB | 3,136 / 119,930 | 13 / 2 / 321 | 88 | 19 | 136,613 | 136,515 | **−98** | 147 B | 301 | +875 |
| FreeDict 8 MiB | 55,856 / 1,125,509 | 167 / 131 / 4,175 | 6,112 | 4,789 | 1,288,030 | 1,288,940 | +910 | 5,714 B | 18,482 | +27,230 |
| GCIDE 8 MiB | 72,676 / 1,428,843 | 299 / 141 / 2,937 | 9,503 | 6,512 | 2,054,005 | 2,057,271 | +3,266 | 6,097 B | 26,199 | +22,577 |
| OMW 8 MiB | 22,428 / 942,411 | 48 / 26 / 2,139 | 352 | 71 | 1,163,301 | 1,163,058 | **−243** | 465 B | 626 | +3,094 |

The positive ideal headroom is about 298, 703, and 109 bytes on the 1 MiB
inventories and 3,404, 2,822, and 387 bytes on the 8 MiB inventories. Its
ratio to the direct inventory diagnostic is approximately 0.17%, 0.24%,
0.08%, 0.26%, 0.14%, and 0.03%, respectively. These are source-model
estimates; a native frame can only confirm them after its actual bucket,
context, and table costs are measured.

The structural reject counts are large because most modal-tail groups have
only one stem or lack a second signature shared across stems. For the priced
classes, full accepted and rejected ledgers are retained, including local
direct/factor model bytes, local Huffman totals, activation/support bytes,
conditional penalties, and gate sign.

Machine-readable records and exact sample hashes:

* [`mdl-gated-1m.json`](mdl-gated-1m.json)
* [`mdl-gated-8m.json`](mdl-gated-8m.json)

These results preserve the useful mechanism—productive classes can replace
some identity word types without transmitting occupied pairs—but the bounded
policy does not show enough inventory savings to justify native integration
by itself.
