# Frozen helper API

The common import root is `src6/experiments/bzip4/frontier_python`.

```python
from common import corpus_partition, load_corpus
from protocol import bzip3_decode, bzip3_decode_block, bzip3_encode_blocks

training, screen = corpus_partition("gcide-054", "screen")
frame = bzip3_encode_blocks(screen, 16 * 1024)
assert bzip3_decode(frame) == screen
assert bzip3_decode_block(frame, 0) == screen[:16 * 1024]
```

`corpus_partition` always returns exactly 1 MiB of training bytes and the
named evaluation range.  The accepted lanes are:

| lane | training | evaluation |
| --- | --- | --- |
| `screen` | `[0, 1 MiB)` | `[1 MiB, 1 MiB + 256 KiB)` |
| `final` | `[0, 1 MiB)` | `[1 MiB, 9 MiB)` |
| `untouched` | `[0, 1 MiB)` | `[9 MiB, 10 MiB)` |

The native control frame returned by `bzip3_encode_blocks` is complete: its
length is `32 + 16 * block_count + sum(encoded_block_lengths)`.  Its header
and directory are validated by `open_frame`; each directory record includes a
decoded CRC-32.  `bzip3_decode` uses one retained decoder-only state across
blocks, while `bzip3_decode_block` creates a fresh decoder-only state for the
requested restart point.  `bzip3_encode_blocks` uses an encoder-only state.
The lower-level `Bzip3Session` retains the historical `purpose="both"`
default for matched controls; pass `purpose="encode"` or `purpose="decode"`
to charge only the state needed by a one-sided phase.

The aliases `protocol.native_bzip3.encode`, `decode`, and `decode_block` are
provided only for control smoke code.  They do not make native bzip3 a
candidate decoder.

`protocol.capture.run_and_save` is the required external-process entry point.
It writes raw stdout, raw stderr, and a status JSON before any parser can run,
rejects an existing capture stem, and `serial_runs` preserves fixed order with
no retry.

Before a final serial matrix, `protocol.capture.snapshot_sources` can copy an
explicit source list into a new read-only directory and write hash/byte
records.  It refuses an existing destination and is intended to freeze the
accepted candidate revision before any later live-tree edits.
`verify_snapshot_sources` checks both the live sources and retained copies for
post-matrix drift.
