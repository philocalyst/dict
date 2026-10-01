# Forgetful phrase operators: proposal and disproof screen

Status: bounded research experiment.  This lane does not add a Bzip4 wire
feature and does not claim a complete archive win.

## Mechanism

For a finite edge-emitting source with (H) hidden states, let (M_b) be the
(H\times H) transfer matrix for byte (or terminal `EOS`) (b).  A fragment
(w=b_1\ldots b_m) has

```
M_w = M_b1 ... M_bm
p(w | q) = q M_w 1
q_w = q M_w / p(w | q).
```

The product sums over all hidden states inside the phrase.  Caching an exact
operator costs (H^2) coefficients, while applying it costs a matrix-vector
product.  Write (r_w=M_w1), and, when every (r_{w,i}>0),

```
P_w[i,j] = M_w[i,j] / r_w[i].
```

The rows of (P_w) are the destination distributions conditional on the
fragment and each incoming state.  The proposed rank-one reset is

```
Mhat_w = r_w v_w^T,
```

where `v_w` is one shared normalized destination row for that fragment.  This
preserves `q M_w 1` for *every* incoming `q`, exactly, because `v_w 1 = 1`.
It does not preserve the following context: after a reset the next belief is
`v_w`, independent of the incoming belief.  A natural deterministic choice is
the `r`-weighted average of the rows of `P_w`; it minimizes the corresponding
weighted squared operator error and is not fitted to the held-out target.

The screen freezes the reset policy across corpora.  A phrase is reset when
the maximum total-variation distance between rows of `P_w` is at most one of
`0`, `1e-4`, `1e-3`, or `1e-2`; otherwise its exact operator is used.  The
thresholds are a sensitivity sweep, not per-corpus tuning.  Exact rank and
row-dispersion diagnostics remain available for fragments that do not reset.
The closed rollout advances its own approximate belief, never the teacher's
belief at each target prefix.

This is a possible composition of standard finite-state filtering and
rank-one approximation, not a novelty claim.  Shue, Anderson and Dey prove
exponential stability/forgetting bounds for finite-state HMM filters using
positive-matrix arguments ([author repository](https://mural.maynoothuniversity.ie/id/eprint/12732/),
IEEE DOI [10.1109/78.705429](https://doi.org/10.1109/78.705429)).  Ye, Ma and
Qian relate the HMM memory-decay rate to the gap of the top two Lyapunov
exponents and give a Birkhoff-contraction bound for positive matrices
([arXiv:1710.06078](https://arxiv.org/abs/1710.06078)).  Those papers justify
measuring contraction; they do not say that a phrase's operator is cheaply
rank one or that its reset survives a lossless coding cost.

For the finite-model side, Suresh et al. optimize a KL approximation of a
probabilistic source by a WFA ([arXiv:1905.08701](https://arxiv.org/abs/1905.08701));
Balle, Panangaden and Precup give an SVD/Hankel canonical form and approximate
WFA minimization ([IEEE 7174924](https://ieeexplore.ieee.org/document/7174924/));
and Thon and Jaeger connect multiplicity automata, observable-operator models
and PSRs ([JMLR 16 (2015)](https://jmlr.csail.mit.edu/beta/papers/v16/thon15a.html)).
They concern model approximation/topology, not this phrase-reset composition.

For a strictly positive (M), the measured cross-ratio diameter is

```
Delta(M) = max_i,j,k,l log(M[i,k] M[j,l] / (M[i,l] M[j,k]))
tau(M)   = tanh(Delta(M) / 4).
```

The Birkhoff bound says that projective (Hilbert) distance contracts by at
most `tau`.  If a matrix contains a zero, the finite cross-ratio bound is
not reported; a large finite `tau` is also evidence that the theorem gives
little practical help.  Row dispersion is an empirical reset criterion, not
a replacement for a proof of forgetting.

## Normalization and phrase inventory

An overlapping bag of words is not a normalized source: its operator masses
usually do not sum to one and a hidden parse would add an uncharged latent
choice.  The experiment therefore builds a finite **complete prefix code** over
the 257-symbol alphabet (bytes plus `EOS`).  A small, frozen set of frequent
training spans is inserted as trie paths.  Every sibling byte branch becomes a
fallback leaf; every internal trie node gets a terminal `prefix + EOS` leaf;
`EOS` at the root is also a leaf.  Thus every finite byte sequence followed by
one terminal `EOS` has exactly one phrase parse and the phrase-operator masses
sum to one for every source row.

If the input ends inside a candidate path, the virtual terminal `EOS` selects
that node's `prefix + EOS` fallback phrase.  If it ends exactly at a candidate
leaf, that leaf is emitted and the root `EOS` leaf follows.  The terminal is
not written to the reconstructed byte stream.  This is the explicit final
partial-phrase rule; no bytes are dropped or normalized.

The word and `morpheme_proxy` inventories are deliberately *diagnostic* and
not normalized codebooks.  The latter is only a byte-substring proxy for a
recurring lexical fragment, not a linguistic segmentation.  Only the
complete codebook is used for the closed likelihood and CDF checks.

For codebook phrases ordered by their trie symbol sequence, precompute

```
R_k = sum_{w < k} M_w 1,       CDF_q(k) = q R_k.
```

After the (O(PH^2)) one-time preparation, a query needs (O(PH)) to form
all cumulative masses (or cached `R_k`) and (O(H log P)) to binary-search a
phrase.  It must not multiply `q` by every (H\times H) operator at each
query (`O(PH^2)`).  The script checks the optimized CDF against direct
enumeration.

## Charged accounting and disproof

The screen reports exact and rank-one coefficient counts, and also constructs
an uncompressed binary model blob with `struct.pack` so the serialized byte
count includes phrase symbols, flags, lengths, all `float64` coefficients,
and the header.  These are model-size diagnostics, not compressed payload
bytes.  No approximate archive, decoder, or v4 replacement is claimed.

The closed rollout compares exact teacher phrase NLL with the same sequence
under each frozen threshold.  A reset may save (H^2-2H) coefficient bytes,
but any NLL increase and the complete prefix-code/trie model cost remain.  The
bounded screen reads only `train.bin` and `dev.target.bin` (at most 64 KiB per
corpus), never `*.untouched.bin`, and does not retrain or modify the stored
HMM teachers.

