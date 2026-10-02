# Development results: exact record registers

These are byte-exact, complete archives on retained 8 MiB development
samples. They are not final holdout results. Every measured archive was
decoded in a fresh native backend process and compared with its source.
`WBP1` pays one mode byte, source length, full WGP6 model/directory/payload,
and CRC32. The earlier `WPG1` prototype additionally pays 128 transformed-page lengths and 128
original-page CRC32 values. Encoder search runs the full backend on every
candidate; trial sizes include their wrappers.

| Exact 8 MiB source | Strong LaneA+M raw (`WBP1`) | Selected `WBP1` | `WPG1` 64 KiB source pages | bzip3 1.5.1, one 8 MiB block |
|---|---:|---:|---:|---:|
| FreeDict XML | 564,432 | 564,432 (raw) | — | 554,003 |
| GCIDE XML | 1,279,049 | 1,279,049 (raw) | — | 1,243,221 |
| Japanese OMW XML | 331,737 | **286,906 (local + ancestor)** | **288,165** | 332,331 |

The Japanese result beats the matched raw strong backend by 44,831 bytes
(13.51%) and whole-block bzip3 by 45,425 bytes (13.67%). The page-reset
archive is 1,259 bytes above the unrestricted archive and 44,166 bytes
below whole-block bzip3. A historical matched 64 KiB bzip3 archive for the
same Japanese bytes was 674,384 bytes; that is a separate access-geometry
comparison. FreeDict and GCIDE offered no eligible register references, and
their whole-block bzip3 controls remain smaller. The older leaf-text/markup
channel split lost on all three 1 MiB samples, so it is not selected.

The later conditional spelling reparse composes with WPG2 without changing
its decoder or page index. A complete eight-way screen (four byte
constructors × initial/conditional graph) on each 1 MiB development prefix
gave FreeDict **82,074 bytes** (raw + conditional), GCIDE **193,406** (raw +
conditional), and Japanese OMW **38,829** (local+ancestor + conditional).
The Japanese local+ancestor initial graph was 41,729 bytes, so the reparse
adds 2,900 bytes of savings (6.95%) to that already constructed source.
Japanese raw + conditional was 42,773 bytes; local-only + conditional was
38,833, just four bytes above the selected both-constructor result. All
frames were freshly decoded by the native reader and matched their inputs.
These are development-prefix results, not a language-specific mode rule.
The corresponding `access` 1 MiB winners are FreeDict 83,576, GCIDE
198,302, and Japanese OMW 39,924 bytes, again selected by the same complete
mode-and-graph search. FreeDict and GCIDE choose raw + conditional; Japanese
chooses local+ancestor + conditional. Their full trial ledgers are in
`evidence/dev1m-access-global.json`.

On Japanese OMW, the local constructor found 9,901 `id`→`members` list
relations and 9,900 other same-record field relations. The ancestor
constructor found 2,320 exact child-field slices and 9,766 prefix/suffix
child references. These labels describe the observed corpus; the byte rules
do not use those names. The 8 MiB selected `WBP1` frame contains 121,993
bytes of native model/dictionary and 163,734 bytes of native payload; the
remaining native bytes plus 16-byte wrapper complete 286,906 bytes.

The earlier `WPG1` used 128 original 64 KiB pages, 896 bytes of page length/CRC index,
and a 287,249-byte shared native frame. Pages 0, 1, 63, and 127 were
reconstructed by freshly extracting only their overlapping native blocks,
then checked against their page CRC and original bytes. Full native
constructor decoding matched the original 8 MiB SHA-256
`d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261`.
Corrupted magic, truncation, final CRC, and page CRC were rejected.

Whole-block bzip3 controls used the pinned repository library and were
decoded and checked against the same input bytes. Encoder time is high
because it tries multiple fully fitted grammar parses. Timings during
concurrent development are not suitable for ranking. The `WBP1` encoder and
reference decoder use Python for orchestration. Earlier fresh `WPG1`
extraction replayed model deltas per query, so no fast random-page claim is
based on its timings.

The current `WPG2` source adds a global mode selector and a checked header
CRC. Its Zig/C++ prepared reader decodes a selected page and checks its CRC
in one process. On OMW 8 MiB, the strong LaneA backend with the legacy
interleaved model selects local+ancestor, yielding a **288,170-byte** complete
archive (13.29% below whole-block bzip3). The corresponding all-choice
unhoisted frames are raw 332,642, local 302,930, scope 325,756, and both
288,170 bytes. This profile prepares all earlier model deltas once before
selected-page payload reads; it does not claim a cold single-model query.

The hoisted common-model profile selects local+ancestor and yields a
**298,002-byte** complete archive:
297,081 bytes native v4 model/payload and 921 bytes wrapper and 128-page
index. The other fully fitted WPG2 candidates are raw 350,058, local 343,492,
and scope 341,711 bytes. This wins by 34,329 bytes (10.33%) against the
same-source one-block bzip3 control while supporting original-byte 64 KiB
page queries. A fresh C++/Zig full read reproduces the source SHA-256 above;
page 63 reads only two payload Jobs and validates its own CRC. The hoisted
frame has one leading common model and 86 payload-only jobs. The prior
byte-seed hoisted candidate was 327,864 bytes. The earlier WPG1 number in
the table is a distinct wire format and unhoisted fit.

Conditional spelling DP was then applied to every distinct constructed
8 MiB OMW source with its actual interleaved native fit. The full eight-way
WPG2 frames were raw initial/DP 332,642/331,203, local 302,930/299,467,
scope 325,756/326,112, and local+ancestor 288,170/**285,569** bytes.
The selected complete archive is 46,762 bytes (14.07%) below whole-block
bzip3, and 1,337 bytes below the unrestricted WBP1 result while retaining
the original 64 KiB page index. Its byte ledger is outer wrapper 921,
native header 6, native directory 1,164, native model/dictionary 122,376,
and payload 161,102 bytes, summing exactly to 285,569. The 5,613,360-byte
constructed source independently regenerated from current encoder code
matches the decoded native inner frame byte-for-byte (SHA-256
`b9ef7a952e8465979af3d889b3248b3c20bc1c50efe2cc63cc1a9c9bab15579b`).
Fresh same-process native full decode matches the 8 MiB original; page 63
uses two payload Jobs and validates its own CRC. This remains a development
result; whole-block English bzip3 controls still lead WPG2 on FreeDict and
GCIDE.

The same eight-way search under the `access` profile fits a genuinely
hoisted common model for both base and conditional graphs. Its complete OMW
8 MiB winner is **294,938 bytes** (11.25% below whole-block bzip3): outer
wrapper 921, native header 6, directory 698, model/dictionary 122,629, and
payload 170,684 bytes. The native frame has exactly one leading model-only
block followed by 86 payload-only Jobs, with no later model deltas. Its
base/DP candidates by constructor are raw 350,058/340,364, local
343,492/335,984, scope 341,711/334,845, and local+ancestor
298,002/294,938. Fresh native full decode and a page-63 query using two
Jobs match the source and page CRCs. The access archive costs 9,369 bytes
more than the quality winner for this source; timing comparison is deferred
until a quiet benchmark run.

Independent audit found that the unchanged v4 reader allocates from a
declared delta-output length before checking the decoded amount. A resealed
WPG2 sample with a 67,108,865-byte claimed first delta initially decoded
successfully. The private WPG2 Job adapter now rejects this before v4 model
preparation via explicit native-header, delta, definition, block, payload,
and total-output caps. The unchanged strong archives still decode exactly;
the resealed mutation and archive tests pass. This is a bounded-metadata
guard, not a complete hostile-input audit of the inherited v4 model reader.

A further bounded 4,096-slot prior-word register was screened as a fresh
candidate. It replaces separator-delimited previously seen byte lexemes with
paid references, resets every 64 KiB page, and has literal fallback for
invalid bytes. It removed 217,156 bytes from the 1 MiB OMW local+ancestor source,
but zlib level 9 grew from 57,805 to 143,941 bytes: frequent spellings were
more predictable than ring indices. Limiting references to long non-ASCII
tokens still grew to 81,671 bytes. A backward-distance operand reduced that
last result to 69,231 bytes, still 19.8% above the unchanged source. These
are exact-transform proxy results, not credited complete native frames; the
variant is kept in `prior_word_register.py` as a negative construction probe.
