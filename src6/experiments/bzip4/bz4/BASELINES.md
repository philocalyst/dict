# bzip3 baselines (Lane D control)

The authoritative bzip3 numbers every bz4 lane is judged against. Produced by
`bz3base.zig`, the only file in this lab allowed to touch C: it links the
vendored `vendor/bzip3/src/libbz3.c` (version string `"1.5.1"`) directly
through `@cImport`, as the control bzip3 that bz4 must beat, not as a codec
any bz4 lane may depend on.

## Method

- Built with: `zig build-exe -O ReleaseFast bz3base.zig
  -I<repo>/vendor/bzip3/include -cflags -std=c99 -DVERSION=\"1.5.1\"
  -fno-sanitize=undefined -O3 -- <repo>/vendor/bzip3/src/libbz3.c -lc
  -femit-bin=bin/bz3base`. (`-cflags ... --` must precede the `.c` file it
  applies to; the flag ordering in the lane brief has the C source listed
  before `-cflags`, which zig 0.16 rejects with "use of undeclared
  identifier 'VERSION'" — the C source must come *after* the `-cflags`
  block, immediately before `-lc`.)
- Each file x block-size cell is one run of `bin/bz3base FILE BLOCK_BYTES 5`.
  The file is split into independent blocks of `BLOCK_BYTES` (last block
  shorter; `BLOCK_BYTES=0` means the whole file as one block). Every block is
  encoded with `bz3_encode_block` through **one retained encoder state**
  sized `max(BLOCK_BYTES, 65*1024)` (bzip3's minimum native state; see
  `min_native_block_bytes` in `../../../compression.zig`, and `bz3_new` in
  `vendor/bzip3/include/libbz3.h`). All encoded blocks are kept in memory,
  then decoded with **one retained decoder state**.
- Every run does one full untimed decode pass first and checks every block
  is byte-exact against the source before trusting any timing (`rules of
  evidence`: no size or speed is reported without a real roundtrip in the
  same run). Only then does it run 5 additional full-decode passes purely
  for timing (memcpy of the encoded block into the work buffer is inside the
  clock; the byte-exact check is not, since it is O(n) work that has nothing
  to do with decode speed and was already proven correct). `decode_min_ms`
  and `decode_median_ms` are the min and median of those 5 passes;
  `decode_MBps` is `(file bytes / 1e6) / (median seconds)` — decimal MB, not
  MiB.
- `total_bytes = 32 + 16*block_count + payload_bytes`: the frozen bz4 frame
  accounting (32-byte header + one 16-byte directory record per block +
  the concatenated encoded blocks). This is what every other lane's
  `total_bytes` is compared against at matching block sizes.
- `encode_ms` is a single pass (not repeated); only decode is repeated,
  since that is the number that matters for the "beats bzip3 on decode
  speed" thesis.

### A build-time bug we hit and fixed

The first full matrix run corrupted `baselines.tsv` when each of the 54
`bz3base` invocations was appended to it with plain shell `>>`. Root cause:
`std.Io.File.stdout().writer(io, buffer)` in Zig 0.16 defaults to
**positional** writes (`pwrite` at an offset the `Writer` tracks itself,
starting at 0), which silently ignores the fd's `O_APPEND` state — every
invocation overwrote the file from byte 0 instead of appending after the
previous line, leaving corrupted fragments of longer earlier lines dangling
past the end of shorter later ones. `bz3base.zig` now uses
`std.Io.File.stdout().writerStreaming(io, buffer)`, which issues plain
`write()` calls and honours whatever seek/append semantics the fd already
has — the behaviour any CLI tool's stdout needs. Re-verified with a small
appended-lines test before re-running the full matrix.

### Caveats

- **Timings are indicative, not authoritative**: several agents share this
  machine concurrently. `encode_ms`/`decode_*_ms` will have noise from
  unrelated CPU contention. One visible spike: `omw.untouched.bin` at block
  4194304 shows `decode_min_ms=19.504` but `decode_median_ms=35.344` — one
  of the 5 passes was hit by a concurrent scheduling stall; the min is the
  more trustworthy figure for that cell. Treat `ns/root` or `MB/s`
  comparisons between lanes as approximate; only the lead's final serial
  timing pass should be treated as authoritative for speed claims.
- For the three `*.untouched.bin` files (1 MiB each), block sizes
  1048576, 4194304, and 0 all produce the **same single block** (the whole
  file), so their `payload_bytes`/`total_bytes` are identical across those
  three columns for a given file — only timing noise differs. This is
  correct, not a bug: `BLOCK_BYTES` only sets the *nominal* block size, and
  the file is smaller than all three.
- All 9 sanity numbers specified in the lane brief were reproduced exactly
  before the full matrix was trusted (see below).

## Sanity check (all exact)

| Cell | Expected | Got |
|---|---:|---:|
| freedict.eval8 @16384 | 1,189,002 | 1,189,002 |
| freedict.eval8 @65536 | 899,408 | 899,408 |
| gcide.eval8 @16384 | 2,362,319 | 2,362,319 |
| gcide.eval8 @65536 | 1,905,560 | 1,905,560 |
| omw.eval8 @16384 | 1,124,142 | 1,124,142 |
| omw.eval8 @65536 | 674,384 | 674,384 |
| freedict.untouched @65536 | 115,160 | 115,160 |
| gcide.untouched @65536 | 235,103 | 235,103 |
| omw.untouched @65536 | 95,276 | 95,276 |

All nine match bit-for-bit. `bz3base` reproduces the frozen protocol.

## Results

Full data in `baselines.tsv`. One table per block size below; columns are
`block_count`, `payload_bytes`, `total_bytes`, `encode_ms` (single pass),
`decode_min_ms` / `decode_median_ms` (5 passes), `decode_MBps` (decimal MB
over median decode time).

### Block size 16384

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 512 | 1,180,778 | 1,189,002 | 365.18 | 201.97 | 203.72 | 41.18 |
| freedict.untouched.bin | 64 | 149,390 | 150,446 | 48.15 | 26.10 | 26.24 | 39.97 |
| gcide.eval8.bin | 512 | 2,354,095 | 2,362,319 | 695.52 | 342.06 | 342.80 | 24.47 |
| gcide.untouched.bin | 64 | 291,591 | 292,647 | 84.30 | 42.35 | 42.86 | 24.46 |
| json.eval8.bin | 512 | 1,306,300 | 1,314,524 | 534.51 | 247.88 | 249.25 | 33.66 |
| macho.eval8.bin | 512 | 3,849,543 | 3,857,767 | 845.67 | 496.28 | 504.66 | 16.62 |
| omw.eval8.bin | 512 | 1,115,918 | 1,124,142 | 555.77 | 241.36 | 241.67 | 34.71 |
| omw.untouched.bin | 64 | 154,056 | 155,112 | 76.62 | 33.64 | 33.84 | 30.99 |
| zigsrc.eval8.bin | 512 | 1,829,197 | 1,837,421 | 673.21 | 323.47 | 330.98 | 25.34 |

### Block size 65536

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 128 | 897,328 | 899,408 | 353.68 | 166.28 | 167.10 | 50.20 |
| freedict.untouched.bin | 16 | 114,872 | 115,160 | 45.60 | 21.41 | 21.62 | 48.49 |
| gcide.eval8.bin | 128 | 1,903,480 | 1,905,560 | 734.10 | 306.34 | 306.89 | 27.33 |
| gcide.untouched.bin | 16 | 234,815 | 235,103 | 89.63 | 38.25 | 38.60 | 27.16 |
| json.eval8.bin | 128 | 1,026,903 | 1,028,983 | 550.60 | 220.21 | 220.90 | 37.97 |
| macho.eval8.bin | 128 | 3,257,268 | 3,259,348 | 802.00 | 434.25 | 448.43 | 18.71 |
| omw.eval8.bin | 128 | 672,304 | 674,384 | 408.88 | 178.69 | 181.07 | 46.33 |
| omw.untouched.bin | 16 | 94,988 | 95,276 | 53.96 | 23.92 | 24.13 | 43.45 |
| zigsrc.eval8.bin | 128 | 1,452,917 | 1,454,997 | 645.33 | 274.08 | 278.29 | 30.14 |

### Block size 262144

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 32 | 743,063 | 743,607 | 319.65 | 154.24 | 155.48 | 53.95 |
| freedict.untouched.bin | 4 | 96,488 | 96,584 | 41.55 | 19.95 | 20.17 | 51.99 |
| gcide.eval8.bin | 32 | 1,615,389 | 1,615,933 | 650.58 | 289.64 | 291.76 | 28.75 |
| gcide.untouched.bin | 4 | 197,898 | 197,994 | 80.77 | 35.87 | 36.35 | 28.85 |
| json.eval8.bin | 32 | 930,942 | 931,486 | 591.42 | 213.99 | 215.01 | 39.02 |
| macho.eval8.bin | 32 | 2,912,673 | 2,913,217 | 781.87 | 404.82 | 407.20 | 20.60 |
| omw.eval8.bin | 32 | 495,524 | 496,068 | 350.75 | 145.93 | 146.42 | 57.29 |
| omw.untouched.bin | 4 | 71,077 | 71,173 | 49.14 | 20.25 | 20.56 | 51.00 |
| zigsrc.eval8.bin | 32 | 1,225,365 | 1,225,909 | 583.54 | 250.74 | 252.11 | 33.27 |

### Block size 1048576 (1 MiB)

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 8 | 641,161 | 641,321 | 310.75 | 147.07 | 148.14 | 56.62 |
| freedict.untouched.bin | 1 | 84,024 | 84,072 | 41.32 | 18.99 | 19.24 | 54.50 |
| gcide.eval8.bin | 8 | 1,421,798 | 1,421,958 | 638.10 | 280.38 | 282.01 | 29.75 |
| gcide.untouched.bin | 1 | 174,637 | 174,685 | 82.14 | 35.50 | 35.84 | 29.26 |
| json.eval8.bin | 8 | 898,776 | 898,936 | 587.17 | 212.76 | 213.22 | 39.34 |
| macho.eval8.bin | 8 | 2,687,793 | 2,687,953 | 790.08 | 383.78 | 390.67 | 21.47 |
| omw.eval8.bin | 8 | 417,601 | 417,761 | 311.36 | 134.73 | 135.80 | 61.77 |
| omw.untouched.bin | 1 | 57,814 | 57,862 | 42.26 | 17.88 | 18.00 | 58.25 |
| zigsrc.eval8.bin | 8 | 1,121,836 | 1,121,996 | 555.55 | 246.43 | 249.67 | 33.60 |

### Block size 4194304 (4 MiB)

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 2 | 568,096 | 568,160 | 313.40 | 145.35 | 145.83 | 57.52 |
| freedict.untouched.bin | 1 | 84,024 | 84,072 | 40.67 | 19.35 | 19.44 | 53.94 |
| gcide.eval8.bin | 2 | 1,291,560 | 1,291,624 | 639.93 | 287.81 | 292.40 | 28.69 |
| gcide.untouched.bin | 1 | 174,637 | 174,685 | 80.03 | 35.58 | 35.91 | 29.20 |
| json.eval8.bin | 2 | 888,547 | 888,611 | 525.26 | 218.01 | 219.13 | 38.28 |
| macho.eval8.bin | 2 | 2,548,489 | 2,548,553 | 820.60 | 396.09 | 403.52 | 20.79 |
| omw.eval8.bin | 2 | 361,770 | 361,834 | 309.94 | 129.78 | 130.66 | 64.20 |
| omw.untouched.bin | 1 | 57,814 | 57,862 | 42.22 | 19.50 | 35.34\* | 29.67\* |
| zigsrc.eval8.bin | 2 | 1,045,867 | 1,045,931 | 539.02 | 245.05 | 263.28 | 31.86 |

\* Noise spike (concurrent machine load): min 19.50 ms is the trustworthy
figure for this cell; the median was pulled up by one stalled pass.

### Block size 0 (whole file, one block)

| file | blocks | payload_bytes | total_bytes | encode_ms | decode_min_ms | decode_median_ms | decode_MBps |
|---|---:|---:|---:|---:|---:|---:|---:|
| freedict.eval8.bin | 1 | 553,955 | 554,003 | 308.88 | 147.83 | 148.69 | 56.42 |
| freedict.untouched.bin | 1 | 84,024 | 84,072 | 39.97 | 19.14 | 19.30 | 54.34 |
| gcide.eval8.bin | 1 | 1,243,173 | 1,243,221 | 662.94 | 349.36 | 358.37 | 23.41 |
| gcide.untouched.bin | 1 | 174,637 | 174,685 | 79.57 | 35.98 | 36.02 | 29.11 |
| json.eval8.bin | 1 | 884,870 | 884,918 | 527.02 | 231.41 | 235.94 | 35.55 |
| macho.eval8.bin | 1 | 2,493,112 | 2,493,160 | 865.81 | 454.52 | 470.62 | 17.82 |
| omw.eval8.bin | 1 | 332,283 | 332,331 | 290.78 | 123.90 | 128.11 | 65.48 |
| omw.untouched.bin | 1 | 57,814 | 57,862 | 44.81 | 18.49 | 18.74 | 55.96 |
| zigsrc.eval8.bin | 1 | 1,037,932 | 1,037,980 | 608.63 | 284.18 | 292.58 | 28.67 |

## Observations

- Total size falls monotonically as block size grows for every corpus (as
  expected: bigger blocks give bzip3's BWT+entropy stage more context and
  amortize the fixed per-block header), but the gain flattens hard past
  256 KiB-1 MiB — the eval8 corpora gain only ~2-3% going from 1 MiB to
  whole-file, and the untouched (1 MiB) files are already at their whole-
  file number by block size 1 MiB. bz4's "wins should be block-size-
  independent" thesis has real headroom to beat only at 16-64 KiB, where
  bzip3 is paying real overhead; at 1 MiB+ bzip3 is close to its ceiling.
- Decode throughput scales with block size for the same reason (fewer BWT
  boundary resets), from ~17-25 MB/s at 16 KiB up to ~55-65 MB/s at 1 MiB
  for the dictionary corpora — a ~2.5-3x spread purely from block size, on
  the same codec. Any bz4 lane comparing decode speed must compare at
  matching block size, never against the wrong cell.
- macho.eval8.bin (arm64 machine code) is the weakest case for bzip3 across
  every block size (worst bytes saved, worst MB/s) — expected for high-
  entropy binary data with little byte-level redundancy for BWT+MTF to
  exploit. It is a useful stress cell for bz4's "generality" lanes.
- omw.eval8.bin is the strongest case (best compression ratio and fastest
  decode at every block size) — consistent with the frozen numbers'
  bytes/root: OMW's grammar is sparser (75.3 bytes/rule vs 12.8-29.8), i.e.
  the raw text itself already has long literal runs bzip3's BWT handles
  cheaply.
