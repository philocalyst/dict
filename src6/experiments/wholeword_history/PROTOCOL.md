# Whole-block word grammar restart study (development only)

This study forks only the admission limits of the faithful `m_reference.zig`
Lane A best seed → Lane M learner → unchanged native v4 encoder. The original
learner and native sources are imported unchanged. Three private helper copies
are byte-identical for Zig's module-path rules. The complete native v4
frame is the compressed artifact. `P6F1` is a private diagnostic graph and is
excluded from archive size. The frame is independently decodable from its own
bytes; there is no external learned model.

## Source audit and preregistration

The original CLI rejects block sizes above 65,536 bytes. `grammar2.zig` and
`m_lexicon.zig` store sequence and symbol offsets as `u32`; native v4's block
raw length, item count, definition count and stream sizes are `u32` varints.
At the 32 MiB source cap, a single learned block fits these widths. The
encoder closes a payload only at a parse-block boundary when `hoist=0`, so
the 32 MiB policy creates one payload per nonempty source. The decoder's
payload `Past` is recreated per job. It has a 4,096-token ring with a
default reach of about 1,023 tokens: this removes 64 KiB resets, but is not
unlimited history. Grammar rules and native model remain shared in either
policy. Larger reparse DP scratch and 20 learner rounds may exhaust the same
4 GiB live-allocation budget; failures are reported as failures.

Fixed candidates, before any result: `block=65536` and `block=33554432`,
both `a-best 20 iterations triples=1 hoist=0`, identical native class
search and all other policies. The only changed source constants are the
private fork's block and input admission ceilings (both 32 MiB). Compare
complete v4 frame bytes, including header, directory, dictionary and payload,
to a fresh complete single-block bzip3 control on exactly matching bytes.
The first six sources are the frozen UTF-8 safe at-most-1 MiB development
prefixes in `/workspace/scratch/books2026-dev/manifest.json` (SHA256
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`).
Shorter books use their entire development text. No reserved sources are read.

Each trial records the source, source SHA256, source and binary hashes, CLI
arguments, exact complete frame SHA256/bytes, JSON byte ledger and live
allocator peak. A separate process runs `whole_reader verify FRAME SOURCE`,
which structurally admits the frame before invoking the unchanged native
decoder, compares the decoded output byte-for-byte with the pinned oracle,
and reports CRC32. `decode` and `inspect` are separate reader modes. Tests
cover all three modes, bad frame length, extra trailer, oversized declared
output, and unequal oracle. The reader's structural bounds apply only to
this research lane and do not alter the existing v4 API.

Expansion to whole development books requires exact prefix admission and a
meaningful complete-byte signal. Concurrent development clocks are diagnostic
only; allocator peaks count live requested bytes, not total process RSS.
