# The next model: predict the surface, compile the work

Research direction, 2026-09-26. **Not a promoted codec or a new size record.**

The existing v4 engine is good at reusing exact text and making token decoding
cheap. A replacement must keep those strengths. A small byte model that ignores
phrase reuse is not a meaningful replacement, even if its inference is elegant.

## One object instead of separate spelling, phrase and prediction machinery

A fragment denotes exact bytes and a transformation of predictive state.
Concatenation composes both. Repeated fragments cache both. A productive lexical
construction shares the transformations of its components; a fixed phrase is
the no-argument case. Ambiguous constructions contribute probability to the
same surface, rather than forcing the archive to identify an arbitrary parse.

The concrete finite-state instance is `M_xy = M_x M_y`. Incoming belief `q`
assigns fragment probability `q M_w 1` and outgoing belief `q M_w / p`.
These are standard weighted-automaton identities. Our experiment is to make
them a compact, fast, self-contained text representation—not to rename the
identities as an invention.

There are three separable questions:

1. **Source quality:** does the language model assign enough probability to
   real multilingual text to improve on the current grammar and cache?
2. **Representation cost:** can that model be delivered for fewer bytes than
   it saves? All strings, transitions, weights and exceptions count.
3. **Execution cost:** can inference be compiled or skipped over fragments
   without excessive memory, preparation or error in future predictions?

An answer to one is not an answer to the others.

## Changes to the actual dependency structure

* The surface coder sums compatible analyses. It does not need to recover a
  particular token boundary or morphological label that the consumer never
  requested. The weighted piece prototype implements this, with a charged
  model and an independently decodable frame.
* A phrase CDF uses cumulative row-sum vectors. Selection costs `O(H log P)`
  rather than testing P matrices. Only the selected fragment needs a state
  update. The independent rational oracle checks this equivalence.
* A fragment whose conditional destination rows agree can replace an H-by-H
  update with a probability vector and a destination vector. The probability
  of that fragment remains exact; approximation affects later predictions.
  The contraction experiment tests when this is useful rather than assuming
  all words may erase context.
* A compiled posterior machine is another execution of the same source idea.
  Its decoder follows delivered integer tables, with no teacher at runtime.
  Its own rollout must be scored: substituting the teacher's hidden state at
  every input prefix would be cheating.

This follows the useful lesson from the user's
[time-of-day article](https://www.benjoffe.com/fast-time-of-day): change which
quantities depend on which others, then verify the identities and benchmark
the resulting execution. Fewer lines or more elaborate terminology are not
the objective.

## What cannot be assumed away

An overlapping phrase vocabulary is not a complete codebook. A full-byte
prefix code has at least 256 leaves, and useful phrase extensions generally
increase that count. Final partial phrases require explicit handling. Exact
latent posteriors need not have finitely many reachable states. Byte-level
low-rank factors need not stay low-rank after composition. A float prototype
does not define portable integer behavior. A latent-label ambiguity gap can
grow without improving any surface probability.

These are tested constraints, not reasons to abandon the direction. The
experiments distinguish a false shortcut from a stronger formulation.

## Reading and evidence

`FORMULATION.md` gives the equations, primary research, and limitations.
`oracle/` contains the root's independent exact tests. `segmentation/` tests
surface marginal coding; `prediction/surface_context/` extends it to contextual
phrase sources; `belief/` tests compiled posterior states; `operators/` tests
predictive resets. These are competing/diagnostic experiments, **not proposed
format modes to accumulate in production**. `evidence/` owns independently
decoded baseline and candidate artifacts. Its new confirmation split remains
reserved until a candidate policy is frozen.

The existing codec remains unchanged. Promotion requires complete-byte wins
and fresh decode/startup measurements; no experiment gets a speed claim from
an operation count alone.
