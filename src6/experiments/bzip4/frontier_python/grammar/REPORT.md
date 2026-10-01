# Global grammar evidence ledger

All rows below are complete framed bytes.  The native column is the matched
`protocol.native_bzip3` control, not a candidate decoder.  Input-fit rows are
ordinary two-pass compression: the complete grammar and canonical lengths are
inside the frame.  The frozen training row is the held-out diagnostic.

## Development screen, 256 KiB (corrected v3 model semantics)

### 16 KiB blocks

| corpus | variant | complete | model | directory | payload | rules | control | delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | input_huff | 43,205 | 12,020 | 384 | 30,753 | 1,976 | 36,428 | +6,777 |
| FreeDict | input_fixed | 47,518 | 9,788 | 384 | 37,298 | 1,976 | 36,428 | +11,090 |
| FreeDict | training_huff | 51,775 | 21,394 | 384 | 29,949 | 3,584 | 36,428 | +15,347 |
| GCIDE | input_huff | 88,120 | 16,379 | 384 | 71,309 | 2,836 | 72,885 | +15,235 |
| GCIDE | input_fixed | 95,056 | 13,287 | 384 | 81,337 | 2,836 | 72,885 | +22,171 |
| GCIDE | training_huff | 95,970 | 22,537 | 384 | 73,001 | 3,897 | 72,885 | +23,085 |
| OMW Japanese | input_huff | 57,335 | 18,762 | 384 | 38,141 | 2,910 | 36,163 | +21,172 |
| OMW Japanese | input_fixed | 58,322 | 15,596 | 384 | 42,294 | 2,910 | 36,163 | +22,159 |
| OMW Japanese | training_huff | 84,773 | 22,038 | 384 | 62,303 | 3,576 | 36,163 | +48,610 |

### 64 KiB blocks

| corpus | variant | complete | model | directory | payload | rules | control | delta |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | input_huff | 42,699 | 11,927 | 96 | 30,628 | 1,953 | 27,239 | +15,460 |
| GCIDE | input_huff | 87,785 | 16,381 | 96 | 71,260 | 2,836 | 58,700 | +29,085 |
| OMW Japanese | input_huff | 56,661 | 18,548 | 96 | 37,969 | 2,864 | 22,279 | +34,382 |

The corrected v3 ledgers are `results/screen-all-16-v3.json` and
`results/screen-all-64-v3.json`, with one exact stdout/stderr/status capture per
child under the corresponding `results/raw/` directory.  The v2 ledgers
(`screen-all-16-v2.json` and `screen-all-64-v2.json`) are retained as a
pre-lead-audit ablation in which every internal rule received a unit prior.
The earlier
pre-wire-cleanup FreeDict run is intentionally retained in
`results/screen-freedict-16.json`: it was 49,348B with an 18,163B model and its
training lane failed on an uncodable unseen rule.  That failure is a retained
negative ablation, not silently removed data.

## Rule-cap ablation

The pre-audit `results/ablation-16.json` ledger captured each child through
`protocol.capture.run_and_save`; it is retained as the rule-cap/model-overhead
ablation before internal zero code lengths were corrected.  Input-fit Huffman
complete/model/payload bytes were:

| corpus | cap | complete | model | payload | retained rules |
| --- | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 1,024 | 81,484 | 5,413 | 75,639 | 1,007 |
| FreeDict | 2,048 | 46,937 | 10,559 | 35,946 | 1,800 |
| FreeDict | 3,072/4,096 | 43,273 | 12,020 | 30,821 | 1,976 |
| GCIDE | 1,024 | 113,402 | 5,283 | 107,687 | 1,002 |
| GCIDE | 2,048 | 91,079 | 10,846 | 79,801 | 1,913 |
| GCIDE | 3,072/4,096 | 88,168 | 16,379 | 71,357 | 2,836 |
| OMW Japanese | 1,024 | 95,725 | 5,765 | 89,528 | 981 |
| OMW Japanese | 2,048 | 70,087 | 11,010 | 58,645 | 1,787 |
| OMW Japanese | 3,072 | 61,080 | 15,546 | 45,102 | 2,445 |
| OMW Japanese | 4,096 | 57,425 | 18,762 | 38,231 | 2,910 |

The pre-audit full 8 MiB fixed-parameter 4,096 versus 8,192 comparison is in
`results/final-input-huff-16.json` and
`results/final-input-huff-r8192-16.json`.  The corrected 8,192 result is in
`results/final-input-huff-r8192-16-v2.json`; the cap is retained as the
strongest input-fit final candidate, not as a corpus-specific dispatch rule.

## Depth and consistent-pair ablations

The corrected 24-pass depth ablation at the fixed 8,192 rule cap is
`results/final-input-huff-r8192-p24-16.json`.  It produced 925,108B (FreeDict),
2,162,795B (GCIDE), and 1,806,370B (OMW), versus controls 1,189,002B,
2,362,319B, and 1,124,142B.  The deeper pass budget materially improves the
OMW failure but does not close it; it raises model bytes to 45,860, 46,654,
and 46,935 and reaches 7,803, 8,046, and 7,774 retained rules.  The measured
rows reached 18, 17, and 18 actual passes, maximum root expansions 238B, 82B,
and 484B, and average root expansions 14.79B, 6.41B, and 9.53B.

The last prior-art consistent-pair ablation is
`results/final-input-huff-r8192-p24-consistent-16.json`.  It keeps the same
frame/decoder but selects a role-consistent non-overlapping pair matching and
rejects self-pairs.  Complete bytes are 864,918B (FreeDict), 1,963,188B
(GCIDE), and 1,365,376B (OMW); controls are 1,189,002B, 2,362,319B, and
1,124,142B.  The OMW gap narrows to +241,234B but remains negative.  The
consistent rows retain 6,418, 6,993, and 7,070 rules with model bytes 36,168,
39,105, and 42,431.  This is the final grammar-family ablation; no
corpus-specific dispatch was introduced.

The fixed nomination is the same consistent policy with an 8,192-rule cap and
64-pass budget.  No corpus-specific stopping rule is used: each row simply
stops when the pair budget is exhausted or no profitable pair remains.  The
16 KiB run (`results/final-input-huff-r8192-p64-consistent-16-refreeze2.json`) reaches
849,886B, 1,935,401B, and 1,334,367B for FreeDict, GCIDE, and OMW; this is a
further improvement over the 24-pass rows for all three inputs.  It retains
8,076, 8,136, and 7,610 rules, with model bytes 45,656, 45,613, and 45,926.
The largest root expansions are 238B, 82B, and 484B, all below the 512B
bound.  The matching 64 KiB run is captured in
`results/final-input-huff-r8192-p64-consistent-64-refreeze2.json`: 835,334B, 1,924,994B,
and 1,337,156B, against controls 899,408B, 1,905,560B, and 674,384B.  It
retains 8,019, 8,131, and 7,530 rules; model bytes are 45,289, 45,603, and
45,573.  The 64 KiB Japanese result remains intentionally visible as a
language/block-size failure rather than being hidden by dispatch.

Both refreeze ledgers were captured after the source freeze and every child in
both ledgers reports the same concatenated `grammar.py + worker.py + screen.py`
SHA-256: `afb5c7f1cdcd27881eb98fe5d0d85083c7ba9a6c18f0938a03e49d9eb16f1e76`.
The exact child stdout/stderr/status files are under the matching
`results/raw/final-input-huff-r8192-p64-consistent-*-refreeze2/` directories.

## Retained early 8 MiB size gate: overlap-greedy, 10 passes

### 16 KiB blocks, 8,192 rules, corrected model

| corpus | complete | model | directory | payload | rules | control | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 993,647 | 27,586 | 12,288 | 953,725 | 4,700 | 1,189,002 | -195,355 |
| GCIDE | 2,303,133 | 28,425 | 12,288 | 2,262,372 | 4,941 | 2,362,319 | -59,186 |
| OMW Japanese | 2,031,184 | 29,038 | 12,288 | 1,989,810 | 4,836 | 1,124,142 | +907,042 |

The corrected ledger is `results/final-input-huff-r8192-16-v2.json`.

### 64 KiB blocks, 8,192 rules

| corpus | complete | model | directory | payload | rules | control | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 979,568 | 26,802 | 3,072 | 949,646 | 4,528 | 899,408 | +80,160 |
| GCIDE | 2,292,175 | 28,335 | 3,072 | 2,260,720 | 4,920 | 1,905,560 | +386,615 |
| OMW Japanese | 2,020,196 | 28,594 | 3,072 | 1,988,482 | 4,739 | 674,384 | +1,345,812 |

The corrected 64 KiB final ledger is `results/final-input-huff-r8192-64-v2.json`.  The
boundary change matters to the native control and is therefore not pooled with
the 16 KiB totals.

## Final nominated size gate: consistent, 64 passes

The tables below are the source-frozen refreeze ledgers, using one fixed
8,192-rule/64-pass nomination across all corpora.

### 16 KiB blocks

| corpus | complete | model | directory | payload | rules | control | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 849,886 | 45,656 | 12,288 | 791,894 | 8,076 | 1,189,002 | -339,116 |
| GCIDE | 1,935,401 | 45,613 | 12,288 | 1,877,452 | 8,136 | 2,362,319 | -426,918 |
| OMW Japanese | 1,334,367 | 45,926 | 12,288 | 1,276,105 | 7,610 | 1,124,142 | +210,225 |

### 64 KiB blocks

| corpus | complete | model | directory | payload | rules | control | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 835,334 | 45,289 | 3,072 | 786,925 | 8,019 | 899,408 | -64,074 |
| GCIDE | 1,924,994 | 45,603 | 3,072 | 1,876,271 | 8,131 | 1,905,560 | +19,434 |
| OMW Japanese | 1,337,156 | 45,573 | 3,072 | 1,288,463 | 7,530 | 674,384 | +662,772 |

The refreeze ledgers are `results/final-input-huff-r8192-p64-consistent-16-refreeze2.json`
and `results/final-input-huff-r8192-p64-consistent-64-refreeze2.json`.

## Decoder operation and resident-state accounting

The decoder eagerly validates and pre-expands every retained rule once.  On the
fixed 8 MiB/8,192-rule/64-pass nomination, preparation took 37--41ms in Python
for 16 KiB blocks and 38--44ms for 64 KiB blocks.  It retained 45.6--45.9KiB
of serialized model plus 73--159KiB of flat rule expansions at 16 KiB (73--167KiB
at 64 KiB); the exact copy is in each result row.  The 16 KiB retained table
performed 536,626, 1,266,024, and 852,912 decoded-symbol operations for
FreeDict, GCIDE, and OMW respectively, each copying exactly 8,404,992 bytes
across 512 independent blocks.  The 64 KiB rows performed 534,334, 1,273,233,
and 861,591 operations, copying 8,454,144 bytes across 128 independent blocks.
These timings are descriptive Python measurements, not a native-speed claim.

The old decoder path materialized a symbol list before expansion; this
prototype now bounds Huffman/fixed token materialization by the declared raw
block length and checks exact `ceil(valid_bits/8)` body size.  A future native
decoder can fuse prefix lookup and checked expansion, but that optimization is
not needed to decide the storage gate.  Eager startup is charged and visible;
lazy topological expansion remains an explicitly unmeasured design option.

## Complexity assessment

For `N` current symbols and `P` bounded passes, encoder pair counting and
replacement are `O(PN)` plus sorting the bounded candidate map.  Packed integer
pair keys avoid tuple allocation.  The rule table and model serialization are
linear in retained references and alphabet length.  Preparation is linear in
model bytes plus pre-expanded rule bytes, bounded by 512 bytes per rule and an
8 MiB total expansion table.  Coded block decode is one canonical code walk and
one checked bulk extension per event; raw fallback is a direct bounded copy.

All rules reference earlier IDs, all literal bytes remain available, and the
test suite exercises cycles/forward references, expansion overflow, tails,
padding, malformed directory lengths, invalid UTF-8, empty input, full 64KiB
blocks, a single seeded random stream, long repeats, frozen unseen literals,
independent restart, and decode-bomb limits.
