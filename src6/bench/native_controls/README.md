# Native codec controls

This comparison-only C executable runs bzip2 level 9, pinned bzip3 1.5.1,
Zstandard level 19, and xz level 9 extreme inside one native process per frame.
It avoids charging hundreds of command launches to a block-matched baseline.
All controls pay the same 32-byte header, 16-byte directory record per block,
and block CRC-32. Each block is independently decoded; bzip3 retains one native
state across blocks. Internal codec windows may differ; the restart boundary
is the matched quantity. This is not a production codec or parser.

```sh
sh src6/bench/native_controls/build.sh
python3 src6/bench/native_controls/test_controls.py
python3 src6/bench/native_controls/test_reader.py
src6/bench/native_controls/native-controls encode bzip3 INPUT OUTPUT --block 65536
src6/bench/native_controls/native-controls decode bzip3 INPUT OUTPUT
src6/bench/native_controls/native-controls decode-block bzip3 INPUT OUTPUT --index 2
```

The runner dynamically loads `libbz2.so.1.0`, `libzstd.so.1`, `liblzma.so.5`
and the pinned bzip3 shared library. Set `LEX_BZIP3_LIBRARY` to that library's
absolute path. Build the exact source revision recorded in
`THIRD_PARTY_NOTICES.md`, for example:

```sh
cc -O3 -fPIC -shared '-DVERSION="1.5.1"' -Ivendor/bzip3/include \
  vendor/bzip3/src/libbz3.c -o /tmp/libbzip3.so
export LEX_BZIP3_LIBRARY=/tmp/libbzip3.so
```

JSON `codec_ns` includes frame parsing/construction, allocations, native state
setup, codec work and CRC checking; file reads and writes are outside that
boundary. `maxrss_kib` is the Linux process high-water RSS, including resident
input and output. Subprocess wall time is a separate end-to-end observation.
Record library identities/versions and binary/source hashes with any result.
Fresh processes do not imply cold disk. CRC detects accidental corruption.

## Persistent 64 KiB query reader

`native-controls-reader CODEC FRAME RAW REPORT` is a separate comparison
program. It includes `codec.c` unchanged and retains one codec state and work
buffer. It validates the full WCTR26 header/directory/tail. `--mode verify`
fully decodes and compares every restart with the independent raw file without
clock reads. `--mode full` times a fresh full decode, then checks the result
against the oracle. `--mode query` prepares the frame and decodes 256 uncached
64 KiB source pages in the fixed first/middle/last cycle; it does not run a
full decode first. Each query owns a fresh output allocation; native codec
state and its work buffer are retained, but decoded pages are not cached.
Preparation, full decode, and the batch query therefore
have separate fresh-process measurements. File reads are reported separately.
The batch checksum is the shared FNV-1a-style fold of each queried page's
CRC-32, matching the WPG2, WSB2, and legacy readers.
Clock reads stay disabled unless both the explicit quiet-gate arguments and
the matching `FRONTIER2026_ACCESS_QUIET` environment value are provided:

```sh
FRONTIER2026_ACCESS_QUIET=FRONTIER2026-ACCESS-QUIET \
  src6/bench/native_controls/native-controls-reader bzip3 FRAME RAW REPORT.json \
  --mode query \
  --measure 1 --quiet-gate FRONTIER2026-ACCESS-QUIET
```

The timing-free mode is used by `test_reader.py`; it checks all four libraries,
the exact 256-query checksum against an independent byte oracle, frame
corruption rejection, and the quiet-gate requirement. The reader requires a
65,536-byte restart geometry so its source-page sequence matches WPG2, WSB2,
and the retained legacy reader.

## Retained legacy lexical jobs

The unchanged legacy bz4 decoder already supports immutable payload jobs after
processing dictionary deltas. `bz4_reader.zig` prepares all of them once, then
answers the same 256 first/middle/last **logical raw ranges** as the WSB2 reader.
It indexes cumulative raw offsets because the legacy restart boundaries follow
words: a 64 KiB requested range may require two payload jobs. Each query returns
and CRC-consumes exactly the requested source bytes. This is a stronger reuse
baseline than repeatedly launching the old extraction CLI and replaying deltas.
It accepts both original and WGP6-produced legacy frames, without changing their
wire format or old source.

```sh
sh src6/bench/frontier2026/build_bzip4_v3.sh
sh src6/bench/native_controls/build_bz4_reader.sh
python3 src6/bench/native_controls/test_bz4_reader.py
/tmp/frontier2026-bz4-reader bench-reader FRAME REPORT.json --measure 0
```

Preparation includes reading/copying the whole stored frame, building entropy
tables, expanding every dictionary delta, and retaining per-block jobs. Report
that cost separately and include it in startup/total comparisons. Per-query work
includes output/scratch allocations and CRC of the exact queried range. Arena
capacity, retained job capacity and source-copy bytes are separate memory
quantities, not RSS. The old decoder remains the comparison implementation;
this client does not establish new hostile-input safety guarantees.

Clock measurements require `--measure 1 --quiet-gate WORDZIP-READER-QUIET` during
a globally quiet window. Timing-disabled tests verify every logical restart,
whole output, and the complete consumed batch against an independent byte/CRC
oracle, including ranges that cross word-aligned restart boundaries. No speed
result is implied by these correctness checks.
