# Exact-byte causal prose codec: bounded PPM plus match

## Why this is a separate bet

The Unicode word-order diagnostic pays every newly spelled type and every
separator, but its best ideal costs on three 1 MiB dictionary DEV sources
are 118–167% above the strongest M frames. It has no complete wire. This
experiment instead predicts the **next raw byte**, including lexical spelling,
spacing, punctuation, Unicode encodings, and malformed bytes in one stream.
It can learn recurring long contexts without sending a vocabulary. The
structural sibling owns phrase skeletons; SolFit owns static class models.

## Fixed source-only diagnostic

The source-only `byte_ppm_screen.py` computes causal ideal real-valued log
loss on a locked input. Order-0 uses KT byte counts. Orders 1, 2, 4, 8, 16,
and 32 use Witten–Bell recursive interpolation:

`p_o(x) = (count_o(x) + distinct_o * p_lower(x)) / (total_o + distinct_o)`.

A missing row simply returns its lower-order distribution. Each order has
at most 32,768 LRU rows; orders 1 and 2 admit all 256 successors, other
orders at most 16. Counts and evictions are reconstructed from preceding
decoded bytes. A separate exact last-successor expert for 8- and 16-byte
contexts uses a KT hit/miss probability, backing off to order-16 PPM. The
Bayesian equal-prior mixture includes PPM orders 4/8/16/32 and both match
experts. Its ideal log loss is within log2(6) bits of its best expert on
the entire stream; real integer coding still needs its own accounting.

The first representative matrix uses frozen UTF-8 book bodies from the
development-only books2026 manifest, at each book's fixed 1 MiB UTF-8-safe
prefix (entire book if shorter), followed by the complete books if there is
a material ideal margin. Every input and control must have the same exact
source hash. No raw Project Gutenberg headers, Latin-1, or Shift-JIS sources
are substituted for the projected book bodies. Dictionary DEV is a separate
generalization control. The sealed final sources are excluded from modeling
choices. Record every attempted configuration and negative result.

## Complete wire gate if the ideal margin is substantial

The wire stores magic/version, fixed expert mode, raw byte count, hard caps,
CRC, integer arithmetic payload length, and termination. All probability
tables are learned online and reset as the mode specifies; no preloaded
weights, external dictionary, or source fingerprint is shared. A deterministic
integer CDF must normalize at least one count per byte within a bounded
total. Order-0 can use Fenwick prefix counts. Recursive PPM is a weighted
combination of that global CDF and at most 6 × 16 sparse byte corrections;
match adds one spike. Thus the decoder can form a 256-symbol CDF in bounded
time, initially even by direct enumeration, then compress it into sparse
prefix calculations if profiling supports the extra complexity.

The range coder and decoder must agree bit for bit with integer operations
only, including mixture updates and rescaling. Decode work is bounded by
declared raw length and context caps; reject malformed lengths, exhausted
payload, bad CRC, and unconsumed suffix. Full decode must equal the source
hash on every candidate. Only **complete frame bytes** count against the
same-source whole-file bzip3 control; ideal bits are merely a falsifier.
This quality mode may retain state across the whole file and does not claim
independent page reads until a paid reset/index profile is implemented.
