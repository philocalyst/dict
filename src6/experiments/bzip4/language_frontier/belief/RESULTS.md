# Persistent latent-belief screen results

The machine-readable evidence lives under `runs/`.  The dev phase is complete;
the untouched/final phase remains intentionally unrun pending an explicit
root policy freeze.  That is a protocol gate, not a missing result.

## Frozen dev screen (54 complete frames)

All nine dev workloads have a fresh-process exact re-decode, a complete old
v4 frame, and a matched bzip3 control.  The six policies below are aggregate
weighted values across 294,912 target bytes.  `frame_bpb` includes every LBEL
header/table/restart/payload/checksum byte; CE is diagnostic only.

| teacher/compiled states | clustering | frame bytes | frame bpb | teacher bpb | compiled bpb | vs old v4 | vs bzip3 |
|---:|---|---:|---:|---:|---:|---:|---:|
| 2 | observed | 223,757 | 6.070 | 4.654 | 5.539 | 3.125x | 3.865x |
| 2 | balanced | 225,217 | 6.109 | 4.654 | 5.578 | 3.145x | 3.890x |
| 4 | balanced | 265,235 | 7.195 | 4.369 | 6.161 | 3.704x | 4.581x |
| 4 | observed | 266,195 | 7.221 | 4.369 | 6.187 | 3.717x | 4.598x |
| 8 | observed | 307,017 | 8.328 | 4.261 | 6.289 | 4.287x | 5.303x |
| 8 | balanced | 307,467 | 8.341 | 4.261 | 6.301 | 4.294x | 5.310x |

The complete controls sum to 71,608 bytes for old v4 and 57,899 bytes for
matched bzip3.  The aggregate dev rule therefore selects `K=2, observed` if
root freezes a policy: it has the smallest charged frame.  The teacher CE
improvement from K=2 to K=8 does not survive finite-state quantization/table
cost; this is a clean topology/table-cost rejection, not a compression win.

Raw per-case JSON, frames, decoded outputs, teacher-only artifacts, commands,
and hashes are under `runs/latent-belief-dev-20260926/`.  The corrected
aggregate is `summary.json`; `summarize.py` recomputes it from immutable
per-case JSON rather than trusting an entropy estimate.

Required reporting fields per workload/candidate are:

* train, target and frame SHA-256 hashes, source offsets and lengths;
* teacher cross-entropy, compiled finite-state cross-entropy, and complete
  frame bytes;
* header/table/restart/payload/checksum breakdown;
* complete old v4 frame and matched bzip3 controls on the same target bytes;
* fresh-process decode result and exact output hash;
* truncation/checksum/row-reference safety tests.

Interpretation gate: reject a candidate if its frame is mostly duplicated CDF
and transition tables with no plausible shared representation, or if its
teacher CE improves while its charged frame loses.  A CE result is not an
archive result.  The frame includes EOS, explicit length and restart state,
so termination and restart costs cannot be silently omitted.
