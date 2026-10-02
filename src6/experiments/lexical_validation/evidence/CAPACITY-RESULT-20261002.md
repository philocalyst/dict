# LTCv2 registered capacity-only whole-source validation

The uniform capacity repair admits all three sources exactly. It does not
establish a general compression win: Turkish and Arabic lose to both backend
scopes, and every source loses to whole-flat bzip3 and zstd19. Japanese's smaller
untyped surface frame improves the matched-page controls; its typed frame loses
to matched-page bzip3 and narrowly improves matched-page zstd19.

All 64,999 predeclared whole records and 991 original native groups remain.
TR/AR include every projected record; JA uses the original pre-outcome
SHA-256(source-entry-ID) modulo16 whole-record selection. The source oracle is
complete adapter-normalized serialized TEI entry content, not the original raw
TEI file; original front matter is outside that projection. No analysis was
inferred from the prose. Native-v3 fields, IDs, ordered keys, arbitrary UTF-8,
duplicate values, source content and group boundaries are exact.

| Source | Records / groups | Complete-size minimum | Typed/headword minimum | Matched-page bzip3 / zstd19 | Whole-flat bzip3 / zstd19 |
| --- | ---: | ---: | ---: | ---: | ---: |
| tur-eng | 1,026 / 14 | 40,960 B | 43,322 B | 31,195 / 31,820 B | 21,626 / 25,602 B |
| ara-eng | 52,996 / 719 | 2,097,348 B | 2,491,063 B | 1,813,579 / 1,858,632 B | 1,079,165 / 1,352,413 B |
| jpn-eng | 10,977 / 258 | 915,715 B | 972,326 B | 941,628 / 975,665 B | 510,812 / 668,407 B |

The complete-size minimum is `global_causal_surface` for each source. It carries
exact native packets as surface constructions and has no typed headword prefix.
Relative to matched-page bzip3 / zstd19 it costs +31.30% / +28.72% in TR,
+15.65% / +12.84% in AR, and -2.75% / -6.14% in JA. Relative to whole-flat
it costs +89.40% / +59.99%, +94.35% / +55.08%, and +79.27% / +37.00%.

The typed minimum is `global_joint` in TR and AR, and `global_causal_joint` in
JA. Relative to matched-page bzip3 / zstd19 it costs +38.87% / +36.15%,
+37.36% / +34.03%, and +3.26% / -0.34%. Relative to whole-flat it costs
+100.32% / +69.21%, +130.83% / +84.19%, and +90.35% / +45.47%.
All ten candidates were actually encoded and fully admitted for every source;
the unchanged complete-frame minimum and fixed candidate-order ties select
these profiles. Models, stock, independent root streams/offsets, original group
directory, checksums and framing are included in actual published artifacts.

Typed projection requires resolving the entire shared stock and performing full
native/source admission first. The pool includes serialized XML source content;
these are resident component costs, not cold-leaf or cache-free access claims.

| Typed winner | Decoded stock | Lexeme index | Owned model heap | Page value | Retained payload total | Borrowed complete frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| tur-eng | 431,668 B | 49,248 B | 66,820 B | 1,320 B | 549,056 B | 43,322 B |
| ara-eng | 22,351,035 B | 2,538,112 B | 147,004 B | 1,320 B | 25,037,471 B | 2,491,063 B |
| jpn-eng | 8,108,303 B | 728,608 B | 163,452 B | 1,320 B | 9,001,683 B | 972,326 B |

Allocator capacity/headers, transient source/admission arenas and stack copies
are excluded from those payload totals. Peak RSS and speed were not measured.
The process guard was a hard/soft **4 GiB virtual address-space** limit with an
**1,800-second** deadline per native all-ten-candidate process, new process
session, complete process-group termination on timeout, and durable launch/exit
status. All three native processes exited zero without timeout. The address-space
ceiling is not a peak-RSS measurement. These were concurrent diagnostic jobs.

The independently registered repair changes only lexeme capacity to 500,000,
absolute entropy events to 128 MiB and all three global/native/dictionary work
ceilings to 128 MiB. Schema, wire, model, ten options/order, selectors and sources
remain unchanged. Debug/Safe/Fast each pass 15 tests. All twenty DEV candidate
frames and four selector frames reproduce their retained bytes. In this fresh
run, **all ten Turkish frames remain byte-identical to the first fixed run**, and
**all twelve backend controls** across the three sources remain byte-identical.
The [first fixed ledger](FIRST-FIXED-20261002.json) still records the original
Arabic/Japanese `WorkLimit` failures and Turkish size loss; they are not erased.

All 30 native candidates pass **649,990** full native/source/root/group
observations and **454,993** direct typed headword projections. The artifact audit
checks all **48** published candidate/control/selector frames, their real
hashes/lengths, every complete inner/outer byte ledger, source/group provenance,
original observation agreement, and frozen selectors. This run makes no whole
file compressor or timing claim and stops without tuning from these outcomes.

The [result ledger](CAPACITY-RESULT-20261002.json) SHA-256 is
`5946056f3314bf972c45bcb769a6f4786b56296394dc64d1724e9ccb067900dd`.
The [artifact audit](CAPACITY-ARTIFACT-AUDIT-20261002.json) SHA-256 is
`0f004d3a74beb19c11d3965d8ce80af6589a3cb844bb57ec6cdc63c67bb86b34`.
The [bounded freeze](CAPACITY-FREEZE-BOUNDED-20261002.json) SHA-256 is
`22db34ae729fb4f5ab4e824b25d04123f88c1447acad0e21c7cad12d2d04ff04`,
the [root registration](ROOT-CAPACITY-REGISTRATION-20261002.json) SHA-256 is
`ec4aab670f573405f1725d6aab73999d45e81236011a3ecdae264845506ca0ca`,
and the native binary remains
`336ebc07506450e2ee2b03c217b3da06dfc00d518c1c2a88142c586bba2d28db`.
Those manifests retain the exact command, sources, historical-v3 core pin,
source/binary/runtime hashes, process status and every model/cost component.
