# Structural/context separation screen

Status: **rejected as a next-wave storage candidate; retained as a complete
negative result**.  The code and inverse are useful reference machinery, but
the structural transforms lose to the raw zlib diagnostic on every corpus and
boundary in the fixed 256 KiB screen.  No final 8 MiB timing run was started.

The entropy backend in every row is `zlib-diagnostic`, a standard library
codec.  These rows are not a pure-Python entropy-decoder claim and do not
support a native performance claim.  `raw` is a diagnostic baseline only.

## Frozen protocol and provenance

* Input is field three of the pinned `projection.tsv`, concatenated in source
  order by `common.corpus_partition`.
* Training is exactly `[0, 1,048,576)` bytes.  The screen is exactly
  `[1,048,576, 1,310,720)` (256 KiB).  The final window `[1 MiB, 9 MiB)` and
  untouched holdout `[9 MiB, 10 MiB)` were not timed here.
* Blocks are independently framed at 16 KiB and 64 KiB.  Header, model,
  32-byte restart records, payload, raw fallback, transformed lengths, and
  CRCs are included in `complete_bytes`.
* `common.py` checks projection byte count/SHA-256 and full decoded-content
  byte count/SHA-256 before the worker sees the partition.  The screen rows
  carry those pinned hashes and the evaluation hash.

The three child processes were run serially through
`frontier_python/protocol/capture.py`.  The capture helper wrote stdout,
stderr, and status before any row parsing:

Wrapper command: `PYTHONPATH=. python3 src6/experiments/bzip4/frontier_python/structure/capture_screen.py`

| corpus | status | stdout SHA-256 | stderr bytes | elapsed field |
| --- | --- | --- | ---: | ---: |
| FreeDict `eng-spa` | 0 / ok | `40771af34e4b9722372e1e8c2c55d5d727a7dd55363f5bf2ca44cfb12a005943` | 0 | 2,039,565,542 ns |
| GCIDE | 0 / ok | `2d78342eae1c3b184360dfb9137ae2d14c5080fcbdc67389c0f0c3aa7cc4efab` | 0 | 2,344,597,708 ns |
| OMW Japanese | 0 / ok | `e29b0089ada5ec1d63ca2ef0074c0ab467ca5dc06bbd573c9ad74c6323857a3d` | 0 | 2,233,499,250 ns |

The elapsed field is only the wrapper's subprocess envelope.  It is not a
codec timing measurement.  Raw files are retained under
`evidence/screen-capture/structure-screen-*.{stdout.bin,stderr.bin,status.json}`;
the exact frame and derived row records are under `evidence/screen/`.

## Complete screen bytes

The bzip3 control values below are the lead's independently captured matched
screen controls.  Structural rows are complete framed bytes, not payload-only
ratios.

| corpus | boundary | bzip3 control | raw zlib diagnostic | shape | byteclass | templates |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FreeDict | 16 KiB | 36,428 | 36,141 | 56,890 | 66,397 | 58,069 |
| FreeDict | 64 KiB | 27,239 | 30,446 | 47,675 | 51,161 | 48,540 |
| GCIDE | 16 KiB | 72,885 | 77,614 | 116,166 | 123,121 | 118,981 |
| GCIDE | 64 KiB | 58,700 | 68,909 | 102,744 | 106,841 | 104,540 |
| OMW Japanese | 16 KiB | 36,163 | 37,449 | 42,984 | 52,659 | 44,552 |
| OMW Japanese | 64 KiB | 22,279 | 27,280 | 30,033 | 34,787 | 30,735 |

Relative to raw zlib, the structural penalties range from 10.09% (OMW/64K,
shape) to 87.82% (FreeDict/64K, byteclass).  Relative to matched bzip3,
the best structural row is OMW/16K shape at +18.86%; FreeDict/16K raw is
the only raw-zlib row slightly below bzip3 (-0.79%), and it is not a new
structural transform.

## Accounting and ablations

At FreeDict/16 KiB the fixed charged bytes are 564 for raw (52-byte header plus
16 directory records), 832 for shape/byteclass (the same directory plus a
268-byte model), and 1,810 for templates (a 1,246-byte model).  At 64 KiB
those fixed totals are 180, 448, and 1,426 bytes.  The corresponding
transformed payload sizes at 16 KiB are 262,144 / 481,010 / 360,768 / 406,542
for raw / shape / byteclass / templates; the complete totals show that zlib
cannot recover the selector/descriptor cost.

The variants are deliberate ablations, not fixture tags:

* `shape` uses maximal deterministic byte-class runs, a compact
  `(class,length)` event stream, and exact bytes grouped into class lanes.
* `byteclass` keeps one three-bit selector for every byte and class-grouped
  value lanes.  It is a lower-level control exposing selector cost.
* `templates` trains at most 96 repeated descriptor sequences from the first
  60,000 descriptors of the first MiB.  The model contains only class/length
  descriptors, never held-out value bytes; each model byte is charged.
* `raw` passes the input bytes directly to zlib and has no model.  It bounds
  the backend and is not presented as the proposed codec.

The break-even field in every derived record is
`fixed_bytes / (1 - payload_bytes/raw_bytes)` when the payload ratio is below
one.  For example, FreeDict/16K gives 653 raw bytes for raw, 1,058 for shape,
1,109 for byteclass, and 2,305 for templates.  This explicitly prevents the
256 KiB screen from hiding model cost; the model would have to earn its way
back on the 8 MiB window, but its payload is already worse than raw there on
the observed screen.

## Failure ledger and limits

| observation | consequence |
| --- | --- |
| Grouping bytes by class removes cross-class phrase adjacency that raw zlib exploits. | `shape` is rejected as a general next-byte model. |
| Three selector bits per byte plus grouped lanes are expensive. | `byteclass` is rejected; it is an intentionally explicit negative control. |
| Repeated descriptor templates save some events but add a charged model and still lose value locality. | `templates` is rejected for the next wave. |
| Raw zlib is occasionally close to or below matched bzip3 on this small screen. | This is only a standard-codec diagnostic bound, not a novel decoder result. |
| No source values, Unicode normalization, markup parsing, case folding, or whitespace omission occurs. | Exact bytes, including invalid UTF-8 and metadata, roundtrip. |
| No final timing was run. | Startup, decode latency, and native performance remain unclaimed. |

`test_structure.py` exercises all variants at 1-byte, odd, 16 KiB, and 64 KiB
boundaries; every block is independently decoded; empty input and arbitrary
high/control bytes are covered; header/model/directory/payload corruption,
truncation, unknown variant, selector tails, and resource bounds are rejected.

The decoder's logical work is `raw_bytes + transformed_bytes`, excluding Python
allocator overhead.  A cold independent block still parses the header, model,
and complete directory: the screen records expose this as
`cold_block_metadata_bytes` (for example 832 B for shape/byteclass at 16 KiB,
1,810 B for templates).  Transform construction and zlib hold both the raw
block and transformed/compressed buffers; a future native implementation must
measure actual peak scratch rather than infer it from these logical counters.
