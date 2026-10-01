# Parameterized lexical-context lane — primary-source synthesis

Status: implemented as a bounded reference experiment and rejected by the
first complete 256 KiB development screen.  The code remains useful as a
round-trip/charging control.  It does not claim a language-compression win.

## Mechanism carried over from the literature

Naganuma et al., *Grammar compression with probabilistic context-free grammar*
(DCC 2020, [arXiv:2003.08097](https://arxiv.org/abs/2003.08097)), encode both a
grammar and a derivation sequence.  Their grammar may generate alternatives,
so a small reusable generator can be cheaper than an SLP that must generate a
single string.  Their theorem and measurements use powers/Fibonacci strings
with synthetic noise; those examples are evidence for the representation, not
evidence of a real-language win.  This lane borrows only the accounting idea:
the reusable program and the per-record derivation are both charged.

Johnson, Griffiths, and Goldwater, *Adaptor Grammars: A Framework for
Specifying Compositional Nonparametric Bayesian Models* (NeurIPS 2006,
[paper](https://proceedings.neurips.cc/paper/2006/file/62f91ce9b820a491ee78c108636db089-Paper.pdf)),
separate a generator from a cache of previously generated subtrees.  Their
Pitman–Yor adaptor makes later expansions dependent on earlier ones.  The
production v4 past buckets already supply a static exact-token cache, so this
lane does not add an adaptive cache or an MCMC sampler.  The missing
expressivity tested here is a *parameterized* cached context: the same literal
surroundings can be selected while the slot binding changes.

Lohrey, Maneth, and Schmidt-Schauß, *Parameter Reduction in Grammar-Compressed
Trees* (FOSSACS 2009, [DOI](https://doi.org/10.1007/978-3-642-00596-1_16),
[author PDF](https://www.eti.uni-siegen.de/ti/veroeffentlichungen/09-fossacs.pdf)),
show that a linear straight-line context-free tree grammar can be reduced to a
linear **monadic** one (one context parameter) in polynomial time.  They also
show why non-linear/nondeterministic parameter reduction can require an
exponential blow-up.  That boundary motivates this prototype's finite ranked
programs: at most six slot occurrences, no recursive calls, and repeated slot
IDs only when every training derivation binds the same bytes.  We do not claim
their tree algorithms apply unchanged to byte records.

Lohrey, Maneth, and Mennicke, *Tree structure compression with RePair*
([arXiv:1007.5406](https://arxiv.org/abs/1007.5406)), extend Re-Pair to ranked
trees and retain direct tree operations over a straight-line context-free tree
grammar.  That is the closest grammar-induction precedent.  Ordinary SLP/
Re-Pair reuses an exact substring/subtree; the candidate here is an
anti-unified context whose literals stay fixed while one or more leaves vary,
and its derivation carries the exact leaf bytes.  Thus it is not a renamed
exact-substring rule or a byte-class stream.

Adaptor grammars and Morfessor-style morphology induction also motivate a
generator/cache split, but their inferred probabilities, external linguistic
categories, and sampling procedures are not decoder state here.  The scanner
is a byte policy, not a Unicode tokenizer: LF only delimits records; a word
slot is a maximal run of ASCII alphanumeric bytes or bytes with the high bit
set.  Invalid UTF-8, combining marks, casing, mixed scripts, controls, NUL,
and whitespace remain exact bytes.  A raw event always exists.

## Precise bounded composition

For each training record `r`, the deterministic scanner obtains maximal byte
word spans.  If there are at most six spans and every intervening literal
island is nonempty, it proposes

```
T = L0 · X[v0] · L1 · X[v1] · ... · X[vk] · Lk
```

where `Li` are complete byte slices and `vi` are slot IDs.  Exact skeletons
are grouped.  A deterministic, bucketed pair screen also anti-unifies two
near records using equal byte islands from `difflib.SequenceMatcher`; unequal
islands become bounded slots.  A group is retained only with at least two
uses and two distinct binding tuples.  Slot IDs are merged only if all
derivations agree on the same bytes at those positions; this is the repeated
variable identity test.  Candidates are ranked by a lower-bound saving and a
fixed tie break, then capped at 96 templates.  A global binding dictionary is
kept only when repeated binding references pay their serialized bytes, capped
at 512 entries.

The decoder sees only the serialized ranked programs, the binding dictionary,
and block event streams.  A template event carries its template ID and one
binding selector per *distinct* variable; selectors are either a model binding
ID or a length-prefixed inline byte string.  Expansion is a single bounded
loop over literals/slots.  It has no grammar recursion, no inferred schema,
and no language-specific fixture rule.

## Complete price and disproof rule

The wire frame charges a 52-byte header, the complete model (`BMD1` header,
literal bytes, slot IDs, and binding bytes), one 24-byte restart directory row
per block, each event stream, zlib payload bytes (or an explicitly marked raw
event fallback), per-block CRCs, and metadata CRC.  zlib is a diagnostic
backend, not a native decoder claim.  A model is trained on `[0, 1 MiB)` and
frozen before the held-out `[1 MiB, 1.25 MiB)` screen.  Blocks target 64 KiB.
The retained v4 executable is run serially on the exact same bytes as an
end-to-end control and independently decoded.

The cheap screen rejects this lane if no candidate has two distinct bindings
with positive charged saving, or if complete binding frames fail to beat the
input-fit v4 control on all three dictionaries.  Synthetic repeated-context
fixtures must still win over their raw diagnostic control, while random
no-repeat and arbitrary-byte fixtures must not invent a model.  No timing is
used for promotion.

## Decoder bounds

Frames are capped at 512 MiB, models at 8 MiB, blocks at 64 KiB, records at 1
MiB, templates at 1,024, bindings at 4,096, and event streams at 16× a block
plus a constant.  Directory offsets are contiguous and checked; model/table
IDs, ULEBs, block lengths, CRCs, zlib output, event counts, and expansion
lengths are validated before allocation/copy.  An unrecognized event, mode,
padding/trailing byte, or truncated stream is rejected.
