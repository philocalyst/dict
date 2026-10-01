# Query the cumulative source directly

Proposed after SCM3's backoff screen, before implementation. This is a new
quantization law, not an accelerated implementation of identical SCM3 bytes.
It keeps the same causal copy initialization, posterior projection, continuation,
pruning and restarts. Its purpose is to remove alphabet-wide sorting from the
dependency structure of each byte decision.

Let C_i(k) count historical bytes below k in the applicable suffix row,
T_i its total, Q=65536, and alpha=16. Endpoints k range from0 through256.

```
L_0(k) = k + floor((Q-256)*(C_0(k)+k)/(T_0+256))
L_i(k) = k + floor((Q-256)*(Q*C_i(k)+alpha*L_lower(k))
                  /(Q*(T_i+alpha)))
```

Missing suffix rows leave the lower-order cumulative distribution unchanged.
Orders1,2,4 recursively back off to the previous applicable row. Each function
is nondecreasing, has endpoints0/Q, and each byte interval is at least one.

With escape mass e and copy mass W(k) predicting bytes below k:

```
F(k) = k + floor((Q-256)*(e*L(k)+Q*W(k))/Q^2)
```

Again endpoints are0/Q and all256 intervals are positive. The encoder queries
only F(b) and F(b+1); the decoder searches using eight cumulative queries.
Posterior literal likelihood is L(b+1)-L(b). The projected integer posterior
remains deterministic state, not an exact Bayesian posterior of F.

Sparse suffix rows retain sorted observed byte values and cumulative counts.
The order-zero row can use a dense256-entry Fenwick tree. Copy positions are
grouped by next byte before cumulative queries. Context rows and indexes still
grow linearly in the capped block; bounded posterior is not bounded total state.

Verification must compare this query law with an independently materialized
257-entry reference at randomized reachable histories, check endpoints and
strict increments, encode identical frame bytes through both implementations,
and fresh-decode arbitrary bytes. Evaluate one frozen SCM3 policy plus literal
control, with all selectors/framing/checksums charged under distinct SCM4 magic.
Compare complete frames to SCM3; altered quantization may improve or worsen
compression, so no byte-identity or free speed claim is made across versions.
