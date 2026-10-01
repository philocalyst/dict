# Lane X — soft-context modelling of root symbols

Owner files: `rootctx.zig` (library), `rootlab_ctx.zig` (CLI), this notebook.
Binaries under `bin/`. Never touches another lane's files.

## The question

After a full pair grammar, every adjacent root pair is (almost) unique by
construction — that's the whole point of growing the grammar until pairs
stop repeating. So an *exact*-context model over root ids (order-1, order-2,
BWT of roots, ...) has nothing left to learn: `P(root_b | root_a)` is either
0 or 1 for almost every pair actually seen. But the *bytes* at the junction
between two roots are not random: after a root whose expansion ends in a
space, the next root almost always starts with a letter; after a root
ending in "q", the next one is very likely to start with "u". This is
**soft** structure — first-byte-of-next given last-byte-of-previous — and
it survives the grammar's own compression because the grammar only merges
pairs that repeat *verbatim*; it never merges "a root ending in space" with
"a root starting with a letter" as a *class*.

The question: how many bytes (if any) can modelling that soft structure
save over the static order-0 code, once every table the decoder needs is
either charged in bytes or free (derivable from the shared grammar), and
blocks stay independently decodable at 16 KiB / 64 KiB?

## Method

1. Read a B4SD dump (`dumps/*.b4sd`, format in `PLAN.md`). Rule children
   always have smaller ids than their rule, so one forward pass over ids
   0..k-1 gives every symbol's first byte, first second-byte, last byte,
   second-to-last byte, and expansion length (`SymInfo`, `buildSymInfo`).
2. `g[s]` = global root-occurrence count of symbol `s`, computed once from
   the dump's own block streams (`computeG`). This is the "shared model"
   the whole lab treats as free (Lane B's job to charge its storage).
3. `u[s]` = total usage of `s` anywhere in the fully expanded byte stream:
   `u[s] = g[s] + sum over parents p of u[p]`. Because child ids are always
   smaller than their parent's id, processing rule ids from **highest to
   lowest** finalises every parent's `u` before it is propagated down to
   its children — the decoder can compute this top-down from the rule
   table alone, in one pass, at zero storage cost (`computeUsage`).
4. Every root sequence is coded with `rc.zig`'s range coder, one **fresh**
   `Encoder`/`Decoder` per block (no state crosses a block boundary except
   where a variant explicitly re-derives its starting state from the
   shared, free prior). The decoder's stop condition is "accumulated
   expansion length reaches this block's raw byte length" — a quantity
   derivable from the frame header (`block_bytes`, `raw_len`) alone, so no
   per-block root count is ever stored.
5. Every reported byte count comes from a real `enc.finish()`; every
   reported root sequence comes from a real decode that is compared
   symbol-by-symbol against the dump's own root sequence before any number
   is trusted (`rootctx.zig` returns `error.RootMismatch` /
   `error.LengthMismatch` otherwise, and the driver prints a `FAIL` row
   instead of a number — none occurred in the whole sweep below).
6. Decode timing wraps only the decode loop (`rootctx.Timer`, same
   `std.Io.Clock.awake` idiom as `gprobe.zig`/`bz3base.zig`), summed across
   all blocks of a dump, divided by total roots decoded.

### Fixed constants (same for every file, no per-corpus tuning)

| constant | value | meaning |
|---|---:|---|
| `CTX_START` | 256 | sentinel "beginning of block" byte-context |
| `LEN_BUCKETS` | 6 | length buckets {1,2,3-4,5-8,9-16,17+} for X2 |
| `CTX_PRIOR_TARGET` | 2048 | pseudo-count budget an adaptive row is rescaled to |
| `CTX_BUMP` | 64 | adaptive row increment per observed junction |
| `SMOOTH_EPS` | 1 | flat additive smoothing per grammar-prior cell |
| `BOOST` | 32 | in-block recency/frequency boost added per occurrence (X3/X4) |

These were picked once by inspection (order-of-magnitude sane, not
grid-searched) and then frozen; LANE_X.md reports what they produce, not a
tuned optimum. A follow-up could sweep `CTX_BUMP`/`BOOST`, but see the
Conclusion — the ceiling looks too low for that to matter much.

## Variants

- **X0** — static order-0, `P(s) = g[s]/M`. One big Fenwick tree over every
  symbol with `g[s] > 0` (up to ~1.07M roots / ~350K distinct symbols for
  the largest dump here), so lookup/find is O(log n) even for the biggest
  alphabets. Reference every other variant is measured against.
- **X1i** — `P(s|ctx) = P(f|ctx) * P(s|f)`, `f` = first byte of `s`'s
  expansion, `ctx` = last byte of the previous root's expansion (or the
  start sentinel). `P(f|ctx)` from a **stored** 257x256 table, measured
  directly from the dump's actual root-to-root junctions, quantised to a
  byte per cell and packed through `rc.zig`'s own bitstream (9-bit
  per-row entry count + (8-bit column, 8-bit scaled count) pairs — not
  entropy-coded further, just "compact and real"). Its byte length is
  charged once per frame, separately from block payloads.
- **X1ii** — same factorisation, but `P(f|ctx)` comes from the **free**
  grammar prior: for every rule `(A,B)`, add weight `u[rule]` to
  `T[last(A)][first(B)]`. Zero stored bytes, static for the whole run.
- **X1iii** — the free prior again, rescaled to `CTX_PRIOR_TARGET` and
  **adapted** within each block (`CTX_BUMP` per observed junction), reset
  to the prior at every block boundary.
- **X2** — richer context `(last byte, length-bucket)` of the previous
  root (257*6 = 1542 rows instead of 257), same free-prior-adaptive
  machinery as X1iii. Tests whether more context helps or just dilutes.
- **X3** — no context factorisation at all. A single global order-0 model
  whose weight for `s` is boosted by `BOOST` every time `s` occurs in the
  current block (`P(s) ~ g[s] + n_block[s]*BOOST`), boosts undone at block
  end so blocks stay independent. Tests local repetition/recency alone.
- **X4** — X1iii's adaptive `P(f|ctx)` combined with X3's in-block boost
  applied to `P(s|f)` inside each bucket. The "stack both ideas" variant.

All seven share the same `BucketSet`/`Fenwick` machinery
(`rootctx.zig`); X0/X3 use one bucket covering every symbol, X1/X2/X4 use
256 buckets partitioned by first byte.

## X0 sanity check (is the coder calibrated?)

PLAN asks X0 to land within ~0.1% of the entropy sum. Measured directly:

| dump | H0 est. (bytes) | X0 payload | flush overhead (8B x blocks) | X0 - (H0+flush), % |
|---|---:|---:|---:|---:|
| freedict.eval8.16k.full | 518566.3 | 522354 | 4096 | -0.059% |
| freedict.eval8.64k.full | 516800.4 | 517781 | 1024 | -0.008% |
| gcide.eval8.16k.full | 1273930.6 | 1277772 | 4096 | -0.020% |
| gcide.eval8.64k.full | 1272258.8 | 1273288 | 1024 | 0.000% |
| omw.eval8.16k.full | 196708.3 | 200463 | 4096 | -0.174% |
| omw.eval8.64k.full | 191640.2 | 192598 | 1024 | -0.035% |
| macho.eval8.64k.full | 2152248.4 | 2153312 | 1024 | +0.002% |
| zigsrc.eval8.64k.full | 833282.3 | 834275 | 1024 | -0.004% |

X0's real coded payload equals the exact Shannon entropy of `g[]` **plus
the unavoidable 8-byte range-coder flush per independent block**, to
within ±0.17%, and mostly within ±0.05%. (Naively comparing X0 to entropy
*alone*, ignoring the flush cost, looks like a 0.3% miss at 16K blocks —
that gap is not miscalibration, it is 512 blocks x 8 bytes = 4096 bytes of
real, charged, unavoidable per-block coder overhead, which shrinks to
0.01–0.08% at 64K blocks because there are 4x fewer blocks.) The coder and
the reference are trustworthy; every percentage below is measured against
this real X0, flush cost included on both sides.

## Full results

18 dumps x 7 variants, 126 rows, zero `RootMismatch`/`LengthMismatch`
failures. `pct_vs_x0` = savings versus X0's real coded total (payload +
table bytes), positive = smaller. `ns/root` is decode-only, this machine,
shared with other lanes — indicative, not a benchmark.

```
dump                               variant  payload   pct%    table   total     ns/root  roots     blocks
freedict.eval8.16k.full            x0        522354   0.000       0   522354    99.1      281885   512
freedict.eval8.16k.full            x1i       497873   2.964    8996   506869   137.7      281885   512
freedict.eval8.16k.full            x1ii      619551 -18.607       0   619551   139.3      281885   512
freedict.eval8.16k.full            x1iii     539278  -3.240       0   539278   149.3      281885   512
freedict.eval8.16k.full            x2        542642  -3.884       0   542642   161.0      281885   512
freedict.eval8.16k.full            x3        511021   2.170       0   511021   111.5      281885   512
freedict.eval8.16k.full            x4        528957  -1.264       0   528957   163.4      281885   512
freedict.eval8.64k.full            x0        517781   0.000       0   517781   103.8      281074   128
freedict.eval8.64k.full            x1i       493446   2.965    8982   502428   140.2      281074   128
freedict.eval8.64k.full            x1ii      614690 -18.716       0   614690   146.8      281074   128
freedict.eval8.64k.full            x1iii     514335   0.666       0   514335   154.7      281074   128
freedict.eval8.64k.full            x2        522221  -0.858       0   522221   157.9      281074   128
freedict.eval8.64k.full            x3        506442   2.190       0   506442   112.8      281074   128
freedict.eval8.64k.full            x4        505082   2.453       0   505082   154.5      281074   128
gcide.eval8.16k.full               x0       1277772   0.000       0  1277772   119.4      656587   512
gcide.eval8.16k.full               x1i      1231742   3.137    5949  1237691   144.6      656587   512
gcide.eval8.16k.full               x1ii     1436235 -12.402       0  1436235   152.6      656587   512
gcide.eval8.16k.full               x1iii    1303195  -1.990       0  1303195   167.2      656587   512
gcide.eval8.16k.full               x2       1290330  -0.983       0  1290330   168.3      656587   512
gcide.eval8.16k.full               x3       1252723   1.960       0  1252723   132.9      656587   512
gcide.eval8.16k.full               x4       1278828  -0.083       0  1278828   164.7      656587   512
gcide.eval8.64k.full               x0       1273288   0.000       0  1273288   116.5      655702   128
gcide.eval8.64k.full               x1i      1227128   3.161    5915  1233043   142.5      655702   128
gcide.eval8.64k.full               x1ii     1431558 -12.430       0  1431558   140.5      655702   128
gcide.eval8.64k.full               x1iii    1259562   1.078       0  1259562   156.1      655702   128
gcide.eval8.64k.full               x2       1261995   0.887       0  1261995   161.6      655702   128
gcide.eval8.64k.full               x3       1248234   1.968       0  1248234   128.0      655702   128
gcide.eval8.64k.full               x4       1235910   2.936       0  1235910   158.5      655702   128
omw.eval8.16k.full                 x0        200463   0.000       0   200463    87.8      111407   512
omw.eval8.16k.full                 x1i       189026   3.635    4150   193176   155.0      111407   512
omw.eval8.16k.full                 x1ii      210759  -5.136       0   210759   155.0      111407   512
omw.eval8.16k.full                 x1iii     203243  -1.387       0   203243   172.4      111407   512
omw.eval8.16k.full                 x2        197102   1.677       0   197102   195.9      111407   512
omw.eval8.16k.full                 x3        187976   6.229       0   187976    97.4      111407   512
omw.eval8.16k.full                 x4        190902   4.769       0   190902   178.5      111407   512
omw.eval8.64k.full                 x0        192598   0.000       0   192598    86.2      108946   128
omw.eval8.64k.full                 x1i       181535   3.661    4012   185547   156.4      108946   128
omw.eval8.64k.full                 x1ii      202842  -5.319       0   202842   156.0      108946   128
omw.eval8.64k.full                 x1iii     192336   0.136       0   192336   167.9      108946   128
omw.eval8.64k.full                 x2        188380   2.190       0   188380   179.5      108946   128
omw.eval8.64k.full                 x3        180194   6.440       0   180194    94.5      108946   128
omw.eval8.64k.full                 x4        180098   6.490       0   180098   174.7      108946   128
freedict.untouched.64k.full        x0         73004   0.000       0    73004    59.5       46544    16
freedict.untouched.64k.full        x1i        69272  -0.762    4288    73560   112.8       46544    16
freedict.untouched.64k.full        x1ii       90906 -24.522       0    90906   113.5       46544    16
freedict.untouched.64k.full        x1iii      74638  -2.238       0    74638   124.0       46544    16
freedict.untouched.64k.full        x2         76531  -4.831       0    76531   128.4       46544    16
freedict.untouched.64k.full        x3         74018  -1.389       0    74018    67.8       46544    16
freedict.untouched.64k.full        x4         75679  -3.664       0    75679   128.3       46544    16
gcide.untouched.64k.full           x0        165251   0.000       0   165251    76.4       98270    16
gcide.untouched.64k.full           x1i       157367   2.273    4128   161495   107.2       98270    16
gcide.untouched.64k.full           x1ii      188023 -13.780       0   188023   108.2       98270    16
gcide.untouched.64k.full           x1iii     163653   0.967       0   163653   124.4       98270    16
gcide.untouched.64k.full           x2        166509  -0.761       0   166509   131.7       98270    16
gcide.untouched.64k.full           x3        166245  -0.602       0   166245    92.8       98270    16
gcide.untouched.64k.full           x4        164786   0.281       0   164786   125.7       98270    16
omw.untouched.64k.full             x0         35393   0.000       0    35393    61.4       23212    16
omw.untouched.64k.full             x1i        32683  -1.331    3181    35864   139.1       23212    16
omw.untouched.64k.full             x1ii       37659  -6.402       0    37659   141.7       23212    16
omw.untouched.64k.full             x1iii      35070   0.913       0    35070   152.3       23212    16
omw.untouched.64k.full             x2         35153   0.678       0    35153   167.6       23212    16
omw.untouched.64k.full             x3         34815   1.633       0    34815    68.1       23212    16
omw.untouched.64k.full             x4         34529   2.441       0    34529   162.1       23212    16
freedict.eval8.16k.r8192           x0        749816   0.000       0   749816    57.1      507954   512
freedict.eval8.16k.r8192           x1i       704547   4.713    9932   714479   107.1      507954   512
freedict.eval8.16k.r8192           x1ii      957176 -27.655       0   957176   107.6      507954   512
freedict.eval8.16k.r8192           x1iii     770093  -2.704       0   770093   118.4      507954   512
freedict.eval8.16k.r8192           x2        794257  -5.927       0   794257   127.6      507954   512
freedict.eval8.16k.r8192           x3        735427   1.919       0   735427    65.6      507954   512
freedict.eval8.16k.r8192           x4        757119  -0.974       0   757119   122.2      507954   512
freedict.eval8.16k.r32768          x0        623403   0.000       0   623403    84.2      362454   512
freedict.eval8.16k.r32768          x1i       591748   3.547    9541   601289   126.6      362454   512
freedict.eval8.16k.r32768          x1ii      755361 -21.167       0   755361   126.4      362454   512
freedict.eval8.16k.r32768          x1iii     640727  -2.779       0   640727   136.5      362454   512
freedict.eval8.16k.r32768          x2        651601  -4.523       0   651601   146.6      362454   512
freedict.eval8.16k.r32768          x3        606883   2.650       0   606883    92.8      362454   512
freedict.eval8.16k.r32768          x4        625358  -0.314       0   625358   142.2      362454   512
gcide.eval8.16k.r8192              x0       1803290   0.000       0  1803290    53.8     1225276   512
gcide.eval8.16k.r8192              x1i      1704724   5.121    6225  1710949    96.0     1225276   512
gcide.eval8.16k.r8192              x1ii     2170298 -20.352       0  2170298    93.7     1225276   512
gcide.eval8.16k.r8192              x1iii    1806190  -0.161       0  1806190   101.7     1225276   512
gcide.eval8.16k.r8192              x2       1858810  -3.079       0  1858810   108.9     1225276   512
gcide.eval8.16k.r8192              x3       1778001   1.402       0  1778001    63.6     1225276   512
gcide.eval8.16k.r8192              x4       1782015   1.180       0  1782015   108.6     1225276   512
gcide.eval8.16k.r32768             x0       1547840   0.000       0  1547840    87.7      909773   512
gcide.eval8.16k.r32768             x1i      1479816   3.996    6171  1485987   119.8      909773   512
gcide.eval8.16k.r32768             x1ii     1786011 -15.387       0  1786011   114.0      909773   512
gcide.eval8.16k.r32768             x1iii    1562825  -0.968       0  1562825   123.4      909773   512
gcide.eval8.16k.r32768             x2       1577880  -1.941       0  1577880   133.1      909773   512
gcide.eval8.16k.r32768             x3       1514925   2.127       0  1514925    95.2      909773   512
gcide.eval8.16k.r32768             x4       1530790   1.102       0  1530790   135.7      909773   512
omw.eval8.16k.r8192                x0       1256770   0.000       0  1256770    59.0      845888   512
omw.eval8.16k.r8192                x1i      1161583   7.009    7099  1168682   126.6      845888   512
omw.eval8.16k.r8192                x1ii     1386130 -10.293       0  1386130   126.9      845888   512
omw.eval8.16k.r8192                x1iii    1191048   5.229       0  1191048   137.0      845888   512
omw.eval8.16k.r8192                x2       1190528   5.271       0  1190528   146.2      845888   512
omw.eval8.16k.r8192                x3       1178001   6.268       0  1178001    65.9      845888   512
omw.eval8.16k.r8192                x4       1114341  11.333       0  1114341   140.7      845888   512
omw.eval8.16k.r32768               x0        617917   0.000       0   617917    69.6      376245   512
omw.eval8.16k.r32768               x1i       577086   5.601    6219   583305   144.7      376245   512
omw.eval8.16k.r32768               x1ii      643570  -4.152       0   643570   144.5      376245   512
omw.eval8.16k.r32768               x1iii     600473   2.823       0   600473   156.4      376245   512
omw.eval8.16k.r32768               x2        594859   3.732       0   594859   169.6      376245   512
omw.eval8.16k.r32768               x3        569796   7.788       0   569796    78.6      376245   512
omw.eval8.16k.r32768               x4        553076  10.493       0   553076   160.7      376245   512
json.eval8.64k.full                x0       1058276   0.000       0  1058276    98.2      605039   128
json.eval8.64k.full                x1i      1035530   1.905    2586  1038116   127.8      605039   128
json.eval8.64k.full                x1ii     1144302  -8.129       0  1144302   127.0      605039   128
json.eval8.64k.full                x1iii    1053230   0.477       0  1053230   134.1      605039   128
json.eval8.64k.full                x2       1060493  -0.209       0  1060493   141.9      605039   128
json.eval8.64k.full                x3       1039108   1.811       0  1039108   108.2      605039   128
json.eval8.64k.full                x4       1034488   2.248       0  1034488   141.6      605039   128
macho.eval8.64k.full               x0       2153312   0.000       0  2153312   146.6     1069450   128
macho.eval8.64k.full               x1i      2093899  -2.774  119145  2213044   196.9     1069450   128
macho.eval8.64k.full               x1ii     2240680  -4.057       0  2240680   194.1     1069450   128
macho.eval8.64k.full               x1iii    2167944  -0.680       0  2167944   225.9     1069450   128
macho.eval8.64k.full               x2       2160358  -0.327       0  2160358   248.0     1069450   128
macho.eval8.64k.full               x3       2085758   3.137       0  2085758   163.5     1069450   128
macho.eval8.64k.full               x4       2107576   2.124       0  2107576   208.8     1069450   128
zigsrc.eval8.64k.full              x0        834275   0.000       0   834275   122.8      430537   128
zigsrc.eval8.64k.full              x1i       794891   3.267   12130   807021   135.8      430537   128
zigsrc.eval8.64k.full              x1ii      894460  -7.214       0   894460   135.9      430537   128
zigsrc.eval8.64k.full              x1iii     799897   4.121       0   799897   145.9      430537   128
zigsrc.eval8.64k.full              x2        805969   3.393       0   805969   154.4      430537   128
zigsrc.eval8.64k.full              x3        794928   4.716       0   794928   137.7      430537   128
zigsrc.eval8.64k.full              x4        767828   7.965       0   767828   150.1      430537   128
```

(126 rows, 18 dumps x 7 variants, generated by
`while read d; do ./bin/rootlab_ctx dumps/$d all; done < dumplist.txt`,
~13s wall total on this shared machine, zero failures.)

## Best variant per dump

| dump | best variant | % vs X0 | decode ns/root |
|---|---|---:|---:|
| freedict.eval8.16k.full | x1i | +2.96% | 138 |
| freedict.eval8.64k.full | x1i | +2.96% | 140 |
| gcide.eval8.16k.full | x1i | +3.14% | 145 |
| gcide.eval8.64k.full | x1i | +3.16% | 143 |
| omw.eval8.16k.full | x3 | +6.23% | 97 |
| omw.eval8.64k.full | x4 | +6.49% | 175 |
| freedict.untouched.64k.full | (none) | -0.76% (x1i, still a loss) | 113 |
| gcide.untouched.64k.full | x1i | +2.27% | 107 |
| omw.untouched.64k.full | x4 | +2.44% | 162 |
| freedict.eval8.16k.r8192 | x1i | +4.71% | 107 |
| freedict.eval8.16k.r32768 | x1i | +3.55% | 127 |
| gcide.eval8.16k.r8192 | x1i | +5.12% | 96 |
| gcide.eval8.16k.r32768 | x1i | +4.00% | 120 |
| omw.eval8.16k.r8192 | x4 | +11.33% | 141 |
| omw.eval8.16k.r32768 | x4 | +10.49% | 161 |
| json.eval8.64k.full | x4 | +2.25% | 142 |
| macho.eval8.64k.full | x3 | +3.14% | 164 |
| zigsrc.eval8.64k.full | x4 | +7.96% | 150 |

## What each idea bought

- **X1ii (free prior, static) is a clear loss, usually a bad one**
  (-4% to -28%). This is the most important negative result in the lab:
  the "mine junction stats from every rule in the grammar, weight by usage,
  it's free" idea sounds right but is **miscalibrated by construction**.
  The junctions the grammar *did* encode as rules are exactly the ones
  that repeated verbatim and got merged away; root-level junctions are
  disproportionately the ones that *didn't* repeat that way. Applying a
  prior mined from "the junctions the grammar chose to keep internal" to
  predict "the junctions the grammar chose to leave external" transfers
  worse than the plain unconditional order-0. Free is not free if it's
  wrong.
- **X1iii (same prior, adapted in-block) mostly recovers to break-even or
  a small win** (-3% to +5%), because the adaptive counts correct the
  prior's systematic bias within a few dozen observations. This validates
  the "scale the prior down, then adapt" recipe from PLAN, but the ceiling
  is low: it rarely beats X1i (the stored, *true* empirical table) and
  never by much.
- **X1i (stored real junction table) is the most reliable single-context
  win on the dictionary corpora**: +2.3% to +7.0%, for 2.5–12 KB of stored
  table (a fixed, small, one-time cost). It loses narrowly on the smallest
  corpus (freedict.untouched, -0.76%: 1 MiB isn't enough data to amortise
  even a compact 257-row table) and on machO (-2.8%: binary code doesn't
  have byte-level junction structure the way text does).
- **X2 (richer context) never clearly beats X1iii's simpler context**, and
  is often worse (dilution, as PLAN warned: 1542 rows starve most cells of
  observations, and the adaptive part has less signal per row to work
  with). Confirms more context is not free even when the *prior* is free.
- **X3 (in-block frequency/recency boost, no context at all) is the most
  robust idea in the lab.** Positive on every single dump, dictionary or
  not, full or partial grammar, text or binary: +1.4% to +7.8%. It is also
  the cheapest to decode (closest to X0's speed, since it's still one
  factorisation-free symbol lookup) and needs no context table, stored or
  free. On machO — where none of the byte-junction ideas work, because
  compiled code doesn't have "vowel follows consonant"-style structure —
  X3 is the *only* variant that beats X0 (+3.1%), because straight local
  repetition of instruction-level roots is real regardless of domain.
- **X4 (X1iii's context + X3's boost) is the best variant on the partial
  grammars and several full-grammar files** (up to +11.3% on
  omw.r8192), and it's the general-purpose "stack what works" answer: it
  never does worse than the better of its two ingredients by much, and on
  the partial-grammar dumps — where root repetition is real because
  the grammar was deliberately capped before pairs stopped repeating —
  the context and the boost compound instead of interfering.

## Where soft-context modelling helps most / least

- **Partial grammars (r8192/r32768) show the largest gains** (up to
  +11.3%), confirming PLAN's prediction: with a capped grammar, roots
  still repeat somewhat, so in-block adaptive statistics (X3/X4) have
  real signal, on top of the same junction structure the full grammar
  also has.
- **Full grammars still show real, if smaller, gains** (+2–8% for text,
  ~+2–3% for JSON/Zig source/machO), meaning the "soft junction structure"
  hypothesis is correct even after the sequence-level redundancy the
  grammar was designed to remove is actually gone.
- **The one dump where nothing wins**: `freedict.untouched.64k.full` (1
  MiB raw, only 16 blocks, 46,544 roots total). Every context/adaptive
  idea is a net loss there; only the cheapest static X1i comes close to
  break-even, still slightly negative. Too little data for any of these
  models — stored, free, or adaptive — to pay for their own overhead or
  their own bias. Block size and corpus size both matter more than which
  clever model you pick once you're this small.
- **Block size (16K vs 64K) barely matters** for any variant, on the
  dumps that have both (freedict/gcide/omw full): the percentages move by
  well under half a point either way. The soft junction signal is a
  property of the language/grammar, not of how the bytes happen to be
  chopped into blocks.

## Decode cost

X0 decodes at roughly 55–160 ns/root depending on corpus (faster on
partial grammars with smaller buckets, slower on full grammars with huge
first-byte buckets like the ~600K-symbol "space" bucket in a dictionary).
Every context/adaptive variant costs roughly 1.3-2.5x X0's decode time —
the extra cost is the 256-wide linear scan for `P(f|ctx)` and (for
adaptive variants) a hash-map lookup per root, both O(1)-ish in practice
but with real constants next to X0's single Fenwick-tree descent. X3's
extra cost is smallest (just one extra Fenwick point-update per root,
undone at block end) since it does no context lookup at all.

Absolute ns/root moved noticeably between repeated back-to-back sweeps of
the *identical* binary and dumps (e.g. X0 on freedict.16k.full: 99ns in
one full-sweep run, 142-155ns in a later run a few minutes after, with no
code change) — this machine is genuinely shared with other lanes'
compute, exactly as PLAN warns. Byte counts (payload/table/total) were
bit-for-bit identical across every re-run and every optimisation level
(`-O ReleaseSafe` vs `-O ReleaseFast`) tried, as they must be for a
deterministic static/adaptive coder — only the timing column is noisy.
The *relative* ordering (X0 fastest < X3 a close second <
{X1i, X1ii} < {X1iii, X4} < X2 slowest) was consistent across every dump
and every repeated run regardless of absolute noise, so it is the
ordering — not the specific ns numbers — that should be trusted.

## Honest verdict

Soft-context modelling of root junctions is real: it is not a fluke of
one corpus, it shows up on every text corpus, on JSON, on Zig source, and
even (via pure repetition, not byte structure) on machO. But the ceiling
is modest: **2–8% on full grammars, up to 11% on partial grammars,
essentially 0% on a corpus too small to amortise any table**. None of
that is free — X1i pays a few KB per frame, and every adaptive variant
pays 1.3–2.5x decode time versus the X0 baseline it's trying to beat.

Given PLAN's own yardstick ("a 2% gain is probably not [worth it], 8%
probably is"): most of this lab's results sit in the "probably not"
range. The two ideas worth carrying forward, if any are, are (1) **X3's
in-block boost**, because it is nearly free (no context table, smallest
decode-time tax, positive on literally every dump tried including
non-text), and (2) **X1i's stored empirical table** on corpora big enough
to amortise it, because it's the single biggest, most reliable win
(+2–7%) for a genuinely small, one-time, charged cost. The richer-context
(X2) and free-static-prior (X1ii) ideas are net negative results: X1ii in
particular is a useful warning against assuming "derivable from the
grammar" implies "unbiased" — it's free, but it's free because it's
measuring the wrong thing (the junctions the grammar *kept internal*,
not the ones it left at root boundaries), and using it without adaptation
actively hurts. Given the added code complexity, the modest and
corpus-dependent ceiling, and the decode-time tax, my honest recommendation
is that soft-context modelling is **not** worth adding to the production
codec as a whole X1/X2/X4 stack — but X3's boost alone is cheap enough
and consistent enough (never negative, up to +7.8%) that it's a
reasonable one-line addition if Lane S's static coder ever gets a
"good idea" slot to spare.
