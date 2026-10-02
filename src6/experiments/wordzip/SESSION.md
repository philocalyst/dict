# Reusable WSB2 reader experiment

`sbwt_session.cpp` adds a prepared reader without changing any frozen encoder
or the wire format. It includes the exact frozen `sbwt.cpp` implementation as
a dependency. It accepts primary, capacity-search, Unicode-search, and surface
binding frames. This is a Linux/POSIX prototype, not production LEX6 integration.

```sh
make -C src6/experiments/wordzip sbwt-session test-session
src6/experiments/wordzip/sbwt-session decode FRAME WHOLE_OUTPUT
src6/experiments/wordzip/sbwt-session decode FRAME BLOCK_OUTPUT --index 7
src6/experiments/wordzip/sbwt-session bench-reader FRAME REPORT.json --measure 0
```

The reader maps the file read-only after checking its 576 MiB file bound. It
copies and validates only metadata during preparation, decompresses the fully
delivered models, checks every restart record, and then discards the original
grammar edges and string objects. It retains a flat byte pool, expansion
offsets/lengths in the required symbol order, rANS tables, and the validated
directory. A requested block uses one directory lookup and only that payload's
span. It reconstructs no other block. Model preparation and sorting happen
once, outside subsequent block calls.

`PreparedFrame` copies share immutable prepared state and mapping ownership.
Each decode uses local scratch and returns independently owned bytes. Returned
directory records are values. Decoded bytes stay valid after the last reader
and mapping are destroyed. Callers must keep the mapped file's contents and
size unchanged while any reader exists; concurrent file truncation is outside
this contract. Replacing/unlinking a pathname does not transfer ownership of
the mapped inode. CRC32 is accidental-corruption detection, not authentication.

The fixed `bench-reader` workload contains exactly 256 fresh block decodes,
cycling first, middle, and last records. It does not cache decoded blocks.
Every result's CRC contributes to an externally emitted checksum. Preparation
and the sum of block decode times are separate; checksum consumption occurs
outside the per-call timer. Timing is disabled by default. Only run measured
captures after the coordinating quiet gate:

```sh
src6/experiments/wordzip/sbwt-session bench-reader FRAME REPORT.json \
  --measure 1 --quiet-gate WORDZIP-READER-QUIET
```

Report fields include complete frame bytes, metadata bytes, prepared model
bytes charging vector capacities and container objects, logical live model
bytes, the separate 1,024-byte fixed CRC table, decoded bytes, and distinct
logical input bytes requested by this exact workload. Mapped virtual address
space is the complete frame. `MADV_RANDOM` requests a paging policy but does
not establish physical disk bytes, OS cache state, or absence of read-ahead.
Peak RSS includes process/runtime and launcher effects; model byte accounting
is not an allocator-overhead proof.

The timing-disabled prior Japanese development frame example has 536,324
complete bytes, 63,704 metadata bytes, 528,768 prepared capacity bytes, and
484,161 logical live model bytes. The fixed workload requests 75,635 distinct
logical input bytes and reconstructs 16,777,216 output bytes over its repeated
256 accesses. This is an accounting example, not a latency ranking or a
claim that those are exact physical I/O bytes.

Six focused tests pass: whole and every-restart parity for plain/binding frames,
multiple scripts/random bytes, unselected corrupted payload isolation,
copy/move/output ownership, consumed batches with timing disabled, 512 fixed
mutations and truncations, resealed directory checks, and oversized sparse-file
rejection. A corrupted unselected payload does not prevent decoding an intact
selected block; whole verification still fails. The experiment makes no claim
about end-to-end dictionary predicates, cold disk access, or comparison with a
retained-state bzip3 reader until those controls are captured independently.
