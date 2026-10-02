# WGP6 productive spelling experiments

This research lane improves the spelling graph supplied to the unchanged
native v4 lexical automaton. It preserves exact bytes and whole-word reuse.
The frozen independent WGP5 codec, its frame, and its policies are separate.

Old prefix sharing uses a previously named word and a CUT operand. Both the
donor and receiver then need retained identities. A direct constant stem has
no donor dependency: a one-off word can inline `stem + tail`, and a frequent
word can keep its identity. The new learner proposes maximal repeated
substrings from the distinct type inventory, defines them using shorter
fragments, and chooses a complete spelling by dynamic programming. Prefixes,
suffixes, and internal fragments compete with exact literal bytes.

The later spelling passes use conditional reference-price estimates from
the fitted native model, including successor states and bucket widths.
These probabilities are proposal scores, not bit-exact archive predictions;
every complete native frame is encoded before selecting a winner. Whole-word
and phrase identities, native class rows, first-use spelling definitions,
past-token copies, and all archive framing are paid by the native compiler.

## Build and concrete pipeline

```
make ZIG=/home/agent/.local/bin/zig
python3 encode.py encode development-input.txt candidate.frame --block 65536
python3 encode.py decode candidate.frame candidate.decoded
python3 encode.py inspect candidate.frame ledger.json
python3 encode.py extract candidate.frame block.raw --index 0
make test ZIG=/home/agent/.local/bin/zig
```

The fixed research policy uses maximal fragments of 2–128 bytes, support
three, capacity 200,000, two initial scalar re-estimation rounds, no recent
CUT donors, and once-used-word inlining. It then runs four native-model
parse/refit rounds. Automatic native class planning applies throughout. The
encoder chooses the smallest complete frame across these five graphs and
the original native compressor, breaking ties in trial order. The original
candidate supplies a complete-frame size fallback. All candidates and fits
are paid in the encoder metrics; the selected graph requires no additional
decoder selector because the complete chosen graph is already in the frame.

Input and effective source/binary/backend hashes, every trial size, the
selected candidate, and the full archive ledger are reported as JSON. The
sum of native stage `codec_ns` includes learning, every fitted model, price
matrix reconstruction, and auxiliary price-file reads. A separate driver
wall clock includes process startup and file I/O. These research clocks are
not interchangeable with a monolithic codec timer. No comparative timing
claim is made from concurrent development runs.

`native` also supplies lower-level operations:

```
./native original input.txt old.frame 65536
./native compile candidate.parse candidate.frame 0 next.prices
./native decode candidate.frame candidate.decoded
./native extract candidate.frame block.raw 0
```

`P6P1` parses, `P6S1` seed maps, and `P6C1` price matrices are private encoder
interchange, not supported archives. The parse adapter checks acyclic
backward references and array structure before fitting. `prepare_maximal`
alone exposes explicit experimental controls; `encode.py` freezes its policy.

## Scope and access

The output is the existing v4 frame, readable by the old decoder. Its raw
word-aligned restart target can extend to the end of an atom; this is not
WGP5's strict 64 KiB byte bound. Extracting a block in a fresh process replays
the archive's preceding dictionary deltas, then decodes only the selected
payload. The JSON extraction metric includes model and delta preparation.
The existing decoder can prepare immutable jobs once and then run payload
jobs in any order; that capability predates this learner.

This is a research pipeline, not a new hardened decoder. It retains old v4's
decoder and integrity behavior. WGP5's hostile-input audit and resource
guarantees do not apply to this frame. Raw research input is limited to
64 MiB, requested restart targets to 1–65,536 bytes, proposal strings to
128 bytes, priced matrices to 20 million cells/192 MiB, and conditional word
DP to one million cells. This does not establish a global decoder-memory
bound for the old library or an encoder-work bound for all admitted inputs.
Substring proposals come from types no longer than 512 bytes; longer atoms
retain their literal/learned spelling fallback and can reach the word-DP
budget. The research pipeline rejects a breached budget rather than
advertising support for every possible 64 MiB byte sequence.

The atomizer matches the old native learner's byte classes: ASCII letters
and bytes at least 128 form runs, decimal digits form runs, other bytes are
individual atoms. No normalization, language-specific morphology, external
vocabulary, or neural weights are hidden. Byte fragments may split a UTF-8
scalar internally; exact reconstructed bytes are preserved. This avoids
assuming English linguistic boundaries while retaining literal fallback.

## Evidence and further experiments

`RESULTS.md` reports complete native frames on retained old development
input. The strongest measured global policy reduces exact 8 MiB frames by
1.73% on FreeDict, 0.62% on GCIDE, and 7.98% on Japanese OMW relative to the
actual original native compressor. These are development results. They are
not held-out wins, whole-file bzip3 records, or wins over older experiments
that supplied a different external byte-MDL parse.

`context_screen.py` pays every intermediate preparation and model fit and
fresh-decodes each graph. `--combined --compiler ./compile_combined` removes
a duplicate planner fit when producing the next price matrix, with an
internal byte-identical frame assertion. `make experiments` builds isolated
order/capacity/activation/phrase ablations. `research/` contains Luna's
charged stem/tail, exact DAWG, phrase-MDL, and recent-paper investigations.
Their negative or nearly tied table probes are not credited as compression
wins. No final holdout observation was used to choose this policy.

## Faithful byte-MDL reference and whole-block reparse

```
make ZIG=/home/agent/.local/bin/zig m_reference native_forward reparse_context
./m_reference input.txt base.frame base.forward 65536 20 a-best 1 0
./native_forward compile base.forward same.frame 0 base.prices
./reparse_context input.txt base.forward base.prices next.forward both 0
./native_forward compile next.forward next.frame 0
python3 test_context.py
```

`m_reference` reproduces the stronger historical Lane A best-seed → Lane M
→ v4 path while retaining original learner IDs. Its final positional flag
is `hoist` (0 or 1); all previous controls are explicit. `bytes` can replace
`a-best` for a separate initialization ablation. It writes a full existing
v4 archive plus a private `P6F1` forward-DAG graph. Its complete native
timer pays seed selection, every learner round, live-state copies, and
every native class fit. The per-iteration diagnostic `ms` covers the
original learner procedures; the complete timer also includes the added
lifetime copies. `phase_peak_allocated_bytes` counts requested live
allocations through a shared 4 GiB budget and is distinct from process RSS.
The input cap is 64 MiB, not a guarantee that every admitted input fits
every resource budget.

`native_forward` validates a forward DAG with a bounded topological pass
before calling the original compiler. The private graph and price caps
remain explicit. `reparse_context` prices strict-shorter definition tilings
and complete byte restart blocks, retaining original long-macro edges.
Its exact-byte proposal trie is bounded to 256-byte strings and four
million nodes; its materialized spelling pool to 64 MiB; its DP to ten
million cells; and total candidate-state evaluations to twenty billion.
This is an encoder search bound, not an old-decoder hardening claim.

The `native_forward_hoist` target uses the same graph/price interface with
the old library's shared leading-model profile. Ordinary extraction still
reports all model preparation it performs. A prepared reader can reuse
the common model and decode later payload jobs independently; that old
decoder capability predates this frontend.

`context_m_screen.py` applies one fixed joint/no-pruning policy to retained
old development inputs, records every source/binary/backend fingerprint,
fresh-decodes every trial, and includes all intermediate fitting/search
time. The chosen archive already contains its complete graph, so selecting
the smallest fully encoded trial does not require a free external model
or an uncharged decoder selector. `RESULTS.md` distinguishes the native
word control, the stronger historical byte-MDL reference, and new results.
