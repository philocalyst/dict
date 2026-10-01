# SCM4 direct-CDF mathematical review

Reviewed 2026-09-26: `surface_copy/SCM4.md`, `surface_copy/RULES.md`, current
SCM3 `surface_copy/codec.py`, and the direct-CDF section of `STATUS.md`.
This is an equation/design review, not an SCM4 implementation review.
`cdf_codec.py` did not exist at review time. No benchmark or sweep was run.

## Verdict and proof conditions

The proposed cumulative law is valid and supports direct queries, provided
each row reports an exact total and prefix sum, lower CDF endpoints are 0/Q,
and pre-emission escape plus copy masses sum exactly to Q=65536. It is a new
quantization law; SCM3 byte identity is neither expected nor a correctness test.

For a suffix row, let A(k)=Q*C(k)+16*L_lower(k). A is nondecreasing,
A(0)=0, and A(256)=Q*(n+16). Consequently
`L(k)=k+floor(65280*A(k)/(Q*(n+16)))` has endpoints 0 and 65536.
For adjacent endpoints its difference is 1 plus a nonnegative difference of
floors: every byte has strictly positive integer mass. The order-zero formula
has the same proof with A(k)=C(k)+k and denominator n+256. At an empty history
it yields L(k)=256*k exactly. Missing rows must return the lower CDF unchanged.

For emission, B(k)=e*L(k)+Q*W(k) is nondecreasing, B(0)=0, and
B(256)=Q*(e+sum(copy))=Q². Thus F has endpoints 0/Q and strictly positive
increments. Individual emitted masses sum Q by telescoping. This differs
from independently flooring each SCM3 byte mass then renormalizing its total.

Literal posterior weight must be `e*(L(b+1)-L(b))`; matching copy weights are
`w*Q`. The projected posterior is explicitly not exact Bayes for emitted F:
F adds minimum byte mass and performs cumulative rounding, and subsequent
normalization/pruning further changes state.

**Important denominator condition:** F's minimum-one mass alone does not prove
that the latent posterior normalization denominator is positive. An observed
byte unsupported by both latent components would have a legal F interval but
zero posterior weights. The existing survival/start policy prevents this:
when escape is zero, at least one positive active weight exists; floor survival
with denominator 4..64 or 16 releases at least one mass unit. Start rates at
most 3/4 leave positive escape. Hence pre-emission e>=1 and positive literal
increments imply posterior sum>=1. Preserve this condition in SCM4; allowing
start=1 or survival=1 exactly would require an explicit fallback law.

## Arithmetic and binary-search boundaries

For inclusive arithmetic state [low, high], R=high-low+1, and total Q:

```
v = ((code-low+1)*Q-1)//R
b is the unique byte with F(b) <= v < F(b+1)
new_high = old_low + (R*F(b+1))//Q - 1
new_low  = old_low + (R*F(b))//Q
```

Both updates must use old_low and old R. For a valid code, v is in 0..Q-1.
Use upper-bound semantics at equality: v=F(k) belongs to byte k, not k-1.
An eight-query search is possible over bytes [0,255], querying F(mid+1) and
testing `v < F(mid+1)`; a generic search over all 257 endpoint indices may
have a different query bound. F(256)=Q is an endpoint, never an emitted byte.
The current 32-bit renormalizer leaves range greater than one quarter of its
32-bit domain before the next step, comfortably above Q, so every positive
CDF interval produces a nonempty arithmetic interval. Preserve renormalization
and validate code/interval state when decoding hostile payloads.

Materializing all 257 boundaries under these same recursive formulas gives
exactly the direct-query result: each query is a pure function of one frozen
pre-byte state. Differences of the dense endpoints, not a largest-remainder
normalization of per-byte values, are the dense reference counts. Predictions
must not mutate rows or copy state during encoder endpoints or decoder search.

## Exact integer widths

These bounds assume the existing row rescale threshold 4096, alpha=16,
64 KiB blocks, Q-mass conservation, and positive state weights.

| Quantity | Maximum | Required unsigned bits |
|---|---:|---:|
| Q, CDF endpoint, individual state mass | 65,536 | 17 |
| Row total at prediction | 4,095 | 12 |
| Order-zero numerator 65280*(C+k) | 284,033,280 | 29 |
| Q*C+16*L and Q*(n+16) | 269,418,496 | 29 |
| Suffix numerator 65280*(Q*C+16*L) | 17,587,639,418,880 | 44 |
| Emission inner e*L+Q*W | 4,294,967,296 | 33 |
| Emission numerator 65280*(e*L+Q*W) | 280,375,465,082,880 | 48 |
| Projected individual/summed unnormalized posterior | Q²=4,294,967,296 | 33 |
| Posterior normalization product weight*Q | Q³=281,474,976,710,656 | 49 |
| Inclusive arithmetic range R | 2³²=4,294,967,296 | 33 |
| Arithmetic R*F endpoint | 2⁴⁸=281,474,976,710,656 | 49 |
| Decoder scaled numerator before division | at most 2⁴⁸-1 | 48 |

Use u64 intermediates before multiplication, addition, and range computation;
u32 `high-low+1` overflows at the initial interval. CDF endpoints and Q state
also cannot fit u16. The inner suffix bound is 29 bits, not 28. The posterior
sum remains at most Q² because matching copies plus literal escape are a
submass of the entire source; normalization multiplies that by Q.
Copy survival multiplication is at most 65536*63 (22 bits). Ages under the
block cap can safely use u32; offsets should likewise use u32, including
advanced positions and temporary history lengths. Python integers currently
avoid overflow, but these bounds matter to any fixed-width implementation.

## Causal updates and row invariants

Take all literal/context keys from the prefix before appending b. Advance only
copy positions j satisfying 0<=j<len(history) and history[j]==b. After append,
j+1 is valid even when j was the former last offset. New continuation index
entries store the former history length, and become queryable only after b is
appended. A sparse implementation must not expose an index with j==current
history length during prediction. Merge duplicate starts and surviving offsets
before ranking/pruning; move discarded mass to escape and preserve exact Q.

Before observation each row total is <=4095. One increment reaches at most
4096; applying `(count+1)//2` gives a new total
`(4096 + number_of_odd_counts)/2 <=2176`, since there are at most 256 observed
symbols. Stored counts stay positive, sorted observed symbols remain valid,
and totals/prefix structures must be rebuilt or updated consistently after
rescaling. A Fenwick implementation cannot rescale only its aggregate nodes:
rescale actual leaf counts, then rebuild/update all affected prefix nodes.
The new byte inserted into a previously absent row must be present before
updating its total and cumulative representation.

## Required oracle and adversarial cases

Compare direct and independently dense endpoints at every k, including 0/256,
on randomized reachable histories across all frozen source policies. Assert
strict increments, exact Q totals, e>=1, active/index validity, and exact row
prefix totals after every update. Test empty history, all 256 byte values,
repeated single bytes, alternating bytes, absent contexts, overlapping copies,
duplicate start offsets, pruning ties, oldest/newest retained indexes, first
appearance of a row byte, and row totals 4095/4096 around rescaling.

For decoder search test every v in 0..Q-1 for representative dense CDFs, with
special emphasis on F(k)-1 and F(k), intervals of width one, highly peaked
sources, e=Q, and minimum positive escape. Compare dense/query complete frame
bytes under SCM4 and independently decode both. Exercise block_size=1 and
65536, empty input, restarts, truncated/extra frames, invalid policies/lengths,
CRC damage, and arithmetic payload modifications with recomputed CRC so raw
hash/budget/framing checks are tested beyond the cheap CRC rejection.

No compression or speed conclusion follows from these proofs. The necessary
next evidence is implementation tests and charged complete SCM4 frames versus
SCM3 and the same-backend literal control.
