# GEN transient-token preflight

This is an isolated exact-byte prototype for a new source item, `GEN`, which
creates a token in the current payload without assigning it a permanent
dictionary name. A generated token joins the existing bounded recent-token
ring with its post-generation row. Later exact occurrences may use `PAST`,
which copies that token and resumes its saved row. Payload restart fences reset
the ring. The prototype does not alter WGP6, bz4 v4, WGP5, or any frozen source.

`GTG1` is a fully charged private frame. It contains one serialized 256-entry
static byte rANS model, every block's raw/token/event/coded lengths, a raw CRC32
per block, and all literal and operation operands. `PAST` carries a canonical
ULEB token distance. `LITERAL` carries exact bytes. `EDIT` carries a past-token
distance, a source byte span, and exact prefix/suffix bytes; the result is
`prefix + source[start:start+length] + suffix`. There is no occupied-pair list,
word vocabulary, external model, Unicode normalization, or decoder-side
tokenizer. The encoder's hash/substring indexes are temporary search aids and
are not delivered.

The candidate uses the old v4 byte atomization and 64 KiB atom-aligned restart
targets. Its scalar-boundary ablation uses the same atoms and exact-byte
fallback, but only permits an edit span whose endpoints are valid UTF-8 scalar
boundaries in both source and target. The rANS model and private framing are
included in every reported `GTG1` byte count. These are prototype frame sizes,
not native v4 or WGP5 compression claims. The comparison controls are freshly
encoded and decoded native v4 original and fixed WGP6 maximal frames over the
same retained old development prefix.

```sh
python3 gen_transient.py encode RAW FRAME [--scalar-boundaries]
python3 gen_transient.py decode FRAME OUTPUT [--block INDEX]
python3 run_dev.py /tmp/gen-transient-dev --report results-1m.json
```

The falsifier is deliberately strict: a useful GEN source must beat the best
complete WGP6 frame after the ring reset, source/edit operands, literal
residuals, rANS model, block directory, and CRCs are paid. The script checks a
fresh full decode and a fresh selected decode for every restart. A smaller
private prototype frame would establish only that the GEN representation
merits integration into the native finite-state source; it would not establish
a production or held-out win.

## 1 MiB development result

The fixed byte-operand version loses decisively. All bytes below are complete
frames, including models and framing; input prefixes are the same for all
three encoders. `results-1m.json` records hashes and event ledgers. Timings
were not collected.

| Retained old development prefix | Native original | WGP6 maximal | GEN byte spans | GEN scalar-boundary spans |
|---|---:|---:|---:|---:|
| FreeDict | 82,873 | 81,280 | 785,305 | 785,430 |
| GCIDE | 197,039 | 195,006 | 886,804 | 886,804 |
| OMW Japanese | 49,619 | 46,077 | 537,905 | 540,202 |

Both GEN modes decoded the whole frame and each restart exactly. The past ring
did find many exact repeats, but token operations and fresh literal/edit
operands dominated the complete file. Scalar restrictions preserved exact
fallback but did not help this representation. This rejects the private
byte-rANS wire as a compression candidate; it does not prove that a native
context-priced GEN symbol with shared grammar operands cannot work. Any
follow-up needs a quantified lower bound showing enough savings to justify
native integration, since even this prototype is roughly 4.5–11.7 times the
current WGP6 frame.

### Native price oracle for transient generation

`stats_oracle.py` runs the retained 1 MiB DEV prefixes through the same maximal WGP6 complete-frame candidate search, retains the winning P6P1 parse, and prices that parse with the unchanged v3 planner and rANS encoder. The local `encode_instrumented.zig` is an exact copy with observation-only per-token NAME/DEF attribution; it does not change model fitting, event construction, normalization, or frame bytes. The report separates the exact `Stats.token_bits` at each stream token from NAME and first-use DEF event prices.

Rebuild the isolated observer and rerun a prefix with:

```sh
zig build-exe -O ReleaseFast -Mroot=stats_native.zig -femit-bin=/tmp/wgp6-stats-native
python3 stats_oracle.py /path/to/retained-dev-prefix.bin oracle-result.json
```

The C++ `prepare_maximal` and native WGP6 binaries must already be built. The
checked-in JSON reports include their SHA-256 hashes, the frozen and
instrumented encoder source hashes, the selected candidate ledger, input and
parse hashes, and per-event Stats totals. The temporary per-token binary
arrays are intentionally not retained.

The oracle counts standalone WGP6 root entries whose expanded spelling is exactly one old lexical atom (one all-letter/high-byte run or one digit run). For each once-used spelling, the most generous removable credit is only its first occurrence's NAME plus DEF coded bits. Child spelling events, ARITY, generator opcode, operands, cache controls, any model/header growth, and changed model fit are all left unpaid. Therefore the numbers below are gross upper bounds, not candidate frame sizes.

| Retained DEV prefix | Current WGP6 complete frame | Once-used word types | Gross NAME + DEF credit | Credit per type |
|---|---:|---:|---:|---:|
| FreeDict 1 MiB | 81,280 B | 278 | 295.97 bits (37.00 B) | 1.065 bits |
| GCIDE 1 MiB | 195,006 B | 400 | 436.78 bits (54.60 B) | 1.092 bits |
| OMW 1 MiB | 46,077 B | 213 | 305.26 bits (38.16 B) | 1.433 bits |

This closes the GEN hypothesis at its requested necessary-condition stage: after retaining WGP6's spelling source and class source, every generated once-used word has roughly one bit of NAME/DEF headroom before its GEN command, any source operands, cache control, or new model rows. I therefore did not spend an 8 MiB slot or build a native GEN row. The earlier byte-varint wire prototype remains a separate result: its loss is not used as evidence against a native context-coded GEN representation.

The oracle is intentionally narrow. It does not decide whether an edit transducer can win by changing the spelling source, and it says nothing about frequent words, whose cache/reference savings are a different hypothesis.
