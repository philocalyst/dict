# Joint lexical PPM: fixed development headroom diagnostic

This is one causal, source-only probability-model test, not an archive or a
claimed codec size. It addresses the older `word_order_screen.py`'s separate
word/separator models, expensive first-use order-one spelling, and 16-entry
context rows. The new representation codes a single event sequence containing
both word and separator tokens. A retained row holds **all** successor counts;
whole rows alone are replaced under a deterministic state cap.

## Exact reversible event representation

The primary byte policy greedily groups consecutive ASCII letters, digits and
bytes at least 128 into a word token; all other bytes form maximal separator
tokens. Token concatenation reproduces arbitrary input bytes, including zero
and malformed UTF-8. The fixed ablation decodes UTF-8 with `surrogateescape`,
emits each Han, Kana or Hangul scalar as its own token, groups other Unicode
letters/marks/numbers into word runs, and groups other scalars or invalid-byte
surrogates into separator runs. Every token retains its original byte sequence;
the ablation also round trips malformed input. Both modes are tested on the
same six pinned sources, and a prospective archive would pay one mode bit.
No language labels or external lexicon are used.

IDs are assigned on first occurrence. At every event, the model scores the
next ID or a `NEW` escape with PPM-D half-count discount and exclusion over
suffix orders 4, 3, 2, 1, 0. At a retained context, allowed successor `x`
gets `(count(x)-1/2)/N`; escape gets `T/(2N)`, where `N` is the sum of allowed
counts and `T` is the number of allowed successors after exclusions. On escape,
all successors in that context are excluded at lower orders. At order zero,
all previously seen IDs are present; an unknown token leaves via the root
escape and is spelled. Empty contexts cost zero and fall through. This is a
normalized online choice at each context, not a capped top-successor proxy.

First-use spelling codes every raw byte then explicit `END` (alphabet 257)
with a second PPM-D model over byte suffix orders 4..0 and a uniform
order −1 over not-excluded byte/END symbols. Its state updates on *every*
event's decoded spelling, including repeated tokens, and resets byte context
at each event start. The decoder could mirror both online updates without
transmitting learned tables. A repeated event pays its lexical probability
only; a first use pays root/context escapes plus the entire char spelling.
The explicit END pays token lengths and guarantees termination.

## Fixed budget and decisive test

The lexical context store has at most 80,000 non-root rows and 400,000
successor edges; the byte spelling store has at most 40,000 non-root rows and
160,000 edges. LRU replacement discards whole rows, retaining complete
successor distributions in live rows. Both keep uncapped order-zero rows,
whose maximum entries are bounded by the at-most-1 MiB source. The diagnostic
process has a 512 MiB address-space limit. Any limit failure is a failed row,
never an idealized success. Record row/edge peaks and replacement counts.

For each source and mode, report separate ideal bits for lexical word hits,
separator hits, first-use escapes, word spellings, separator spellings, and
framing reserve. The accounting is
`ceil((lexical_bits + spelling_bits + 1 mode bit)/8) + 24 bytes`.
The 24-byte reserve is a hypothetical fixed header/length/checksum allowance;
integer range-coder rounding, a verified decoder and actual frame overhead are
**not** measured. Thus this is a *model-specific optimistic cost*, not a lower
bound on all compressors or a complete-frame result.

The only data are six fixed at-most-1 MiB DEV prefixes in
`/workspace/scratch/books2026-dev/manifest.json`, SHA256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`.
Same-source whole-bzip3 controls come from the independently exact-decoded
`controls/prefix-1048576/controls.json` manifest. Do not read reserved data.
Select the shorter of the two fixed modes only after separately reporting
both, and charge the selector bit. A native wire implementation is justified
only if the selected optimistic cost beats bzip3 by at least 20% in aggregate,
at least 10% on every book/language, and the 512 MiB cap holds in every case.
Otherwise close this branch; no parameter grid or post-result retuning.
