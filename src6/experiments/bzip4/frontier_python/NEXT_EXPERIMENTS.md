# Experiments worth doing next, and why they are not silently included

The current program fixes the candidate family and measures it before adding
another encoder policy. These are follow-up hypotheses, not unmeasured gains.
They do not waive the exact-byte, complete-frame, every-corpus acceptance gate.

## Wire-preserving decoder fusion before another encoding variant

The reference deliberately materializes events, ranks, BWT symbols, and
restored roots as separate arrays. A native design need not. A bounded stream
can fuse Huffman events, zero-run reconstruction, and MTF into the BWT last
column. Build the inverse permutation once, then traverse it in forward text
order and copy each grammar expansion directly into its final output slot.
This removes the event, rank, and restored-root arrays without changing one
stored byte.

For the forward walk, build `next_row[first_occurrence(symbol) + occurrence] =
last_column_row`; start at the stored primary, advance through `next_row`, then
emit that row's last-column symbol. Check the root count and decoded byte
measure independently. Validate against an independent rotation oracle,
periodic strings, arbitrary grammar expansions, hostile frames, and every
saved corpus block before any timing claim.

This also offers a useful implementation boundary: a bounded source of root
symbols plus one measured expansion sink. Plain entropy-coded roots and
inverse-BWT roots can share that sink without sharing their unrelated fast
paths. Do not introduce a universal traversal abstraction merely to disguise
two loops. This fusion is a proposed native architecture, not implemented or
included in the frozen timing numbers.

### Replace prefix movement with rank selection, without changing the wire

The final operation audit sharpens the bottleneck. On 8 MiB of GCIDE the
reference restores about 1.25 million roots, but median MTF ranks are 827–831.
Even an ideal u16 flat list would shift 4.48–4.71 billion bytes of prefixes.
This is a logical copy-volume count, not a measured bandwidth requirement or
native timing prediction. It nevertheless rules out assuming that fewer roots
automatically means little serial work.

An exact-wire alternative is a bounded order-statistics MTF. Reserve `N`
initially empty front positions followed by the `K` initial symbols. A Fenwick
tree contains a one at each live position. For each rank, select its `(rank+1)`th
live position, read the symbol, clear that position, and set the next reserved
front position. Every update preserves the same MTF sequence as the flat list.
The decoder already has checked `N=root_count` and `K=alphabet_count`; no new
model or selector is stored. Its cost becomes logarithmic selection and two
updates rather than rank-sized copying, with explicitly charged `O(N+K)`
scratch. A zero rank can reuse the current front symbol without an update.

This is a data-structure hypothesis, not a claimed new compression algorithm.
Compare it with flat u16 prefix shifts and a bounded two-level chunked list,
including allocation, initialization, cache misses, and short-block latency.
Use the existing saved frames to make byte equality automatic. A tree is not
automatically faster than a small contiguous shift, and its extra scratch may
erase the advantage. Do not add it to production without native measurements.

## 1. Preserve the consistent grammar parse all the way into BWT

The current symbol prototype learns a consistent pair vocabulary and then
retokenizes through a longest-match trie. That latter step is deterministic
and lossless but is not the same parse. The most direct next ablation is to
retain the builder's post-prune root streams, remap surviving IDs, and feed
them directly to the same integer BWT and entropy coder.

This changes only encoder choice, not the decoder, wire fields, or safety
rules. Measure root count, distinct roots per block, BWT zero-run distribution,
complete bytes, and encode time. A smaller root count alone is insufficient:
it may make contexts less consistent. Run all three corpora at both boundaries
with one fixed policy. Do not choose parses by corpus name.

## 2. Make alphabet order a consequence of expansion semantics

Rule IDs currently follow construction/topological order. Their numeric order
therefore carries encoder history rather than linguistic adjacency. Test a
root-only ordering derived from lexicographic expansion bytes while preserving
topological definition IDs separately. Reconstruct the permutation from the
stored grammar, or charge it if serialized. Compare sorting/model-preparation
cost and first-block latency as well as storage.

This can test whether a more meaningful root order improves BWT contexts and
initial MTF ranks. It is not guaranteed: recency ranking may erase the benefit,
and sorting expanded strings can increase startup. One explicit mapping type
must keep definition IDs, root IDs, and MTF ranks from becoming interchangeable.

## 3. Learn an encoder, not an inference engine in the reader

The ML connection most compatible with a small portable decoder is expensive
encoder-only search. Learn or optimize a grammar for the actual charged
objective: DAG bytes + event-model bytes + directory + coded payload, with a
penalty for expansion-table footprint and serial decode operations. Compile
the result into the same bounded immutable DAG and ordinary entropy table.

Try a minimum-description-length deletion/substitution pass before a neural
proposal system. A trained proposal model must be evaluated on genuinely new
corpora; if any model state is required at decode, include it in bytes and
startup. No external tokenizer, embeddings, or unstored universal vocabulary
may be free. The existing results do not establish an ML advantage.

## 4. Compress the stored program, not just its output stream

The first full symbol frame charges roughly 37 KiB of grammar and 8 KiB of
dense event lengths. Those are small on an 8 MiB input but materially affect
small archives. Inspect the grammar's own known structure before adding a
generic outer compressor: topological references, common binary arities,
reference deltas, and repeated canonical-code lengths have constrained domains.

Test one bounded model writer/reader that packs those domains with an explicit
model-format version. It must reconstruct the identical DAG and code lengths,
not silently learn a different model. Charge its restart/header/state and
preparation time. Compare against the uncompressed model on all frame sizes;
do not amortize the model across independently stored files unless the shared
model is an explicit archive object with a separately charged lifetime.

The final small-frame diagnosis gives concrete targets. Keeping all other
stored bytes fixed, the complete model plus any new framing must fit below
13,043 B (FreeDict), 16,919 B (GCIDE), and 29,279 B (OMW) to beat bzip3 on the
untouched 1 MiB / 64 KiB cells. Current models are 17,599 / 33,289 / 29,945 B.
As a diagnostic only, standard bz2 on the exact model blobs produces complete
streams of 10,438 / 20,647 / 19,385 B. Thus ordinary outer model compression
would not even close the GCIDE gap before new framing/startup costs. These
streams are saved under `lead_review/evidence/post-final-v1/`; they are not
candidate frames, not a portable decoder proposal, and not included as wins.
The hard case needs more efficient model representation or a better
model-versus-payload tradeoff, not a claim that the model is almost free.

## 5. Decode blocks without preparing irrelevant expansions

The grammar's bounded pre-expansion table is simple and fast after startup,
but a single random block pays for every rule. Compare eager expansion with
bounded memoized expansion of roots touched by the selected block. Charge the
per-rule validity state, memo storage, and any additional root-usage metadata.
Avoid a second traversal framework or hidden recursive depth: topological DAG
order and explicit capacity checks should define the state machine.

Run both first-query and retained-query measurements. Reject a smaller startup
number that merely shifts more work into the first selected-block decoder or
breaks pointer stability in a caller-owned output arena.

## 6. Schema-derived contexts as a separate semantic-format experiment

`TYPED_ENTROPY_PROPOSAL.md` describes a different lane: a typed packet decoder
already knows whether the next value is a tag, reference, integer, or language
string. That state can select an entropy context without storing a selector
for each value. Test it within the canonical packet format, preserving exact
packet re-encoding, admission limits, forward references, and final-address
construction. It must not be reported as a win over bzip3 on arbitrary source
bytes unless byte fidelity is separately demonstrated and fully accounted.

## Deliberate stopping rules

- Do not add a per-corpus switch to rescue a failed universal claim.
- Do not layer LZ, grammar, multiple BWTs, and learned prediction merely
  because each wins somewhere. Require an ablation identifying the mechanism.
- Do not port a Python branch merely to manufacture a native speed claim.
  First choose the storage frontier, then specify the smallest equivalent
  scalar decoder and independently measure it.
- If the dominant gap is entropy-model quality rather than event count,
  preserve that finding. A giant adaptive model would contradict the reader's
  startup, portability, and simplicity objectives even if it saves bytes.
