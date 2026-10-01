# Persistent latent-belief screen

This lane tests one structural hypothesis: a lexical stream can carry a
small persistent belief over latent source states, while the delivered
decoder sees only a finite table transducer.  The encoder trains a tiny
input-local HMM on a separate frozen train slice.  It then samples the
teacher's pre-emission beliefs, clusters those beliefs, and freezes one
representative per compiled state.  For every representative and each of
256 bytes plus `EOS`, preparation computes:

```
q' = normalize((q * emission[:, symbol]) * transition)
next = nearest_compiled_representative(q')
```

The frame stores only the integer CDF row and `next` ID.  A decoder performs a
range decode and table lookup; it never evaluates an HMM, posterior, float,
teacher, tokenizer, or external dictionary.  Because the next row is computed
from the representative `q`, the compiled cross-entropy and frame rollout use
the actual finite-state recurrence.  They do not assign each prefix to the
teacher's original posterior, which a decoder cannot know.

The bounded screen uses latent/compiled state counts `K=B ∈ {2,4,8}` and two
fixed clustering ablations:

* `observed`: deterministic farthest-point seeds plus eight nearest-centroid
  refinement rounds over observed training beliefs; state 0 remains the exact
  initial belief.
* `balanced`: deterministic sorting by the first posterior coordinate and
  equal-count representative groups, with the same exact state-0 rule.

The alphabet is full byte space plus `EOS`, so arbitrary invalid UTF-8,
NULs, combining bytes and mixed scripts remain exact.  Frames have explicit
length, CRC32, checked table sizes, restart records carrying state IDs, and
independent fresh-process decode checks.  Every CDF, next-state row, restart
record, range payload, header and checksum is charged.

## Why this is not Lane F Q4

Lane F Q4 adds ordinary order-2 or sticky class rows to a static bucket model;
its row choice is a function of one or two observed class labels.  This lane's
row is a quantized posterior over a trained latent process and can persist
memory after the immediately preceding byte's class has become ambiguous.  It
therefore tests non-local state, not a larger last-token context.  The finite
table still resembles v4's `Model.next`; the proposed composition is the
teacher-belief recurrence followed by deterministic quantization.  It is a
hypothesis, not a novelty claim.

## Literature mechanism and limits

The screen is motivated by the target-topology bottleneck in [probabilistic
source distillation and KL-best WFAs (2020)](https://arxiv.org/pdf/1905.08701),
where fitting probabilities is insufficient if the finite topology cannot
represent the source; by exact forward recurrence in [block-sparse HMM language
models (2020)](https://arxiv.org/pdf/2011.04640); and by latent supervision for
compact finite models in [encoder-only teacher latent distillation
(2024)](https://arxiv.org/html/2210.04398v2).  [Transducing Language Models
(2026)](https://arxiv.org/html/2603.05193v1) is a related caution: pushforward
probabilities through token/byte transducers need explicit finite safety
checks, not a hidden teacher query.  None of these papers is a claim that this
small byte experiment wins on natural-language storage.

## Run protocol

`python3 screen.py dev` trains on 64 KiB prefixes of the old dictionary train
files and 16 KiB prefixes of each frozen UD projection, then evaluates only
dev slices.  It never reads old `*.untouched.bin` files.  Choose one policy by
the predeclared aggregate dev rule (mean frame bytes/input bytes over all
nonempty rows; ties choose smaller `K`, then `observed`) and invoke, for
example, `python3 screen.py final --k 4 --mode observed`.  The final phase is
the only phase that reads untouched slices.  It does not retune per corpus.

The teacher JSON files are retained as encode-time evidence but marked
`teacher_params_in_frame: false`; deleting them does not affect decoding.
Frame bytes in `runs/` are authoritative.  Cross-entropies are diagnostics and
never substitutes for the complete frame.

