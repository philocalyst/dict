# Native bzip3 control protocol

The native lane is a comparison control only.  Candidate workers must not
reuse its C implementation as a candidate decoder or hide candidate model
bytes in the control.

## Input and partitions

Each run starts from one of the three pinned projection files.  The common
loader verifies the projection byte count and SHA-256, decodes only field 3,
concatenates rows in source order, and verifies the decoded byte count and
SHA-256.  The training prefix is exactly `[0, 1 MiB)`.  The screen is
`[1 MiB, 1 MiB + 256 KiB)`, the final lane is `[1 MiB, 9 MiB)`, and the
untouched linguistic holdout is `[9 MiB, 10 MiB)`.

## Complete frame

Native bzip3 receives independent raw blocks at the requested boundary.  The
Python control stores the returned native bytes in a complete restartable
frame:

* 32-byte little-endian header;
* 16-byte directory record per block (`payload offset`, encoded length, raw
  length, decoded CRC-32);
* the actual bzip3 block bytes, without re-encoding or truncation.

The header and directory CRC are checked before decoding.  libbz3's own block
CRC is checked by the native decoder, and the directory CRC is checked again
after every decode.  This gives both a retained-state whole-stream decode and
fresh-state random-block checks without relying on output length alone.

## State, memory, and measurements

`Bzip3Session` accepts `purpose="encode"`, `"decode"`, or the historical
default `"both"`.  It retains only the requested native state(s) plus one
mutable work buffer.  The conservative scratch record charges
`state_count * bz3_min_memory(max(block_bytes, 65 KiB)) + bz3_bound(state_size) + 1 MiB`
(`1 MiB` is the pinned libsais allowance used by the earlier Zig control).
Historical `bzip3_control` remains `both` and reports two states; final native
encode/decode phases use one state each and record that purpose explicitly.
The control reports startup, retained encode/decode, and one deterministic
middle-block random decode only when its caller explicitly opts into timing.
Screening calls leave clocks disabled; the coordinating root owns the final
quiet gate.

## Native build isolation

`protocol/builder.py` checks the pinned vendor source hashes from the prior
round-2 ledger and builds/reuses `protocol/vendor/libbz3.dylib` (or the
platform equivalent).  The compiler command, source hashes, output hash, and
raw compiler result are written to `protocol/vendor/build-manifest.json`.
No production build directory or shared `vendor/` artifact is modified.

## Raw process evidence

External measurement commands use `protocol.capture.run_and_save`.  It writes
the exact stdout bytes, stderr bytes, and process-status JSON before parsing;
existing stems are rejected and scheduled commands execute serially without
retries.  The native ctypes call itself has no child stdout to capture; its
frame/result record includes all input, frame, checksum, and scratch hashes.

The screening control reproduced the prior complete-frame totals exactly:

| corpus | 16 KiB total | 64 KiB total |
| --- | ---: | ---: |
| FreeDict `freedict-eng-spa` | 1,189,002 | 899,408 |
| GCIDE `gcide-054` | 2,362,319 | 1,905,560 |
| OMW Japanese `omw-ja-20` | 1,124,142 | 674,384 |

These are size/correctness checks only; no Python candidate is claimed to beat
the native control, and final three-sample timing remains gated by the root.

The non-timed screen/untouched run is retained under `raw/` from
`size_controls.py`; it checked retained whole-lane decode and every restart
block for all 3 corpora × 2 lanes × 2 boundaries.  Its child status was zero,
stderr was empty, and the exact stdout hash is recorded in the sibling status
JSON.  The status envelope may retain process wall duration for provenance;
the codec itself was called with `measure=False` and emitted no timing fields.

## Gated final capture

`final_serial.py` is the only final-matrix entry point.  First inspect the
planned jobs without doing work:

```text
python3 evidence/controls/final_serial.py --prepare
```

The runner refuses an existing output directory and requires an explicit
`--quiet-lane` gate on `--run`.  Before the first child it copies the exact
candidate, common-loader, framing, native-control, builder, capture, grammar,
and harness files to a read-only source snapshot (package `__init__.py` files
receive explicit qualified snapshot names).  Each child loads a pinned corpus,
trains A/E on `[0, 1 MiB)`, or runs the explicitly input-fit
`grammar_input` variant with explicit grammar options (defaults are `4096`
rules/`10` passes), then encodes its
selected final or untouched lane once and saves the complete frame.  BWT-F is
accepted automatically when the independent BWT module exposes that API (and
can be requested explicitly with `--variants F`).  The grammar input-fit encoder sees the evaluation lane by design; its discovery
work is included in the complete encode clock and is never reported as a
held-out training result.  Every child performs one excluded full-decode
warmup (timed as `first_full_decode_ns` for lazy-startup accounting), three
retained whole-frame decode samples, and fresh first/middle-block restart
checks.  Child max RSS is labeled as whole-process peak (corpus load
through decode); analytic decoder initialization/native scratch is reported
separately, or marked unavailable rather than guessed.  The parent stores raw
stdout/stderr/status before parsing and verifies the source hashes again after
the serial matrix.  The `symbol_bwt` adapter is also input-fit: it trains its
grammar-root/event model on the selected lane, stores the complete model in
the frame, and uses the same decode/restart protocol.  Grammar settings are explicit parent/child options
(`--grammar-max-rules`, `--grammar-max-passes`, and
`--grammar-pair-policy`); defaults remain `4096`, `10`, and
`overlap_greedy`, and every job records the values.  The native-only six-job
size/control subset is the same harness with `--variants native --lanes final`;
it does not turn the ctypes library into a candidate implementation.  The
final snapshot also includes the pinned bzip3 source files and retained build
manifest; the isolated library path/size/SHA-256 is verified before and after
the matrix and the run aborts if that artifact changes.
