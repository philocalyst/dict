# Recent byte-level modeling: transferable ideas and native tests

**Status:** source review plus bounded development diagnostics. The DAFSA
proposal below has since been measured and rejected; see
[`DAWG_RESULTS.md`](DAWG_RESULTS.md). No final corpus was used.

## What the recent primary sources establish

The [Byte Latent Transformer paper and author repository](https://github.com/facebookresearch/blt)
describe a byte-level language model that groups bytes into dynamically sized
patches using the entropy of the next byte. Its authors report long average
patches and publish 1B and 7B checkpoints. This supports testing variable
patching as a modeling idea; it does not supply a free codec model. Shipping
even the smallest checkpoint would dwarf these dictionary frames, and running
it for each emitted byte conflicts with the native decoder's inexpensive
word copies.

[MambaByte](https://arxiv.org/abs/2401.13660) is a token-free selective
state-space language model. Its [author code repository](https://github.com/jxiw/MambaByte)
loads 353M/972M-class checkpoints and reports byte-level cross entropy/bits
per byte. It shows that raw-byte prediction is a viable language-modeling
unit, but it is not a lossless codec design and carries large weights and
per-byte inference work. The native transfer worth testing is a very small,
fully serialized finite-state source over a one-time lexicon stream, not a
pretrained byte model.

[Transducing Language Models](https://openreview.net/forum?id=qOyF214xmg)
composes a source LM with a finite-state transducer and sums the probability
of all source strings that map to an output string. The [official code](https://github.com/rycolab/transducing-language-models)
describes the finite quotient/remainder method for transformed-prefix
probabilities. This is a useful formal account of ambiguity and transformed
sources. The WGP6 language-frontier lane already tested weighted
emission/marginal coding, so another latent-parse marginal experiment is not
recommended here. A deterministic lexicon automaton avoids that frontier and
its per-prefix growth.

These papers are modeling references, not compression results for this
format. In each experiment below, the encoder must serialize every state,
transition, symbol table, boundary code, rank map, and payload operand. No
checkpoint, corpus vocabulary, or normalization is assumed to be shared.

## Native experiments, ranked

### 1. Rank-addressed minimal acyclic word graph

Replace only the direct spelling inventory with a minimal deterministic
acyclic automaton (DAFSA) for the exact sorted set of byte strings. Accepting
paths enumerate the same words in byte-lexicographic order, which remains the
existing occurrence-ID order. Store labeled arcs, target-state deltas, and
terminal flags. Number states topologically so the decoder can recompute the
number of accepted suffix paths per state; use those counts to unrank an ID.
The occurrence stream and its frequency coder stay unchanged, and the graph
contains no occupied stem/tail pairs, first-use permutation, or separate
word-ID map.

At frame start, enumerate/unrank the graph once into a flat byte arena plus
word offsets. The normal occurrence loop can then continue to decode one ID
and `memcpy` its word, preserving the fast bulk-word path. All arc labels,
state/arc counts, terminal flags, headers, and any rank aids are charged in
the graph section. State path counts should be derived rather than sent when
the chosen numbering makes that safe.

**Falsifier:** compare the complete graph plus unchanged ID source against the
same-order front-coded inventory control on the retained 1 MiB and 8 MiB
samples. Reject if its total frame does not improve by at least 1% on one
development dictionary or if pre-expansion dominates decode time. This is
different from the current spelling DAG: it shares equivalent *suffix
languages* across word paths instead of naming reusable substrings and
parsing each word into those names. The distinct-word set is represented
directly; no generated combinations are implied. The bounded probe rejected
both raw and path-compacted forms on all six rows, before a native frame.

### 2. Tiny finite-state byte source for the one-time lexicon prelude

Keep the same sorted distinct-word order and same occurrence-ID stream, but
encode the prelude as a byte stream with explicit word-end symbols. Learn a
fixed, small source automaton from the permitted training prefix: for example,
4–8 byte-history states, a delivered transition for every state/byte,
and one static byte-plus-EOW code row per state. Reset or carry state across
word boundaries according to one fixed policy. Use a native table coder, and
include all transitions, code lengths/frequencies, restart state, and word
ends in the frame. Train and price the model on the compressor side; the
decoder receives only the serialized tables.

The decoder expands the prelude once into the same flat word arena used by
occurrence decoding. Thus the inner payload still uses word-sized copies;
only initialization decodes individual bytes. A useful upper bound on table
size is roughly `states × 256` transition bytes plus the per-state symbol
tables. With 8 states, even a compact implementation should charge a few
kilobytes rather than a neural checkpoint. It wins only if the coded byte
stream beats the existing front-coded spelling bytes by more than that table
cost plus word-end coding.

**Falsifier:** compute actual native table bytes and coder output for this
prelude against direct front coding, holding the sorted type IDs and every
other stream fixed. Reject before full integration if it cannot save at least
the delivered transition/table cost, or if the complete frame misses the 1%
screen. BLT motivates variable effort where byte entropy changes; MambaByte
motivates checking raw-byte predictability. The proposed model uses neither
paper's neural weights nor a free tokenizer, and its finite-state transition
table is fully paid.

### 3. Byte-history copy patches for the lexicon prelude

As a separate low-priority control, encode the concatenated exact word
spellings with boundary symbols using a bounded byte-history parser. A patch
is either a literal run or a `(distance, length)` copy from already decoded
lexicon bytes; use a small static model for patch kind, length, distance, and
literal bytes. Freeze a deterministic maximum window/length policy and price
every patch operand and table. This uses dynamic source positions rather than
named substrings, BPE intermediates, CUT donors, or stem/tail combinations.

Decode that prelude sequentially into the flat word arena, then use the same
word-ID `memcpy` path. It is likely less attractive than the graph because
distance operands and byte-wise prelude work can outweigh the string savings;
the immediate screen is therefore just an exact parse-price comparison
against front coding and the native automaton's existing past-copy source.
Drop it if either the delivered command tables erase the savings or
prelude-only decoding is materially slower. It needs no new held-out tuning
and no neural patch predictor.

## Evidence thresholds and scope

The old native learner's FreeDict 8 MiB spelling delta is 273,038 of 579,677
bytes (47%), so this area justifies one new source representation. It does
not justify another unpriced candidate-count sweep: for a 1% total-frame
improvement, a new inventory source must save at least about 5.8 KB on that
row after all metadata and occurrence operands. The direct stem/tail probe
and MDL-gated hybrid already show that apparent table savings can be erased
by conditional information and support metadata. Keep all existing native
sources as controls, report 1 MiB and 8 MiB by corpus and type inventory, and
promote only complete byte-exact native frames with round trips.

## Source verification

Read-only source review used the author/official GitHub repositories above;
the BLT repository links its paper PDF and describes entropy-driven patches,
MambaByte's repository identifies its 2024 arXiv paper and checkpoint sizes,
and the TLM repository identifies the ICLR 2026 paper and spells out its FST
precover sum. Direct arbitrary-site network access was unavailable in this
environment, so the factual summaries above are limited to those primary
repository materials and their linked paper records.
