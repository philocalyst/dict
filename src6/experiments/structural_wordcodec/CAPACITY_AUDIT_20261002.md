# Independent LTCv2 capacity-ceiling audit, 2026-10-02

Scope: read-only review of
`src6/experiments/lexical_validation/CAPACITY-PROPOSAL-20261002.md`
against the owned source freeze `1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84`
and active `src6/experiments/lexical_constructions/` source. All 17 frozen
snapshot hashes were checked; the 16 source files with matching active
basenames have the same hashes. The remaining entry is the frozen binary.
This review did not edit or execute the owner codec or inspect any new
reserved source.

## Arithmetic

Let `C,B <= 2^25`, `K <= 500000`, `R <= 65535`, and `S >= B` as defined in
the proposal. `K < 2^21` gives at most three 7-bit varint events for each
lexeme ID. Every byte length, copy length/start, and causal backward distance
is at most `B < 2^28`, so four events suffice. The typed grammar follows the
canonical v3 packet's scalar/tag/length/mask order. Each byte-string field
trades its length varint plus source bytes for one ID of at most three
events. The other fields emit no more events than their packet bytes, hence
typed roots cost at most `3(C-S)` events. Packet-root IDs cost at most `3R`.

For causal surfaces, each lexeme length costs at most four events, each
literal run has at most five overhead events plus its literal bytes, and each
copy has at most nine events and produces at least six bytes. With `Q`
copies and `L` literal bytes, runs are at most `K+Q` and `L+6Q<=B`, so

`E_causal <= 4K + L + 5(K+Q) + 9Q <= B + 9K + 8Q <= (7/3)B + 9K`.

Earlier-lexeme copies use at most twelve events (opcode, 3-event donor ID,
4-event start, 4-event length) and produce at least twelve bytes. Thus
`E_prior <= B + 9K + 5Q <= (17/12)B + 9K`. Literal-only surfaces cost at
most `B + 4K`. The root/dictionary combined upper bounds are

`E_typed <= 3(C-S) + (7/3)B + 9K <= 3C + 9K <= 105163296`,

`E_packet <= 3R + (7/3)B + 9K <= 82990280`,

and dictionary output-byte work plus events is at most
`B + (7/3)B + 9K <= 116348107`. All are below `2^27 = 134217728`.
The existing 64 MiB frame cap, 32 MiB decoded pool cap, model cap 8192,
u32 header fields and ID indices remain sufficient. These calculations
cover the existing encoding rules; they make no prediction about compressed
frame size or a particular reserved source succeeding.

## Required ceiling edit and independent guard

The current global runner initializes `grammar.Limits.max_work`,
`limits.dictionary.max_work` **and** `limits.packet.max_work` to 64,000,000.
`grammar.Budget.step` applies both the global and packet ceilings to its
aggregate typed collect/emit traversal across all roots. To implement the
proposal without changing its algorithm, the new capacity fork must set
all three fields to 134,217,728, in addition to `max_lexemes=500000` and
`entropy.max_events=134217728`. Raising only global and dictionary work
leaves the old 64,000,000 typed guard in force. The per-root input-byte,
allocation-payload, slice-length and depth limits remain unchanged. The
packet work ceiling is itself a resource ceiling, not a serialized field.

Native structural work cannot be inferred from entropy event count. The
typed traversal charges visited nodes and full byte-string occurrence
lengths, even where the transmitted stream uses a short shared ID. Its
separate `Budget.step` checks must remain. The decoder's per-root and
aggregate prepare guards, dictionary `B+events` guard and absolute entropy
guard must also remain. The proposal is a bounded *admission profile*, not
a promise that every 32 MiB canonical source will fit every other limit.

The proof bounds logical events/output; it is not a peak-RSS proof. A full
candidate can retain large event arrays, causal history and decode stock
at once. Use a documented process address-space/CPU bound, retain resource
failures in the ledger, and keep the unchanged two-DEV byte-for-byte replay
gate before any reserved-source run. With these conditions, the ceiling-only
fork is safe to implement without changing schema, wire or compression
policy. No code or candidate result was produced by this audit.
