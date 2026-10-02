# Prepared multilingual access capture

This protocol extends the frozen 22-lane final size matrix. It does not alter
the existing size-only report or codec sources. The durable run matrix is in
`final_capture_registry.json`; candidate reader commands and byte accounting
are in `access_profiles.json`; native controls use the persistent reader in
`../native_controls/reader.c`.

`access_capture.py size --out DIR --whole-controls` builds each fixed
64 KiB candidate frame once on all 22 hashed final lanes, retains it in
`DIR/cells/`, records raw argv/stdout/stderr/exit events, checks full-frame
accounting, and gates the frame on fresh decode and source/restart parity.
Whole-frame controls are captured as separate artifacts in the same run.
`results.jsonl` and `status.json` are atomically checkpointed after each
candidate cell. Re-running resumes only cells whose source, frame SHA, and
frozen runtime fingerprint still match. `--smoke-development NAME` is limited
to one explicitly named hashed development lane and never participates in
final summaries.

## Frames and comparisons

The new size rows are WPG2 quality and WPG2 access on each official final
corpus lane at 65,536 original bytes per page. Each encode pays its complete
WPG2 wrapper, page index, model, directory, and payload. Preserve each verified
frame as a benchmark artifact, indexed by raw-source SHA-256, profile, frame
SHA-256, encoder source/binary manifest, and dependency identities.

The access comparison uses the same corpus bytes and the same sequence of 256
logical source-page requests: first, middle, last, repeated in that order. Each
process prepares its model once, then decodes each requested page from its
native restart data. It must not retain decoded pages between requests.

Use the frozen LaneA+M native frames as the raw construction reference. Its
frame is encoded directly by frozen `m_reference`; it has no WPG2 page wrapper.
The root-provided `bz4_reader` retains the immutable native Jobs and returns
exact original 65,536-byte source ranges, including requests that cross two
word-aligned jobs. Report quality (`... a-best 1 0`) and hoisted/access
(`... a-best 1 1`) frame policies separately.

WSB2 variants use `sbwt-session bench-reader`, which prepares the model once
and performs the same uncached 256-request schedule. The native-control reader
accepts WCTR26 frames for bzip2, bzip3, zstd, and xz. It validates complete
metadata and exact frame tail. First run `--mode verify` once for each unique
frame SHA to fully decode and compare every restart against the independent
raw source. Run `--mode full` in separate fresh processes for repeated
full-decode samples. Run `--mode query` in separate fresh processes for 256
uncached page reads; query processes do not first decode the whole frame. Each
query is checked against the raw oracle. Measurements separate frame read,
oracle read, preparation, full decode, and query batch. The query batch
checksum folds each page's CRC-32 with the same FNV-style accumulator used by
the WPG2, WSB2, and legacy prepared readers.

Whole-frame native controls are a separate result group. They must fully
decode and verify the entire source before page slicing; their full decode and
slice work are charged. Do not place these results beside matched 64 KiB
independent-page timings.

## Timing gate and schedule

All final access timing runs require the explicit global quiet release from the
root. The native-control reader additionally requires both
`--measure 1 --quiet-gate FRONTIER2026-ACCESS-QUIET` and
`FRONTIER2026_ACCESS_QUIET=FRONTIER2026-ACCESS-QUIET`. The WPG2, WSB2 and
legacy readers keep their existing `WORDZIP-READER-QUIET` gate. Run candidates
serially, using one fresh-process warm-up per operation followed by five paired
rounds. Alternate pair order across rounds and checkpoint each completed
process with its full argv, stdout, stderr, exit code, frame/source hashes,
start/end source and dependency fingerprint, and parsed timing fields.

After all final size frames pass their guards, `access_capture.py timing
--out DIR --quiet-token FRONTIER2026-ACCESS-QUIET` runs the 17 core lanes from
`final_capture_registry.json`: five dictionary-content sources, five UD prose
lanes, five UD forms lanes, and the multilingual prose/tagged lanes. It writes
`timing-results.jsonl` and `timing-status.json` after each process. The command
requires both the root quiet release and the matching
`FRONTIER2026_ACCESS_QUIET` environment token.

Each trial reports preparation, full decode, and batch query as distinct
metrics. Include file-read time where the reader reports it; process-launch
wall time remains a separate end-to-end metric. Record OS peak RSS only as a
diagnostic from each fresh process. Do not rank memory from inherited
`ru_maxrss` floors or from logical model-byte counts; report charged model,
directory, wrapper, and frame bytes separately.

Before timing, verify every unique deterministic frame by SHA-256 and perform
full fresh-process decode plus every-restart extraction against the raw oracle.
For new WPG2 frames, run its existing native full decode and page extractor;
for WSB2 frames, use the registered native decoder and every independent
block; for WCTR26, `native-controls-reader` performs all-block validation; for
LaneA+M, use its full decode and prepared-reader range checks. Repeat source,
binary, and dynamically loaded dependency hashes after the final measured
cell; any change invalidates the capture.

The current frozen size JSON contains dimensions and complete byte ledgers,
not serialized frame bytes. Reusing a candidate's size row therefore does not
replace retaining a fresh immutable frame artifact for the prepared access
reader. Encode each new frame only once per raw-source/profile/configuration,
then share its verified SHA-addressed artifact across warm-up and trials.
