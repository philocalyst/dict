# Productive-program screen: bounded evidence

This is an auditable **diagnostic**, not a v4 size claim. `screen.py` uses a
small byte-exact PPL1 frame with unsigned LEB128 integers. `CUT` and
`program` share the same header, payload records, CRC, word order, and literal
separator bytes; only the charged dictionary model changes. No tANS/rANS
backend or current-v4 decoder opcode is implied here. A production integration
would have to repeat this comparison in the v4 entropy backend and add a
bounded decoder path outside this owned directory.

The productive candidate uses recurring edit geometry, not nearest-word
selection as an oracle:

* a relation pays a parent delta and a template ID;
* the template pays fixed `COPY`/`DELETE`/`SUB` geometry once;
* each edge pays variable insertion/substitution literals and any required
  parameters;
* final `COPY_REMAINDER` is parameter-free only when it consumes the exact
  remainder of the already-decoded parent;
* singleton geometries fall back to independent records;
* the candidate set is frozen by length/endpoint buckets plus a fixed
  eight-parent fallback, with deterministic bounded byte edit distance;
* every frame is decoded and checked against the original bytes and CRC.

## Commands and inputs

All corpus runs below used Python 3, `--limit 65536`, `--max-edits 4`,
`--max-word 128`, `--edit-limit 2000`, and:

```text
python3 src6/experiments/bzip4/language_frontier/paradigms/screen.py \
  src6/experiments/bzip4/bz4/data/omw.eval8.bin \
  --limit 65536 --edit-limit 2000 --modes cut,program --order both
```

The same command was run for `freedict.eval8.bin`, `gcide.eval8.bin`, and the
local `/usr/share/dict/words` control. Input prefix hashes make the bounded
slices reproducible without normalizing or dropping bytes.

Full SHA-256 hashes of the screened prefixes:

```text
omw      7b8124b6cde70665409887bdb03f88af9873d0490272cdbe97cc2af752007283
freedict d3bae0c328de1d07a3fde062f4cd68a6b72b828d6098f37aea4c73effae55b63
gcide    8719c720994d16f2276bbccf0fc315e7c950a77fc426814924ed9b4f1d1e223b
words    328d13eb19288331b00baea9463133153b0383a9486fcf5ab8fb31ea3e177f5e
```

## Complete frame ledger

`total = header + model + payload + CRC`; `padding` is zero in every row.
`dict` excludes the template table, so `model = dict + template`.

| input (SHA-256 prefix) | order | types / occurrences | CUT total | program total | program model (`dict + template`) | payload | relations / novel / templates | delta (program − CUT) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| OMW `7b8124b6…52007283` | first | 459 / 9,741 | 61,163 | 61,366 | 6,838 + 87 = 6,925 | 54,421 | 67 / 63 / 16 | **+203** |
| OMW `7b8124b6…52007283` | lex | 459 / 9,741 | 60,132 | 60,646 | 6,831 + 80 = 6,911 | 53,715 | 67 / 54 / 15 | **+514** |
| FreeDict `d3bae0c3…ae55b63` | first | 1,013 / 11,648 | 80,785 | 81,170 | 8,798 + 42 = 8,840 | 72,310 | 54 / 29 / 9 | **+385** |
| FreeDict `d3bae0c3…ae55b63` | lex | 1,013 / 11,648 | 87,311 | 88,106 | 8,741 + 47 = 8,788 | 79,298 | 65 / 29 / 10 | **+795** |
| GCIDE `8719c720…1e223b` | first | 2,003 / 11,727 | 90,513 | 90,647 | 15,322 + 48 = 15,370 | 75,257 | 98 / 64 / 11 | **+134** |
| GCIDE `8719c720…1e223b` | lex | 2,003 / 11,727 | 95,614 | 96,830 | 15,236 + 35 = 15,271 | 81,539 | 121 / 52 / 8 | **+1,216** |
| `/usr/share/dict/words` `328d13eb…e177f5e` | first | 6,504 / 6,504 | 86,616 | 105,981 | 66,582 + 485 = 67,067 | 38,894 | 785 / 513 / 86 | **+19,365** |
| `/usr/share/dict/words` `328d13eb…e177f5e` | lex | 6,504 / 6,504 | 86,590 | 107,295 | 67,981 + 400 = 68,381 | 38,894 | 602 / 364 / 70 | **+20,705** |

Headers are 16 bytes and CRCs are 4 bytes in these rows. The payload is
identical between each same-order CUT/program pair, so the differences are
model costs rather than a hidden occurrence-count change. The model ledger
also counts parent-ID bytes, operation/template parameters, and literal
exceptions. The program-side relation ledger (all numbers are bytes) is:

| input / order | parent-ID bytes | template bytes | edge op/ref bytes | exception-literal bytes | relations |
| --- | ---: | ---: | ---: | ---: | ---: |
| OMW / first | 69 | 87 | 154 | 81 | 67 |
| OMW / lex | 68 | 80 | 200 | 114 | 67 |
| FreeDict / first | 64 | 42 | 173 | 90 | 54 |
| FreeDict / lex | 73 | 47 | 234 | 127 | 65 |
| GCIDE / first | 121 | 48 | 259 | 121 | 98 |
| GCIDE / lex | 163 | 35 | 370 | 180 | 121 |
| words / first | 804 | 485 | 2,769 | 1,588 | 785 |
| words / lex | 606 | 400 | 2,152 | 1,228 | 602 |

`edge op/ref` is the tool's `relation_ops` field: template IDs and variable
parameters are included, while `exception-literal` is the subset of literal
bytes in insert/substitute operations. Parent deltas are separately counted
in `relation_parent`; relation tags and independent fallback records remain
inside the full dictionary model. Thus this table exposes the parent-ID tax
and repeated geometry table separately instead of presenting a raw relation
count as free savings. For example, OMW first-use parent IDs are only 69 bytes,
but template plus edge costs are 241 bytes before fallback/model effects; the
full program model is still 203 bytes larger than CUT.
These are raw LEB128 byte charges, not entropy-coded source-ID bits; they are
therefore a lower-level diagnostic of where the loss comes from, not evidence
that an entropy backend would preserve the same fractions.

Relation-family counts for the OMW first-use row are:

```text
deletion_nonprefix=15, infix=2, other_edit=11, prefix_only=4,
substitution=13, substitution_nonprefix=22
```

The corresponding lexicographic OMW row has 68 parent bytes, 200 operation
bytes, 114 literal bytes, and families:

```text
deletion_nonprefix=12, infix=6, other_edit=2, prefix_only=13,
substitution=10, substitution_nonprefix=24
```

## Interpretation / disproof

The candidate discovers genuine non-prefix relations: OMW has 63 novel
first-use relations and 54 novel lexicographic relations after the tool's
prefix-only exclusion. Nevertheless, after charging model/template, parent,
operation, and exception bytes, the complete program frame loses to the
prefix-only control on all six dictionary rows and loses badly on the word-list
control in the raw LEB128 frame. The cheap raw-frame gate is therefore a
**negative** for this frozen policy, although the later generic backend has
small first-use wins recorded below.
Recurring geometry is not free evidence of a production compression win.

For a smaller all-control sanity slice (OMW first 4,096 bytes,
`114fcafd3b5a73a088d703628acc2c98f6ca4e0c10876acac0fa132f679e728d`,
76 types / 615 occurrences), complete custom-frame totals were: independent
4,296 bytes in both orders; CUT 4,205 first / 4,191 lex; raw edit 4,239
first / 4,228 lex; and lexicographic DAFSA 5,713 bytes for 481 states. Every
row round-tripped exactly. This is a control against accidentally selecting a
relation mode merely because it was compared with no independent model.

The relation count is not a claim about gold morphology: these are exact byte
alignments and can be accidental. A future production experiment should only
proceed if a common v4 entropy backend, decoder cost, and language-aware
candidate index reverse this negative result without relaxing byte exactness.
The OMW slice is intentionally a byte-level multilingual control, not a
Japanese morphological-tokenization result: the current v4 policy treats a
whitespace-free CJK span as one high-bit run. Any language-aware segmentation
would need its own side-data cost and an exact inverse.

## Round-trip and failure checks

The bounded test suite exercises all five modes (`independent`, `CUT`, raw
`edit`, productive `program`, and DAFSA), mixed invalid UTF-8/NUL/high-byte
inputs, non-prefix `C-S-C` template reuse, frame truncation, and CRC damage:

```text
python3 -m unittest discover \
  -s src6/experiments/bzip4/language_frontier/paradigms \
  -p 'test_*.py' -v
```

Result: 7 tests passed. The DAFSA control is fully charged (state topology,
edge labels, terminal bits, and lexicographic enumeration) and is not composed
with edit programs because this screen did not find a reason to pay for both.
The independently runnable comparison ledger also asserts the signs and key
mixed results:

```text
python3 src6/experiments/bzip4/language_frontier/paradigms/evidence_check.py
```

## Common-backend adapter

The raw PPL1 frame is not a fair proxy for an entropy-coded production stream,
so `backend_screen.py` compressed the **complete** frame—including header,
model, payload, CRC, and every exception—through the same generic backend as a
raw direct slice. These are explicit zlib-9/bz2-9 diagnostics, not bz4/tANS.
All rows round-tripped through both compression/decompression directions.

| input / order | raw direct zlib / bz2 | PPL1 independent zlib / bz2 | PPL1 CUT zlib / bz2 | PPL1 program zlib / bz2 | program − CUT zlib / bz2 |
| --- | ---: | ---: | ---: | ---: | ---: |
| OMW / first | 6,040 / 5,560 | 7,188 / 6,243 | 7,326 / 6,448 | 7,261 / 6,353 | **−65 / −95** |
| OMW / lex | 6,040 / 5,560 | 7,057 / 6,283 | 6,997 / 6,246 | 7,107 / 6,350 | **+110 / +104** |
| FreeDict / first | 7,442 / 6,504 | 10,838 / 9,012 | 10,970 / 9,188 | 10,899 / 9,127 | **−71 / −61** |
| FreeDict / lex | 7,442 / 6,504 | 10,775 / 9,101 | 10,607 / 8,739 | 10,793 / 9,103 | **+186 / +364** |
| GCIDE / first | 17,099 / 14,795 | 24,845 / 19,835 | 25,056 / 20,120 | 24,886 / 20,053 | **−170 / −67** |
| GCIDE / lex | 17,099 / 14,795 | 24,785 / 19,900 | 24,129 / 18,907 | 24,752 / 19,990 | **+623 / +1,083** |

The generic backend changes the first-use comparison: program beats same-order
CUT on all three dictionary rows under both zlib and bz2, by 61–170 zlib bytes
and 61–95 bz2 bytes. It loses same-order CUT on all three lexicographic rows
(110–623 zlib bytes and 104–1,083 bz2 bytes). This mixed result is why the
backend table is retained rather than summarized as an all-loss claim. The
complete-frame wrapper remains a diagnostic, not a codec replacement.

## Shared generative-set gate

The PGS1 candidate was then measured as a set generator: fixed signatures,
stems, sparse occupied argument tuples, exact exceptions, canonical lexicographic
enumeration, and an explicit first-use permutation. The occurrence payload is
the same exact byte stream with every rank charged. The raw capability gate
against the independent PPL1 control was:

| input / order | PGS1 total | independent total | PGS1 − independent | CUT total | PGS1 − CUT | groups (one-arg + two-hole) | generated / exceptions | permutation bytes | model components (`sig + stem + occupancy + exceptions`, plus counts/permutation) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| OMW / first | 61,892 | 61,769 | +123 | 61,163 | **+729** | 24 (12 + 12) | 446 / 13 | 792 | 132 + 5,704 + 709 + 109 |
| OMW / lex | 60,395 | 61,063 | **−668** | 60,132 | **+263** | 24 (12 + 12) | 446 / 13 | 0 | 132 + 5,704 + 709 + 109 |
| FreeDict / first | 82,180 | 81,459 | +721 | 80,785 | **+1,395** | 41 (25 + 16) | 949 / 64 | 1,900 | 221 + 5,649 + 1,876 + 199 |
| FreeDict / lex | 87,269 | 88,447 | **−1,178** | 87,311 | **−42** | 41 (25 + 16) | 949 / 64 | 0 | 221 + 5,649 + 1,876 + 199 |
| GCIDE / first | 91,402 | 91,197 | +205 | 90,513 | **+889** | 52 (38 + 14) | 1,826 / 177 | 3,880 | 274 + 8,019 + 3,430 + 516 |
| GCIDE / lex | 93,805 | 97,479 | **−3,674** | 95,614 | **−1,809** | 52 (38 + 14) | 1,826 / 177 | 0 | 274 + 8,019 + 3,430 + 516 |

The component sums omit only the small count varints; first-use rows add the
explicit permutation column to the model, while lex rows add zero.

This raw gate shows enough regularity to justify the common-backend check on
the two lexicographic wins over the independent control. Against the existing
CUT control, PGS1 is positive on OMW (+729 first, +263 lex), but wins on
FreeDict lex (−42) and GCIDE lex (−1,809). After the full generic backend,
PGS1 loses same-order CUT on every row:

| input / order | PGS1 zlib / bz2 | same-order PPL1 CUT zlib / bz2 | PGS1 − CUT (zlib / bz2) |
| --- | ---: | ---: | ---: |
| OMW / first | 8,297 / 8,080 | 7,326 / 6,448 | +971 / +1,632 |
| OMW / lex | 7,543 / 7,252 | 6,997 / 6,246 | +546 / +1,006 |
| FreeDict / first | 13,184 / 12,690 | 10,970 / 9,188 | +2,214 / +3,502 |
| FreeDict / lex | 11,704 / 10,908 | 10,607 / 8,739 | +1,097 / +2,169 |
| GCIDE / first | 28,518 / 26,193 | 25,056 / 20,120 | +3,462 / +6,073 |
| GCIDE / lex | 25,673 / 22,365 | 24,129 / 18,907 | +1,544 / +3,458 |

The structural hypothesis therefore fails this bounded capability gate after a
common backend. Its raw model still demonstrates the intended composition—12,
16, and 14 two-hole groups respectively—but those groups do not remove enough
stem/occupancy/signature bytes. This is a measured disproof of this frozen
set-generator policy, not a rejection of all morphology.

## Fresh v4 comparison

For the same 65,536-byte prefixes, I freshly compiled the external v4 lab and
word parser into `/private/tmp` with Zig 0.16 and ran a fixed-harness
round-trip measurement. This is not the current CLI/autofit record: the
parser was explicitly run with `--share 32 --lcp 3 --block 65536`, and the lab
was explicitly run with `--classes 64 --stats` (one block):

```text
zig build --build-file src6/experiments/bzip4/bz4/v3/build.zig \
  -p /private/tmp/language-frontier-v4-build -Doptimize=ReleaseFast
/private/tmp/language-frontier-w-parse SLICE DUMP --block 65536 --share 32 --lcp 3
/private/tmp/language-frontier-v4-build/bin/lab SLICE DUMP --classes 64 --stats
```

| input | v4 total | header | delta | payload | framing | blocks | round-trip |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| OMW | 8,457 | 3,500 | 3,869 | 1,067 | 21 | 1 | checked |
| FreeDict | 10,872 | 4,507 | 4,932 | 1,412 | 21 | 1 | checked |
| GCIDE | 21,835 | 6,328 | 9,368 | 6,117 | 22 | 1 | checked |

The comparison is deliberately qualified: the **program** wrappers are below
the fresh v4 total on both OMW orders, below v4 on FreeDict lex (and both
FreeDict bz2 rows), but above v4 on GCIDE zlib and FreeDict first-use zlib. Raw
direct zlib/bz2 is lower still on every slice. These are different codecs and
should not be collapsed into a blanket “competitive” or “noncompetitive”
claim. The v4 run is included to prevent the common-backend adapter from being
mistaken for a production measurement; no v4 source or decoder was modified
in this lane.
