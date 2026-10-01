# Frozen storage captures

These are the storage-only captures made on 2026-09-26.  The run directories
contain the raw subprocess output, frame bytes, input/dump/binary hashes, and
independent decoder checks.  No timing field is used as a result.

## v4 reference rows

All rows below use 65,536-byte blocks.  `saved` means the exact retained
`dumps/m_*.b4sd` parse; `end-to-end` means the current learner made the parse
from the same input.  Every v4 frame was decoded once in the capture driver
and once by the separate `v3/zig-out/bin/bz4 d ... 1` process.

| input | bytes | saved total (header + delta + payload + framing) | end-to-end total | matched bzip3 total | saved / bzip3 |
|---|---:|---:|---:|---:|---:|
| FreeDict eval8 | 8,388,608 | 564,416 (12,467 + 82,331 + 467,922 + 1,696) | 579,202 | 899,408 | 0.6275 |
| GCIDE eval8 | 8,388,608 | 1,276,838 (29,489 + 149,040 + 1,096,573 + 1,736) | 1,324,034 | 1,905,560 | 0.6701 |
| OMW eval8 | 8,388,608 | 330,148 (10,512 + 148,211 + 169,701 + 1,724) | 374,217 | 674,384 | 0.4896 |

The matched bzip3 column is the lane's 65,536-byte control.  Historical
whole-file bzip3 numbers in v3/RESULTS.md are a separate control and must not
be mixed with this table.

The complete saved-parse run is
`runs/storage-screen-auto-20260926-forms-fixed/`; its manifest reports 24/24 successful
samples (three saved parses, three end-to-end frames, six bzip3 controls, and
six frozen-language workloads with their controls).

## `lab --stats` replication

The exact auto-fit command was, once per input and serially:

```text
v3/zig-out/bin/lab DATA dumps/m_NAME.eval8.65536.b4sd --workers 1 --stats
```

The raw output and parsed records are in
`runs/lab-stats-auto-20260926b/`.  `stats` byte counters are event-category
accounting; their rounded category sums do not replace the authoritative
complete-frame `delta` and `payload` fields.

| input | classes | total | header | delta | payload | framing | buckets | delta stats bytes (`use,past,def,arity,name,silent`) | payload stats bytes (`use,past,def,silent`) |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| FreeDict | 64 | 564,416 | 12,467 | 82,331 | 467,922 | 1,696 | 714 | 40,640, 4,077, 2,341, 3,629, 7,019, 24,379 | 294,811, 59,530, 8,148, 105,130 |
| GCIDE | 128 | 1,276,838 | 29,489 | 149,040 | 1,096,573 | 1,736 | 1,417 | 56,473, 7,458, 3,872, 4,788, 13,261, 62,915 | 616,489, 130,599, 16,980, 332,093 |
| OMW | 64 | 330,148 | 10,512 | 148,211 | 169,701 | 1,724 | 665 | 69,454, 28,475, 4,802, 7,017, 6,750, 31,458 | 90,742, 40,079, 4,879, 33,739 |

The fixed-C64 control is separate in
`runs/lab-stats-fixed-c64-20260926/`: FreeDict and OMW are unchanged, while
GCIDE is 1,282,509 bytes (`header=12,675`, `delta=149,760`,
`payload=1,118,339`, `framing=1,735`, `buckets=791`) instead of auto-fit C128
at 1,276,838 bytes.  This is why fixed-C64 and auto-fit claims are not merged.

## New language screens

The deterministic projections and raw CoNLL-U test bytes are frozen in
`corpora/`, with source/license/pinned-commit/Git-blob/raw/projection hashes
in `ud-manifest.json`.  These are test splits, not tuning data.  If a candidate
is selected after inspecting these rows, treat the touched split as
development and reserve a new untouched split before claiming generalization.

The screen is intentionally a negative result against matched bzip3 on these
small files:

| workload | input bytes | v4 total | bzip3 total | v4 / bzip3 |
|---|---:|---:|---:|---:|
| Finnish FORM | 161,246 | 59,518 | 53,508 | 1.1123 |
| Finnish prose | 158,155 | 59,294 | 53,559 | 1.1071 |
| Turkish FORM | 67,770 | 26,157 | 22,113 | 1.1829 |
| Turkish prose | 65,596 | 26,036 | 21,581 | 1.2064 |
| Arabic FORM | 245,812 | 56,244 | 51,354 | 1.0952 |
| Arabic prose | 239,109 | 59,883 | 51,516 | 1.1624 |

These rows do not imply that the codec is unsuitable for larger multilingual
corpora; they do establish that the current charged non-payload bytes
(`header + lexical-definition delta + framing`) are visible and that the lane
has no cross-language win to overclaim on these holdouts.  The delta contains
first-use spelling/text definitions, and bzip3 payload also carries comparable
spelling information, so this arithmetic decomposition does not establish an
intrinsic sequence-model advantage.

## Fairness and decoder notes

The frame totals charge header, all serial lexical-definition deltas, payloads,
framing, block/restart data, and bucket tables.  A payload worker cannot be
treated as an independent random-page decoder: model/header preparation and
all preceding deltas are shared serial work.  The capture does not report
decode speed, and it does not treat a model-size estimate or a Lane M
model-codec total as a v4 frame.

The current v3 source test suite was run without writing into the shared v3
tree (`zig test -O ReleaseFast -Mroot=../../bz4/v3/src/root.zig` with a
temporary cache/output): all 7 tests passed.  The evidence driver itself was
rebuilt from the current `bz4/v3/src/root.zig`; its binary hash is recorded in
each run manifest.

## Weighted-emission candidate: frozen seven-row negative screen

The complete run is `runs/wam-screen-final-20260926/`. It uses the exact
first-65,536-byte prefixes in the preflight run, current v4 raw capture, and
the matched bzip3 totals from that preflight. WAM uses the same fixed policy
for every row (`max_piece=8,min_occ=2,max_vocab=256,em_rounds=2`); fitting from
the charged input itself is legal here because the full fitted token/frequency
model is serialized in the frame header. The seven prefixes are development
inputs only; TRAIN confirmation-20 was not read.

| exact prefix | bzip3 | current v4 | WAM MAP | WAM marginal |
|---|---:|---:|---:|---:|
| web2 | 21,093 | 18,168 | 31,403 | 30,681 |
| FreeDict eval8 | 6,674 | 7,588 | 28,657 | 28,606 |
| GCIDE eval8 | 14,613 | 17,417 | 34,166 | 33,986 |
| OMW eval8 | 5,032 | 6,493 | 29,449 | 29,380 |
| UD Finnish FORM | 21,980 | 26,526 | 32,915 | 32,202 |
| UD Turkish FORM | 20,939 | 25,346 | 33,749 | 33,208 |
| UD Arabic FORM | 13,567 | 17,425 | 23,125 | 22,876 |

All 28 rows (four codecs/modes per workload, including the reused controls)
passed frame parsing and exact re-decode checks. WAM MAP and marginal are
larger than bzip3 on all 7/7 rows and larger than current v4 on all 7/7 rows;
this is a negative candidate result, not a v4 win. The WAM breakdown labels
`header` as magic/mode/raw length/full serialized model (and MAP path count),
`framing` as the payload-length varint, and `payload` as arithmetic bits plus
finish padding; WAM has no separate v4-style `delta` section (`delta=0`).

Representative WAM rows include web2 MAP
`header=2,107, payload=29,293, framing=3, total=31,403` and marginal
`header=2,104, payload=28,574, framing=3, total=30,681`. The exact model
source hash is `cd6b043d0d1d0cbf406649cb97e6a3a3b865686e6d4037f9e4b971426a2af95d`;
the manifest records every input/frame/binary hash and the fresh decode helper.
