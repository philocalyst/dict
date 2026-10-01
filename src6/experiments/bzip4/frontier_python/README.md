# Language compression frontier research

This is an isolated Python-first research program, not production integration.
Its strongest structural candidate is `symbol_bwt`: a fully stored bounded
phrase grammar, integer-symbol block sorting, recency/zero-run coding, and one
canonical Huffman model. The decoder expands phrases after restoring the short
root stream. It uses no external tokenizer, hidden dictionary, neural weights,
or native compression library.

The frozen serial matrix and independent artifact audit are complete: **48/48
cells and 8,640 independently decoded blocks passed**. The six complete 8 MiB
`symbol_bwt` frame cells beat matched bzip3 at 16 KiB and 64 KiB independent raw
boundaries. However, all three untouched 1 MiB / 64 KiB cells are larger, and
the Python decoder is slower than native bzip3 in every cell. **Replacement
acceptance fails; do not integrate this as a bzip3 replacement.** See
[`RESULTS.md`](RESULTS.md) for the explicit scorecard and
[`TABLES.md`](lead_review/evidence/post-final-v1/TABLES.md) for all measurements.

| Corpus | Block | Symbol-BWT bytes | bzip3 bytes |
|---|---:|---:|---:|
| FreeDict English–Spanish | 16 KiB | 814,375 | 1,189,002 |
| FreeDict English–Spanish | 64 KiB | 778,935 | 899,408 |
| GCIDE | 16 KiB | 1,860,752 | 2,362,319 |
| GCIDE | 64 KiB | 1,826,256 | 1,905,560 |
| OMW Japanese | 16 KiB | 778,911 | 1,124,142 |
| OMW Japanese | 64 KiB | 642,092 | 674,384 |

These figures include headers, shared grammar, entropy tables, directories,
primary indices, lengths, checksums, mode flags, and padding. They are codec
frames over identical normalized-content bytes, not complete dictionary
containers or original XML serializations. Results at larger bzip3 block sizes
or with another random-access contract are outside this comparison.

## Read this first

- `RESULTS.md`: final outcome, complete-byte comparison, experiment ledger,
  correctness/held-out evidence, limitations, and acceptance scorecard.
- `PLAN.md`: fixed inputs, hypotheses, gates, and serial measurement plan.
- `STRUCTURAL_FINDINGS.md`: the implementation/model mistakes that mattered.
- `RESEARCH.md`: primary sources and the limits of their evidence. The
  grammar/BWT connection is established prior art, not a claimed invention.
- `DECODER_DESIGN.md`: complete wire regions, bounded decoder state machine,
  ownership, selective access, and migration risks.
- `TYPED_ENTROPY_PROPOSAL.md`: a separate semantic-format proposal. It cannot
  substitute for the exact-byte codec comparison.
- `NEXT_EXPERIMENTS.md`: concrete follow-up hypotheses and stopping rules.

## Exact worker roster

The lead is `/root/bzip4_frontier_astra_xhigh`. Every experimental worker below
was explicitly launched as **gpt-5.6-luna, reasoning max**. No worker modified
production or old codec/build files.

| Canonical worker under the lead | Ownership / responsibility |
|---|---|
| `protocol_luna_max` | Frozen corpus/control protocol, actual raw captures, final serial benchmark |
| `bwt_context_luna_max` | BWT event/context/factorization/support ablations |
| `structure_luna_max` | Reversible structural transforms; independent hostile reviews of finalists |
| `phrases_luna_max` | Flat phrase parsing family; later the isolated symbol-BWT family |
| `grammar_luna_max` | Bounded grammar, stored-reference pruning, codeable roots, consistent-pair ablations |

The lead personally read the relevant production architecture, earlier failed
experiments, vendor control, research, and candidate code; selected experiments
from measured failures; and independently checked transformation oracles and
wire behavior. Reviews led to real fixes, including payload bounds, entropy
normalization, non-codeable internal rules, model parsing, and encoder/parser
limit agreement.

## Where the evidence lives

- Final frozen matrix: `evidence/controls/final-v1/`; all 48 captured cells
  returned status 0, with no candidate/control/vendor source drift.
- Independent full artifact audit, selected-query memory, operation counts,
  and model-packing diagnostics: `lead_review/evidence/post-final-v1/`.
- Independent lead tests and control replications: `lead_review/evidence/`.
- Independent BWT/grammar/symbol reviews and captures: `structure/`.
- Family experiments and rejected variants: `bwt_context/RESULTS.md`,
  `grammar/REPORT.md`, `phrases/README.md`, `structure/RESULTS.md`, and
  `symbol_bwt/README.md`.
- Exact protocol and pinned native bzip3 build: `common.py` and `protocol/`.

Actual stdout, stderr and process status are persisted before parsing. Earlier
experimental captures with missing snapshots or synthetic/transcribed output
are historical diagnostics, not final timing evidence. The final matrix
snapshots all candidate/control sources and verifies source/vendor hashes
before and after the run. Failed experiments are retained, not selected out.
