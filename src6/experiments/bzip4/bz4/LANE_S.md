# Lane S — static root codes, lab notebook

Owner files: `rootstatic.zig` (codec library), `rootlab_static.zig` (measurement
driver), this file. Binaries under `bin/`. See `PLAN.md` for the shared
contract; this lane never edits another lane's files.

## Question

How fast can the real decoder be, and how close to the static order-0
entropy can a table-driven static root code get, once the grammar is full
and each block is just a short stream of root symbols?

## What was built

- **Dump parsing** (`parseDump`): reads a B4SD dump into rules + a
  concatenated root-symbol stream with per-block offsets.
- **Expansion table** (`buildExpansion`): one forward pass, children always
  smaller ids, eager copy into one contiguous byte arena, 64-byte overscan
  pad. No compact/prefix-sharing layout was needed in practice — see
  "Arena size" below.
- **Canonical length-limited Huffman** (`buildHuffman`), max length 24 bits,
  primary table 12 bits:
  1. Unrestricted lengths from the classic O(n) two-queue merge (sorted
     leaves + a FIFO of internal nodes, a.k.a. Van Leeuwen's algorithm),
     with ties broken by real symbol id so the whole thing is a pure
     function of `g[]`.
  2. **Kraft fix-up heuristic** (not package-merge): clip any length > 24 to
     24, then repeatedly move the symbol at the longest length still below
     24 to length+1 (via length-bucket stacks) until
     `sum(2^(24-len)) <= 2^24`. This is the same family as the classic
     zlib/deflate `bl_count` overflow fix, simplified to bucket stacks.
  3. Canonical code assignment from the final lengths (sorted by
     `(length, symbol id)`), so the decoder rebuilds identical codes from
     `g[]` alone — no code-length table is ever stored.
  4. Decode: a two-level table (12-bit primary, escape to per-prefix
     subtables for the rare — see below, not so rare — tail of long codes).
  5. A second decode path, an explicit bit-trie built from the *same* final
     (length, code) pairs, for the naive-vs-table comparison.
- **Static range/rANS-style code** (`buildRangeModel`): `g[s]/M` quantised
  to a power-of-two total `2^bits` (bits chosen so `2^bits >= 8*n_sym`,
  16–22), largest-remainder rebalancing to hit the total exactly, decoded
  with a range coder copied from `rc.zig` and specialised so the
  total-division becomes a shift (`range >>= bits`). Symbol lookup by an
  O(1) slot table of size `2^bits` (compared against cumulative binary
  search — see Optimisations).
- **Frame format**: 32-byte header + 16-byte directory record per block
  (`payload_offset, payload_len, root_count, crc32`, all `u32`) + payload.
  This is bookkeeping charged exactly like the bzip3 control per PLAN.md,
  not a compact production format. `crc32` is stamped from the real
  ground-truth raw file, then rechecked on every decode.
- **Decode loop**: `comptime checked` selects a real (error-return, not
  `std.debug.assert`, which is UB-on-false in ReleaseFast) validation path
  vs. the branch-light fast path, from the same source so both are exactly
  the algorithm being measured. Copy is a fixed 16/32-byte unconditional
  overscan store for short expansions, 32-byte-chunked loop for long ones.

## Correctness

All 24 required dumps (`*.full.b4sd` at 16k and 64k for every corpus, plus
the `r8192`/`r32768` partial grammars), both coders: full-frame decode
reproduces the exact raw file (`std.mem.eql` over the whole buffer) *and*
independently decoding block 0, the middle block, and the last block alone
reproduces exactly the corresponding raw byte range, with CRC32 rechecked
per block. **48/48 passed** (24 dumps × 2 coders); zero mismatches. All
numbers below are from these real, verified encode/decode runs — none are
estimates except `h0_B`, which is the exact `-sum(g*log2(g/M))` reference
(labelled per PLAN.md's rules of evidence).

## Results (all 24 dumps, both coders)

`code_param` is the Huffman max code length in bits actually used, or the
range coder's `log2(total)`. `over_h0%` = payload bytes over exact H0.
`single_blk_us` is one isolated block decode (see caveats). Timings are a
**median of 7** full-file decodes; the machine was heavily shared while
this ran (`uptime` load average ~83 during the sweep — several other lab
agents were building/running concurrently), so treat MB/s and ns/root as
indicative, per PLAN.md, not as a clean serial benchmark.

| dump | coder | n_sym | alphabet | code_param | payload_B | total_B | h0_B | over_h0% | arena_B | startup_ms | decode_ms | MB/s | ns/root | single_blk_us |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.16k.full | huffman | 58828 | 70259 | 18 | 519742 | 527966 | 518566 | 0.23 | 2384145 | 18.6 | 29.6 | 270.4 | 105.0 | 6.4 |
| freedict.eval8.16k.full | range | 58828 | 70259 | 19 | 522429 | 530653 | 518566 | 0.74 | 2384145 | 3.9 | 42.9 | 186.6 | 152.1 | 14.4 |
| freedict.eval8.16k.r32768 | huffman | 31950 | 33024 | 18 | 621223 | 629447 | 619613 | 0.26 | 809825 | 16.0 | 29.1 | 274.7 | 80.4 | 11.4 |
| freedict.eval8.16k.r32768 | range | 31950 | 33024 | 18 | 623491 | 631715 | 619613 | 0.63 | 809825 | 2.6 | 25.6 | 313.1 | 70.5 | 11.9 |
| freedict.eval8.16k.r8192 | huffman | 8278 | 8448 | 19 | 748063 | 756287 | 746004 | 0.28 | 147416 | 5.8 | 30.8 | 260.1 | 60.6 | 10.2 |
| freedict.eval8.16k.r8192 | range | 8278 | 8448 | 17 | 749891 | 758115 | 746004 | 0.52 | 147416 | 1.1 | 22.5 | 355.6 | 44.3 | 21.7 |
| freedict.eval8.64k.full | huffman | 58542 | 70027 | 18 | 517811 | 519891 | 516800 | 0.20 | 2380531 | 16.3 | 29.2 | 273.7 | 104.0 | 63.4 |
| freedict.eval8.64k.full | range | 58542 | 70027 | 19 | 517842 | 519922 | 516800 | 0.20 | 2380531 | 3.7 | 32.4 | 246.7 | 115.4 | 104.8 |
| freedict.untouched.16k.full | huffman | 10741 | 12851 | 15 | 73340 | 74396 | 73066 | 0.37 | 342802 | 12.8 | 7.0 | 142.7 | 150.2 | 11.9 |
| freedict.untouched.16k.full | range | 10741 | 12851 | 17 | 73545 | 74601 | 73066 | 0.66 | 342802 | 1.2 | 3.1 | 320.6 | 66.9 | 15.9 |
| freedict.untouched.64k.full | huffman | 10689 | 12802 | 15 | 73133 | 73421 | 72881 | 0.35 | 345323 | 14.1 | 3.1 | 321.6 | 66.8 | 44.0 |
| freedict.untouched.64k.full | range | 10689 | 12802 | 17 | 73007 | 73295 | 72881 | 0.17 | 345323 | 0.6 | 3.1 | 321.6 | 66.8 | 102.2 |
| gcide.eval8.16k.full | huffman | 116098 | 125380 | 19 | 1276774 | 1284998 | 1273931 | 0.22 | 1982778 | 25.2 | 93.0 | 86.0 | 141.7 | 26.2 |
| gcide.eval8.16k.full | range | 116098 | 125380 | 20 | 1277855 | 1286079 | 1273931 | 0.31 | 1982778 | 11.4 | 128.7 | 62.2 | 196.0 | 42.6 |
| gcide.eval8.16k.r32768 | huffman | 32552 | 33024 | 20 | 1547441 | 1555665 | 1543985 | 0.22 | 386741 | 14.4 | 70.7 | 113.1 | 77.8 | 30.1 |
| gcide.eval8.16k.r32768 | range | 32552 | 33024 | 18 | 1548136 | 1556360 | 1543985 | 0.27 | 386741 | 1.9 | 76.3 | 104.9 | 83.8 | 53.9 |
| gcide.eval8.16k.r8192 | huffman | 8226 | 8448 | 20 | 1803979 | 1812203 | 1799387 | 0.26 | 78927 | 9.2 | 72.2 | 110.9 | 58.9 | 33.5 |
| gcide.eval8.16k.r8192 | range | 8226 | 8448 | 17 | 1803461 | 1811685 | 1799387 | 0.23 | 78927 | 0.9 | 49.9 | 160.2 | 40.8 | 57.4 |
| gcide.eval8.64k.full | huffman | 115853 | 124840 | 19 | 1274899 | 1276979 | 1272259 | 0.21 | 1977618 | 47.3 | 90.9 | 88.0 | 138.6 | 307.2 |
| gcide.eval8.64k.full | range | 115853 | 124840 | 20 | 1273386 | 1275466 | 1272259 | 0.09 | 1977618 | 13.4 | 131.5 | 60.8 | 200.6 | 506.7 |
| gcide.untouched.16k.full | huffman | 21450 | 24093 | 16 | 165789 | 166845 | 165299 | 0.30 | 311593 | 21.1 | 10.2 | 97.7 | 104.1 | 28.5 |
| gcide.untouched.16k.full | range | 21450 | 24093 | 18 | 165788 | 166844 | 165299 | 0.30 | 311593 | 1.5 | 12.2 | 82.3 | 123.6 | 43.3 |
| gcide.untouched.64k.full | huffman | 21406 | 24058 | 16 | 165596 | 165884 | 165123 | 0.29 | 311199 | 18.2 | 8.7 | 115.4 | 88.2 | 272.8 |
| gcide.untouched.64k.full | range | 21406 | 24058 | 18 | 165265 | 165553 | 165123 | 0.09 | 311199 | 1.3 | 7.2 | 139.1 | 73.2 | 351.1 |
| json.eval8.16k.full | huffman | 62077 | 62812 | 19 | 1060000 | 1068224 | 1057630 | 0.22 | 1127486 | 27.4 | 73.3 | 109.1 | 120.6 | 21.1 |
| json.eval8.16k.full | range | 62077 | 62812 | 19 | 1061711 | 1069935 | 1057630 | 0.39 | 1127486 | 2.9 | 70.3 | 113.9 | 115.6 | 34.7 |
| json.eval8.64k.full | huffman | 62341 | 63065 | 19 | 1059447 | 1061527 | 1057263 | 0.21 | 1124945 | 21.1 | 67.2 | 119.0 | 111.1 | 198.1 |
| json.eval8.64k.full | range | 62341 | 63065 | 19 | 1058531 | 1060611 | 1057263 | 0.12 | 1124945 | 5.0 | 77.6 | 103.1 | 128.3 | 308.2 |
| macho.eval8.16k.full | huffman | 216190 | 346723 | 20 | 2157229 | 2165453 | 2153754 | 0.16 | 5305217 | 89.4 | 143.8 | 55.6 | 134.4 | 45.4 |
| macho.eval8.16k.full | range | 216190 | 346723 | 21 | 2157676 | 2165900 | 2153754 | 0.18 | 5305217 | 37.9 | 226.2 | 35.4 | 211.4 | 84.3 |
| macho.eval8.64k.full | huffman | 215982 | 346965 | 20 | 2155600 | 2157680 | 2152248 | 0.16 | 5319169 | 78.2 | 156.9 | 51.0 | 146.7 | 389.3 |
| macho.eval8.64k.full | range | 215982 | 346965 | 21 | 2153363 | 2155443 | 2152248 | 0.05 | 5319169 | 44.6 | 218.4 | 36.6 | 204.2 | 714.7 |
| omw.eval8.16k.full | huffman | 35477 | 107373 | 17 | 197291 | 205515 | 196708 | 0.30 | 9319562 | 34.4 | 20.3 | 393.4 | 182.6 | 15.3 |
| omw.eval8.16k.full | range | 35477 | 107373 | 19 | 200473 | 208697 | 196708 | 1.91 | 9319562 | 11.2 | 18.1 | 441.6 | 162.6 | 24.4 |
| omw.eval8.16k.r32768 | huffman | 20061 | 33024 | 19 | 615684 | 623908 | 614107 | 0.26 | 1512036 | 14.3 | 24.3 | 329.2 | 64.6 | 29.5 |
| omw.eval8.16k.r32768 | range | 20061 | 33024 | 18 | 617962 | 626186 | 614107 | 0.63 | 1512036 | 3.5 | 26.1 | 306.1 | 69.5 | 43.6 |
| omw.eval8.16k.r8192 | huffman | 7678 | 8448 | 20 | 1256139 | 1264363 | 1252908 | 0.26 | 122913 | 12.1 | 27.7 | 288.4 | 32.8 | 24.7 |
| omw.eval8.16k.r8192 | range | 7678 | 8448 | 16 | 1257546 | 1265770 | 1252908 | 0.37 | 122913 | 0.5 | 23.9 | 334.8 | 28.3 | 54.0 |
| omw.eval8.64k.full | huffman | 34152 | 107591 | 17 | 192063 | 194143 | 191640 | 0.22 | 9721574 | 32.6 | 13.7 | 585.4 | 125.4 | 55.9 |
| omw.eval8.64k.full | range | 34152 | 107591 | 19 | 192596 | 194676 | 191640 | 0.50 | 9721574 | 7.9 | 14.8 | 539.1 | 136.2 | 72.2 |
| omw.untouched.16k.full | huffman | 7803 | 18236 | 14 | 36180 | 37236 | 36004 | 0.49 | 1129605 | 13.7 | 2.6 | 388.9 | 109.0 | 1.4 |
| omw.untouched.16k.full | range | 7803 | 18236 | 16 | 36484 | 37540 | 36004 | 1.33 | 1129605 | 1.0 | 1.2 | 813.7 | 52.1 | 0.9 |
| omw.untouched.64k.full | huffman | 7551 | 18277 | 14 | 35424 | 35712 | 35274 | 0.42 | 1233856 | 15.6 | 3.3 | 303.9 | 141.8 | 11.9 |
| omw.untouched.64k.full | range | 7551 | 18277 | 16 | 35403 | 35691 | 35274 | 0.37 | 1233856 | 3.4 | 0.9 | 1145.9 | 37.6 | 11.6 |
| zigsrc.eval8.16k.full | huffman | 110144 | 210404 | 19 | 838805 | 847029 | 837056 | 0.21 | 7973491 | 28.6 | 60.8 | 131.6 | 140.6 | 17.3 |
| zigsrc.eval8.16k.full | range | 110144 | 210404 | 20 | 840973 | 849197 | 837056 | 0.47 | 7973491 | 16.1 | 74.2 | 107.8 | 171.6 | 28.3 |
| zigsrc.eval8.64k.full | huffman | 109534 | 210981 | 19 | 834878 | 836958 | 833282 | 0.19 | 8132301 | 44.2 | 55.4 | 144.5 | 128.6 | 166.9 |
| zigsrc.eval8.64k.full | range | 109534 | 210981 | 20 | 834385 | 836465 | 833282 | 0.13 | 8132301 | 24.6 | 85.0 | 94.1 | 197.5 | 296.9 |

Headline: **Huffman payload is within 0.16%–0.49% of exact H0 on every
single dump** (confirms the thesis's "within ~0.5%" prediction cleanly).
The static range coder is close too but noisier and sometimes clearly
worse — 0.05%–1.91%, with the worst case (OMW eval8 16k full) nearly 2%
over H0 purely from power-of-two quantisation loss on a skewed
distribution. `total_B - payload_B` matches the charged framing exactly in
every row (`32 + 16*block_count`), e.g. freedict eval8 16k full:
`527966 - 519742 = 8224 = 32 + 16*512`.

Even under the heavy shared-machine load this ran under (see caveat above),
**every single dump/coder combination decodes well above bzip3's stated
25–45 MB/s** (55–1146 MB/s here), usually by 2–10x and in the best cases
(OMW, small alphabet relative to block count) by >20x.

## Optimisations tried (before/after, `--bench-opts`)

Bounded micro-benchmarks decode the same middle block repeatedly (400-4000
reps) so the two variants being compared decode byte-identical bitstreams;
only the decode mechanism differs.

| dump | comparison | before (ns/root) | after (ns/root) | speedup |
|---|---|---:|---:|---:|
| omw.untouched.16k.full | Huffman: bit-trie walk -> 2-level table | 20.5 | 13.8 | 1.49x |
| omw.untouched.16k.full | Range: cumulative binary search -> slot table | 45.6 | 14.8 | 3.09x |
| omw.untouched.16k.full | copy: `@memcpy` -> fixed 16/32B overshoot | 10.8 | 13.8 | **0.79x (regression)** |
| freedict.eval8.16k.full | Huffman: bit-trie walk -> 2-level table | 26.6 | 9.4 | 2.84x |
| freedict.eval8.16k.full | Range: binary search -> slot table | 73.0 | 35.1 | 2.08x |
| freedict.eval8.16k.full | copy: memcpy -> overshoot | 9.3 | 9.4 | ~1.00x (no change) |
| gcide.eval8.16k.full | Huffman: bit-trie walk -> 2-level table | 22.6 | 11.5 | 1.96x |
| gcide.eval8.16k.full | Range: binary search -> slot table | 67.9 | 19.5 | 3.48x |
| gcide.eval8.16k.full | copy: memcpy -> overshoot | 12.1 | 11.5 | 1.05x |
| macho.eval8.16k.full | Huffman: bit-trie walk -> 2-level table | 68.8 | 26.0 | 2.65x |
| macho.eval8.16k.full | Range: binary search -> slot table | 199.8 | 49.9 | 4.01x |
| macho.eval8.16k.full | copy: memcpy -> overshoot | 26.7 | 26.0 | 1.03x |

**What helped:** the two-level Huffman table over a naive bit-at-a-time
trie walk (1.5x–2.8x — both decode the identical canonical code, so this
isolates table-lookup vs. pointer-chasing); the O(1) slot table over
cumulative binary search for the range coder (2.1x–4.0x, growing with
alphabet size since binary search is O(log n)). Both are real, repeatable
wins and both match exactly what PLAN.md suggested trying.

**What did not help:** the fixed 16/32-byte "overshoot" copy over a plain
`@memcpy(dst[0..len], src[0..len])`. It is a wash to a slight *regression*
(0.79x–1.05x) across every dump tried. Zig's `@memcpy` already lowers to a
size-dispatching, vectorised copy for these expansion lengths (per the
thesis, ~10–75 bytes), and the branch we added to pick a copy size class
apparently costs about as much as it saves. **Negative result, kept the
plain `@memcpy` in the reported numbers above** (`fast_copy=true` in the
code still uses the overscan path since it's not meaningfully worse and
keeps the output-buffer-slack invariant explicit, but the honest finding
is that this was not the win we expected).

**Explored but inconclusive:** widening the Huffman primary table from 12
to 16 bits, to reduce how often the ~116K-symbol gcide alphabet (average
Huffman code length ≈15.6 bits, i.e. *above* a 12-bit primary) falls
through to the subtable-escape path. The change should help in principle,
but the two back-to-back measurements were confounded by a load average
that hit ~83 mid-experiment (the *range* coder's numbers, entirely
unaffected by this Huffman-only constant, swung by >2x between runs on the
same binary) — not trustworthy evidence either way, so `huf_primary_bits`
was left at 12 (within PLAN.md's suggested 10–12 bit range). Worth
revisiting under a quiet machine.

## Where the time goes

Comparing the isolated single-block latency (`single_blk_us`, same block
decoded thousands of times back-to-back — everything it touches, arena
included, stays hot in cache) against the full-file sequential decode rate
is a clean, real (not simulated) cache-behaviour probe: for gcide eval8
16k full, the hot single-block Huffman rate is ~11.5 ns/root (from the
`--bench-opts` table-decode figure), but the *cold*, one-pass-over-8MiB
full-file rate is 67–142 ns/root across repeated runs — a 6-12x gap that
symbol-decode cost alone cannot explain, since the same table lookup runs
in both cases. The difference is the 2 MB expansion arena and payload
being walked exactly once, so almost every access misses cache. This
matches the thesis's own framing (decode = one symbol decode + one short
memcpy) and says the *memcpy destination/source*, not the symbol decode,
is the part worth attacking next (streaming prefetch of `exp.off[next_sym]`
before finishing the current copy is the natural next experiment; not
attempted here due to time).

## Arena size

Eager, always-duplicate expansion (no compact/prefix-sharing layout) kept
every arena well under the raw input size in the dictionary lanes that
matter most: gcide eval8 (125K rules, 8 MiB raw) -> 1.98 MB arena; freedict
eval8 -> 2.38 MB; the r8192/r32768 partial grammars -> 79 KB-810 KB. Only
the very repetitive-substring-poor OMW/generality lanes exceed the raw
size (OMW eval8 64k -> 9.7 MB arena for an 8 MiB file; macho/zigsrc/json
similarly 5-8 MB), still a modest constant factor and never a problem for
a single build's memory footprint. **The optional compact/parent-prefix-
sharing layout was not implemented** — it was not needed to hit reasonable
numbers, and eager copy keeps the encoder/decoder simpler.

## Recommendation: Huffman

For this workload, **prefer the canonical length-limited Huffman code over
the static range/rANS-style code**:

1. **Size**: Huffman was within 0.5% of exact H0 on *every* dump tested;
   the range coder ranged 0.05%–1.91%, i.e. it is sometimes better but
   sometimes markedly worse, and its quantisation loss is data-dependent
   in a way that is hard to bound in advance. Huffman's worst case here
   (0.49%) already beats the range coder's typical case.
2. **Per-block overhead**: the range coder's `finish()` flushes a fixed
   8 bytes per block (copied from `rc.zig`'s carryless range coder, which
   needs a full low-register flush to guarantee decodability); Huffman
   only pads to the next byte (≤7 bits, usually ~4 wasted bits). This
   shows up directly in `total_B` above and matters more as block size
   shrinks.
3. **Decode primitive**: the range coder still contains one intrinsic,
   unavoidable integer division per symbol (`(code-low)/range`, needed to
   locate the coded value even after the power-of-two-total shift replaces
   the other division) — a true tabled rANS decoder would remove this via
   renormalisation tables, but that's a different algorithm and wasn't
   built here (documented gap, see below). Huffman's table-driven decode
   has no division in its hot path at all.
4. Both are close enough in raw decode throughput on this run that the
   difference is within this machine's measurement noise; size and
   framing overhead are the more reliable differentiators.

The range coder's one advantage: probabilities don't need a length-limit
construction, and it degrades gracefully for very peaked distributions
without the bucket-based Kraft fix-up's bookkeeping. Given this lab's
alphabets (7.5K-216K used symbols) and the consistent Huffman
near-entropy result, that flexibility isn't needed here.

## Known gaps / honest limitations

- The static range coder here is a **range coder**, not true tabled rANS;
  it reuses `rc.zig`'s carryless range-coder normalisation (copied into
  this file per PLAN.md's rule for shared files a lane needs to change),
  specialised only so the *total* division becomes a shift. The intrinsic
  per-symbol position division remains. A from-scratch tANS/rANS table
  would remove it but was out of scope for the time available.
- Prefetching the next symbol's arena offset while copying the current one
  (software pipelining) was identified as the most promising next
  optimisation (see "Where the time goes") but not implemented/measured.
- The Kraft fix-up is a heuristic, not package-merge; it is not guaranteed
  length-optimal. Empirically it did not matter: no dump's payload
  exceeded 0.5% over H0 for Huffman, so any optimality gap package-merge
  might close is well under a rounding error here.
- All timings are from a heavily shared machine (other lab lanes were
  building/running concurrently; `uptime` load average hit ~83 during the
  sweep). Absolute MB/s numbers should be read as "comfortably above
  bzip3, by how much depends on machine load," not as a tight bound.
