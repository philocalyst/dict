# Flat phrase frontier (Python reference)

This directory is an isolated compression experiment.  It is not wired into
LEX6 and the Python timings below are prototype timings, not evidence about a
future Zig decoder.

## Result at a glance

The fixed development screen passed exact round trips and independent decoding
of every block for FreeDict `eng-spa`, GCIDE, and OMW Japanese.  It did not beat
the retained bzip3 controls on the 256 KiB screen, and no final 8 MiB serial
gate has been run.  The new two-round minimum-bit parser reduces the lexical
frame by 4.0% on FreeDict, 4.5% on GCIDE, and 13.2% on OMW, but remains decisively
larger than native bzip3.  The input-fit row is a fully stored encoder-derived
model and is therefore a legitimate byte-codec size measurement; it is only
invalid if described as an unseen-training generalization result.

The screen is fixed at bytes `[0, 1 MiB)` for training and
`[1 MiB, 1.25 MiB)` for development, with 16 KiB or 64 KiB raw restart
boundaries.  The untouched linguistic holdout `[9 MiB, 10 MiB)` is not read by
this script.

### 16 KiB development screen

Complete frame bytes include the 40-byte header, front-coded model, restart
directory, block payloads, CRCs, and bit padding.

| corpus | variant | frame | model | payload | phrase count | status |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| FreeDict | `lex_huff` | 51,241 | 2,748 | 48,069 | 234 | pass |
| FreeDict | `lex_dp_huff` | 49,172 | 7,416 | 41,332 | 926 | pass |
| FreeDict | `ngram_huff` | 50,855 | 1,591 | 48,840 | 67 | pass |
| FreeDict | `lex_fixed` | 71,703 | 2,258 | 69,021 | 234 | pass |
| FreeDict | `input_lex_huff` (input-fit, fully stored) | 50,983 | 2,738 | 47,821 | 232 | pass |
| GCIDE | `lex_huff` | 98,950 | 3,398 | 95,128 | 341 | pass |
| GCIDE | `lex_dp_huff` | 94,452 | 5,557 | 88,471 | 899 | pass |
| GCIDE | `ngram_huff` | 103,023 | 3,060 | 99,539 | 212 | pass |
| GCIDE | `lex_fixed` | 160,152 | 2,644 | 155,864 | 498 | pass |
| GCIDE | `input_lex_huff` (input-fit, fully stored) | 98,800 | 3,448 | 94,928 | 505 | pass |
| OMW Japanese | `lex_huff` | 85,356 | 3,611 | 81,321 | 341 | pass |
| OMW Japanese | `lex_dp_huff` | 74,114 | 7,663 | 66,027 | 992 | pass |
| OMW Japanese | `ngram_huff` | 96,571 | 2,088 | 94,059 | 212 | pass |
| OMW Japanese | `lex_fixed` | 122,045 | 3,014 | 118,607 | 341 | pass |
| OMW Japanese | `input_lex_huff` (input-fit, fully stored) | 80,966 | 3,581 | 76,961 | 333 | pass |

The OMW input-fit payload is 76,961 bytes in the raw JSON.  Its complete model
is stored in the frame, so this is a valid input-derived compression datapoint;
the row is marked `input-fit` only to prevent an unsupported claim that its
vocabulary generalized from the first MiB.  The latest complete machine-
readable records, including the DP row, are in `screen-dp16.raw.stdout` and
`screen-dp64.raw.stdout`; earlier baseline captures remain in the other
`screen-*.raw.stdout` files.  `screen-dp-source-manifest.json` seals the
per-source file hashes and the ordered capture hash for these final bounded
runs.

### 64 KiB development screen

| corpus | `lex_huff` | `lex_dp_huff` | `ngram_huff` | `lex_fixed` | input-fit |
| --- | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 50,825 | 48,803 | 50,392 | 71,269 | 50,567 |
| GCIDE | 98,629 | 94,134 | 102,693 | 159,831 | 98,481 |
| OMW Japanese | 84,976 | 73,744 | 96,219 | 121,677 | 80,583 |

All 64 KiB rows passed the same complete and per-block checks.  The model is
charged once per frame; therefore these tiny screens intentionally overcharge
the archive-wide vocabulary.  A final decision must use the prescribed 8 MiB
lane and the separate 1 MiB holdout.

For orientation only, the retained matched bzip3 totals for the bounded screen
are 36,428 / 72,885 / 36,163 bytes at 16 KiB and 27,239 / 58,700 / 22,279
bytes at 64 KiB for FreeDict / GCIDE / OMW.  The retained matched bzip3 totals
for an 8 MiB lane were
1,189,002 / 2,362,319 / 1,124,142 bytes at 16 KiB for FreeDict / GCIDE / OMW,
and 899,408 / 1,905,560 / 674,384 bytes at 64 KiB.  The development screen is
not a matched replacement for those full-lane controls; extrapolating its
payload rate is pessimistic for some corpora and optimistic for others.  No
superiority claim is made.

## Concrete ablations

* `lex_huff`: split bytes into generic ASCII word runs, bounded whitespace
  runs, valid UTF-8 codepoint units, and single-byte fallback units; count
  repeated one-to-seven-unit spans; choose cost-ranked phrases; longest-match
  tokenize; static canonical Huffman-code phrase IDs and literal bytes.
* `lex_dp_huff`: retain the same candidate pool, but perform two encoder-only
  rounds of minimum-bit dynamic programming over the flat phrase trie.  Each
  round recounts selected phrase/literal symbols and refits canonical Huffman
  lengths.  After round one, unused rules are pruned and remaining capacity is
  replenished only from contiguous residual literal runs; round two prunes
  again.  The decoder and frame are identical to `lex_huff`.
* `ngram_huff`: count generic byte n-grams at lengths 2--32, with deterministic
  sampling only for long windows; no lexical or markup knowledge.  This is the
  byte-structure control for the lexical hypothesis.
* `lex_fixed`: the same learned lexical table but fixed-width IDs.  It tests a
  shallow direct-expansion decoder without a Huffman tree.
* `input_lex_huff`: same codec, but the trainer receives the train prefix plus
  the development prefix.  The complete dictionary and entropy model are
  charged in the frame, making this legitimate input-derived compression.  It
  is not evidence that a first-MiB-only model generalizes to unseen bytes.

Candidates that are not used by the deterministic longest-match parse are
pruned before code lengths are built.  Every phrase is stored as bytes, not as
a semantic token.  No XML/SGML names, language-specific vocabulary, external
dictionary, omitted spelling, case, or whitespace is used.

The DP comparison separates parser loss from dictionary-family loss.  Relative
to greedy `lex_huff`, `lex_dp_huff` saves 2,069 B (4.0%) on FreeDict, 4,498 B
(4.5%) on GCIDE, and 11,242 B (13.2%) on OMW at 16 KiB.  The charged model
grows because it retains 926/899/992 flat phrases rather than 234/498/341.
Against the native screen controls, however, the DP frames are still 35.0%,
29.6%, and 104.9% larger at 16 KiB, and 79.2%, 60.4%, and 231.0% larger at
64 KiB (FreeDict / GCIDE / OMW).  The refinement therefore rejects greedy
parsing as the only culprit but rejects this entire flat family for promotion.

## Decoder and wire audit

The frame layout is:

```text
40-byte header | complete front-coded model | 24-byte restart records | payloads
```

The header records variant, block target/count, raw length, model length,
directory length, metadata CRC, and a zero reserved field.  A directory record
contains absolute payload offset, encoded length, raw length, raw CRC32, and the
number of valid coded bits.  Payload mode `0` is a raw fallback; mode `1` is a
Huffman or fixed-ID bitstream.  The metadata CRC covers the zeroed-CRC header,
model, and directory.  Block payloads are contiguous and there is no trailing
data.

`prepare(frame)` performs the one-time cold work: limits, metadata CRC, model
front decoding, flat trie construction, canonical Huffman tree construction,
directory validation, and exact payload layout checks.  `Prepared.decode_block`
then runs this state machine:

1. Select one directory record and check its absolute bounds.
2. Validate mode, exact bit-to-byte padding, and symbol alphabet.
3. Read a Huffman tree path or a fixed-width ID.
4. For a phrase ID, bulk-copy the stored flat byte expansion; for a literal ID,
   copy one byte.  Expansion never invokes another phrase and never recurses.
5. Stop as soon as declared raw length would be exceeded, then require exact
   output length and CRC32.

Truncated frames, extra payload bytes, non-contiguous records, invalid code
lengths, out-of-range fixed IDs, nonzero padding, overlong blocks, CRC failures,
and mutated headers are rejected by tests in `test_phrases.py`.

The logical cold state is bounded by the charged model plus one block output,
one directory record set, and the fixed decode tables.  For the screen rows,
the stored model is 1.6--3.6 KiB and the largest phrase expansion table is
about 3.6 KiB of bytes; a 16 KiB cold block therefore has roughly
`model + directory + 16 KiB output + phrase bytes + code/tree tables` logical
storage before Python object overhead.  Python dictionaries and objects are
not presented as native-memory proof.  The frame metrics expose setup time,
phrase expansions, Huffman lookup steps, literal/phrase symbol counts, and
padding bits so a native implementation can replace those estimates.

For a concrete 16 KiB screen trace, FreeDict `lex_huff` decoded 262,144 bytes
with 14,162 phrase expansions, 47,170 literal symbols, and 384,364 Huffman
bit/tree steps; its 16 blocks averaged 24,023 tree steps per 16,384 raw
bytes.  The final DP row changed that to 16,509 phrase expansions, 32,890
literals, and 330,490 bit/tree steps.  GCIDE DP had 23,866 phrase expansions,
88,927 literals, and 707,582 steps; OMW DP had 32,373 phrase expansions,
34,558 literals, and 528,022 steps.  These are
counts from the reference interpreter, useful for comparing state-machine
shapes but not native instruction counts.  Fixed-ID decoding performs one
`id_width` bit read per symbol (9--10 bits on these screens) and bulk-copies
the same flat phrases; its larger payload is why it is retained as a rejected
speed control.

## Reproduction and raw evidence

From this directory:

```sh
python3 -m unittest -v test_phrases.py
python3 screen.py --corpus ../../../../bench/real-world/evidence/corpora/freedict-eng-spa/projection.tsv
python3 screen.py --block-bytes 65536 \
  --corpus ../../../../bench/real-world/evidence/corpora/gcide-054/projection.tsv
```

The captured development runs retain JSON stdout, empty stderr, and process
status files.  Each envelope records the full projection SHA-256, the source
range, code SHA-256, Python/platform string, train/evaluation hashes, timing,
model/frame decomposition, and exact output digests.  The current captured
screen code hash (ordered as `screen.py` then `phrases.py`) is
`6b9c27f4918f8ff4904f1be98be62718b7e8555bac27d5a988cebe14d771aefb` for
the latest DP captures.
Each variant row also records a SHA-256 of the complete framed bytes.
Projection hashes were:

* FreeDict: `687008296b727878d26472bca5315beca8136a64365f2ac819e9e1f7f22f3865`
* GCIDE: `4cddd7f0d23d7ef5dd923ef97b1894f7fff86cc26dbda1a9621653c1338c635b`
* OMW Japanese: `ff9b2f1e56912bf3874cb77377a6f97949206a3efdff7739a10f61e1f0c43c75`

The status is **development evidence only**.  The final serial gate, matched
8 MiB storage/timing matrix, untouched `[9 MiB, 10 MiB)` validation, and any
native-speed claim remain pending.

## Rejected ledger

* The fixed-width control is substantially larger on all three screens.  Its
  benefit is decoder simplicity, not storage.
* `lex_dp_huff` confirms that greedy longest-match parsing is not the sole
  failure: two minimum-bit rounds reduce the frame by 4.0--13.2%, yet the
  charged result remains 29.6--231.0% above native bzip3 controls.  The flat
  phrase family is rejected for promotion.
* Generic n-grams reduce model bytes on FreeDict but lose to lexical phrases
  on GCIDE and OMW in the 256 KiB screen; there is no uniform winner.
* Input-fit improves some rows only slightly while inspecting evaluation bytes;
  its complete model is charged and the size is valid, but it cannot support a
  claim that a first-MiB-only vocabulary generalizes to unseen bytes.
* No external entropy library, neural inference, or unstored weight is used.
  LLM arithmetic coding was not implemented because it would violate the
  bounded pure-Python decoder requirement and would charge a very large model.
* A recursive grammar is not included in this slice.  Deep rule expansion was
  intentionally rejected in favor of flat preexpanded entries and explicit
  per-output bounds; a separate batch grammar experiment would be a different
  ablation, not a hidden part of this codec.

## Research basis (hypotheses, not novelty claims)

The experiments borrow established ideas and charge their complete artifacts:

* [Sennrich, Haddow & Birch, 2016, BPE subword units](https://aclanthology.org/P16-1162/)
  motivates open-vocabulary subword fallback, but this codec stores full byte
  phrases and does not reuse a pretrained tokenizer.
* [Nevill-Manning & Witten, SEQUITUR](https://courses.cs.washington.edu/courses/cse490g/06wi/reading/nevill97a.pdf)
  motivates repeated-sequence grammar learning; this slice keeps only flat
  expansions, avoiding recursive decoder state.
* [Gee et al., Multi-word Tokenization for Sequence Compression](https://arxiv.org/abs/2402.09949)
  motivates testing multi-unit phrase reuse beyond word boundaries.
* [Kalcher, Frequency-Ordered Tokenization](https://arxiv.org/abs/2602.22958)
  motivates measuring complete vocabulary/ID overhead rather than reporting
  token counts alone.  Its tokenizer assumptions are not imported here.
* [Delétang et al., Language Modeling Is Compression](https://deepmind.google/research/publications/39768/)
  motivates the distinction between predictive modeling and a decoder that can
  actually reconstruct bytes; no neural model is hidden in this experiment.
* [Boncz et al., FSST](https://vldb.org/pvldb/vol13/p2649-boncz.pdf) is a
  relevant direct-symbol-expansion prior art control.  `lex_fixed` is retained
  only as a transparent fixed-ID comparison, not as a novelty claim.
