# Bzip4 frontier program: final research result

Completed 2026-09-19. This is a Python reference research result, not an
integrated Zig codec or an approved format replacement.

## Decision

**Do not replace bzip3. Continue only with targeted research.** A bounded phrase
grammar followed by integer-symbol BWT is a real storage improvement on all six
8 MiB comparisons: complete frames are **4.16–31.51% smaller** than matched
bzip3. However, it loses all three untouched 1 MiB / 64 KiB comparisons by
**0.70–6.96%**, and its Python decoder is slower than native bzip3 everywhere.
No equivalent native implementation was built, so native speed remains
unproven. There is no order-of-magnitude compression or speed win to claim.

The useful result is structural, not a bag of winning modes: represent repeated
byte fragments once, block-sort the shorter phrase stream, and expand only
after restoring its order. The experiments also identify exactly why this is
not yet sufficient: shared-model cost on small inputs, large-alphabet recency
updates, and eager startup. The next experiments target these causes rather
than introduce corpus-specific switches.

## Evidence and reproducibility

- [All 48 cells, distributions, startup, restarts, encoding and memory](lead_review/evidence/post-final-v1/TABLES.md).
- [Frozen serial result records](evidence/controls/final-v1/results.json),
  [source snapshots and hashes](evidence/controls/final-v1/source-snapshot/manifest.json),
  and saved frames/raw captures in the same directory.
- [Independent final audit](lead_review/evidence/post-final-v1/final_audit.json):
  all 48 frames and **8,640 independent blocks** reproduced their exact source
  bytes, complete region sums matched frame sizes, capture hashes/statuses
  matched, and live/snapshotted sources and native artifact were unchanged.
  All six large symbol-BWT frames also equaled prior independent encodes.
- [Post-analysis summary](lead_review/evidence/post-final-v1/summary.json):
  five captured jobs succeeded, with immutable helper snapshots and raw
  stdout/stderr/status saved before parsing. These jobs were untimed audits,
  not replacement benchmark samples.
- Root integration review ran every Python experiment and adversarial review
  suite together: **60/60 tests passed**. Three test modules were made
  package-relative so aggregate discovery cannot alias the sibling
  `grammar`, `phrases`, and `structure` packages; no frozen codec or benchmark
  source changed, and all four hashes listed below still match.
- [Protocol API](protocol/API.md), [fixed plan](PLAN.md),
  [complete decoder specification](DECODER_DESIGN.md), and
  [future experiments with stopping rules](NEXT_EXPERIMENTS.md).

The final serial invocation, run from the repository root, was:

```sh
python3 -B src6/experiments/bzip4/frontier_python/evidence/controls/final_serial.py \
  --run --quiet-lane \
  --variants native,F,grammar_input,symbol_bwt \
  --lanes final,untouched --blocks 16384,65536 \
  --grammar-max-rules 8192 --grammar-max-passes 64 \
  --grammar-pair-policy consistent \
  --output-root src6/experiments/bzip4/frontier_python/evidence/controls/final-v1
```

For replication, use a **new output directory**; do not overwrite `final-v1`.
The outer capture at `evidence/controls/outer/final-v1-matrix.*` records status
0 and 1,689,074,123,125 ns elapsed. There were no dropped or retried cells.

Environment: Apple M3 Pro, Mac15,6, 11 cores, 38,654,705,664 bytes RAM;
macOS 15.7.4 arm64; Python 3.14.7; clang 17. The control uses the vendored
bzip3 1.5.1, compiled `-O3 -fPIC -DVERSION=1.5.1 -dynamiclib`. Its 85,568-byte
library SHA-256 is
`6e1b8f75fd1580a642014adee174c25b8121df6e99a64957ad1b31e35ebc42b9`.
The exact compiler invocation/source hashes are in
`protocol/vendor/build-manifest.json`. Hardware capture is
`lead_review/evidence/hardware-environment-2.*`; the sandbox-denied first
attempt is preserved rather than hidden.

The final source manifest pins 18 files. In particular:

| Source | SHA-256 |
|---|---|
| `symbol_bwt/codec.py` | `7fd9c43f1f291522a0e23a2c807888c5fd8639e05249c0874442eed74bdff638` |
| `grammar/grammar.py` | `d317635c080dd80f3aea7dcb4fff08f99259b8e51ade6d4017be6eda5e2cdcd1` |
| `bwt_context/codec.py` | `ad20998c88df51a42b17ca1f1a9f587cc1f6bee6aae3efa352047c3ebd64addd` |
| `evidence/controls/final_serial.py` | `11711e0bb804c69d96f2ce4976e3d2eac0dd3ab9a28396fb67517517b2598a59` |

## Scope of the comparison

Inputs are the strict hex-decoded normalized-content field of the existing
FreeDict English–Spanish, GCIDE 0.54, and OMW Japanese projections. They are
not original XML byte streams or complete dictionary containers. Compression
is byte-exact for these fixed inputs; no Unicode normalization, deduplication
of meanings, schema projection, or lossy change occurs inside a candidate.

The prefix `[0, 1 MiB)` trains the fixed-table byte-BWT family. The 256 KiB
screen starts at 1 MiB. The final 8 MiB lane is `[1 MiB, 9 MiB)` and therefore
contains the screen; it is not all untouched data. The separate untouched
lane is `[9 MiB, 10 MiB)`. Grammar and symbol-BWT fit their fully stored model
to their input, as ordinary two-pass compressors do. The untouched test checks
the frozen algorithm, not a claim of model generalization without fitting.

| Corpus | Full decoded length | Full decoded SHA-256 |
|---|---:|---|
| FreeDict | 43,700,255 | `6e36329d204b027aea0cff19982964eba36df2445bda96bc6e250ba372a61649` |
| GCIDE | 58,808,436 | `f41f0505f35686d1463bf05a5e988a7cea3de8ae5c7c52020f5a3e0b19fdfc74` |
| OMW | 112,147,272 | `d3be8f96361e91ad1b48f640d0c92a1041cd6e9a6ab134b1d2412f7d2a5d7242` |

Every cell records its exact slice hash; the independent audit reloads and
hashes the corpus before comparing every block. Both codecs receive identical
16 KiB or 64 KiB raw restart boundaries. This is a random-access codec-frame
comparison, not a comparison against bzip3's much larger default CLI blocks.
The control's minimum state is 65 KiB even for a 16 KiB raw block.

Every size includes all frame/model/directory/payload/checksum/padding bytes.
The native control has a 32-byte outer header and 16-byte block records; the
candidate has a 56-byte header, complete stored models and 36-byte records.
Both check decoded CRC32; bzip3 additionally has its internal block checksum.
No cryptographic-authentication or outer-dictionary-container cost is claimed
in either frame total. Such a container must charge its own integrity metadata.

## Strongest candidate versus native bzip3

All values below are actual complete saved frame sizes. Decode clocks are
retained medians: Python reference versus native bzip3, not an estimate of a
future Zig implementation. The linked full tables retain min/median/max,
throughput, separate preparation, first/middle restart, encoding and memory.

| Corpus | Input | Block KiB | bzip3 B | Symbol-BWT B | Size change | bzip3 decode ms | Python decode ms |
|---|---|---:|---:|---:|---:|---:|---:|
| FreeDict | 8 MiB | 16 | 1,189,002 | 814,375 | −31.51% | 211.769 | 5,105.185 |
| FreeDict | 8 MiB | 64 | 899,408 | 778,935 | −13.39% | 190.126 | 4,701.965 |
| GCIDE | 8 MiB | 16 | 2,362,319 | 1,860,752 | −21.23% | 358.291 | 14,199.461 |
| GCIDE | 8 MiB | 64 | 1,905,560 | 1,826,256 | −4.16% | 319.522 | 11,718.015 |
| OMW | 8 MiB | 16 | 1,124,142 | 778,911 | −30.71% | 256.580 | 3,739.220 |
| OMW | 8 MiB | 64 | 674,384 | 642,092 | −4.79% | 194.066 | 3,052.369 |
| FreeDict | untouched 1 MiB | 16 | 150,446 | 123,840 | −17.68% | 27.334 | 357.286 |
| FreeDict | untouched 1 MiB | 64 | 115,160 | 119,716 | +3.96% | 22.687 | 340.955 |
| GCIDE | untouched 1 MiB | 16 | 292,647 | 256,645 | −12.30% | 44.806 | 1,143.039 |
| GCIDE | untouched 1 MiB | 64 | 235,103 | 251,473 | +6.96% | 40.071 | 1,125.701 |
| OMW | untouched 1 MiB | 16 | 155,112 | 109,073 | −29.68% | 34.100 | 305.833 |
| OMW | untouched 1 MiB | 64 | 95,276 | 95,942 | +0.70% | 24.571 | 233.258 |

Serial methodology: fixed corpus/lane/variant/boundary order; fresh process per
cell; encode and save a frame; reread it; time fresh preparation; record one
first full decode separately; then retain three full decodes. Three first-block
and three deterministic middle-block restarts each include fresh preparation.
The middle index is not a random-latency distribution. These are warm
filesystem, in-process clocks, not disk-cold/process-startup/p99 claims. No
timed candidates ran concurrently. Fixed order is reproducible but does not
eliminate thermal/order bias; an eventual native comparison needs repeated
counterbalanced sessions as well.

Large-frame symbol preparation was 35.65–38.66 ms, versus native 0.72–1.25 ms.
Its large first restart was 42.82–120.41 ms and middle restart 48.43–135.94 ms.
Large encode time was 72.44–260.79 s versus native 0.36–0.77 s. Expensive
encoding was allowed, but it is not hidden outside the clock. These startup
and query costs are serious current failures for dictionary use.

## Experiment ledger and exact roster

Lead: `/root/bzip4_frontier_astra_xhigh`. Each of the five workers below was
launched as **gpt-5.6-luna, reasoning max**. They owned disjoint directories;
the lead read architecture/research/code, selected hypotheses, reviewed model
logic, fixed/reviewed protocol, and performed independent final audits. All
planned workers and final measurements have completed. Production, old codecs
and build files were not modified by this research branch.

| Worker under lead | Implemented work / final disposition | Evidence |
|---|---|---|
| `protocol_luna_max` | Frozen corpus/control, real captures, source snapshots, one-state native control, serial 48-cell harness | `protocol/`, `evidence/controls/` |
| `structure_luna_max` | Shape, byte-class and template splits; all rejected. Then independent hostile BWT/grammar/symbol reviews | `structure/RESULTS.md`, `structure/*REVIEW.md` |
| `phrases_luna_max` | Flat phrase/DP/replenishment family rejected; then integer-symbol BWT over bounded grammar, strongest storage candidate | `phrases/README.md`, `symbol_bwt/README.md` |
| `bwt_context_luna_max` | A–F event/context/factor/support ablations; F retained as compact/simple byte-BWT control, not replacement | `bwt_context/RESULTS.md` |
| `grammar_luna_max` | Bounded DAG, stored-use pruning, codeable-root distinction, repeated/consistent-pair discovery | `grammar/REPORT.md` |

Screen sizes below are complete 256 KiB frames with 16 KiB boundaries, in
FreeDict / GCIDE / OMW order. They are diagnostic screening, not substitutes
for the final matrix.

| Family | Representative complete screen bytes | Decision / mechanism |
|---|---|---|
| Structural shape split | 56,890 / 116,166 / 42,984 | Loses even own raw-zlib diagnostic (36,141 / 77,614 / 37,449): selectors/lengths and lost adjacency cost more than regrouping saves |
| Byte-class / template split | 66,397 / 123,121 / 52,659; 58,069 / 118,981 / 44,552 | Same failure; native zlib is diagnostic only, not a claimed new decoder |
| Flat phrases, initial→DP/refit | 51,241→49,172 / 98,950→94,452 / 85,356→74,114 | Parse search helps, but flat dictionary cost and residual stream lose to bzip3 (36,428 / 72,885 / 36,163) |
| A: byte BWT + MTF + zero runs + global rANS | 35,986 / 73,519 / 35,504 | Baseline |
| B: previous-event-class tables | 36,768 / 74,446 / 36,467 | Context/model overhead loses |
| C: bounded LZ factor before byte BWT | 37,329 / 76,633 / 34,136 | OMW-only gain; not a universal codec |
| D: clustered segment tables/selectors | 37,558 / 74,816 / 36,482 | Model/selector burden loses |
| E: raw/factored model pair with measured block choice | 36,502 / 74,035 / 34,523 | Stored extra table hurts; no free adaptive choice |
| F: exact support-conditioned table | 35,487 / 72,389 / 35,052 | Decoder-known alphabet eliminates impossible ranks without new selectors; retained for final comparison |
| Symbol-BWT with consistent-pair vocabulary | 33,032 / 75,386 / 35,566 | Mixed small-screen result, but a structural scaling hypothesis justified the full-size experiment |

F uses a single 528-byte stored table. Reachable ranks are determined by the
already stored alphabet mask; exact renormalization avoids paying probability
mass for impossible events. An input-fit F table saved only 12–54 bytes per
screen over the prefix-trained table, so added training was rejected. Full F
still loses GCIDE/OMW at 64 KiB. This was a useful simplification, not the final
storage breakthrough.

Grammar ablation, complete 8 MiB / 16 KiB frames:

| Discovery policy | FreeDict B | GCIDE B | OMW B |
|---|---:|---:|---:|
| 4,096 rules, 10 passes, overlapping choices | 1,029,514 | 2,379,483 | 2,122,317 |
| 8,192 rules, 10 passes, overlapping choices | 993,647 | 2,303,133 | 2,031,184 |
| 8,192 rules, 24 passes, overlapping choices | 925,108 | 2,162,795 | 1,806,370 |
| 8,192 rules, 24 passes, consistent pairs | 864,918 | 1,963,188 | 1,365,376 |
| 8,192 rules, 64-pass cap, consistent pairs | 849,886 | 1,935,401 | 1,334,367 |
| Same frozen family plus integer-symbol BWT | 814,375 | 1,860,752 | 778,911 |

The final builders stopped before the 64-pass cap. No corpus-specific policy
chooses a different family. Stored-reference pruning is not dynamic expansion
frequency: a definition used by one stored owner can be inlined even when the
owner expands many times. Definition IDs are not codeable-root IDs: internal
rules may have zero root frequency. These distinctions fixed real size and
correctness errors; see [structural findings](STRUCTURAL_FINDINGS.md).

Earlier native BWT+rANS is not a fallback success. A separate exact-slice size
replication reproduced its six complete totals: FreeDict 1,195,903 / 940,246;
GCIDE 2,490,928 / 2,087,612; OMW 1,194,897 / 825,074 B at 16/64 KiB. All lose
the matched bzip3 control. Historical native speed figures do not prove the
speed of this different phrase-symbol codec. The raw replication is retained
under `lead_review/evidence/old-native-size-1/`.

## Strongest technique, from first principles

Language repeats fragments at many scales. A flat dictionary repeatedly stores
substrings inside its own entries; a bounded topological grammar shares those
subfragments. This turns bytes into a much shorter sequence of root symbols.
Global root frequencies alone are weak on OMW: root order contains remaining
structure. Integer-symbol BWT groups similar contexts before recency/zero-run
coding and one canonical Huffman table. Restore the short root sequence first,
then copy checked immutable byte expansions into output.

The decoder needs only the stored DAG, event code lengths, one independent
block and bounded scratch. It does not repeat grammar learning, use an external
tokenizer, call another compression library, or load neural weights. The
current encoder learns a consistent-pair vocabulary, then **retokenizes by
longest matching expansion**; it does not preserve the discovery parse. That
distinction is a specific remaining encoder-only experiment.

This is established algorithmic territory, not a claimed invention. Grammar
precompression and BWT were connected explicitly in
[Grammar Precompression Speeds Up Burrows–Wheeler Compression](https://www.cs.helsinki.fi/u/tpkarkka/publications/spire2012.pdf).
That work's measurements and entropy-coding scope cannot be imported into our
claim. Our contribution here is a tested bounded composition, complete-frame
accounting and identified tradeoffs for this workload. Research on learned
compression informed encoder-only model search as a future option; no ML
advantage was demonstrated. See [primary-source research notes](RESEARCH.md).

## Correctness, hostile inputs, and independence

The final post-audit reparsed every saved capture and frame, matched hashes and
exact input slices, summed every wire region, decoded each independently
addressable block, and matched final full-output hashes. Its 8,640 block checks
are independent reruns of the candidate public APIs, not a second complete
codec implementation. Algorithm-level oracles are separate:

- Byte BWT was checked against naive rotation sorting, and rANS against an
  independent scalar interval decoder without the candidate lookup tables.
- Integer BWT was checked against exhaustive ternary strings of lengths 1–7
  and randomized cases; grammar expansion/byte roundtrips cover arbitrary
  bytes and invalid UTF-8, not just language samples.
- Focused reviewer suites: BWT 8/8 plus local 12/12; grammar 6/6 plus local
  10/10; symbol-BWT 7/7 plus local 5/5. Lead final tests add 9/9. These overlap;
  do not sum them into a fictional independent-test coverage percentage.
- Resealed hostile frames test actual parser bounds, not only CRC failure:
  forward rule references, invalid arities, expansion bombs, model bounds before
  slicing/copying, counts/primary indices, Huffman exact bits/tails, rANS state,
  factor output limits, unused alphabet symbols and wire-width mismatches.
- Three BWT P2 findings and symbol model/encoder-count issues were fixed before
  the frozen matrix; reviews document pre-fix evidence and corrected expected
  rejection. No open P2 remains in the bounded reviews.

Bounds are explicit but this is not a formal proof or exhaustive fuzz campaign.
Python references are not hardened production parsers. CRC32 is not
authentication. A future container must preserve authenticated-source and
decoded-admission boundaries, not assume these codec checks replace them.

## Memory, complexity, and the remaining blockers

Process RSS is reported for every final cell but includes corpus loading,
training, encoding and decode; it is not decoder-only memory. The native
control uses one needed state, with conservative scratch 2,654,274 bytes.
Candidate logical byte estimates omit Python object overhead and are **not**
a measured native memory victory.

A separate `tracemalloc` experiment starts after imports/frame loading and
prepares fresh state for each selected query. Across all candidate cells,
symbol preparation peaks at 2,677,076–6,735,542 traced bytes, and selected-query
peaks including retained prepared state are 1,786,258–5,542,470 bytes. It
excludes preloaded frame bytes, untraced/native memory and full-output decode
peak. See [memory records](lead_review/evidence/post-final-v1/memory_profile.json).

The Python encoder uses comparison sorting in a prefix-doubling BWT and
bounded heuristic grammar discovery, not linear-time construction. The
decoder currently materializes events, ranks, last-column symbols and restored
roots. `symbol_bwt/codec.py` is 1,033 lines and imports the 1,286-line grammar
reference including its builder; this is not a claimed polished compact Zig
implementation. A later reader can be separated from encoder search, but that
refactor has not been benchmarked.

The operation audit reveals a stronger limit than interpreter overhead. The
8 MiB GCIDE cells need about 1.25 million roots—6.69 raw bytes per root—but
median MTF rank is 827–831 and p95 is 6,727–6,874. Even ideal u16 prefix shifts
would move 4.48–4.71 GB logically. FreeDict roots average 15.77–16.09 bytes,
yet imply 1.84–2.03 GB of shifts. These are operation counts, not native
bandwidth predictions. Fewer symbols alone does not guarantee low latency.

The small-input model gap is equally concrete:

| Untouched 1 MiB / 64 KiB | Current model B | Model + new framing budget to tie bzip3 B | Standard bz2 model stream B |
|---|---:|---:|---:|
| FreeDict | 17,599 | 13,043 | 10,438 |
| GCIDE | 33,289 | 16,919 | 20,647 |
| OMW | 29,945 | 29,279 | 19,385 |

The last column is a separately saved diagnostic of standard bz2 on the exact
stored model, with exact roundtrip, **not a Bzip4 frame or decoder proposal**.
It omits no bytes from that standard stream, but a real model-container change
would need new framing and startup accounting. Even this shortcut would not
close GCIDE. The task is better model representation or a different
model/payload tradeoff, not declaring model bytes negligible.

## Acceptance scorecard

| Gate | Result | Evidence / limit |
|---|---|---|
| Fixed diverse real inputs and untouched slice | PASS | Three pinned corpora; same slices and boundaries; untouched algorithm test stated honestly |
| Actual raw output/status, hashes and serial reproducibility | PASS | 48 status-0 cells, 18 frozen source files, no source/native drift, independent artifact audit |
| Complete stored bytes, no hidden decoder model | PASS | Header + all models + directory + payload + checksums/padding sum exactly |
| Lossless every recorded block | PASS | 8,640 independent block reruns and exact input/output hashes |
| Hostile validation and bounded reference state | PASS for tested scope | Resealed adversarial suites; finite limits; not proof, crypto-authentication or production hardening |
| Smaller than bzip3 on every required cell | FAIL | 9/12 wins; all three untouched 64 KiB cells lose |
| Faster native full decode on every cell | FAIL / unproven native candidate | Current Python loses everywhere; no equivalent native decoder exists |
| First/random-access startup latency victory | FAIL | Startup/restarts measured and currently slower; first/middle samples are not a random latency distribution |
| Scratch/peak memory characterization | PARTIAL | RSS, logical bounds and selected-query tracing recorded; equivalent native candidate peak remains unmeasured |
| Portable scalar decoder without hidden codec | PASS as reference only | Python algorithm, no external entropy/phrase decoder; no cross-platform Zig validation |
| Composability and selective decode | PASS at block layer only | Explicit shared model + independent blocks; no free field-level random access or container integration |
| Simple production implementation / new frontier claim | NOT ESTABLISHED | Clear stored program, but prototype still multi-stage; prior art acknowledged |

## Recommended next step, not a silent integration

Keep the frozen prototype and its evidence. The highest-value next work is:

1. **Wire-preserving decoder work:** fuse entropy→runs→MTF into the last column,
   walk inverse BWT directly into checked expansion output, and test a bounded
   rank-select MTF against flat shifts. This can remove arrays and prefix
   traffic without changing a stored byte; native measurements are mandatory.
2. **Model/payload objective:** pack topological references, arities and dense
   code lengths; then test minimum-description-length rule pruning and the
   preserved discovery parse. GCIDE's exact budget is the stopping criterion,
   not a favorable average across corpora.
3. **Separate typed-format lane:** use schema-known decode state to choose
   contexts without storing redundant selectors. Preserve canonical packet
   fidelity, final-slot `decodeInto`, pointer stability, admission/deferred
   references, bounded continuation state and selective-page accounting. This
   is [a different comparison](TYPED_ENTROPY_PROPOSAL.md), not an escape from
   the failed byte-codec gate.

`NEXT_EXPERIMENTS.md` gives concrete mechanisms, hazards and rejection rules.
No production integration, model substitution, benchmark-specific dispatch,
Zig speed claim, or promise of inevitable superiority follows from this report.
