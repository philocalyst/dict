# Native-frame productive substring search

Research encoder only. Production sources/build and the public decoder are unchanged.
`adapter.py` exposes the quickbench `encode`/`decode` contract. It uses the existing
evidence capture executable for full native v4 encoding, not an estimated entropy
objective. Dependencies are `../evidence/bin/capture_frame` and
`../../bz4/v3/zig-out/bin/bz4`; fingerprint both when invoking quickbench.

The structural experiment changes the graph offered to the native encoder:
shared variable-length substrings compete over lexical **types** through a DP,
then competing variable-arity phrase proposals are introduced in three rounds.
This differs from the current learner's simultaneous near-best pair mergers.
Runs, Unicode category boundaries and record segments offer different ownership
of separators and definitions. Unicode segmentation preserves invalid UTF-8 via
surrogateescape. No normalization, shared dictionary or external model is used.

Frozen policy (before the 8KiB and larger screens): 24 candidates from three
boundary policies, two fragment budgets (64/256), two hapax introduction policies,
and two phrase span limits (2/6). Candidate substring lengths are
2/3/4/6/8/12/16/32/64 bytes. A full-frame winner among these graphs receives six
coordinate refits: budgets 32/128/512 and phrase spans 4/8/12. Every candidate is
refitted with the unchanged native class planner. The native current learner is
the incumbent. Selecting a graph requires no extra selector bytes because the
selected graph and all tables are already in the self-contained native frame.
This costs up to 31 subprocess encodes, and is an expensive encoder policy.

Reachability removes unused proposals, not price-based grammar pruning. Every
reference points to an earlier entry, no CUT is generated, and graph depth is
bounded by one fragment level, one lexical level, and three phrase levels.
Payloads obey exact requested byte block boundaries; dictionaries remain shared
at frame level. Native encoding performs an exact reconstruction check on every
trial. The final frame is independently decoded with the public CLI.

Run `python3 test_adapter.py` in this directory for graph reconstruction tests
across all 24 configurations (empty, all 256 byte values, invalid UTF-8, combining
scripts, multiple blocks) and a native external decoder test. `screen.py` retains
every trial's complete bytes, header/delta/payload/framing breakdown, wall effort,
input hashes and the final exact frame. Timings are encoder effort, not serial
idle-machine performance evidence. The early `dev-2k` run predates expanded
substring lengths and coordinate refits and is not the frozen algorithm.

8KiB frozen screen: OMW native 1449 B, best alternative 1611 B; Finnish native
4241 B, search 4186 B; Turkish native 4146 B, search 4142 B. The small wins do not
survive the frozen 16KiB quickbench screen: search equals native on all three,
with full frames 2027/7941/7508 B versus real bzip3 1575/6500/6184 B. No production
promotion or decoder speed claim follows from this experiment. The reserved
confirmation-20 data was never opened.

64KiB frozen first-policy screen: native/search returns 6493/27344/26067 B,
where the best alternative graphs cost 7296/27884/26665 B. Real native bzip3
controls cost 5032/22522/21265 B on those identical bytes. Entire search effort
was approximately 15/34/25 seconds; concurrent activity prevents interpreting
these as controlled performance measurements. No winning 64KiB graph justified
scaling the first policy to 128–256KiB.

`priced_refit=True` is a separately frozen second policy. Its isolated
`prices.zig` driver obtains actual entry code charges from `encode.Stats` after
the planner's measured-bucket refit. It also reads the fitted body-row literal
bucket charge, including eight raw bits. These charges rerank shared substring
proposals and resegment competing overlaps. Three new graphs test the same
structure, toggled lexical introduction, and doubled shared inventory, and only
full native frame bytes determine acceptance. This is graph regeneration, not
per-entry price pruning. Measured charges do not include DEF/ARITY/NAME or past
uses; those interactions are paid by the acceptance oracle. Unobserved pieces
use a frequency proposal prior, so this is still a bounded approximate search.
The initial `priced-dev-8k` predecessor used fixed literal fallback and is retained
as a development ablation; it must not be conflated with the later native-literal
priced policy.

Build the stats driver from the repository root:

```
zig build-exe -O ReleaseSafe --cache-dir src6/experiments/bzip4/language_frontier/parse_search/zig-cache --global-cache-dir src6/experiments/bzip4/language_frontier/parse_search/zig-global --dep bz4 -Mroot=src6/experiments/bzip4/language_frontier/parse_search/prices.zig -Mbz4=src6/experiments/bzip4/bz4/v3/src/root.zig -femit-bin=src6/experiments/bzip4/language_frontier/parse_search/prices
```

Add `prices` to quickbench dependencies when testing this second policy.

Frozen native-priced V2 16KiB results (`priced-frozen-v2-16k/`) retain the native
2027/7941/7508 B frames. The three regenerated graph frames cost
2241/2243/2293 B on OMW, 8229/8693/8401 B on Finnish, and 8160/8844/8553 B on
Turkish. Thus actual aggregate use prices also fail to improve this bounded
proposal family. Encoder effort was 13.8/13.2/18.1 seconds with concurrent CPU
activity. V2 makes 35 capture subprocess calls plus one stats subprocess whose
two encodes obtain measured use prices. Every final frame passes public native
decode with an exact input hash; a separate all-256-byte, combining-mark,
multiblock priced-refit check also reconstructs exactly.

These literal charges are a proposal control: the body-row charge does not
describe every incoming row, and alias averages cover bucket-served uses only.
The full-frame oracle pays actual context, recency, definitions and tables.
Before/after resource fingerprints detect any concurrent implementation change;
the V2 screen preserves source snapshots and hashes for all external binaries.
The incomplete `priced-frozen-16k/` directory records a premature invocation
while the executable was being rebuilt; it contains no successful result.
Future rebuilds should write a unique temporary output and atomically replace
the stable driver only after compiler success, while no measurement uses it.

The approximate fragment/phrase proposal score remains the principal limitation:
full-frame selection cannot recover graphs absent from its proposal set. Native
class fitting also stops when successive class powers first fail to improve, so
the oracle here is the actual current encoder rather than exhaustive model search.
This is a concrete negative control for broad factorization search, not a solution
to marginal coding or a new generative decoder.
