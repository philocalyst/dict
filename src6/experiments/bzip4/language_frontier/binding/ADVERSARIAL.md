# Adversarial audit of the segmentation and prediction candidates

Date: 2026-09-26. This is an independent review of the candidate math and
wire accounting in `language_frontier/segmentation/**` and
`language_frontier/prediction/**`. It intentionally makes no changes to
those lanes. The review was done against the current files, including the
post-fix two-row `circuit_probe.py` and the exact-fraction oracle in
`language_frontier/oracle/renewal.py`.

## Verdict

There are three different objects in the experiments and they must not be
reported as though they were one model.

1. `marginal_gap.py` computes a useful *relative ambiguity diagnostic*, but
   its token PMF has no length or END factor. It is not a normalized source
   distribution over arbitrary byte strings. Its `MAP - SUM` gap is not
   available archive bits.
2. `atom_marginal_coder.py` is a valid small arithmetic coder for an observed
   finite list of atom IDs after it renormalizes the leaf masses onto that
   list. It is not an arithmetic coder for the latent segmentation marginal.
   Its negative result is valid for that leaf design only.
3. `weighted_emission_coder.py` is the right structural direction for a
   prefix weighted trie: its live-suffix posterior and byte CDF are causal and
   every byte has a singleton fallback. It is currently an in-memory
   research emitter, not an independently framed decoder. It also codes an
   infinite token-stream *prefix* conditioned on the separately sent raw
   length, whereas the finite renewal model in the oracle codes a path whose
   token lengths sum to that length. Those are different distributions.

The current `prediction/circuit_probe.py` does **not** retain the former
unreachable-final-position defect. `ROWS = 2`, and END is emitted from the
interior row as a genuine hazard. The finite-mass test in
`prediction/test_circuit_probe.py` passes. It remains a diagnostic, because
the score has no type-boundary/occurrence stream and its “model bytes” are a
lower bound, not a frame.

The key acceptance rule is therefore: report surface probability and complete
frame bytes, not latent path ambiguity. A proposed prefix emitter should be
accepted only after an exact finite-length oracle check, deterministic integer
CDF specification, independent truncation/malformed-frame tests, and a
complete charged frame against the v4 control.

## Independent checks performed

These checks passed on the current files:

```text
PYTHONPATH=src6/experiments/bzip4/language_frontier/oracle \
  python3 -m unittest -v \
  src6/experiments/bzip4/language_frontier/oracle/test_renewal.py
  6 tests, all OK

PYTHONPATH=src6/experiments/bzip4/language_frontier/prediction \
  python3 src6/experiments/bzip4/language_frontier/prediction/test_circuit_probe.py
  tests=causal_rows,variable_length_normalization,empty_word
  status=ok

PYTHONPATH=src6/experiments/bzip4/language_frontier/segmentation \
  python3 -c 'import marginal_gap, weighted_emission_coder; marginal_gap.self_test(); weighted_emission_coder.self_test()'
  no assertion failures
```

The renewal oracle is especially important because it uses `Fraction` and an
independent exhaustive path enumeration. It checks partition functions,
causal CDF chains, arbitrary byte alphabets, and latent-label aliases. Its
alias check gives the following exact surface-invariant result for a toy
model:

```text
text       surface P unchanged   original gap   eight aliases gap
ab         yes                    0.169925       3.169925 bits
abab       yes                    0.339850       6.339850 bits
ababab     yes                    0.509775       9.509775 bits
```

Splitting one `ab` token into eight byte-identical labels leaves the observed
surface distribution unchanged while increasing latent ambiguity by about
three bits per occurrence. Any selection rule that rewards this gap without
charging the labels is measuring a representation accident.

## 1. What the segmentation PMF actually means

Let `P` be a finite piece inventory, including singleton bytes, and let

```text
w(p) = positive_count(p) / sum_q positive_count(q)
F(x) = sum_{z : emit(z) = x} product_{p in z} w(p)
M(x) = max_{z : emit(z) = x} product_{p in z} w(p)
```

`marginal_gap.py` computes `-log2(M(x))` and `-log2(F(x))` using a forward
DP. For a fixed observed `x`, this is a well-defined finite sum because no
piece in a parse can be longer than `x`. It is not, however, a normalized
distribution over all finite strings. With the two singleton pieces `a` and
`b`, each of probability `1/2`, the total mass of all strings of length `n`
is one. Summing over all lengths gives

```text
sum_{x in {a,b}*} F(x) = 1 + 1 + 1 + ...,
```

because this is an unbounded token stream with no stop event. Thus the
diagnostic is a path-weight comparison, not an NLL from a complete source
model. The inventory is also learned from the evaluated bytes, so it is an
input-fit diagnostic rather than held-out coding evidence.

The code has one smaller consistency trap. In `marginal_gap.py:105`,
`posterior_entropy()` uses `1 / total` when a token is absent from `logp`,
while the Viterbi/forward paths at `:211` use the intended smoothed fallback
`alpha / total`. The current in-sample atom set normally contains every byte,
so this does not alter the published screen, but a held-out or direct caller
can get a different posterior. Use the same `alpha / total` fallback or
reject an unknown byte explicitly.

The gap itself is

```text
G(x) = log2(F(x) / M(x)).
```

It is at most the log of the number of paths only when all path weights are
compared under one proper fixed model. It is not a selector-free code for the
surface. A MAP encoder has to send a path (or make the path recoverable from
the surface with a uniquely decodable deterministic rule); a marginal encoder
has to implement the surface CDF. Bits-back can change that accounting only
with a charged posterior sample, prior code, and seed/restart state. See
[Townsend, Bird & Barber, *Practical Lossless Compression with Latent Variables using Bits Back Coding*](https://arxiv.org/abs/1901.04866).

For a finite record length `n`, the proper renewal normalizer is

```text
Z(0) = 1
Z(n) = sum_p w(p) Z(n - len(p))
P(x | n) = F(x) / Z(n).
```

The oracle's `Renewal.partition()` and `prefix_mass()` implement this
normalizer exactly. A fixed-length arithmetic decoder can use

```text
P(next_byte=b | prefix=u, n)
  = P(prefix=u+b | n) / P(prefix=u | n)
```

and is causal because `u` and the charged `n` are already known. Alternatively
an infinite token-stream prefix model may be used, but then the frame must say
so and must charge a separate length code; it must not be compared to
`F(x)/Z(n)` as if they were the same marginal.

## 2. The exact prefix weighted-trie recurrence

For an infinite token-stream prefix model, the current weighted emitter has a
sound recurrence. After observing a byte prefix `u`, maintain normalized mass
`m_u(r)` for the root state `r = epsilon` and for each live remaining suffix
`r` of a token. Equal suffixes are merged. The next-byte mass is

```text
c_u(b) = m_u(epsilon) * sum_{p starts with b} w(p)
         + sum_{r starts with b} m_u(r).
```

Normalize `c_u` over the 256 bytes, arithmetic-code the selected byte, then
advance every matching suffix and start every token beginning with that byte:

```text
m_{u+b}(r') = unnormalized matching mass / sum_b c_u(b).
```

`weighted_emission_coder.py:173-197` is an implementation of this equation.
The singleton tokens make every byte CDF positive. It does not pay a selector
for each byte and it preserves byte adjacency, which is the desired structural
distinction from the rejected byte-class stream.

For a finite-length model, the suffix vector is not enough: a live token may
overrun the charged endpoint. The remaining-length partition `Z(n - j)` has
to be included in every suffix's completion mass. The oracle's
`next_byte(prefix, length)` is the reference definition. A finite trie emitter
must either implement that length-conditioned recurrence, send length first and
intentionally use the infinite-prefix model, or emit a genuine END transition
at every reachable state. “Multiply an END factor once after the whole string”
is not a valid variable-length source model unless the byte continuation hazard
is also present.

### Reachable-state bounds

Let `V = |P|`, `L = max_p len(p)`, alphabet size `A = 256`, and let the
unmerged token trie have `N` residual-prefix/suffix nodes. A simple bound is

```text
N <= 1 + sum_p len(p) <= 1 + V*L.
```

The unweighted support of a decoded prefix is a subset of these nodes, so a
general subset construction has at most `2^N` supports. The worst-case
determinization blow-up is exponential even for unweighted automata; weighted
determinization additionally carries residual weights and is not guaranteed to
terminate. This is not handwaving: Mohri gives the weighted-subset
construction, its residual-weight states, the exponential worst case, and
non-determinizable examples in [*Weighted Automata Algorithms*, sections 6.2–6.3](https://cs.nyu.edu/~mohri/pub/hwa.pdf).

With all singleton bytes present, support alone can sometimes be keyed by the
last `L-1` bytes, giving the more concrete bound

```text
1 + A + A^2 + ... + A^(L-1),
```

but the **weights** in that support vector still depend on the complete prefix.
They are rational ratios of path sums and can take a different value at every
prefix length. Quantizing each of `d` independent residual coordinates to
`Q` bins gives at most `Q^d` quantized vectors, but this is an approximation
and its state table is part of the model. For a `K`-component circuit, a
quantized posterior alone can contribute up to `Q^(K-1)` states.

A tiny non-periodic counterexample is already enough to rule out an assumed
constant row table. Use tokens `a`, `aa`, `b` with integer weights `[1, 1, 2]`.
Following the prefix `a^n`, the exact next-byte probability of `b` from the
live-suffix recurrence is:

```text
n = 0  0.500000000000
n = 1  0.250000000000
n = 2  0.416666666667
n = 3  0.321428571429
n = 4  0.381578947368
n = 5  0.345744680851
n = 6  0.367886178862
n = 7  0.354501607717
```

The root masses obey the non-periodic recurrence
`R_n = (R_{n-1} + R_{n-2})/4`, while the live `aa` suffix contributes
`R_{n-1}/4`. A finite deterministic automaton following repeated `a` would
eventually repeat a state and therefore make the `b` probabilities eventually
periodic. Exact rows cannot do that here. A bounded maximum record length can
unroll the states, and quantization can merge them, but both choices must be
explicit and charged.

If the compiled machine has `S` reachable quantized states, a dense integer
CDF implementation needs roughly

```text
S * (A + END) * B                 # integer CDF/count entries
  + S * A * ceil(log2(S))         # successor state IDs, if table-driven
```

bits, where `B` is the chosen count precision. A generated trie can reduce the
serialization below this dense bound, but then the decoder performs the same
residual update at runtime. The current Python emitter chooses the runtime
route: approximately `O(V + active_suffixes)` work per byte and
`O(active_suffixes)` live state, with an `O(VL)` token header. It does not
magically obtain both a tiny static table and exact marginalization.

The finite-length oracle pays a different computational price: a straightforward
forward/backward implementation computes `Z(j)` and prefix completion masses in
`O(nV)` time for a record of length `n` (or `O(nN)` with trie sharing). Caching
those values keeps the decoder causal but does not remove the work; compiling
them for every allowed `n` turns the length bound into more serialized states.

## 3. Candidate-specific findings

### `segmentation/marginal_gap.py`

* The forward and Viterbi recurrences are internally consistent for the
  finite set of paths of one observed atom. The `self_test()` exhaustive
  oracle is useful.
* I did not reproduce the earlier min/max or log-base defects in the current
  file: the `inf` reachability guard, base-2 `logadd2`, and exhaustive toy
  oracle agree. This is a code-verification result, not evidence that the
  unnormalized source model is a probability distribution.
* There is no END/length factor, so `map_bits`, `marginal_bits`, and
  `posterior_entropy_bits` are diagnostics only. Keep the warning in the
  report next to every gap number.
* The input-fit inventory and counts make this a development diagnostic. A
  held-out screen must freeze the inventory and probability integers before
  reading the held-out bytes.
* The model charge at `:246-250` is a spelling/index estimate, not a v4 frame
  charge. It cannot be subtracted from the gap.

### `segmentation/atom_marginal_coder.py`

`quantize()` at `:124-128` rescales each atom's log mass relative to the peak,
rounds to integer frequencies, and constructs one CDF over the finite
`atom_freq` surface list. This is a proper finite atom-ID arithmetic code once
that list and its frequencies are in the header. It is not the CDF of `F(x)`
over all surface atoms, and unseen atoms are not decodable. Therefore the
clean `marginal` versus `map` negative row should be described as a negative
result for the **renormalized finite leaf coder**, not as a disproof of a
prefix weighted trie.

There are also two prototype hardening issues:

* `Decoder.__init__` at `:159-168` silently zero-fills a payload shorter than
  the required eight-byte arithmetic seed. A direct `Decoder` user only gets
  `self.payload` after the special assignment in `encode_decode()` at `:192`;
  a sufficiently long direct decode otherwise raises `AttributeError` during
  renormalization. A real frame parser must reject short payloads and never
  invent zero bytes.
* The script has no independent frame decoder, raw-length/CRC check, or
  malformed-header budget. The in-memory round trip proves only the selected
  list-ID loop.

### `segmentation/weighted_emission_coder.py`

Positive evidence:

* `Model.advance()` merges equal live suffixes and `byte_probs()` includes
  both root token starts and unfinished token suffixes. The exact recurrence
  passes the small CDF and round-trip tests.
* The header charges all singleton/piece strings, integer token weights, raw
  length, CDF precision marker, arithmetic flush, and payload. It does not pay
  a selector per byte.

Required corrections before treating it as a wire candidate:

1. The model state is a Python `float` dictionary. `quantized_byte_cdf()`
   rounds those floats with a minimum count, so the emitted distribution is
   not the exact real-valued posterior used in the explanatory docstring. The
   header's one-byte “precision 20” does not specify a portable state update,
   tie rounding, or integer posterior representation. Store a deterministic
   rational/integer recurrence (or serialize the compiled CDF rows), and test
   an independent decoder implementation. Measure the actual quantized frame,
   not `-log2` of the unquantized mass.
2. `encode_marginal()` uses the infinite-stream prefix model and stops after
   the raw length. `encode_map()` codes an unconditional token-ID path and
   does not condition the path PMF by `Z(raw_len)`. They are useful ablations,
   but they are not two codings of one finite `P(x | n)`. Add the oracle's
   length-conditioned CDF as the like-for-like marginal control, or state the
   prefix model/length side information explicitly in all comparisons.
3. There is no independent `decode_frame()`. `read_varint()` is unused;
   section lengths, raw length, path count, token-count bounds, trailing bytes,
   and CRC are never parsed. `ArithmeticDecoder` at `:116-143` also silently
   zero-fills a truncated arithmetic seed/renormalization byte. The truncation
   block in `self_test()` only compares two byte strings and never decodes the
   shortened frame, so it is not a corruption test.
4. `make_tokens()` learns from the same `data` that it encodes. A complete
   claim needs a frozen train/eval split and a held-out model header. The
   existing output rows can remain an input-fit diagnostic.

The recommended implementation order is: first add a parser with strict
varint canonicality and budgets; then replace float posterior state with a
specified integer state; then compare infinite-prefix and finite-renewal
models on identical held-out bytes.

### `segmentation/unigram_interval.zig`

This lane is a deterministic v4-parse learner and its final `plan.fit` frame
is authoritative, so it does not inherit the marginal normalization issue.
Its selection score is still a heuristic, not a probability:

* `pieceCost()` at `:179-184` uses overlapping occurrence counts and a fixed
  byte fallback of eight bits. The denominator is not the sum of all edge
  masses, so it cannot be interpreted as a normalized unigram PMF.
* In `learn()`, `total_occ` is replaced by the sum of selected multi-byte
  piece uses (`:293-303`), excluding fallback bytes. After the best active set
  is restored, the final paths at `:304-310` reuse the last round's
  `total_occ`, which need not be the round that supplied `best_active` and is
  not the `objective()` denominator. This can change the selected parse
  without changing the final complete-frame accounting.

Keep these values labeled as learner heuristics; add a regression that freezes
the winning round's full costs (or recomputes the denominator after restoring
the winning state) if the selection itself is to be compared scientifically.
The final v4 encode/decode check is the correct promotion gate.

### `prediction/circuit_probe.py`

The current two-row circuit is normalized. If `s` is the start END
probability and `e` is the interior END probability, then

```text
P(empty) = s
sum_{|x|=n} P(x) = (1-s) * e * (1-e)^(n-1),  n >= 1,
```

and the sum over all lengths is one. This is why the old “final byte uses an
unreachable END row” objection no longer applies. Do not reintroduce a
`position == length` feature: the decoder only learns the end when it decodes
END. `prediction/test_circuit_probe.py` checks the geometric finite-prefix
mass and empty-word branch.

Remaining accounting limits are real:

* `score()` deduplicates atoms and reports a type-level mixture score. It has
  no atom boundary code, occurrence IDs, or complete type dictionary stream.
* `model_bytes` is explicitly a lower bound for raw count arrays. It omits
  serialized integer CDF policy, arithmetic precision/seed, type boundaries,
  restart/padding, and occurrences.
* The advertised u32 count layout has no overflow/bounds check. A future
  serialized circuit must either cap the training corpus before counting or
  use a specified wider count representation.
* `train()` uses a hard component assignment after a deterministic seed. This
  is a valid bounded training heuristic, not a marginalized training result.
  `script()` is only a training seed feature; using it as an observed wire
  label would be an uncharged side channel.

### `prediction/spelling_model.py`

The complete `LPRED001` prototype has stronger framing and decoder checks than
the diagnostics: it stores row code lengths, section sizes, a CRC, output and
model budgets, END symbols, and zero-padding checks. Two issues still matter
for the candidate math:

* At `:356-372`, the second training segmentation uses `rows[0].lengths` for
  every symbol, even though the final encoder at `:460-507` chooses a path
  using the state-specific row and the final END row. Thus the rows are trained
  from a path that is not necessarily optimal under the final wire cost. This
  is not a round-trip bug, but it invalidates a claim that the training Viterbi
  objective equals the emitted spelling objective. Re-price and resegment until
  fixed, or report the mismatch and add a test with a state-dependent
  counterexample.
* `take_vleb()` implements canonical ULEB checking but the old-ID decoder at
  `:642-652` parses the bytes itself and accepts encodings such as `0x81 0x00`.
  Use the checked helper or reject noncanonical old IDs in the frame parser.

## 4. Actionable disproof and promotion tests

These tests are deliberately cheap and should run before any broad timing
run.

### Normalization and causality

For a frozen piece model and every `0 <= n <= N`, enumerate a tiny byte
alphabet and assert:

```text
sum_x P(x | n) == 1
sum_b P(next=b | prefix=u, n) == 1
product_j P(x_j | x[:j], n) == P(x | n)
```

Use exact `Fraction` arithmetic for the oracle. For the infinite-prefix
variant, assert the first equation separately for each fixed `n` and charge
the raw length code; do not substitute `F(x)` or an unnormalized finite-path
sum. Include prefixes that end inside a multi-byte token.

### Surface/latent invariants

Run the duplicate-alias construction from `test_renewal.py`. Surface
probability and complete frame bytes must be the primary comparison; adding
byte-identical latent labels may not be called a gain just because it raises
`G(x)` or posterior entropy. A model with eight aliases must pay eight labels
and any selector/seed state.

### Reachable state and compiled-table audit

For vocabularies `{a, aa, b}`, `{a, aa, aaa, b}`, and a real frozen inventory:

1. Enumerate every live-suffix support and exact residual vector up to a
   bounded raw length.
2. Report support-state count, distinct exact vectors, quantized-state count,
   transition count, CDF bytes, and model bytes.
3. Compare the lazy `Model.advance()` output with the compiled transition table
   on every prefix. Never replace the vector by only the last byte unless this
   exhaustive check proves equal CDFs.

Accept a finite automaton only when state merging is by identical serialized
integer CDF/END rows and successor semantics. Approximate row merging must
report its changed probabilities and its actual frame cost.

### Quantization and frame robustness

Serialize the exact integer CDF convention (including tie rounding and minimum
counts), decode with an independent implementation, and compare bytes. Mutate
or truncate every section, especially the eight-byte arithmetic seed; reject
instead of zero-padding. Test noncanonical varints, impossible raw lengths,
path/token lengths that do not emit `raw_len`, extra payload bytes, and nonzero
padding. The complete frame must include model, CDF policy, length, boundary,
selector, restart, flush, CRC, and padding bytes.

### Final storage gate

Compare, on one frozen train/eval policy and untouched byte slices:

* v4 current/strongest retained parse;
* deterministic MAP/joint piece path;
* finite-length weighted-trie surface marginal;
* infinite-prefix marginal with its explicit length code.

Report model/header, CDF/automaton, length/boundary, latent selector (if any),
payload, restart/seed, padding, and CRC separately. A diagnostic gap or
cross-entropy win is retained as evidence but cannot promote a candidate
without an independently decoded complete-frame byte win.

## Primary sources

* Liu, Mandt & Van den Broeck, [*Lossless Compression with Probabilistic Circuits*](https://arxiv.org/abs/2111.11632). The relevant claim is tractable exact marginalization for a decoder-visible circuit; its image experiments do not establish a text weighted-trie win.
* Mohri, [*Weighted Automata Algorithms*](https://cs.nyu.edu/~mohri/pub/hwa.pdf), especially the probability/log/tropical semiring definitions and weighted determinization. The residual-weight subset construction and exponential worst case are directly relevant to compiling live posterior states.
* Townsend, Bird & Barber, [*Practical Lossless Compression with Latent Variables using Bits Back Coding*](https://arxiv.org/abs/1901.04866). A latent path is not free: posterior coding, prior coding, and ANS seed/restart accounting are part of the rate.

These sources motivate the audit and do not claim that this exact composition
compresses real language data. The local renewal oracle is the acceptance
reference for the bounded piece model; all arbitrary bytes, invalid UTF-8,
NULs, and mixed scripts remain ordinary byte strings.
