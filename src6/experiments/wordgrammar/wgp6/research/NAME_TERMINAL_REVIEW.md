# P6C2 / P6S2 name-terminal review

Scope: static inspection of `../native_nameprice.zig` and
`../prepare_nameprice.cpp`; no compile or runtime checks.

## Concrete cost-model gap: ARITY is absent

The P6C2 layout is internally consistent for the fields it carries: each
token/state cell is `{reference-price, successor-class, name-terminal-price}`
and the reader expects 12 bytes. The new terminal field also appears to use
the right NAME path: it selects `name_row` from the DP's ending row, includes
`name_via` and its successor, and omits the raw bucket-index width because
NAME rows are plain.

However, the candidate definition's **ARITY cost is missing**. The native
encoder emits `ARITY(kids.len)` before every definition body
(`bz4/v3/src/encode.zig:268–273`); different Viterbi parses of the same
spelling can produce different child counts. Its arity-row symbol prices
therefore vary with the chosen parse. P6C2 exports only reference and NAME
prices, and `Parser::conditional` (`prepare_nameprice.cpp:149–192`) initializes
the final value with NAME cost but never adds the cost of the path's resulting
arity. The transition after ARITY is common, but its entropy cost is not.

This biases the native-priced parser toward fragmentations whose omitted
arity symbols are expensive. Export an ARITY price table for the possible
child counts and make the end condition pay the price indexed by the number
of selected children, in addition to the NAME terminal. Keep the native
complete-frame gate; this fixes the proposal price rather than replacing
that exact selection.

## Seed activation is also not amortized for mapped seeds

When a seed has a prior retained ID, the conditional parser charges its
ordinary reference event from `model.price` (`prepare_nameprice.cpp:171–175`)
and uses the new scalar `seeds[i].cost` only when the prior map is absent
(`:176–180`). But the new candidate still has to transmit the seed's own
definition. The iteration computes a body/usage-based `seeds[i].cost`
(`:317–324`), yet the mapped-seed Viterbi branch bypasses that cost; P6C2
contains no first-use definition charge. A prior token's reference price is
not the price of defining the new candidate in this parse. This can make a
mapped seed look free to activate during parsing even though the final
archive later pays its delta body and NAME.

For a consistent proposal objective, charge each retained seed's definition
once (its native-priced child body, ARITY, and NAME), amortized over the
estimated selected uses, while still charging each occurrence's stateful
reference price. If exact integration is deferred, label mapped-seed
activation as an omitted surrogate term and rely on the complete-frame
selection only as the final archive gate.

## Mapping/layout observations

The P6C2 header and 12-byte cell stride agree between writer and reader; its
cell count includes 256 byte symbols plus source entries and one extra
body-start state. The P6S2 header carries seed count and type count followed
by those two token maps, matching `PriceModel.load`. Seed IDs map only when
retained; the word map maps only atom types whose surface has a distinct
whole-word entry. That matches the stated restriction and avoids aliasing a
byte or a seed as a separate whole-word identity. Seed and word targets are
validated against the P6C2 token count. I found no separate layout or ID
ordering mismatch by inspection.
