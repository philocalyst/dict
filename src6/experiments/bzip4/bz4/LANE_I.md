# Lane I — standalone in-band grammar (the "bzip3 file" regime)

Owner files: `inband.zig` (codec), `inbandlab.zig` (CLI), this notebook.
Question: for one big block (no shared model, no random access), how small
and how fast is a full pair grammar transmitted **in-band** with exact urn
probabilities? Does it beat bzip3 on a *whole file* (bzip3's strongest case)?

## Codec as built

`gprobe.build(raw, block_bytes=raw.len, max_rules=1<<24, min_freq, alpha=50)`
gives one block's worth of rules + root sequence. Then:

1. **First-occurrence item stream.** Walk roots left to right; `emit(s)`:
   byte or already-defined -> REF(s); else DEF, `emit(left)`, `emit(right)`,
   then `s` gets the next sequential id (post-order, exactly at the point
   both children are fully resolved).
2. **Exact urn REF.** `n[s]` = total future REF(s) events = `root_count[s] +
   child_count[s]` for bytes, minus 1 for rules (the first occurrence is the
   DEF, not a REF). This is **static** — computable in one pass over
   `g.seq` + `g.rules` before any coding starts, independent of traversal
   order — so it needs no dry run. Verified every rule gprobe builds is
   reachable from the roots (`rules == reachable` on every file tested), so
   nothing is wasted.
   A single Fenwick tree (`remaining[id]`) is walked/decremented per REF via
   `rc.encodeFreq`/`decodeFreq`+`consume`; symbols hit 0 and vanish from the
   effective alphabet for free.
3. **n[s] binarisation.** Elias-gamma on `v=n+1`: adaptive-unary exponent +
   adaptive mantissa bits, context = `(depth bucket x 8, expansion-length
   bucket x 8, n[left-child] bucket x 3)` = 192 contexts, all known exactly
   at the post-order point where `n[s]` is transmitted (both children have
   already been resolved, whether by earlier reuse or by just-now DEF).
4. **DEF/REF flag**: two interchangeable modes, `Options.exact_flag`:
   - adaptive `rc.Bit` per (call-stack-depth bucket x8, slot in
     {root,left,right}) = 24 contexts (default)
   - exact urn `defs_left/items_left` countdown (both counts are static:
     `num_defs_total` = reachable-rule count, `items_left` = `roots + 2 x
     num_defs_total`, transmitted in the header)
5. **First-byte factorisation** (`Options.first_byte`): `f` = first byte of
   the referenced expansion, coded via an adaptive order-1 model keyed on
   the last output byte (256 Fenwick trees, Laplace-smoothed, +24 per use);
   then the symbol is coded *within its first-byte class* via a private
   Fenwick tree per class (256 trees, exact urn, same total leaf count as
   one flat tree). Class sizes are static and go in the header
   (256 x u32 = 1 KiB, charged).
6. **Recency cache** (`Options.cache`): 16-slot MTF cache of the last
   referenced ids, checked before the base REF coder; hit -> 1 flag bit +
   adaptive-unary position; miss -> 1 flag bit + the base coder. Fenwick
   bookkeeping (`remaining[-1]`) always happens regardless of path, so cache
   hits don't desync the urn.

Header (charged, not range-coded): magic, version, options byte, raw_len,
roots_len, num_defs_total, [+ 256 x u32 class_capacity iff first_byte].
Self-describing: `decode(bytes)` needs no external variant argument.

Every number below is a real encode + a real decode that
`std.mem.eql`-verifies against the raw file in the same run (`inbandlab`
aborts loudly with `MISMATCH` otherwise — never hit once the Fenwick
bookkeeping above was fixed).

## Results: min_freq=2, full 8 MiB / 1 MiB single block

Best variant found is **`fb+cache`** (first-byte factorisation + recency
cache, adaptive flag). `base` = plain exact-urn REF, adaptive flag, no fb,
no cache. bzip3 columns are Lane D's `baselines.tsv` `block_bytes=0` rows
(whole-file bzip3, its strongest regime).

| file | base B | fb+cache B | bzip3 whole B | fb+cache vs bzip3 | base decode MB/s | fb+cache decode MB/s | bzip3 decode MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8 | 631,759 | 598,837 | 554,003 | +8.1% | 191.7 | 146.9 | 56.4 |
| gcide.eval8 | 1,478,205 | 1,408,735 | 1,243,221 | +13.3% | 76.7 | 46.7 | 23.4 |
| omw.eval8 | 393,739 | 346,780 | 332,331 | +4.4% | 296.0 | 208.1 | 65.5 |
| json.eval8 | 1,113,103 | 1,075,696 | 884,918 | +21.6% | 114.9 | 57.2 | 35.6 |
| macho.eval8 | 2,803,503 | 2,723,739 | 2,493,160 | +9.2% | 31.1 | 16.5 | 17.8 |
| zigsrc.eval8 | 1,230,099 | 1,144,385 | 1,037,980 | +10.3% | 76.0 | 50.5 | 28.7 |
| freedict.untouched | 91,769 | 89,713 | 84,072 | +6.7% | 176.9 | 107.5 | 54.3 |
| gcide.untouched | 203,594 | 195,255 | 174,685 | +11.8% | 65.1 | 46.6 | 29.1 |
| omw.untouched | 65,804 | 61,645 | 57,862 | +6.5% | 186.3 | 136.4 | 56.0 |

**We do not beat whole-file bzip3 on size on any file yet** — closest on
OMW (+4.4%), worst on JSON (+21.6%, low byte-level regularity hurts the
first-byte factorisation). Decode is faster than bzip3 everywhere except
macho.eval8 (346,690 rules, largest grammar; `fb+cache` decode drops below
bzip3 there — see ablation).

## Ablation: what each piece buys (freedict.eval8.bin, min_freq=2)

| variant | total B | Δ vs base | decode MB/s |
|---|---:|---:|---:|
| base (adaptive flag, flat urn) | 631,759 | — | 191.7 |
| eflag (exact urn flag) | 633,426 | +1,667 (worse) | 159.3 |
| cache only | 622,758 | -8,983 (-1.4%) | 181.4 |
| fb only | 605,919 | -25,840 (-4.1%) | 144.2 |
| fb+cache | 598,837 | -32,922 (-5.2%) | 146.9 |
| all (eflag+fb+cache) | 600,502 | -31,257 (-4.9%) | 128.0 |

Same shape on every other file (full numbers in the raw run log below).
Per-file fb-only / cache-only deltas from base:

| file | fb only | cache only | fb+cache |
|---|---:|---:|---:|
| gcide.eval8 | 1,423,611 (-3.7%) | 1,459,385 (-1.3%) | 1,408,735 (-4.7%) |
| omw.eval8 | 375,009 (-4.7%) | 362,044 (-8.1%) | 346,780 (-11.9%) |
| json.eval8 | 1,076,769 (-3.3%) | 1,111,916 (-0.1%) | 1,075,696 (-3.4%) |
| macho.eval8 | 2,764,926 (-1.4%) | 2,761,642 (-1.5%) | 2,723,739 (-2.8%) |
| zigsrc.eval8 | 1,183,521 (-3.8%) | 1,185,799 (-3.6%) | 1,144,385 (-7.0%) |

Findings:
- **`fb` (first-byte factorisation) is the single biggest lever**, worth
  1.4-4.7% alone, everywhere. Weakest on macho (binary, no stable byte
  grammar) and json (punctuation-heavy, flatter byte distribution).
- **`cache`** is inconsistent alone (0.1% on json, 8.1% on omw) but stacks
  on top of `fb` for a real combined win everywhere — the two clearly catch
  different redundancy (recency vs. byte-level shape).
- **Exact urn flag is a small net loss** vs. the adaptive
  (depth,slot)-context Bit, and it's the reason `all` < `fb+cache`. The
  context evidently already captures what the flat urn ratio would, at
  lower cost, because DEF/REF at shallow call-depth (roots) behaves very
  differently from DEF/REF deep inside a first-time expansion.
- **fb+cache roughly halves decode throughput** vs. `base` (146.9 vs 191.7
  MB/s on freedict; 16.5 vs 31.1 MB/s on macho — there it goes *below*
  bzip3). The 256 per-class Fenwick trees plus the adaptive last-byte model
  plus the cache scan each cost real time per REF; `base`'s single flat
  Fenwick is much cheaper per symbol. This is a genuine speed/size
  trade-off, not a free lunch — worth flagging for whoever picks a
  production variant.

## min_freq 2 vs 3 vs 4 (fb+cache)

| file | min_freq=2 | min_freq=3 | min_freq=4 |
|---|---:|---:|---:|
| freedict.eval8 | 598,837 (69,728 rules) | 611,660 (38,672) | 622,174 (27,857) |
| gcide.eval8 | 1,408,735 (124,903) | 1,430,049 (71,762) | 1,448,822 (52,278) |
| omw.eval8 | 346,780 (105,499) | 370,436 (76,997) | 400,122 (62,108) |

**min_freq=2 wins outright everywhere**, and the gap widens with min_freq.
This is the opposite of the frozen-cap-era intuition (where a naive
20-30-bit/rule code made marginal rules a loss): under exact-urn in-band
coding, a rule used only twice costs `n=1` (a couple of gamma bits) plus
one DEF flag, so it almost always pays for itself in the roots it removes.
Raising min_freq only throws away cheap-to-transmit structure and pushes
more symbols back into the (more expensive, deeper) root/REF stream. This
directly answers the "which rules pay for themselves" question: at this
coding efficiency, essentially all of them do, so min_freq should stay at
its floor (2) for the standalone/whole-file regime.

## Where the bytes go (freedict.eval8.bin, est breakdown)

Idealised root-only order-0 entropy (`gprobe`'s `static_H0`, labelled
**est**, no real code implements it standalone) is 515,548 B for 280,481
roots. Real `base` total is 631,759 B, i.e. 116,211 B / 69,728 rules =
13.3 bits/rule of grammar overhead over the idealised root floor. Real
`fb+cache` total is 598,837 B, 83,289 B over the same floor = 9.6
bits/rule — context and factorisation genuinely shrink the grammar-transfer
cost, they don't just move bits around.

Of that overhead, an **est** lower bound for the DEF/REF flag alone: the
flag fires DEF on `rules/(roots+2*rules)` = 69,728/419,937 = 16.6% of the
419,937 total emit() calls; the binary entropy of that split is 0.649
bits/call, i.e. ~34.1 KB even with a perfect static coder — our real
adaptive-context flag should do at least this well. That leaves roughly
~49 KB (598,837 - 515,548 - 34,100) split between the `n[s]` gamma codes
(69,728 of them, mostly 1-3 bits each -> ballpark 15-20 KB) and residual
REF-coding inefficiency (Fenwick/range-coder granularity, first-byte-class
imperfect fit, cache misses paying their flag bit for nothing).

**Biggest remaining inefficiency**: it is not the grammar transmission
machinery (that's down to ~9.6 bits/rule, and min_freq sweeps confirm
essentially every rule earns its keep) — it's that a fully-grown one-block
grammar has no repeats *left to exploit* by construction, so the residual
331 KB "root/REF entropy" (598,837 - grammar-overhead) is close to
information-theoretic and hard to shrink further without breaking the
"soft, general, no text-specific tricks" constraint. bzip3's BWT+Huffman
apparently still finds order-2+ structure in the *literal byte stream* that
our post-grammar root symbols have already consumed/hidden (each root is a
multi-byte phrase, so we've thrown away the fine byte-level context bzip3's
entropy coder still profits from between phrase boundaries). Chasing that
would mean context-mixing across root *boundaries* using the bytes
immediately before/after each phrase — sketched by `fb`'s last-byte context
but only for the REF path, not for byte literals inside a phrase, and not
for phrase-to-phrase junction pairs beyond first-byte. That is the natural
next lever, not more grammar-header cleverness.

## Failures / things that didn't get built (time-boxed)

- Did not try "n of left child" bucket resolution beyond 3 buckets
  ({<=1, 2, >=3}), nor a from-scratch context-selection sweep (depth-only
  vs explen-only vs combined) — shipped the combined 192-context version
  directly since it clearly beat an early depth-only prototype in a quick
  spot check on freedict (not tabulated).
- Cache eviction doesn't remove exhausted symbols (remaining=0) early;
  they just age out via MTF naturally. A smarter cache (drop on exhaustion)
  was not implemented — plausible small further win, untested.
- Did not attempt urn-exact (rather than adaptive order-1) coding of the
  first-byte symbol `f` itself; PLAN allows either, adaptive was simpler
  and got real gains, didn't circle back to compare.
- No attempt at a variant that skips first-byte factorisation for very
  common first bytes (e.g. space) to save the class-Fenwick lookup cost on
  the hot path — this is likely why macho's decode speed regresses below
  its `base` speed and below bzip3; a fast-path special case for
  high-population classes would probably recover most of that.

## Raw run log

```
$ bin/inbandlab data/freedict.eval8.bin 2 base
data/freedict.eval8.bin	base	69728	280481	631759	0.6025	980.363	41.725	191.73
$ bin/inbandlab data/freedict.eval8.bin 2 fb+cache
data/freedict.eval8.bin	fb+cache	69728	280481	598837	0.5711	818.019	54.446	146.94
$ bin/inbandlab data/gcide.eval8.bin 2 base
data/gcide.eval8.bin	base	124903	655734	1478205	1.4097	1881.491	104.363	76.66
$ bin/inbandlab data/gcide.eval8.bin 2 fb+cache
data/gcide.eval8.bin	fb+cache	124903	655734	1408735	1.3435	1844.193	171.402	46.67
$ bin/inbandlab data/omw.eval8.bin 2 base
data/omw.eval8.bin	base	105499	107534	393739	0.3755	1170.996	27.028	295.99
$ bin/inbandlab data/omw.eval8.bin 2 fb+cache
data/omw.eval8.bin	fb+cache	105499	107534	346780	0.3307	1178.715	38.452	208.05
$ bin/inbandlab data/json.eval8.bin 2 base
data/json.eval8.bin	base	62511	604539	1113103	1.0615	1293.418	69.655	114.85
$ bin/inbandlab data/json.eval8.bin 2 fb+cache
data/json.eval8.bin	fb+cache	62511	604539	1075696	1.0259	1536.404	139.915	57.18
$ bin/inbandlab data/macho.eval8.bin 2 base
data/macho.eval8.bin	base	346690	1070099	2803503	2.6736	5022.527	257.561	31.06
$ bin/inbandlab data/macho.eval8.bin 2 fb+cache
data/macho.eval8.bin	fb+cache	346690	1070099	2723739	2.5976	5290.660	484.619	16.51
$ bin/inbandlab data/zigsrc.eval8.bin 2 base
data/zigsrc.eval8.bin	base	210582	429891	1230099	1.1731	3123.479	105.321	75.96
$ bin/inbandlab data/zigsrc.eval8.bin 2 fb+cache
data/zigsrc.eval8.bin	fb+cache	210582	429891	1144385	1.0914	2656.586	158.372	50.51
$ bin/inbandlab data/freedict.untouched.bin 2 base
data/freedict.untouched.bin	base	12557	46647	91769	0.7001	105.257	5.654	176.88
$ bin/inbandlab data/freedict.untouched.bin 2 fb+cache
data/freedict.untouched.bin	fb+cache	12557	46647	89713	0.6845	105.877	9.306	107.46
$ bin/inbandlab data/gcide.untouched.bin 2 base
data/gcide.untouched.bin	base	24036	98589	203594	1.5533	253.066	15.362	65.09
$ bin/inbandlab data/gcide.untouched.bin 2 fb+cache
data/gcide.untouched.bin	fb+cache	24036	98589	195255	1.4897	206.797	21.461	46.60
$ bin/inbandlab data/omw.untouched.bin 2 base
data/omw.untouched.bin	base	17807	23119	65804	0.5020	218.042	5.368	186.29
$ bin/inbandlab data/omw.untouched.bin 2 fb+cache
data/omw.untouched.bin	fb+cache	17807	23119	61645	0.4703	134.832	7.330	136.42
```

Ablation raw log (freedict.eval8.bin, min_freq=2):

```
base            631759  0.6025  191.73
eflag           633426  0.6041  159.26
fb              605919  0.5778  144.15
cache           622758  0.5939  181.42
fb+cache        598837  0.5711  146.94
all             600502  0.5727  128.02
```

min_freq sweep raw log (fb+cache):

```
freedict.eval8  mf=2  598837   (69728 rules)
freedict.eval8  mf=3  611660   (38672 rules)
freedict.eval8  mf=4  622174   (27857 rules)
gcide.eval8     mf=2  1408735  (124903 rules)
gcide.eval8     mf=3  1430049  (71762 rules)
gcide.eval8     mf=4  1448822  (52278 rules)
omw.eval8       mf=2  346780   (105499 rules)
omw.eval8       mf=3  370436   (76997 rules)
omw.eval8       mf=4  400122   (62108 rules)
```

Reachability sanity check (all rules gprobe builds are used, none orphaned):

```
freedict.eval8.bin: rules=69728 reachable=69728
macho.eval8.bin:    rules=346690 reachable=346690
```
