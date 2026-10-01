# Protocol checkpoint (screening-ready)

Available now for all three workers:

* `common.load_corpus(name) -> bytes`: verifies projection bytes/SHA-256 and
  decoded bytes/SHA-256 before returning field-three concatenation.
* `common.corpus_partition(name, lane) -> (training, evaluation)` with exact
  `screen` (1 MiB + 256 KiB), `final` (8 MiB), and `untouched` (1 MiB) lanes.
* `protocol.bzip3_encode_blocks(data, block_bytes) -> bytes`: actual native
  libbz3 block bytes inside a complete `32 + 16 * block_count + payload` frame.
* `protocol.bzip3_decode(frame) -> bytes`: retained-state decode with native
  and directory CRC checks; `bzip3_decode_block(frame, index)` is restartable.
* `protocol.bzip3_control(data, block_bytes, measure=False)`: exact control
  roundtrip, deterministic middle-block random check, startup/encode/decode/
  random clocks only when explicitly requested, and conservative scratch.

The isolated native path is
`src6/experiments/bzip4/frontier_python/protocol/vendor/libbz3.dylib` on this
host.  `protocol.builder.build_shared_library()` verifies the pinned vendor
source hashes and reuses only a manifest-matched output; the build command is
explicitly recorded in `vendor/build-manifest.json`.  `protocol.capture` owns
raw stdout/stderr/status-before-parse and deterministic serial process runs.
`protocol.control_library_record()` returns the retained object's size and
SHA-256 for control ledgers.

The six complete baseline totals reproduced by the control are:

| corpus | 16 KiB | 64 KiB |
| --- | ---: | ---: |
| `freedict-eng-spa` | 1,189,002 | 899,408 |
| `gcide-054` | 2,362,319 | 1,905,560 |
| `omw-ja-20` | 1,124,142 | 674,384 |

No 18-run duplicate matrix or final timing was run; timings remain under the
root's explicit gate.
