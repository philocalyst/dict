# Stem × tail-class probe — development result

Status: **negative type-inventory capability screen**. The direct occurrence
source is distinct from a finite generated-set format, but even with
byte-front-coded stem and signature tables it costs more than the direct
front-coded type inventory on all six retained development slices. No native
frame or tANS size is claimed.

## Method and scope

`lexical_factor_probe.py` used the retained decoded development samples under
`language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/`
at 1 MiB and 8 MiB. It extracted WGP letter-run atoms only. The direct source
stores their sorted byte strings with LCP front coding and emits a static
Huffman-coded type ID per occurrence. The factor source emits a stem ID and a
class-conditioned tail-signature ID per occurrence. A signature stores exact
prefix and suffix bytes around one contiguous stem. Stem-to-class mappings
and the class support rows are serialized; a decoder may form any
stem/signature pair supported by that class, including unseen combinations.
There is no per-word ID, occupied-pair list, or first-use permutation.

Every row counts the frame marker and occurrence count, literal tables, class
map, class support, Huffman length tables, and Huffman payload bits. The
reported total is an isolated diagnostic encoding over letter-run types;
non-letter atoms, separators, phrase order, restarts, and WGP framing are
outside this comparison. A second factorized measurement uses raw literal
tables to show the effect of front coding. Full JSON ledgers, including every
class mode and raw ULEB operand count, are in [`results-1m.json`](results-1m.json)
and [`results-8m.json`](results-8m.json).

No bytes are normalized. UTF-8 boundaries are used only to propose exact
substring splits; malformed UTF-8 and atoms over 64 codepoints remain
identity stems. The screen performs no final-corpus tuning or timing.

## Charged totals

The candidate row is the smallest of the fixed `one`, `top1`, and `top2`
tail-class groupings, always using front-coded stems and signatures. The
serialized model includes the exact class map/support and code-length bytes.
“Payload Δ” is candidate minus direct static-Huffman payload bytes. “Model
saving” is direct model bytes minus candidate model bytes; a negative value
means the factor model is larger.

| sample | types / occurrences | direct model + payload = total | best factor mode | factor model + payload = total | total Δ | model saving | payload Δ | `H(T|C)-H(T|S)` bits |
|---|---:|---:|---|---:|---:|---:|---:|---:|
| FreeDict 1 MiB | 9,843 / 140,956 | 68,009 + 108,465 = 176,474 | top1 | 93,135 + 123,604 = 216,739 | +40,265 | −25,126 | +15,139 | 19,895 |
| GCIDE 1 MiB | 16,960 / 178,239 | 100,096 + 196,313 = 296,409 | top1 | 113,534 + 217,609 = 331,143 | +34,734 | −13,438 | +21,296 | 81,407 |
| OMW 1 MiB | 3,136 / 119,930 | 55,106 + 81,507 = 136,613 | top1 | 61,224 + 94,578 = 155,802 | +19,189 | −6,118 | +13,071 | 8,757 |
| FreeDict 8 MiB | 55,856 / 1,125,509 | 369,097 + 918,933 = 1,288,030 | top1 | 426,551 + 1,051,007 = 1,477,558 | +189,528 | −57,454 | +132,074 | 283,576 |
| GCIDE 8 MiB | 72,676 / 1,428,843 | 412,664 + 1,641,341 = 2,054,005 | top1 | 380,693 + 1,820,771 = 2,201,464 | +147,459 | +31,971 | +179,430 | 746,974 |
| OMW 8 MiB | 22,428 / 942,411 | 441,063 + 722,238 = 1,163,301 | top2 | 472,870 + 823,648 = 1,296,518 | +133,217 | −31,807 | +101,410 | 2,172 |

Every candidate total is larger, including the three 8 MiB cases where the
classing nearly preserves tail predictability (OMW top2) or the factor model
is smaller than the direct model (GCIDE top1). The occurrence cost outweighs
those model savings.

## Cost details and interpretation

Front coding is material on both sides. At the selected class mode, replacing
raw stem/signature literals with front-coded records reduced the factor total
by 9,860 / 16,427 / 4,605 bytes on 1 MiB FreeDict / GCIDE / OMW, and by
68,193 / 76,317 / 43,436 bytes on 8 MiB. The comparison above already uses
the smaller front-coded form.

The exact Huffman payload count is intentionally separated from the
information-theoretic conditional penalty. The former includes Huffman
rounding per row; it is a reproducible cheap backend diagnostic, not a proxy
for native rANS. The latter is the sharper source-model result:

| sample | factorized model saving in bits | conditional tail penalty in bits | model saving minus penalty |
|---|---:|---:|---:|
| FreeDict 1 MiB | −201,008 | 19,895 | −220,903 |
| GCIDE 1 MiB | −107,504 | 81,407 | −188,911 |
| OMW 1 MiB | −48,944 | 8,757 | −57,701 |
| FreeDict 8 MiB | −459,632 | 283,576 | −743,208 |
| GCIDE 8 MiB | +255,768 | 746,974 | −491,206 |
| OMW 8 MiB | −254,456 | 2,172 | −256,628 |

Thus even the entropy penalty plus literal/model savings is negative for every
inventory, before any WGP frame or speed requirement. The class supports also
show the sparse-combination tradeoff. The selected rows permit 67,708, 312,658,
and 107,530 unseen combinations on the 1 MiB FreeDict, GCIDE, and OMW slices.
At 8 MiB, FreeDict and GCIDE permit 1,855,071 and 4,594,432 unseen pairs;
OMW top2 permits 1,203. More precise supports reduce the probability penalty
but increase the number and size of class tables.

For an additional literal-operand check, direct word-ID versus paired
stem/tail-ID ULEB operands were 280,431 vs 421,007, 360,783 vs 532,600, and
145,298 vs 263,742 bytes on the 1 MiB rows; at 8 MiB they were 3,287,101 vs
3,559,764, 4,213,365 vs 5,204,421, and 1,188,413 vs 2,081,587. The static
Huffman row results in the main table are more relevant than those uncompressed
operands, but both ledgers are charged and retained.

This rejects the tested split heuristic and class policies as a useful
dictionary source. It does not reject other morphologies or a native coder
that changes the candidate's model, split, or event representation. A future
candidate would need to show positive model savings large enough to pay its
measured conditional tail penalty before integration work.
