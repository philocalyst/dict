# Productive spelling and productive occurrence sources

The useful distinction is between a finite dictionary of observed surfaces
and a source that constructs a surface. Both preserve arbitrary literal
bytes. A spelling DAG replaces a word's stored body by references to constant
parts; a productive occurrence source replaces its delivered word identity
by a choice of parts. These have different costs and should be measured
separately.

## Constant spelling DAG

The current native probe changes only spelling proposals and their order of
selection. It counts reusable substrings in the distinct type inventory,
then offers the useful strings directly as n-ary definitions. A dynamic
program chooses a complete byte-exact word spelling, including literals. An
iterative description-length surrogate charges each selected fragment's use
cost and its one-time activation cost. Its definition can itself use shorter
fragments. Whole-word and phrase identities remain available to the old
native compiler.

This tests whether a greedy binary merge history imposes identities that
would not survive a direct choice of useful constant substrings. It also
tests whether productive prefix constants can free hapaxes from CUT's donor
and receiver naming requirement. Candidate cost estimates choose the parse;
they are not compression evidence. Complete native coding decides whether
the parse helps after first-use definitions, naming, class rows, and past
copies are included.

The planned order ablations are:

* prefix candidates, suffix candidates, both word edges, all positions;
* an initial activation-cost parse versus alternating parse/refit rounds;
* pure concatenation versus recent-word CUT sharing;
* once-used word bodies inlined versus retained as named whole words;
* fixed-class screening followed by the old full automatic class search.

## Paired occurrence source

Let `W` be the observed word and select one exact pair `(S,T)` per word,
where `S` is a stem and `T` supplies an exact prefix and suffix. Distinct
selected pairs reconstruct distinct word bytes. A stem deterministically
selects a tail class `C(S)`. The occurrence source pays

`H(S) + H(T | C(S)) = H(W) + I(S; T | C(S))`.

The conditional mutual information is the precise information penalty of
sharing a tail row across stems. Delivering a finite occupied-pair list can
avoid this penalty, but pays word-set metadata. Delivering no occupied-pair
list permits supported unseen combinations and pays the extra occurrence
bits instead. The full comparison must also charge stem and tail spellings,
the stem-to-class map, support sets, probability rows, and restart framing.
The Luna probe reports these ledgers rather than treating a smaller stem
table as a compression win.

Context and past copies further complicate this identity-source change.
Splitting a word can lose cheap whole-word recurrence and distort the source
history. A later native experiment could make a generated surface a bounded
past-cache entry without first delivering a permanent word identity, but
would need to charge its operands, runtime storage, and cache-control
symbols. That is a distinct format experiment; it is not implemented or
credited to the current spelling probe.

All candidates preserve bytes without normalization, an external tokenizer,
an external vocabulary, or language-specific spelling rules. Prefix, suffix,
and internal repeated strings can serve different scripts without assuming
English morphology. A Unicode-scalar proposal restriction is a useful future
ablation, but it cannot replace literal-byte fallback.

## Definition terminal states

The baseline spelling Viterbi pass ends with zero terminal cost. A native
definition then emits its NAME event, whose conditional row depends on the
last spelling-reference successor state. A shorter spelling can therefore
leave a more expensive name row. The isolated `prepare_nameprice` /
`native_nameprice` variant exports the current fitted NAME entropy cost for
every target definition and reachable body state and initializes Viterbi's
terminal costs with it. It includes a naming silent transition when needed,
and excludes raw bucket index width because naming rows are plain. The seed
and retained whole-word identity map is an encoder artifact, never delivered
archive metadata. Initial proposals and complete native frame selection are
unchanged. Unknown or dissolved prior definitions have zero terminal price;
the estimate does not claim to simulate future planner changes or the full
definition past cache. It also leaves ARITY(child-count) out of this
proposal score, and known seed-reference prices do not amortize their
one-time definition activation. Luna's static review records these gaps in
`research/NAME_TERMINAL_REVIEW.md`; complete-frame selection still pays
both costs. This isolates the terminal-row hypothesis without presenting
the score as an exact native event simulation. This variant is separate from the fixed maximal
pipeline until a charged native development screen establishes a gain.
