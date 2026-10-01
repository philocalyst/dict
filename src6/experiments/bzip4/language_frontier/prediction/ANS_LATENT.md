# ANS and latent fragment realization

This note reviews the exact oracle in `../oracle/operators.py` and tests
whether an ANS coder state can carry its latent boundary uncertainty for free.
The short answer is: an ANS stack can carry a *sampled latent path*, but a
standard scalar ANS state does not carry an exact posterior belief unless the
state is augmented with a finite compiled context. Cached phrase operators
reduce the number of belief transitions, but they do not remove the context
CDF problem.

The reproducible proof/operation screen is `fragment_ans_probe.py`; its raw
output is in `results/fragment_ans_probe.txt` and its three assertions are in
`test_fragment_ans_probe.py`.

## 1. Oracle algebra and the exact context requirement

The oracle source has edge-emitting matrices `M_b` with

\[
  p(b\mid q)=qM_b\mathbf 1,\qquad
  q_b=\frac{qM_b}{qM_b\mathbf 1},\qquad
  M_{xy}=M_xM_y.
\]

The last identity is the useful part: a phrase operator can be cached once,
then one `qM_phrase` gives both its probability and its outgoing belief. It
does not imply that all phrases share a CDF. In the exact two-state oracle,
the histories `aaaaa` and `bbbba` both end in byte `a`, but their next-`a`
probabilities are `187961/266840 = 0.704396` and
`49289/112760 = 0.437114`. At an ANS total of 16384, the corresponding
frequency for `a` is 11541 versus 7162. A single context-free ANS table cannot
be exact for both histories. The distinction is 0.267282 total variation and
0.688376 bits for that next symbol.

This is not an information-theoretic claim that an unbounded integer can
never encode context. It is a statement about the usual ANS interface: its CDF
must be selected before the symbol update. To make selection depend on `q`,
one must either:

1. carry `q` as an external decoder state;
2. augment the ANS state with a finite context ID and charge one CDF/transition
   row per ID; or
3. sample/encode a hidden state or path, paying its joint code (or using
   bits-back with a posterior seed).

An exact non-degenerate HMM generally reaches more distinct rational beliefs
as the prefix grows, so option 2 is an approximation/compiled-state design,
not a free exact scalar state. A finite hidden *state* is not the same as a
finite observed posterior: the decoder sees bytes and must track a belief over
hidden states unless the latent state itself is transmitted.

## 2. Prefix-free phrase ANS and Tunstall trade-off

The oracle accepts `(a, ba, bba, bbb)` as a complete prefix-free macro
codebook. Its exact phrase probabilities are normalized for every boundary
belief, but they change with that belief:

| boundary belief | phrase probabilities | mean bytes/phrase | fixed 2-bit IDs / byte | entropy IDs / byte |
| --- | --- | ---: | ---: | ---: |
| `(1/2,1/2)` | `(1/2, 3/16, 1/10, 17/80)` | 1.8125 | 1.10345 | 0.97094 |
| `(4/5,1/5)` | `(13/20, 69/400, 527/8000, 893/8000)` | 1.5275 | 1.30933 | 0.95117 |

The IDs have 0.15 total variation between these contexts. A
variable-to-fixed Tunstall parser can therefore reduce *context updates* to
about `1/1.8125 = 0.551724` per input byte on the uniform boundary for this
tiny codebook. But an exact phrase CDF can use cached vectors
`r_w=M_w1` and cumulative vectors `R_k=sum_{w<k}r_w`: each CDF entry is just
`q·R_k`, and inverse lookup can use binary search. The selected phrase’s
posterior still needs one `qM_w` H² matvec unless belief/context rows are
precompiled. Fixed 2-bit IDs avoid the CDF work only by accepting their
fixed-rate trade-off and by charging the prefix tree/phrase surfaces.

The probe materializes these `R_k` vectors with exact fractions and checks that
successive CDF differences reproduce every `M_w1` phrase probability for both
boundary beliefs; this is a normalized arithmetic-CDF check, not a compressed
frame or a claim that the vectors are free to store.

Baer’s generalized Tunstall algorithm explicitly builds multiple parsing trees
for sources with memory; the paper’s `s` source states require `s` trees and
the total leaves determine construction/storage. The hidden-boundary case is
harder: a continuum of `q` values is not the `s`-state Markov case. A bounded
codec must quantize/compile beliefs or transmit the latent state. An
overlapping v4 phrase inventory is not automatically a Tunstall codebook: it
needs a complete prefix-free parser, an escape/partial-phrase rule, or a
latent parse code.

Primary source: [Baer, “Efficient Implementation of the Generalized Tunstall Code Generation Algorithm” (2009)](https://arxiv.org/abs/0809.0949).

## 3. Bits-back and state-space interleaving

For one observed byte and a latent destination state, the toy source has

* observed entropy `H(B) = 1.000000` bits;
* posterior seed entropy `H(Z|B) = 0.811278` bits;
* joint code `H(B,Z) = 1.811278` bits;
* mutual information `I(B;Z) = 0.188722` bits.

With an exact posterior, BB-ANS subtracts the posterior-code term
`H(Z|B)` from the joint code and approaches the marginal `H(B)`. It does not
literally “reclaim mutual information”; the recovered term in this accounting
is the posterior entropy. With no seed for the first item, the safe first-item
rate is the joint 1.811278 bits, 0.811278 bits above the marginal. The ANS
stack is useful because it is LIFO: posterior-pop, likelihood-encode, and
prior-encode can be reversed exactly. It is not carrying an *uncertainty
vector*; it carries a sampled latent and recyclable bits.

For a state-space model, Townsend and Murray’s IconoCLaSM/BitSwap-style
interleaving avoids the naive cost of sampling an entire latent path before
encoding. It factors the approximate posterior into conditionals such as
`Q(z_{t-1}|x_{1:t-1},z_t)`, and requires those conditional CDFs/inverse CDFs.
For a finite HMM, ordinary predictive ANS is already tractable using a
forward filter `qM_b`; full forward-backward is needed only for the naive
whole-path posterior route, not for every valid state-space realization.
The tiny probe’s 1008 H=4 products for n=32 are therefore an upper-cost
full-path accounting (512 forward plus 496 backward), not a claim that
IconoCLaSM must pay that cost. The non-negotiable cost is an available
posterior/predictive context or a finite compiled table.

Primary source: [Townsend, Bird & Barber, “Practical Lossless Compression with Latent Variables using Bits Back Coding” (2019)](https://arxiv.org/abs/1901.04866).

Primary state-space extension: [Townsend & Murray, “Lossless compression with state space models using bits back coding” (2021)](https://arxiv.org/abs/2103.10150).

## 4. Diagonal-plus-low-rank factoring

The probe uses a bounded H=4 source

\[
 M_b=\operatorname{diag}(e_b)\left(\alpha I + \beta\,\mathbf{1}\mathbf{1}^T/4\right),
 \quad \alpha=3/4.
\]

Each byte operator is exactly diagonal plus rank one. For cached phrases of
length 1, 2, and 3, the residual after the product of the diagonal factors
has exact ranks 1, 2, and 3. Storing each operator as a diagonal plus `r`
rank-one terms therefore takes `H+2Hr = 12,20,28` scalar coefficients versus
16 for a full H×H matrix. Across the four codebook leaves `(a,ba,bba,bbb)`,
the full cache is 64 coefficients while this particular factorization is 88;
matvec work has the same 64 versus 88 count. Byte-level rank-one structure
does not survive these phrase products cheaply. This is only a negative result
for this structured family, not a rejection of every shared-transition or
other low-rank construction. Approximate truncation would need a separate
KL/rate and integer-quantization screen.

## 5. Decision and bounded follow-up

The viable mechanism is narrow:

* require a genuinely complete prefix-free macro codebook;
* compile a finite boundary-belief table, with one phrase CDF and next-context
  row per compiled belief;
* decode one ANS symbol per macro and append its cached surface bytes;
* charge trie/surface bytes, CDF rows, context transitions, partial/escape
  handling, and restart/seed bytes.

For `C` compiled beliefs and `P` macro leaves, the row portion is roughly
`C*P` frequency entries plus `C*P` next-context entries (before integer CDF,
header, and trie costs), versus `C*257` entries for byte rows. This comparison
does **not** imply a table-size win for arbitrary byte streams: a complete
256-ary prefix tree has at least 256 leaves, and expanding a byte leaf adds
255 leaves. A small `P` therefore describes a restricted alphabet/grammar or
requires a separately charged factor/escape alphabet. The macro design’s
primary possible win is fewer context transitions per output byte, not an
automatic reduction from `257` rows to a tiny `P`.

Every macro surface, trie/prefix header, incomplete final prefix, and escape
payload must be included in output size. A complete parser may terminate only
at a leaf; if the untouched stream ends inside a macro, the codec must encode
that final prefix through an explicit escape/flush rule rather than use an
encoder-only end oracle.

This removes per-byte posterior arithmetic only because the belief has been
compiled into explicit finite state, exactly the accounting root’s belief
experiment is measuring. The tiny source’s mean phrase length 1.8125 gives
only a 1.81× reduction in context lookups: about 0.551724 compiled-row
lookups per input byte versus one CDF/next-state lookup in the current
table+copy byte path. If the belief is not precompiled, the exact path instead
pays selected H² matvec work and cumulative H-lane CDF dots. No complete-frame
win is claimed from this probe. The next implementation-worthy test would be a
phrase-row extension of the existing compiled-belief codec, using a fixed
prefix-free codebook selected before untouched data and an explicitly charged
escape/final-prefix path; reject it unless all surfaces, rows, headers, and
escapes amortize against the current table+copy baseline.

The 2026 transducing-language-model work reaches the same structural lesson
from a broader angle: exact transformation marginalization propagates a
frontier/state set and can grow exponentially without pruning or finite
quotients. Its finite-state composition ideas support caching operators, but
do not make a latent posterior free.

Primary source: [Snæbjarnarson et al., “Transducing Language Models” (2026)](https://arxiv.org/abs/2603.05193).
