# Research next: a sparse fragment-aware source graph

Status: research formulation only.  This document does not add a wire feature,
does not claim a compression win, and does not use an encoder-only source
oracle.  It records the most promising stronger source model found in this
lane, its exact normalization, the bytes that have to be paid, and a bounded
experiment that can reject it.

## Verdict first

The useful synthesis is a finite, cloned, edge-emitting source graph whose
edges may select an exact reusable fragment.  A fragment is not merely a
dictionary entry and it is not an unrelated language-model feature: the same
edge carries

* the exact byte string (or a charged DAG reference to it),
* a sparse relation from a source boundary clone to a destination boundary
  clone, and
* a probability mass competing with literal, other-fragment, escape, and `EOS`
  events.

The decoder arithmetic-codes the observed bytes, not a hidden edge ID.  If
several fragment, copy, or segmentation paths emit the next byte, their masses
are summed and the posterior over the graph is updated.  Thus one long edge
can reuse a long exact span without paying a selector for every byte, while an
ambiguous source identity is not free: its alternatives appear in the
surface marginal and in the charged graph/model description.

This is stronger than the tested 2/8-state byte HMM because it has sparse
deterministic-emission clones, variable-length exact fragment events, and
boundary relations.  It is still a finite normalized probabilistic source,
not a claim that a suffix tree, a grammar, or a hidden parse is itself a
codec.  The likely obstruction is that exact marginalization either retains a
large live continuation frontier or requires enough cloned boundary states to
become a dictionary plus an ordinary high-order model.  A small model can win
only if many fragments have both high surface mass and a small, reusable
boundary relation.

The immediate research target is therefore a **bounded sparse fragment-aware
cloned source (SFCS)**, with a static frozen version and a separate
decoded-prefix adaptive version.  They must not be mixed in one result.

## 1. Exact source formulation

### 1.1 Boundary clones and event edges

Let `C` be a finite set of boundary clone states.  A boundary state is the
state at which the source may finish one fragment and choose the next event.
An event edge `e` has

```text
src(e)       in C
dst(e)       in C
payload(e)   a non-empty exact byte string
mass(e)      a non-negative probability mass
```

There is also an `EOS` event at each boundary state.  For every `i in C`,

```text
sum(e: src(e)=i) mass(e) + mass(EOS | i) = 1.                 (1)
```

The event set is finite and every payload is non-empty.  The graph must be
almost-surely terminating (for example, every recurrent boundary class has a
positive EOS hazard), or it must carry an explicit finite maximum record
length.  Merely having one reachable EOS edge is not enough: a non-terminating
closed class would leave probability mass outside finite records.  There must
be no uncharged empty-event cycle.

An event whose payload is one byte is a literal or escape.  A long event is an
exact phrase, a productive construction after its arguments have been
resolved, or a copy/reference whose source span is already available.  The
long event's bytes are represented once in a fragment DAG when possible:

```text
fragment := literal bytes
          | concatenate(child_1, ..., child_k)
```

The DAG is acyclic and has positive lengths.  A reference to a fragment does
not make its bytes free.  The frame pays for the DAG nodes that are delivered,
their lengths/child IDs, and the event edges that use them.  If a fragment is a
pointer into previous output rather than a static DAG node, the pointer's
source identity and offset are part of the event definition or its coded
choice.  A decoder may not guess an encoder-only occurrence.

The event graph is expanded conceptually into a byte-emitting hidden graph.
For an event with payload `b_1 ... b_m`, add continuation states that emit
`b_1`, ..., `b_m` deterministically and then enter `dst(e)`.  Continuation
states may be shared only when their complete future transition kernels are
identical (or after an explicitly charged approximation).  Otherwise they are
clones, even when their remaining byte suffix happens to be equal.  This
expansion is important: it makes variable-length events a genuine normalized
byte source rather than a bag of words with an uncharged segmentation choice.

Let `S` be the expanded state set and let `B_b` be the `S x S` matrix whose
entry is the mass of an edge that emits byte `b` and moves between expanded
states.  Let `B_EOS` contain terminal transitions.  For every state `i`,

```text
sum_{b in 0..255} sum_j B_b[i,j] + sum_j B_EOS[i,j] = 1.      (2)
```

The EOS transition is available at boundary states and is absent from an
unfinished continuation state.  The source therefore models record length
and termination causally.  It does not append a late END factor to an
otherwise non-normalized byte stream.

For a current row belief `q` over `S`, the next-byte mass and posterior are

```text
p(b | q) = q B_b 1
q'       = q B_b / p(b | q),                                 (3)
p(EOS | q) = q B_EOS 1.
```

The arithmetic coder has the 257 outcomes `0..255, EOS` at every output
boundary.  An observed byte updates all compatible hidden paths.  If eight
different source spans produce the same byte prefix, the decoder does not
send an eight-way selector; it sums the eight path masses.  Their uncertainty
still changes (3), and the graph/DAG/edge probabilities are charged.  If the
application instead commits to an event ID and then copies its payload, it is
using a different, explicit-event code and must code that ID.  It cannot take
the marginal rate from (3) while recovering a selected event for free.

### 1.2 Fragment operators and boundary relations

For a byte fragment `w = b_1 ... b_m`, define its transfer operator in the
expanded source as

```text
M_w = B_b1 ... B_bm,
r_w = M_w 1,
p(w | q) = q r_w,
q_w = q M_w / (q r_w).                                       (4)
```

The product sums all hidden paths that emit the byte sequence, including
paths that begin in a fragment continuation.  For a complete event fragment,
the boundary-to-boundary block of `M_w` is the exact relation carried by its
edge.  If a surface string has multiple event segmentations, its complete
operator is the sum of their compatible path products; it is not one chosen
parse.

The relation is the part that makes a fragment useful as both text and source
structure.  A static table may store a sparse `M_w`, or derive it from the
expanded event graph.  A stored relation is not free model state: count its
quantized coefficients, row/column IDs, and any CDF data.  If it is derived at
decode time, count the preparation/query work and the underlying graph bytes.

A useful bounded approximation is the row-factorized relation

```text
M_hat_w[i,j] = r_w[i] v_w[j],   v_w 1 = 1.                       (5)
```

It preserves `q M_w 1` for every incoming `q`, so the immediate probability
of the whole fragment is exact, but it resets the outgoing belief to `v_w`
instead of preserving the incoming-state-dependent destination.  Measure the
maximum total-variation distance between the normalized rows of `M_w` before
using (5).  Store the exact relation when dispersion is high.  Low-rank or
clustered boundary relations are promising only if their integer, closed
rollout is cheaper than the residual spelling they replace.

An exact boundary quotient identifies two states only when they have the same
probability for every future byte string and EOS (probabilistic bisimulation,
equivalently equal rows of the relevant predictive Hankel object).  Equal
surface suffixes are not sufficient.  This is the proposed “sufficient
boundary relation”: clone states share a fragment only when their continuation
effect is equal or the measured approximation loss is included.

### 1.3 Marginal coding versus macro coding

There are two valid but different ways to use the graph.

1. **Surface marginal (the primary target).**  Use (2)-(3), maintain the
   forward belief over boundary and continuation states, and code bytes plus
   EOS.  Hidden fragment/source/segment identities are marginalized.  This
   preserves byte adjacency and does not pay a selector per byte.
2. **Committed macro (a control).**  Order a finite set of event leaves in a
   complete prefix code and code an event ID, then emit its exact payload.
   Its row masses must sum to one, including fallback leaves and EOS.  A
   prefix cumulative table can use

   ```text
   R_k = sum_{event e before k} K_e 1,
   CDF(k | q) = q R_k,
   ```

   where `K_e` is the event boundary relation.  This is the useful
   `PrefixCDF` fast path, but it commits a latent event and charges its ID.
   An overlapping phrase bag, a finite list renormalized after the fact, or a
   leaf table with no fallback is not a normalized source.

The surface marginal is the only mode that can claim source-identity
marginalization.  It can still use precomputed cumulative vectors for byte
labels or for a complete event trie as an optimization, but it must not replace
the byte marginal by the MAP event.  A macro table with two equal spellings
must give the same surface probability after duplicate aliases are merged; an
alias count cannot be reported as a language gain.

## 2. How corpus suffix/grammar structure enters without an oracle

The encoder may use a corpus-derived suffix array, Wheeler/FM index, compressed
suffix tree, or grammar induction pass to propose repeated byte substrings and
boundary contexts.  These are proposal/index mechanisms, not free delivered
knowledge.  A deterministic bounded policy is needed, for example:

```text
max fragment length L
max delivered fragment roots F
minimum training occurrence count k
max outgoing events per boundary clone B
max clone states H
fixed tie-breaking and quantization rules
```

For a **static frozen graph**, the training-only pass delivers a fragment DAG,
clone IDs, event edges, initial belief, integer masses/CDF rows, continuation
layout, EOS policy, and restart metadata.  The frame charges all of them.  A
suffix index may be discarded after compilation; if it is shipped for online
queries, its suffix-array/BWT/tree samples, labels, counts, and smoothing
parameters are also model bytes.  The held-out and untouched bytes may not
choose fragments, clones, thresholds, or tie breaks.

For an **adaptive graph**, the frame delivers only a fixed initial skeleton
and a deterministic update rule.  At time `t`, every candidate, count, suffix
link, clone split/merge, and event row is computed from decoded prefix
`x_<t`, with the same insertion order and integer rounding at both ends.  A
new fragment may be made from prior decoded bytes, but its source span is then
known only when the same update rule creates it.  No future corpus lookup or
encoder-side donor identity is allowed.  If the graph is bounded by eviction,
the eviction policy and restart schedule are part of the model.  If it grows,
its resident state and query time are measured; it is not a free dictionary.

Restarting an adaptive graph either rebuilds it from the decoded prefix (paying
the rebuild/query work and losing no bytes only if the prefix is retained) or
sends a checkpoint of counts, suffix links, clone state, and current belief.
The checkpoint is frame data.  A static graph has a model-header cost instead;
it does not receive adaptive graph state for free.

The strongest version is therefore not “train a dense CDF on the corpus and
add a dictionary.”  It is one sparse source graph in which an exact fragment's
surface payload, boundary relation, and source probability are the same
object.  A fragment that improves spelling but has no reusable boundary
relation is a dictionary-only result.  A clone graph that predicts well but
has no exact payload reuse is an ordinary predictor result.  Both must be
reported separately from the combined frame.

## 3. State and byte accounting

Let `H = |C|`, `E` be the number of event edges, `F` the number of unique
fragment DAG nodes, `L` the maximum event payload length, and `D` the number
of expanded continuation clones after legal sharing.  A conservative static
bound is

```text
D <= H + sum_e len(payload(e))
```

before continuation sharing.  A DAG saves payload bytes but does not
automatically save continuation states: two occurrences with different
destination distributions require distinct clones even if their suffix bytes
are identical.  A sparse integer graph costs at least, up to coding details,

```text
fragment DAG bytes       ~ sum node lengths/child-ID descriptions
edge bytes                ~ E * (source, destination, fragment-ID, mass)
state/initial/EOS bytes   ~ D * labels + initial belief + terminal rows
CDF/quantization bytes    ~ reachable states * emitted outcomes * precision
relation cache bytes      ~ F * (exact H^2, sparse, or charged low-rank form)
```

The displayed terms are a lower-level accounting checklist, not a promise
that a particular integer format attains them.  A generated trie can reduce a
serialized dense CDF, but then it performs the residual update at run time.
A fully compiled deterministic surface machine with `Q` quantized predictive
states needs approximately

```text
Q * (257 * precision_bits + 257 * ceil(log2 Q))
```

bits for row masses and successors before compression.  Exact weighted
forward filtering avoids that table but retains a live vector over `D` states,
does more work per byte, and needs deterministic fixed-point/arbitrary-
precision conventions.  Quantizing that vector creates a finite machine whose
states and transition rows are model bytes.

For a non-deterministic fragment trie with `N` residual nodes, the active
support can be represented by a subset of residual nodes.  General weighted
determinization has an exponential worst case in `N` and can carry distinct
residual weight vectors even when the support repeats.  Sharing a suffix is
safe only when the destination relation is equal.  The bounded SFCS screen
should therefore report both the runtime frontier (`K_t`) and the number of
compiled predictive states (`Q`), not just the number of surface fragments.

The complete objective is

```text
frame bytes = header + graph/DAG + edge/CDF/relation model
            + surface payload bits
            + restart/checkpoint bytes + padding.                    (6)
```

The payload is coded with the same integer graph that the decoder receives.
Teacher posteriors, floating-point probabilities, a corpus suffix index kept
only by the encoder, and a selected hidden parse are not terms that can be
subtracted from (6).

## 4. What the three primary sources contribute

### Cloned HMMs: useful topology, no archive result

[Cloned Hidden Markov Models](https://arxiv.org/abs/1905.00507) (the HTML
version is [here](https://arxiv.org/html/1905.00507v4)) puts multiple hidden
clones behind the same observed symbol.  A deterministic/sparse emission
mapping and learned transitions can represent variable-context “holes” that a
plain low-order n-gram or a small dense HMM misses.  Its probability is a sum
over hidden state paths, and its forward/backward inference is the right
reference for the latent fragment graph above.  Sparse clone allocations and
context-specific transition rows are the transferable ideas.

The paper's language-model results are not complete archive comparisons.  Its
reported training/inference costs and model parameters still describe a
delivered model in a compression setting.  A large clone graph with dense
rows can spend more bytes than it saves, and EM cannot be run against future
decoded bytes unless it is converted to a deterministic adaptive update.
SFCS borrows the topology, not the claim that a character-model BPS number is
a frame total.

### Compressed suffix trees: exact query index, not a free source

Shareghi et al., [Fast, Small and Exact: Infinite-order Language Modelling
with Compressed Suffix Trees](https://aclanthology.org/Q16-1034.pdf), shows how
a suffix array/BWT/FM-index/suffix-tree representation can answer very high
order count queries compactly and exactly.  This is a strong candidate source
of sparse boundary relations: suffix ranges identify repeated contexts and
continuations without storing every dense m-gram row.

The index is still derived from a corpus.  In a frozen archive its BWT,
sampled suffix array, labels, counts, smoothing metadata, and restart state
must be delivered if the decoder queries it; compiling only the used fragment
relations is cheaper but charges those relations instead.  In an adaptive
archive the index can be rebuilt from decoded bytes, but suffix insertion and
memory grow with the retained prefix unless a bounded policy is specified.
Rebuilding at a restart and discarding history changes the source and has a
measured query/restart cost.  CST is consequently a construction technique
for SFCS, not evidence that a corpus index predicts for free.

### Sequence Memoizer: hierarchical context sharing, with adaptive cost

Wood et al., [The Sequence Memoizer](https://www.cs.ubc.ca/~fwood/papers/Wood-CACM-2011.pdf),
uses a hierarchical Pitman–Yor context tree: long contexts share parent
distributions, and a compact tree can collapse non-branching chains while
preserving the model's recursive predictive relation.  This is the clearest
precedent for a sparse suffix/context graph with boundary sharing rather than
a fixed short history.  It also demonstrates that an incrementally built
predictive model can be coupled to entropy coding.

The finite data tree and its random posterior state are not free frame bytes.
A frozen SM-like source needs its context tree, counts/discounts, integer
predictive rows, and initial state.  An adaptive version can rebuild counts
from the decoded prefix, but then it is a universal context model with paid
memory, update work, escapes, and restarts.  SFCS is only more than a
sequence memoizer when the same sparse context graph additionally carries
exact reusable fragment payloads and their boundary operators.  If no such
coupling improves complete (6), the honest result is that the broader source
reduces to a known adaptive context model.

## 5. Why the routine byte-HMM screen cannot reject this hypothesis

The negative 2/8-state learned-byte-HMM result is useful evidence against that
small topology under its measured accounting.  It does not test SFCS:

* a dense small HMM has no deterministic clone allocation for one observed
  byte with many context states;
* it has no variable-length event edges or exact fragment DAG, so it cannot
  reuse a multi-byte span as one source event;
* it normally keeps one posterior state per byte step rather than a bounded
  boundary relation for repeated word/phrase constructions;
* it has no suffix/Wheeler-derived sparse relation or source/copy identity
  graph; and
* a BPS or held-out NLL from a teacher does not charge the complete model,
  integer CDFs, graph definitions, fragment bytes, or restarts.

Thus a routine HMM loss says “this low-capacity dense predictor does not pay
for itself,” not “latent exact fragments cannot share predictive boundary
state.” Conversely, the wider claim has a high bar: once clones, fragment
payloads, relations, and posterior state are charged, it must beat the current
v4 frame, not merely beat that weak HMM.

## 6. Cheap falsification experiment

This is a proposed screen, not an experiment run in this task.  Keep all
limits and tie breaks fixed before inspecting held-out bytes.

### Construction

1. Use the existing train/dev/untouched split.  Extract repeated **byte**
   substrings from train only with a bounded suffix/Wheeler/CST or suffix-array
   pass.  Set a small maximum length `L` (for example 8 or 16), occurrence
   threshold `k`, fragment cap `F`, and boundary out-degree `B`.  No fixture
   names, Unicode schema, or free tokenizer is allowed.
2. Build a fragment DAG and cloned boundary graph with at most `H` boundary
   clones.  Allocate clones from deterministic context/boundary signatures;
   allow several clones with the same observed first byte, and keep only
   sparse edges plus literal/escape/EOS fallback.  Expand every long edge to
   continuation states or prove that a shared continuation has the same
   future kernel.
3. Fit integer edge masses on train.  Freeze the graph and CDF rows.  Separately
   run an adaptive variant whose counts/candidates are updated only from the
   decoded prefix.  For both, use the direct byte marginal (3); run the
   committed PrefixCDF macro mode only as a clearly labeled control.
4. Include a no-fragment cloned graph with the same state/edge budget, a
   fragment-only complete event code, and the existing v4 control.  This
   separates “better predictor,” “dictionary reuse,” and “coupled source.”
5. For the surface marginal, record exact/quantized forward frontier size,
   row dispersion for each `M_w`, and the closed decoder rollout.  The encoder
   may not use teacher beliefs or a hidden parse that the decoder cannot
   reconstruct.

### Workloads and pass/fail rule

Evaluate at least one ordinary corpus split, a repeated-context synthetic set,
and controls containing random bytes, NULs, invalid UTF-8, and reordered
records.  The synthetic set should make a long shared context around a varying
hole and include repeated arguments, but its grammar must be described by the
bounded generator rather than fixture-name rules.  Report ordinary language
and synthetic results separately.

For every case report:

```text
complete frame bytes from (6)
  model/DAG/edge/CDF bytes
  surface payload bytes
  restart/checkpoint/padding bytes
closed-rollout bits and bytes per input byte
maximum/mean live frontier K_t
compiled state count Q or adaptive graph size
decode work, cold-start work, and one-block restart work
```

Reject SFCS for this budget if any of the following holds:

* the coupled graph loses to v4 after model and restart bytes, even when its
  held-out NLL beats the no-fragment graph;
* gains disappear when training records are reordered or when a same-surface
  fragment is duplicated under another source alias;
* exact surface likelihood changes when a fragment is split into byte-identical
  aliases (an indication that latent ambiguity, rather than language
  structure, is being rewarded);
* the direct marginal cannot be implemented with the delivered integer graph,
  or round-trip fails on arbitrary bytes; or
* the graph wins only by allowing `K_t`, suffix memory, model bytes, or
  restart rebuild time to grow with the entire corpus.

The strongest cheap disproof is a paired run with the same fragment payloads:
one graph uses source-specific boundary relations and one replaces them by a
single unrelated dense byte CDF.  If the paired graphs have equal complete
bytes, the proposed source/predictor coupling has not paid for its complexity.
The strongest positive signal is a measurable complete-frame saving on
held-out ordinary data that survives alias, reorder, random-byte, and
checkpoint controls while retaining a bounded frontier.

## 7. Main obstruction and the bounded next step

There is a three-way tradeoff that should be treated as a likely negative
result, not hidden in implementation details:

```text
explicit macro boundaries  -> cheap exact copying, but source IDs are paid;
hidden boundaries           -> no per-byte selector, but posterior frontier;
small predictive state      -> compact rows, but only after valid boundary
                               relations/clones have been merged.
```

A suffix graph or Sequence Memoizer can make the second row useful, but its
contexts are numerous and its posterior/count state is not free.  A grammar
DAG can make the first row useful, but if edge weights and destination clones
are unrelated it is just a charged dictionary.  A low-rank operator can make
the third row compact, but it must be judged on closed rollout: preserving the
current fragment mass does not preserve the following context.

The bounded implementation target after this research note should therefore
be one static SFCS screen with small `H`, `F`, `L`, and `B`, plus an exact
surface-marginal oracle for tiny graphs.  Do not start with a billion-weight
teacher, a full Bayesian sampler, or a shipped corpus index.  First measure
whether sparse boundary relations exist at all and whether their charged
fragment bytes can replace v4's current spellings.  If the graph collapses to
an ordinary PPM/DMC/sequence memoizer or its complete frame loses, preserve
that null result.  If a narrow relation survives, only then test compiled
integer CDFs and restart policies.

## References

* Dedieu et al., [Cloned Hidden Markov Models for Sequence Classification](https://arxiv.org/abs/1905.00507)
  (source topology and latent clone-path inference).
* Shareghi, Cohn and Haffari, [Fast, Small and Exact: Infinite-order Language
  Modelling with Compressed Suffix Trees](https://aclanthology.org/Q16-1034.pdf)
  (suffix/BWT query structures and their storage costs).
* Wood et al., [The Sequence Memoizer](https://www.cs.ubc.ca/~fwood/papers/Wood-CACM-2011.pdf)
  (hierarchical infinite-order context sharing and adaptive coding).
* Mohri, [Weighted Automata Algorithms](https://cs.nyu.edu/~mohri/pub/hwa.pdf)
  (weighted composition/determinization and residual-state bounds).
* Root formulation: [language_frontier/FORMULATION.md](../FORMULATION.md).
  The related operator proposal and exact-prefix warnings are in
  [operators/PROPOSAL.md](../operators/PROPOSAL.md).
