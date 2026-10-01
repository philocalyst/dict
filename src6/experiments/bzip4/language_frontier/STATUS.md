# Language compression: measured status and the next structural question

2026-09-26. Research artifacts only; the production codec is unchanged.
Implementation and experimentation switched to Sol during this round. The
earlier Luna work remains an independently checked set of controls, not an
accepted replacement for Bzip4.

## The comparison loop is now usable

From the repository root:

```sh
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py
```

It compares complete, independently decoded frames for the current native v4
CLI and real vendored bzip3. The bzip3 baseline uses the existing B3PY lab
envelope, **not upstream `.bz3` framing**. Cached baseline frames are checked
and decoded again on every run. Candidate encodes are never silently cached.

A candidate supplies `encode(raw, *, block_bytes, **options) -> bytes` and
`decode(frame) -> bytes`. Cartesian `--grid` policies share baseline controls;
all options, input hashes, implementation fingerprints, frames, and failures
are retained. `quickbench/README.md` documents the complete contract. The
harness passes 19 focused tests, including stale outputs, cache corruption,
dependency changes, timeout descendants, and parameter validation.

The root independently exercised the grid on the first 2,048 word-list bytes:
bzip3 795 B, v4 CLI 945 B, SCM3 literal-only 774 B, SCM3 copy policy
`policy=0, frontier=8, survival=0, start=1` 788 B. Thus this copy policy is
smaller than bzip3 but **larger than its simpler literal control**. This is a
small development sample, not a new general compression record.

The root also checked the whole-file distinction on 131,072 Japanese OMW
bytes: bzip3 at 64 KiB boundaries 9,083 B; bzip3 as one block 6,144 B; native
v4 CLI 9,453 B. Larger context is a real advantage and cannot be omitted from
a comparison advertised as beating bzip3.

## What the experiments actually established

| Experiment | Evidence | Decision |
|---|---|---|
| Weighted iid piece marginalization | All seven 64 KiB development frames lose to both native controls, despite modest improvement over same-source MAP | Reject this source model, not the marginalization identity |
| Small contextual piece source | Four classes lower diagnostic likelihood cost but increase complete frames on all three tested inputs | Extra prediction tables did not pay for themselves |
| Compiled byte-HMM belief states | 54 development frames; table costs and weak source quality dominate | Not a replacement for long-fragment reuse |
| Rank-one fragment operators | Algebra/oracles pass; diagnostic model blobs cost megabytes against kilobyte archives | No archive or throughput win; do not integrate |
| Productive source-DAG search | 24 configurations, six full-byte refits, then actual native-price-guided regeneration | Tiny 8 KiB wins disappear at 16/64 KiB; reject these search policies |
| Grammar-derived predictive state | 42 independently verified control/candidate rows; all three frozen policies lose 7/7 on 16 KiB inputs | Reject these delivered models; better payload prediction does not repay model bytes |
| Causal marginal copies + recursive literal backoff | Integer projected state, no transmitted copy selectors or external dictionary; 24-policy screen | Broader confirmation still required; separate literal gains from copy gains |

The detailed independent WAM ledger is in
`evidence/runs/wam-screen-final-20260926/summary.json`; the parse-search audit is
`parse_search/REPORT.md`. Individual reports identify weaker historical
provenance and interrupted runs. Current file hashes must not be retroactively
assigned to code that was already imported before an edit.

These are **alternative experiments**, not a list of new production wire modes.
The v4 CLI control is also not a synonym for the best historical saved-parse
record; winning against the CLI alone would not establish a new Bzip4 record.

## The useful dependency change now being tested

The dense copy-source implementation constructs and normalizes a 256-entry
distribution for every byte and every backoff level. That is unnecessary if
the arithmetic decoder can ask directly for cumulative probability at a byte
boundary. This is a change to the source's execution and quantization law,
not a promise that reimplementing Python in Zig will fix it.

For integer scale `Q`, a context row with total `n`, prefix count `c(k)`,
backoff cumulative `L(k)`, and prior strength `a` can use

```text
L_next(k) = k + floor((Q - 256) * (Q*c(k) + a*L(k)) / (Q*(n+a)))
```

It has endpoints 0 and Q and strictly positive adjacent increments. Sparse
prefix-count queries can evaluate it without materializing the alphabet.
After mixing escape mass `e` and copy mass prefix `m(k)`, use

```text
F(k) = k + floor((Q - 256) * (e*L_next(k) + Q*m(k)) / Q²)
```

The encoder needs two endpoints for its observed byte. The decoder can find
the byte by binary search. Posterior projection remains explicitly part of a
deterministic source state, rather than falsely claiming exact Bayes after
rounding and truncating the frontier. SCM4 is a **new quantized source**, not
the same bitstream as SCM3. Required evidence is dense/query bit identity for
this new law, hostile-input tests, full frame sizes, and actual measurements.

With `Q=65536` and `a=16`, exact cancellation also gives

```text
L_next(k) = k + floor(255 * (4096*c(k) + L(k)) / (16*(n+16)))
F(k)      = k + ((255 * (e*L_next(k) + 65536*m(k))) >> 24)
```

The mixture therefore needs no division; the literal numerator fits u32
under the existing row-rescale bound. This does not eliminate all division
or posterior work. The root's independent `oracle/test_cumulative.py` checks
the reduced forms against the uncancelled equations, extreme intermediates,
and positive complete CDFs. The full mathematical oracle suite passes 18
tests. An additional 100,000 seeded integer identity checks also passed.

## Further ideas worth exploring, not already achieved

- **Joint source and representation learning:** optimize delivered model bytes
  plus coded data, not likelihood first followed by hopeful compression of
  the model. The root-adjacency experiment makes this failure concrete.
- **Compress the predictive graph using its own fragment structure:** sparse
  continuation exceptions currently pay explicit IDs/counts. A second level
  of shared graph structure might lower that cost, but any circular model
  dependency needs an explicit acyclic decoding order.
- **Frozen-prefix prediction intervals:** reconstruct a source index from
  already decoded text, then freeze it for a bounded interval. This might
  permit reusable cumulative kernels and faster span updates. Restart costs,
  delayed adaptation, and prefix preparation must all be measured.
- **Productive morphology beyond adjacent substrings:** shared noncontiguous
  transformations may help lexical inventories. Earlier edit/paradigm probes
  have mixed or negative complete-byte results; a larger grammar alone is not
  evidence. Case, script, normalization, and original byte spelling must stay
  exactly recoverable.

No order-of-magnitude claim is justified by the evidence so far. Promotion
requires wins against strong controls on frozen multilingual inputs, complete
model accounting, honest startup/restart costs, and a decoder implementation
whose speed is measured rather than inferred from operation counts.

`reviews/cdf_sol.md` independently checks the proposed cumulative law and
records its proof conditions. In particular, emitted minimum byte mass does
not by itself make the projected posterior normalizable: the survival/start
rules must preserve positive escape mass. Posterior and arithmetic products
can equal 2^48, requiring 49 unsigned bits; u64 intermediates suffice under
the stated row and state bounds. This is a design review, not a substitute
for reviewing the eventual implementation.
