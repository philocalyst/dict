# CCM1 development result

CCM1 is the first context-conditioned fixed-point logit/APM experiment.
Its [protocol](/workspace/dict/src6/experiments/grammar_automaton/context_mixer/PROTOCOL.md)
fixed the nine experts, five ablations, integer arithmetic, source set and
stop rule before the first book run. The scorer uses no external vocabulary,
model weights or floating-point predictor state. It measures Q15 ideal
arithmetic entropy **without making an archive**.

The exact six-book UTF-8 body manifest is SHA-256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`.
The same-source bzip3 complete-frame controls are SHA-256
`640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f`.
The runner checks every source hash and bzip3 fresh-decode gate before
reporting a model score. Full per-quarter and per-expert results are in
[ccm1-six-prefix.json](/workspace/dict/src6/experiments/grammar_automaton/context_mixer/evidence/ccm1-six-prefix.json)
(SHA-256 `3a598ad8c1260a8d8f6e292a4397f24a8971bfb7fff16668719a0bd2919f0097`).

| Development book input | Best CCM1 ideal bytes | Complete bzip3 bytes | CCM1 excess |
|---|---:|---:|---:|
| Austen, whole 705,012 B | 168,763 | 161,119 | +4.7% |
| Tolstoy, 1 MiB prefix | 260,146 | 247,364 | +5.2% |
| Cervantes, 1 MiB prefix | 263,843 | 252,940 | +4.3% |
| Flaubert, whole 716,472 B | 187,541 | 179,597 | +4.4% |
| Kafka, whole 126,200 B | 36,453 | 35,251 | +3.4% |
| Sōseki, whole 486,098 B | 102,973 | 97,505 | +5.6% |

The conditional logit mixer beats the global-row mixer on five of six
inputs, saving 3,656 B on Austen and 6,610 B on Tolstoy at ideal entropy.
That verifies causal context specialization is useful. The 33-knot APM
then **increases** cost on all six by 70–1,714 B relative to the conditional
mixer. Removing both word predictors or the match predictor usually raises
cost; neither recovers the bzip3 gap. The best candidate is still larger
than a complete bzip3 frame on every book before coder rounding, header,
termination and CRC. The preregistered threshold for a native frame is not
met; no frame or decoder was built.

All six tagged context tables use four-way exact-key replacement. The
byte8 table replaced 538,679–6,296,251 rows per input; those counts are
deterministic capacity pressure, not hash-equality errors. The fixed-state
plus source buffer estimate was 56.9–57.9 MiB, under the 512 MiB ceiling;
the estimate excludes allocator bookkeeping and is not a sampled RSS peak.
The code processed 8 bits per byte with nine expert updates and five mixer
updates per bit. No concurrent-process wall clock is presented as a speed
result.

Source SHA-256s: scorer
`0c7d02d2752a8b44a1cff68d915adef2f36b4ad059520881db8c0f9171dba238`,
Decimal table generator
`c4b087da1b9f3127e055f9e5bc28cb720d3ac02da5a980d2d7b599d7aee5dff4`,
generated integer squash table
`82e8ea89e8116a4ec34b6ad77ab39523109c64d79cde563468a083d98d3d0da7`,
runner `27d7ca92dc006d3870bdf538b3c62cbc3fd106cf1bf3b1a935560b44717b5b2d`,
and ReleaseFast scorer binary
`2fc40cd19cfea3f2092fa8ddcb37bbd960e0c3f5dec271c598cce4fc0d1a5339`.
The arbitrary/invalid-byte tiny source passed an ASan+UBSan scorer run.
No sealed final or reserved validation text was inspected.
