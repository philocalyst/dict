# CCW1: packed bit-history state and causal joint word spelling

This is a new, fixed development round. CCM1 and its negative evidence stay
unchanged. CMIX/PAQ8 `TextModel`/`ContextMap2` motivates joining previous
token and current spelling prefix *inside one context state*. CCW1 uses its
own exact byte tags and fully integer predictor; it does not import their
language-specific dictionaries, floating mixer or weights.

## Source and stop rule

The six UTF-8 book-body DEV prefixes (up to 1 MiB, shorter books complete)
and exact same-source bzip3 controls retain the CCM1 manifest/control hashes
`ee6cf531…` and `640c4ed2…`. No reserved-validation or sealed final text is
available to design. Source-only Q15 log losses are not archive sizes. A new
range-coded wire requires multiple books to show material headroom toward a
complete frame at most **65% of bzip3**, including rounding/header/CRC.
CCM1's best ideal costs would need another 64,036/99,360/99,432/70,803/
13,540/39,595 bytes saved respectively merely to reach that threshold.

## Packed exact state

One outer row is selected by a four-way, tag-checked key for a completed-byte
history or exact capped word tuple. A row contains 16 slots indexed by an
**exact partial-byte prefix** in `[1,255]`, each with two 8-bit bit counts
and a deterministic 16-bit access stamp. A missing prefix backs off; if all
16 slots are occupied, the least-recently touched prefix is evicted. At stamp
wrap, every stamp in that row resets to zero. This does *not* represent all
255 prefix-tree states at once; state changes and evictions are paid as
decoder RAM/work and can reduce prediction quality. No hash-only equality
controls an exact copy or a context match. Prefix-state count rescaling at
total 250 and Witten–Bell-like backoff mass 16 are fixed.

All preceding-byte orders 1–8 get their own packed tagged rows. Four joint
tables condition the next bit on the exact previous one or two capped
16-byte token byte strings *and* the current token's exact already-decoded
byte prefix, with script class and partial-bit prefix. The token streams
without and with CJK/Kana Unicode scalar boundaries are maintained in
parallel from decoded bytes. ASCII whitespace/punctuation ends a token;
length16 cuts longer runs. Invalid UTF-8 produces an explicit class and
literal source bytes. Unicode ranges are fixed in source, not an external
property table. Current token spelling is never visible ahead of the bit
being predicted.

The causal match donor and Q15 integer stretch/squash table are unchanged in
concept from CCM1. The context-conditioned logit mixer uses the same fixed
1024 script/boundary/bit-position/match-tier selection and signed integer
gradient, with no APM (it worsened all six CCM1 inputs). All code paths
update state only after the decoded bit, including bytes reconstructed by a
future decoder. The source limit is 16 MiB and total fixed state plus source
must stay below 512 MiB.

## Four fixed ablations

One scorer records each model and each source quarter under these policies:

1. Packed byte orders 1–8, no joint token expert.
2. Add previous one exact token × current token prefix.
3. Add previous two exact tokens × current token prefix.
4. Use the previous-two model with CJK/Kana scalar segmentation.

The source runner records exact source/binary/table/manifest/control hashes,
source bytes, bzip3 complete-frame bytes, each model's Q15 ideal bits,
outer-row and inner-prefix eviction counts, memory bound and bit work.
There is no parameter sweep after seeing the six-book scores. A wire is
implemented only if the absolute stop rule is met; otherwise preserve the
negative result. Decode, selected original 64 KiB pages, malformed-input
bounds and complete frame accounting are future wire gates, not inferred
from source-only scores.
