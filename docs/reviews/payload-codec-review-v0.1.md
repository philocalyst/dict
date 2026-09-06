# Payload codec integration review v0.1

## Resolution update — 6 September 2026

The findings below record the original minor-2 review, not the current state.
Minor 3 adds explicit decoder state sizes, with a 300 KiB definition / 512 KiB
state regression. Encoded block ownership now has cleanup until transfer;
short probes are zero initialized; invalid codec configuration returns errors.
Definition lookup binary-searches the atom directory and accepts a decode
allocator and memory ceiling through `Reader.Options`. Repaired-checksum codec
corruption and allocator failure are tested, and the benchmark distinguishes
whole raw/bzip3 snapshots from its low-level codec experiment.

These repairs resolve the concrete findings. They do not establish the full
performance rubric below: representative cold p99, concurrent decoder budgets,
cache behavior, and matched legacy comparisons remain separate release gates.

Reviewed surface: `src/lexicon.zig` minor-2 payload records, `src/codec.zig`,
`src/codec/raw.zig`, `src/codec/bzip3.zig`, the vendored libbz3 API, and
`docs/format-v0.1.md`. The Debug and ReleaseSafe test suites pass, and
`zig fmt --check src build.zig` passes. Passing those checks does not clear the
format and adversarial cases below.

## Findings, ordered by severity

### P0 — minor-2 records do not identify the bzip3 decoder state size

`Writer.Options.codec_options.block_size` is public and can be set above the
default 256 KiB. `encodePayload` uses that state size, and a definition larger
than the 65,536-byte placement target is encoded as one bzip3 block. The minor-2
block record stores the codec tag and logical length, but no bzip3 state-size
class. `Reader.definition` then constructs a decoder with
`bzip3.default_block_size` (256 KiB). Upstream explicitly requires the decoder
state's block size to be at least the block's size.

Reproduction path:

1. Create a repetitive definition of about 300 KiB.
2. Build with `payload_codec = .bzip3` and
   `codec_options.block_size = 512 * 1024`.
3. The writer retains a compressed bzip3 block because it is smaller than raw.
4. `Reader.open` accepts the snapshot: validation only caps logical bzip3
   lengths at the upstream 511 MiB maximum.
5. `Reader.definition` returns `Error.CorruptSection`, because the fixed 256 KiB
   decoder state rejects the valid 300 KiB block.

This violates the documented codec-agnostic round-trip contract and the plan's
requirement that a block record carry its permitted state-size class. It also
means a caller cannot safely choose the proposed 512 KiB, 1 MiB, or 4 MiB
profiles. The fix must either put a canonical state-size class/version in every
bzip3 block record and use it during decode, or reject every non-default state
size at writer construction. The former is the correct format design; changing
the field requires a new minor version or an explicit compatibility rule.

### P1 — an allocation failure can leak a successfully encoded block

In `Writer.encodePayload`, a codec-owned `encoded` block is created and then
passed to `encoded_blocks.append`. If that append allocation fails, the error
returns before the block is in the deferred ownership list, so its allocation
is leaked. This is reachable with a failing allocator and affects both raw and
bzip3 builds. Add an `errdefer encoded.deinit()` until ownership is transferred,
or use an ownership-transfer helper that makes the transition explicit.

The ordinary testing allocator does not expose this unless an allocation-failure
test is added at the precise append boundary. A 10/10 implementation needs an
errdefer/failing-allocator regression test and a leak-free error path for every
codec-owned allocation.

### P1 — short malformed bzip3 probes read an undefined byte

`Decoder.decodeBlock` declares `var probe: [9]u8 = undefined`, copies an encoded
block shorter than nine bytes into it, and passes all nine bytes to
`bz3_orig_size_sufficient_for_decode`. The upstream helper intentionally reads
the ninth byte as the model field. For an eight-byte malformed block, that byte
is undefined stack data. The final decoder normally rejects the block, but the
classification and error path become nondeterministic and uninitialized data
crosses the C boundary. Initialize the probe to zero before copying, then keep
the existing length checks. Add a deterministic truncation test that exercises
lengths 0 through 8 under a memory sanitizer or equivalent undefined-value
checker.

### P2 — invalid bzip3 configuration is silently converted to raw output

The writer catches `InvalidBlockSize`, alongside genuine resource-limit errors,
and silently retries raw encoding. For example, selecting bzip3 with
`block_size = 64 * 1024` (below libbz3's 65 KiB minimum) succeeds and emits a
raw snapshot. The documentation promises raw fallback when compression is not
useful or a resource limit is reached; an invalid codec configuration should be
reported to the caller. Keep fallback for a narrowly defined resource error set
and return invalid configuration errors. Test invalid block size, invalid
limits, and an intentional resource ceiling separately.

### P2 — definition reads scan the entire atom directory and allocate through a global allocator

`Reader.definition` linearly scans every atom until it finds an ID. This is
correct for the current small prototype, but random definition lookup is O(N)
and does not meet the plan's block-aware atom-directory goal. The same method
decodes a complete compressed block into `std.heap.page_allocator` even when the
caller requests a small slice. That prevents caller-owned memory budgeting and
can cause avoidable page allocation churn under repeated adversarial reads.

This is not a correctness defect in the current stage: exact and prefix key
lookups remain payload-cold. Before claiming the fast random-definition target,
add a sorted atom restart/index structure or a compact ID-to-atom index, expose
decoder limits/allocator ownership, and measure decoded bytes and allocations.

### P2 — lazy bzip3 corruption behavior is under-tested and underspecified

`Reader.open` validates the compressed-byte checksum and structural bounds but
does not decode every bzip3 block. That is compatible with the payload-cold
lookup requirement, but a malformed block whose checksum is repaired will open
successfully and fail only at `definition`. The existing integration test flips
payload bytes and therefore stops at `Error.CorruptChecksum`; it does not cover
the codec failure path through `Reader.definition`.

Keep validation lazy, but document it explicitly and add a test that mutates a
compressed block, recomputes both section and root checksums, opens the reader,
and verifies that definition access returns a bounded corruption error without a
crash or leak. Also test truncated bzip blocks and incorrect logical lengths.

### P3 — benchmark documentation still describes the snapshot as raw-only

`docs/benchmark-methodology.md` says that the snapshot “is still the raw
prototype,” while minor 2 now emits codec-tagged payload blocks and the main
README describes bzip3-backed snapshots. This can lead to a false benchmark
interpretation. Update the harness documentation so raw and bzip3 snapshot
profiles are named separately, and retain the low-level codec comparison as its
own experiment.

## 10/10 acceptance rubric

The integration reaches 10/10 only when every item below is demonstrated by
tests or a reproducible benchmark artifact:

| Area | Required evidence |
| --- | --- |
| Wire fidelity | Every emitted bzip3 block records enough codec identity, API revision, and decoder state-size information for another supported reader to decode it. Custom legal block-size profiles round-trip byte-for-byte. |
| Compatibility | Minor 0 and 1 raw snapshots still open unchanged; minor 2 raw snapshots remain deterministic; unsupported codec/state combinations fail with a precise error. |
| Corruption | Invalid tags, reserved bytes, offsets, lengths, overlap, checksum, truncated headers, malformed bzip headers, wrong original sizes, and repaired-checksum codec failures all return errors without undefined behavior. |
| Resource safety | Failing allocators prove no leaks on every encode/build/decode path. Declared compressed, logical, scratch, state, output, and aggregate memory budgets are checked before allocation. |
| Ownership | Reader allocations use an explicit caller or reader-owned allocator with documented lifetime. Repeated random definition reads have bounded resident memory. |
| Lookup performance | Exact/prefix lookups decode zero payload bytes and inspect bounded key records. Random definition lookup uses an indexed atom directory or has a measured, documented scan budget. |
| Compression behavior | Raw fallback occurs only for measured expansion or declared resource limits; invalid options are errors. Raw and bzip3 have differential byte-equivalence tests across empty, Unicode, binary, repetitive, incompressible, boundary, and oversized inputs. |
| Interoperability | Independent blocks are differentially checked against the pinned upstream low-level API, with the release/commit and LGPL notices recorded. |
| Measurement | Raw, bzip3, and any alternate profiles report complete snapshot bytes, build time, p50/p95/p99 lookup time, decoded bytes, payload reads, peak memory, and block counts on the same fixture and answers. |
| Documentation | Format tables, codec options, lazy verification semantics, fallback policy, benchmark methodology, and third-party licensing agree exactly with the implementation. |

Original review score: **not 10/10**. The P0 state-size omission must be resolved before
minor 2 can be treated as a complete, portable codec format; the P1 findings
must be fixed before adversarial or long-lived use.
