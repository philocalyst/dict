# Ranked exact-byte construction hypotheses

All proposals reconstruct the original byte string exactly. Their decoder
receives every table and operand. Selection is by complete archive size after
all model rows, symbol supports, recurrence state, and frame costs are included.

## 1. Typed exact allomorph transducer (next distinct hypothesis)

Build bounded templates from exact repeated substrings in the distinct-type
inventory. A template emits a typed source span plus literal prefix/suffix
edits; a second edit can express an infix replacement. Occurrence choices emit
the template ID and typed operands directly. Preserve exact source bytes and
fall back to an identity spelling for invalid, rare, or unsupported forms.
Templates may support unseen combinations only when their byte construction
is unambiguous; no occupied stem/tail-pair list is delivered.

**Cost and test.** Charge each template definition, source/template mapping,
typed operand row, operand code, exact residual bytes, and all extra
occurrence events. Credit only the removed identity spelling and changes in
real native occurrence costs. Use support-weighted conditional model cost
`H(operand | class)` plus the exact finite serialized tables as a proposal
score, then select by native complete frame. Reject if the best exact
allomorph family cannot save 1% of total archive bytes after table and operand
costs, or if scalar-boundary proposals lose their exact-byte fallback rate.
This is a distinct test from direct stem × tail pairing; that earlier probe
lost its charged inventory screen.

## 2. GEN into the bounded past (hapax scope screened out)

On a first or expired occurrence, `GEN` constructs the exact token either
literally or as `prefix + recent_token[lo:hi] + suffix`. It puts the result in
the ordinary causal past ring with a deterministic successor-row class. An
exact recurrence still in range uses ordinary `PAST`; a recurrence after a
restart or past expiry pays another generation. This could remove permanent
word `NAME` and bucket identity for forms served only by local bursts.

**Cost and test.** For a once-used standalone word, retain its current body,
`ARITY`, and class source; credit at most its measured first-use `NAME` plus
`DEF` price. Debit each `GEN` event/row tag, source distance/span operands,
residual literals, cache controls, any model/table growth, and regeneration
after the 1,023-token reach or block restart. The actual fitted native oracle
finds only 296, 437, and 305 bits of gross credit on the 1 MiB FreeDict, GCIDE,
and OMW development prefixes. This is too little to justify a GEN command plus
operands and new model events, so the hapax-only path was rejected before
native integration. The byte-varint GTG1 full-frame loss is separate and does
not falsify context-priced GEN for recurrent forms. Any broader claim needs a
separate exact oracle for recurrent identities.

## 3. First-use constant-fragment realization with explicit naming cost

Keep reusable exact prefix/suffix/infix fragments, but let the compiler decide
per word whether to retain a named identity or realize its spelling from
fragments only at first use. The parse objective charges native successor
rows, child-count `ARITY`, the terminal `NAME` row, and one-time definition
activation, then pays later references from their actual row. This directly
tests when naming a generated lexical form is worth its persistent model
space; it is more principled than a global cutoff over type frequency.

**Cost and test.** For each candidate spelling, sum exact fitted native event
costs for body children, `ARITY(child_count)`, terminal `NAME`, activation,
bucket identity and future references. Compare with inline first-use body
costs and recent-past recurrence, including row changes. Reject if complete
native frames fail to beat the current WGP6 best on at least one old-development
corpus without a larger aggregate regression, or if estimated child/activation
costs disagree with the fitted event counts enough to change the selected
parse. The current name-terminal probe is incomplete until `ARITY` and
first-use activation are included; grammar_codec owns that experiment, and no
claim is based on its uncorrected score.
