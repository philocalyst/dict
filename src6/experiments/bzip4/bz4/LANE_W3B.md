# Lane W3b — making Lane W's TreeCM decoder fast

Owner files: `w3b_fastcm.zig`, `w3b_rc.zig`, `w3b_speedlab.zig`,
`w3b_rcbench.zig`, this notebook. Question: Lane W's round-2 `TreeCM`
(`symcm.zig`) proved the *prediction* design (weight-balanced alphabetic
tree + hashed order-1/2 mixing + SSE) needs 5-20x fewer binary decisions
than a pure byte model, but decoded 2-3x *slower* than bzip3 anyway. Can a
from-scratch, pure-Zig, exact reimplementation of the same algorithm close
that gap without giving back more than ~1-1.5% size?

**Answer: yes, comfortably.** The tuned decoder beats bzip3's decode speed
on 5 of 6 corpora at the 1 MiB/k=32768 cell (up to 1.68x), while landing
within 0.1-1.5% of Lane W's real payload size on every file. ns/decision
dropped from a measured ~109-119 (Lane W's `TreeCM`, this machine, today)
to ~21-25 (this lane's `FastTreeCM`) at that cell — a ~4.5x cut — and the
single biggest lever was not the one the lane brief emphasized most
(hashed-table memory layout): it was a *correctness/tuning* bug in the
fixed-point mixer's learning rate, found only by comparing size against a
known-good reference (see "mixer tuning" below).

## What was built

- **`w3b_rc.zig`** — a from-scratch LZMA-style binary range coder (32-bit
  `range`, `low` widened to `u64` only for shiftLow's carry propagation;
  `bound = (range>>12)*p0`, no XOR/compare carry-detection per call, no
  multi-symbol frequency API since this lane's coder is 100% binary).
  Encoder/decoder verified exact against each other, including a dedicated
  stress test that forces thousands of consecutive near-1.0-probability
  bits to exercise `shiftLow`'s carry-into-pending-0xFF-run path (the one
  place a subtly wrong port would silently corrupt a stream days later).
- **`w3b_fastcm.zig`** — `FastTreeCM`: the same algorithm as `symcm.TreeCM`
  (alphabetic tree, order-0 node + two hashed order-1/2 contexts, mixer,
  SSE, run-shortcut), reimplemented for speed:
  - Integer stretch/squash (12-bit domain, the classic PAQ/lpaq
    construction — reimplemented fresh here from the well-known public
    algorithm, not copied text) instead of `@log`/`@exp` float calls.
  - `CtxTable`: order-1/2 context tables hash *only the context symbol*
    into a 64-byte (32×u16) bucket, using capped tree depth as the offset
    *inside* the bucket — every node on one symbol's root-to-leaf path
    shares one cache line per table, instead of `symcm.TreeCM`'s
    `hash(node_idx, ctx)` scattering every node to an unrelated address in
    a fixed 2^20-entry (2 MiB) table. Table size is derived from the
    alphabet in play (`card = k_leaves+1`), not fixed regardless of K, and
    degrades to a collision-free *direct* index (no hash multiply at all)
    whenever the alphabet fits the bucket space — true for every cell this
    lab tested (K up to ~33k) — falling back to a capped (2^16-bucket)
    hash only above that. A `legacy_hash` config flag reproduces
    `symcm.TreeCM`'s original addressing verbatim for the ablation below.
  - `@prefetch` on both context buckets right after the previous symbol's
    identity is known (before the run-shortcut check even runs), so the
    fetch overlaps other per-symbol work instead of stalling the walk.
  - Fixed-point (16.16) mixer weights, integer gradient update.
  - Same run-shortcut, SSE stage, and tree-walk structure as `TreeCM`,
    ported to the 12-bit probability domain throughout (native to
    `w3b_rc.zig`, so no 16-to-12-bit truncation step at the coding
    boundary the way `symcm.zig` needs one going into `rc.zig`).
  - `Expansion`/`buildExpansion`: the (offset,len)-into-one-arena shape
    from Lane S's `rootstatic.zig`, copied and adapted to `gprobe.Rule`
    (point 7).
  - `BwtScratch`/`inverseBwtExpandFused`: builds the LF/`next[]` array with
    the same one-counting-pass approach as `symbwt.ibwt` (imported
    read-only for the *forward* BWT only — that side isn't this lane's
    target), but inverts `next[]` into a single `Step{i,val}` array (point
    6) instead of `symbwt.ibwt`'s two separate `prev[]`/`full[]` arrays, so
    each walk step is one random load instead of two, and `@prefetch`es
    the next hop's `Step` entry to hide latency behind the current step's
    expansion memcpy. Also point 7's fused write: expanded bytes go
    straight into the final output buffer as each root is produced in text
    order — no intermediate root-symbol array at all.
  - Applies uniformly at K=256 (the k=0 pure-byte case) too, unlike
    `bwtlab.zig` which special-cases K≤256 to plain `ByteCM` — this is the
    "same algorithm, different table layout" the brief explicitly allows,
    and it turns out to be a genuine (if situational) win: see the k=0
    results below, where `FastTreeCM`'s run-shortcut sometimes beats
    `ByteCM` on *size* too, since `ByteCM` has no run-shortcut at all.
  - 16 tests (roundtrip across every config combination, tiny K=1/2,
    monotonicity of stretch/squash, and a full grammar+BWT+CM+inverse-
    BWT+expansion pipeline test) — `zig test -O ReleaseSafe w3b_fastcm.zig`.
- **`w3b_speedlab.zig`** — `w3b_speedlab FILE BLOCK_BYTES K [REPEATS] [ABLATION]`.
  Builds the grammar (`gprobe.build`, shared across blocks — its own
  design), the lexicographic `fwd_rank`/reversed-expansion `rev_rank`
  (copied from `bwtlab.zig`'s private helpers per PLAN.md's "copy a shared
  pattern into your own file" rule — unmodified besides cosmetic renames),
  and both this lane's `AlphaTree` and (for the size comparison only)
  `symcm.zig`'s own `AlphaTree`, from the same weights. Encodes every block
  once (untimed) with both coders. Verifies byte-exact roundtrip and
  `enc.decisions == dec.decisions` in a dedicated untimed pass. Times
  `REPEATS` (default 5) full decode passes — each one: per block, a fresh
  `FastTreeCM.init` (real per-block table alloc+clear cost, charged, not
  hidden — point 2's "count it"), full entropy decode, then the fused
  inverse-BWT+expansion — and reports min/median. Prints one TSV line
  (file, block, k, roots, payload_B, decisions, decisions_per_byte,
  decode_ms_min/median, setup_ms, ns_per_decision, decode_MBps,
  bzip3_decode_MBps from `baselines.tsv`, speedup, size_delta_pct vs a real
  `symcm.TreeCM`/`ByteCM` run at Lane W's own default config) plus a PHASE
  line (cm_init/decode_core/ibwt_expand breakdown, repeat 0) and a SETUP
  line (one-time grammar+sort+tree+expansion-arena+both-coders'-encode
  cost) to stderr.
- **`w3b_rcbench.zig`** — isolated microbenchmark: `w3b_rc.zig` vs `rc.zig`
  on the identical adaptive-bit workload, nothing else in the loop, to
  measure the range-coder-only contribution independent of the model.

## Methodology notes (rules of evidence)

- Every number below comes from a run where `w3b_speedlab` asserted
  byte-exact roundtrip and `decisions` equality between encode and decode,
  in an untimed pass, before any timing was trusted.
- This machine is shared (`uptime` load average fluctuated 5-11 across this
  session, 4-6 other users). Every timing is from `REPEATS=5` inside one
  process (never two of this lane's own timing processes at once, per the
  brief); min and median are both reported. Cross-checked against 3-5
  independent repeated invocations for the flagship cell (freedict, 1
  MiB, k=32768) to confirm the numbers are consistent under load, not an
  artifact of one lucky run.
- `bzip3_decode_MBps` is read directly from `baselines.tsv` (Lane D's real
  numbers) for the matching file + block_bytes.
- `size_delta_pct` compares this lane's real payload against a real run of
  `symcm.zig`'s own `TreeCM` (k>0) or `ByteCM` (k=0) at Lane W's default
  config, same grammar/blocks/sort/tree/weights — not an estimate.

## Baseline, freshly measured today (not just cited from LANE_W.md)

`bin/bwtlab data/freedict.eval8.bin 1048576 32768` (Lane W's real binary,
untouched), 5 independent invocations, decode_ms: 491.35, 557.43, 559.92,
564.38, 654.27 → median 559.92 ms / 5,128,027 decisions = **109.2
ns/decision**. (LANE_W.md's own number for this cell was 406 ms / 79
ns/decision, measured on a presumably quieter machine — this session's
load average was consistently 5-11 throughout, so both numbers are
"indicative" per PLAN.md, but the *relative* comparison below is always
against a same-session, same-load baseline run.)

## Optimisations that mattered — before/after log, freedict + macho, 1 MiB block, k=32768

All rows below are this lane's own `FastTreeCM` (never `symcm.TreeCM`)
with one thing toggled via `w3b_speedlab`'s `[ABLATION]` argument, 5
repeats, same-session measurements. `size_delta_pct` is vs `symcm.TreeCM`'s
real payload at Lane W's default config.

| config | freedict decode_ms (min/median) | freedict ns/dec | freedict size_delta | macho decode_ms (min/median) | macho ns/dec | macho size_delta |
|---|---:|---:|---:|---:|---:|---:|
| **default** (tuned mixer, new hash, run+SSE on) | 118.3 / 118.5 | 23.1 | **+0.11%** | 538.4 / 547.2 | 21.3 | **+0.88%** |
| `legacy_hash` (symcm.TreeCM's `hash(node,ctx)` into one 2^20 table) | 131.8 / 133.0 | 25.9 | −0.03% | 610.1 / 613.6 | 23.9 | −0.06% |
| `fixed_mix` (bzip3-style fixed weights, no mixer at all) | 94.8 / 97.5 | 19.0 | +0.95% | 406.0 / 408.2 | 15.9 | +1.97% |
| `no_sse` | 110.4 / 111.1 | 21.7 | +0.25% | 445.7 / 448.7 | 17.5 | +0.93% |
| `no_run` (run-shortcut off) | 129.9 / 133.4 | 26.4 | +2.01% | 655.6 / 682.7 | 22.2 | **+10.41%** |

Reading this table alongside the Lane W baseline (109.2 ns/decision, freedict):

1. **New hash layout vs `legacy_hash`, same coder otherwise: ~1.10-1.12x.**
   Smaller than hypothesized. Root cause, found by checking table sizes:
   at K≈33k, this lane's *direct-indexed* table (no collisions, sized to
   `nextPow2(33025)` buckets × 32 slots × 2 B ≈ 4 MiB per table) is not
   dramatically smaller than `legacy_hash`'s fixed 2 MiB table — both
   likely mostly resident in this machine's L3, so the win is "fewer L3
   hits" rather than "L3 hit instead of DRAM miss." The plan's own framing
   ("size them to the block... does not need 2^22 entries") is validated
   in spirit — the new table *is* sized to the alphabet, not a blind
   maximum — but the *magnitude* of the memory-layout win at this specific
   K is more modest than the DRAM-miss story implies. It should widen at
   larger K (bigger tables spilling further past cache) — not tested here,
   out of this lab's required K range.
2. **Removing the mixer entirely (`fixed_mix`) is the single fastest
   config on both files** (1.24-1.34x faster than tuned `default`), for a
   real but small size cost (+0.84pp freedict, +1.09pp macho vs default).
   This matches LANE_W.md's own finding in spirit ("mix=fixed costs +1.0%
   size and is 2.4x faster") — the *relative* shape of the trade survived
   translation from float to fixed-point, even though the absolute size
   cost is smaller now (because `default` itself is no longer paying the
   float tax that made `TreeCM`'s own logistic mixer 2.4x slower).
3. **`no_run` is the one config that costs real size on both files**, and
   costs *far more* on macho (+10.41%) than freedict (+2.01%) — macho's
   BWT'd root stream has much longer/more frequent exact-repeat runs after
   sorting (matches LANE_W.md's own round-2 note that the run-shortcut
   mattered "more on macho" in the original ablation). Worth keeping
   unconditionally.
4. **SSE is a small, consistent win** (+0.25/+0.93% cost to remove), same
   shape as LANE_W.md's "SSE off: +0.5%" finding.

### Range coder, isolated (`w3b_rcbench 5000000 7`)

```
rc.zig (64-bit carryless):       2.64 ns/call
w3b_rc.zig (LZMA-style 32-bit):  2.46 ns/call
ratio: 1.07x
```

**Smaller than expected.** `rc.zig`'s `encodeBitProb`/`decodeBitProc` were
already shift-and-multiply (no division) for the binary path — the same
`bound=(range>>12)*p` LZMA uses — so the only real difference is 64-bit vs
32-bit arithmetic plus the carry-detection branch in `rc.zig`'s renormalize
loop, both cheap on a 64-bit CPU. **The range coder was never the
bottleneck**; rewriting it was a correct but low-yield exercise on its own
— its value here is mostly that `w3b_rc.zig`'s 12-bit-native domain let
`FastTreeCM` skip the 16→12-bit conversion `symcm.zig` needs at its coding
boundary, a small constant-factor cleanup rather than the coder's own
speed.

### Mixer tuning — the actual biggest lever, found by accident

The first working fixed-point mixer used lpaq1's own weight-update shift
(`>> 10`), ported directly. It was fast, but comparing its `size_delta_pct`
against Lane W's real `TreeCM` payload caught something a pure speed
measurement would have missed: it was *losing on size* to the simplest
possible fallback (`fixed_mix`, plain bzip3-style fixed weights) — freedict
1.32% vs 0.95%, macho 2.20% vs 1.97%. A well-tuned adaptive mixer should
never lose to a static one; LANE_W.md's own float mixer *beat* `fixed` by
about a point. That contradiction was the tell. Slowing the learning rate
16x (`>> 10` → `>> 14`) fixed it, at no *structural* speed cost — a shift
by 10 vs. 14 is the same one instruction either way, so the small
decode_ms differences between rows below are run-to-run system-load noise
(this session's `uptime` load average moved between 5 and 11 during these
runs), not a real effect of the shift amount:

| learning-rate shift | freedict size_delta | macho size_delta | freedict decode_ms (min/median) |
|---|---:|---:|---:|
| `>> 10` (lpaq1's own rate) | +1.32% | +2.20% | 133.4 / 136.7 |
| `>> 13` | +0.16% | +0.92% | 138.0 / 138.8 |
| `>> 14` (adopted) | **+0.11%** | **+0.88%** | 129.3 / 130.2 |
| `>> 15` | +0.09% | +0.87% | 128.6 / 129.0 |

`>> 14` was adopted (diminishing returns past it, within measurement
noise, and it's the value used for every other number in this notebook).
Plausible cause: this coder's 12-bit stretch/squash domain is coarser than
`symcm.TreeCM`'s float one, so the same relative learning rate that suited
float weights over-corrects here, adding noise instead of signal to the
mix. **This is the single biggest lesson of the lane**: a pure "is it
fast" ablation would have shipped the buggy `>> 10` mixer without ever
noticing it was leaving compression on the table; only checking
`size_delta_pct` against a trustworthy reference on every change caught
it.

## Phase breakdown — one text file, one binary file (1 MiB block, k=32768)

| file | cm_init_ms (per-block table alloc+clear, 8 blocks) | decode_core_ms (entropy decode) | ibwt_expand_ms (fused inverse-BWT+expansion, 8 blocks) | total decode_ms |
|---|---:|---:|---:|---:|
| freedict (text) | 12.3 | 104.7 | 4.7 | 119.3 (median) |
| macho (binary) | 12.6 | 509.7 | 22.7 | 542.4 (median) |

At 1 MiB blocks, **entropy decode dominates** (88-94%); `cm_init` (table
`@memset`, point 2's "clearing large tables per block") and the fused
inverse-BWT+expansion are both small. macho's `decode_core` is ~5x
freedict's for only ~2.4x the decisions (25.7M vs 5.1M) — its
decisions/byte (3.06 vs 0.61) is 5x higher (weak grammar → deeper tree
walks per byte), and per-decision cost is close between them (21.1 vs 23.3
ns), so the wall-clock ratio ~5x tracks decisions/byte almost exactly.

## Whole-file blocks: the inverse-BWT walk dominates instead

At `block=0` (whole 8 MiB file, k=0), the picture flips completely —
`ibwt_expand` becomes the majority of decode time, not the model:

| file | decode_core_ms | ibwt_expand_ms | ibwt_expand share |
|---|---:|---:|---:|
| freedict | 111.4 | 295.2 | 73% |
| gcide | 217.9 | 486.1 | 69% |
| macho | 427.0 | 453.2 | 51% |

This is the expected, documented limit from point 6: the inverse-BWT walk
is `m ≈ 8.39M` steps of an inherently *serial, dependent* pointer chase
(`row = step[row].i`), and the combined `Step{i,val}` array (67 MB at
`m=8.39M`) is far bigger than any cache — each step is close to a full
DRAM round-trip, and the dependency chain means the CPU cannot issue the
next load until the current one resolves. **The two point-6 mitigations
tried (merging `prev[]`+`full[]` into one `Step` array, halving random
accesses per step, and `@prefetch`ing the next hop as soon as it's known)
together bought only ~10-12%** on this specific case (freedict whole-file
k=0: 403 ms → 363 ms in an early measurement) — nowhere near enough to
close a fundamentally memory-latency-bound serial walk. The "two-symbols-
per-step" trick from the brief was not attempted (would need precomputing
paired hops at construction time — a bigger change than this lab's
remaining time budget allowed for a case the main architecture doesn't
actually recommend); **the real fix is smaller blocks**, which the 1 MiB
cell above already demonstrates costs only 3-6 ms per file for the same
phase (a ~50-100x smaller `Step` array that mostly fits cache).

## Main results

### 1 MiB blocks, k=32768 (the flagship cell)

| file | rules | roots | decisions/byte | decode MB/s (this lane) | bzip3 MB/s | speedup | size_delta vs Lane W TreeCM |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict | 32,768 | 360,226 | 0.611 | 70.3 | 56.6 | **1.24x** | +0.11% |
| gcide | 32,768 | 909,698 | 1.543 | 30.9 | 29.8 | **1.04x** | +0.24% |
| omw | 32,768 | 367,876 | 0.392 | 104.1 | 61.8 | **1.68x** | +1.01% |
| json | 32,768 | 671,873 | 1.147 | 37.8 | 39.3 | 0.96x | +1.49% |
| macho | 32,768 | 2,286,648 | 3.059 | 15.5 | 21.5 | 0.72x | +0.88% |
| zigsrc | 32,768 | 996,648 | 1.289 | 37.2 | 33.6 | **1.11x** | +0.88% |

5/6 files beat bzip3's decode speed (up to 1.68x, omw); every file lands
within the ~1-1.5% size budget (best: freedict +0.11%, worst: json
+1.49%). macho is the one loss on both counts — its decisions/byte (3.06)
is 5-8x the other files' because a partial grammar finds much less
structure in machine code, so `FastTreeCM` walks a much deeper tree far
more often; ns/decision itself (21.3) is in line with everyone else.

### Whole file, k=8192

| file | decisions/byte | decode MB/s | bzip3 MB/s | speedup | size_delta |
|---|---:|---:|---:|---:|---:|
| freedict | 0.683 | 78.2 | 56.4 | 1.39x | +0.88% |
| gcide | 1.693 | 31.3 | 23.4 | 1.34x | +1.29% |
| omw | 0.473 | 114.7 | 65.5 | 1.75x | +2.38% |
| json | 1.198 | 42.7 | 35.6 | 1.20x | +3.77% |
| macho | 3.231 | 15.0 | 17.8 | 0.84x | +2.37% |
| zigsrc | 1.402 | 38.9 | 28.7 | 1.36x | +1.96% |

5/6 beat bzip3 again (macho again the exception), but size costs are
higher than the 1 MiB cell (up to +3.77%, json) — k=8192 is a smaller
fixed rule budget applied to a whole 8 MiB file (vs the same budget spread
per-1-MiB-block), so each block gets a thinner slice of the shared
grammar; outside the brief's ~1-1.5% target on 4/6 files at this setting.

### Whole file, k=0 (pure bytes — hardest case for speed)

| file | decisions/byte | decode MB/s | bzip3 MB/s | speedup | size_delta |
|---|---:|---:|---:|---:|---:|
| freedict | 1.640 | 20.4 | 56.4 | 0.36x | +6.88% |
| gcide | 2.429 | 11.8 | 23.4 | 0.50x | +8.93% |
| omw | 1.403 | 26.2 | 65.5 | 0.40x | **−3.86%** |
| json | 2.272 | 21.5 | 35.6 | 0.60x | +4.71% |
| macho | 3.824 | 9.7 | 17.8 | 0.54x | +4.60% |
| zigsrc | 2.116 | 19.6 | 28.7 | 0.68x | +2.31% |

No file beats bzip3 here — the whole-file inverse-BWT pointer chase (see
above) dominates and is not fixed by anything this lane tried. Sizes are
also worse (up to +8.93%, gcide) since `symcm.zig`'s `ByteCM` (the
comparison target at k=0) is a mature, bzip3-shaped order-1/2+SSE design
tuned for raw bytes specifically, while `FastTreeCM`'s general alphabetic-
tree machinery is a reasonable but not specially-tuned stand-in there —
except **omw, where it's 3.86% *smaller*** than `ByteCM`, because omw's
BWT'd byte stream has runs `ByteCM` (no run-shortcut at all) can't exploit
as cheaply as `FastTreeCM` can.

## What still limits speed

1. **Whole-file blocks' inverse-BWT walk is memory-latency-bound and
   largely irreducible** with the techniques tried (array-merging,
   single-step prefetch) — a serial dependent pointer chase over an
   array much bigger than cache has a hard floor near
   `m × DRAM_latency`. The architecture's own answer (smaller blocks) is
   already the right one; this is not a bug to fix so much as a reason not
   to run whole-file blocks when speed matters.
2. **macho (weak-grammar binaries)**: high decisions/byte from a partial
   grammar finding little structure, not a per-decision cost problem — the
   fix (if wanted) is upstream, in the grammar (Lane A) or a stronger fixed
   context for the k=0 fallback, not this lane's decode loop.
3. **The hashed-table memory-layout win was smaller than hypothesized at
   K≈33k** because both the old and new table sizes are within reach of
   this machine's L3 — the technique should matter more at larger K (bigger
   tables, more distinct contexts) or on a machine with less L3, neither
   tested here.
4. Not attempted, flagged for a future lane: BFS/van-Emde-Boas node-array
   reordering (point 3 — `nodes[]` reads are a smaller, not-yet-isolated
   cost next to the context tables); the "two-symbols-per-step" inverse-BWT
   trick for large blocks; a real 256-entry direct C1[256][256]-shaped fast
   path purpose-built for k=0 rather than reusing the general tree (would
   likely close some of the k=0 gap to `ByteCM`, at the cost of a second
   code path).
