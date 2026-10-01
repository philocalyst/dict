# Static shared grammar source experiment

This is a bounded research codec, not a promoted format. It tests whether one
charged binary grammar can provide both exact spelling reuse and useful
predictive continuation relations. All bytes, including invalid UTF-8, remain
unchanged. No confirmation-20 file is read.

[Cloned HMMs](https://arxiv.org/abs/1905.00507) motivate distinct predictive
states behind equal observed emissions. Here that means equal byte suffixes
cannot merge when their exit relations differ. Their character-model results
are not archive totals. [Probabilistic circuits](https://arxiv.org/abs/2111.11632)
show how tractable marginalization can support arithmetic compression. Their
image results do not establish a text-grammar win. The proposed composition
here is deriving fragment-exit prediction from the SAME charged binary DAG,
then testing the complete frame against separately paid actual adjacency.

The grammar stores `A=(B,C,count(A))` with only backward child references,
at most1024 rules, and at most256 expanded bytes per rule. Singleton counts
and every rule count are serialized. The input's final root token sequence
is omitted. Therefore a grammar is a dictionary of constructions, not an
unpaid reconstruction of the input. A repeated long token shares its spelling
through the DAG instead of a separate flat token string table.

Let `k(t)` be a token's exit-boundary key and `c(t)>0` its delivered count.
The exact-token key, last-literal-byte key, and final-two-byte key are separate
source hypotheses. The latter two change the source; they are not asserted
to be predictive-equivalent quotients. Continuation states only merge when
both their exact remaining suffix and exit key agree.

The grammar-only sparse row is derived from its paid rules:

```
H_i(t) = sum count(A), over A=(B,t) with k(B)=i
p_i(t) = (1-alpha_i) c(t)/sum_u c(u) + alpha_i H_i(t)/sum_u H_i(u)
alpha_i = strength/8 if H_i is nonempty, otherwise 0
```

This row is normalized. No class or transition-frequency table is paid a
second time. However, internal grammar joins need not predict the NEXT
top-level token. This semantic misalignment is precisely the hypothesis
tested; a low header cost cannot excuse a poor source. The legacy last-byte
grid control adds a rule's count once for each right-spine ancestor, all of
which project to the same key. It deliberately depth-weights that row, rather
than creating distinct ancestor contexts.

GSG2 adds a stronger, separately charged control. Its retained `(B,C,count)`
triples count ACTUAL neighboring tokens in the final BPE root sequence. The
64/256 largest adjacency counts, each at least2, are delivered explicitly.
Topology1 uses only these rows; topology2 adds the grammar-derived rows.
There is no root token sequence, external training model, unpaid selector,
or encoder-only context available to its decoder. Source identities and all
weights appear in the full header. Unretained contexts back off to the global
fragment source. These paid continuation triples test the cost of repairing
the grammar-join mismatch rather than assuming it away.

At any observed byte prefix, the posterior consists of boundary masses `q_i`
and continuation masses `q_(suffix,dst)`. Its next-byte probability is:

```
P(b) = sum_i q_i sum_t p_i(t) [first(t)=b]
     + sum_(suffix,dst) q_(suffix,dst) [first(suffix)=b]
```

Compatible event paths are added before normalizing. Finishing a fragment
moves its mass to `k(t)`; unfinished paths retain the exact suffix and exit
key. Every event emits at least one byte. No epsilon cycle exists, and each
step consumes exactly one output byte. All256 singleton events have positive
global mass. The delivered raw length truncates this normalized renewal
stream, including a final partial token; it is not an uncharged EOS trick.

The committed control uses the SAME row distribution and header but sends a
greedy token path minimizing per-byte local negative log probability. Its
last token may cross the charged final length. This is explicitly a committed
greedy control, not a global MAP claim. A marginal win against it is not
automatically a latent MAP gap.

Arithmetic coding uses a64-bit interval and20-bit rounded positive CDFs.
Forward posteriors use floating point: cross-architecture bitwise portability
is unverified. In extreme cases, underflow can eliminate tiny root mass even
though the mathematical singleton probabilities are positive. Consequently
these tests do not establish total-byte support for every possible floating
rollout; there is no production support or portability guarantee. This
noncompetitive prototype is not being expanded into an integer implementation.
The exact model-bit diagnostic describes the unquantized
source; actual payload and full-frame bytes, including finish/padding, are
the compression result. Decode reconstructs and canonically re-encodes the
payload, checks lengths/references/counts, and enforces output/model bounds.
The finite expansion bound limits total flattened grammar storage to less
than328KiB. It does not promise a fast decoder or a small Python object graph.

The independent Fraction oracle enumerates token-ID/offset paths, then checks
its exact byte probabilities against the implementation's merged frontier.
Tests also cover empty/singleton inputs, repeated text, arbitrary bytes,
invalid UTF-8, malformed references, count/output limits and truncation.

`encode(raw, *, block_bytes, **options)->bytes` and `decode(frame)->bytes`
are the adapter contract. This prototype accepts one bounded block. The
small, large, and paid-root adapters are corpus-independent frozen policies;
their output requires no encode options to decode.

Reproduce cheap screens with `python3 grammar_source/screen.py grid` and
`python3 grammar_source/root_screen.py grid`, from this frontier directory.
The former grid records48 actual full-frame measurements:12 policies each
on FreeDict/OMW2KiB self-fit and disjoint held-development pairs. The latter
records16 additional paid-root measurements. `results/freeze.json` and
`results/root-freeze.json` record the global freezes before seven16KiB rows.
The filename stems identify64KiB source containers; `raw_bytes`, frame
length and exact hashes identify the actual16KiB tested prefixes.

Initial GSG1 frozen artifacts were produced by an already-imported module
while the subsequent GSG2 extension was developed. GSG2 explicitly decodes
them compatibly, but the original imported encoder source snapshot was not
retained. That initial run's encoder provenance is incomplete; its current
on-disk source hash must not be assigned retroactively. The subsequent
quickbench GSG2 run fingerprints its current source closure and rejects
mid-run source changes. That is the authoritative reproducible frame/control
evidence. No Python wall time is presented as native kernel throughput.
