# Snapshot format v0.1 (minor 4)

This document describes the format emitted and accepted by the current `src/lexicon.zig` implementation. It is an in-memory snapshot format: `Writer.build` creates a byte slice and `Reader.open` validates a byte slice. There is no file container, encryption, signature, or streaming I/O layer in this snapshot format. Minor 3 embeds independently addressable raw or pinned-upstream-bzip3 payload blocks through the reusable codec layer in [`src/codec.zig`](../src/codec.zig), including the bzip3 state size needed for portable decoding. Minor 4 adds adaptive frame-of-reference postings while retaining the exact raw fallback layout. All multi-byte integers are little-endian and all offsets are byte offsets within the snapshot or section explicitly stated below. Readers decode fields explicitly; they never reinterpret on-wire bytes as Zig structs or pointers.

## Container

The snapshot starts with a 64-byte header, followed by three 8-byte-aligned sections, followed by an 8-byte-aligned directory. The directory ends at the end of the snapshot. There is no trailing data.

### Header (64 bytes)

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 8 | bytes | ASCII `LEXSNAP\0` |
| 8 | 2 | `u16` | major format version, currently `1` |
| 10 | 2 | `u16` | minor format version, emitted as `4`; readers also accept `0`, `1`, `2`, and `3` |
| 12 | 4 | `u32` | feature flags; currently `0` |
| 16 | 8 | `u64` | total snapshot length |
| 24 | 8 | `u64` | directory offset |
| 32 | 8 | `u64` | directory length |
| 40 | 8 | `u64` | root FNV-1a-64 checksum |
| 48 | 8 | `u64` | format identifier `0x4c455849434f4e31` |
| 56 | 8 | `u64` | reserved; currently `0` |

The root checksum covers the complete snapshot, with header bytes 40–47 treated as eight zero bytes while hashing. It is FNV-1a-64, a deterministic non-cryptographic corruption check. It does not authenticate a snapshot or establish trust; use an authenticated channel or a signature at a higher layer when that is required.

### Directory entry (48 bytes)

The current directory has three required entries, one for each section, in emitted order. Unknown optional sections are not emitted by this prototype; an unknown required section is rejected.

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 4 | `u32` | section kind: `1` keys, `2` postings, `3` payload |
| 4 | 2 | `u16` | section version, currently `1` |
| 6 | 2 | `u16` | flags; required sections use `1` |
| 8 | 8 | `u64` | section offset, 8-byte aligned |
| 16 | 8 | `u64` | stored byte length |
| 24 | 8 | `u64` | logical byte length; must equal stored length |
| 32 | 8 | `u64` | section item count |
| 40 | 8 | `u64` | section FNV-1a-64 checksum |

The reader checks integer overflow, alignment, truncation, section overlap, section bounds, duplicate/missing required sections, item counts, and section checksums before exposing a reader.

## Keys section (kind 1)

The first 16 bytes are:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 4 | `u32` | number of distinct keys |
| 4 | 2 | `u16` | front-coding restart interval, currently `8` |
| 6 | 2 | `u16` | reserved; `0` |
| 8 | 8 | `u64` | minor 0: reserved `0`; minor 1–4: byte offset of the restart directory within the keys section |

For minor 0, each key record follows at offset 16 and the section ends after the final record. For minor 1–4, the key record stream ends at the offset in the header and a restart directory follows it. Keys are sorted by unsigned byte lexicographic order. Every eighth key is a restart record:

- marker `0` (`u8`), full key length (`u32`), full key bytes;
- marker `1` (`u8`) otherwise, common-prefix length with the previous key (`u16`), suffix length (`u32`), suffix bytes.

Both forms then contain a posting start (`u64`) and posting count (`u64`). The posting start is an index into the posting stream, independent of its raw or packed physical representation. Keys are non-empty and valid UTF-8. Prefix lookup uses literal `startsWith` byte semantics.

### Minor 1–4 restart directory

The restart directory begins at the header's offset and has an eight-byte header followed by one 16-byte entry per restart record:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 4 | `u32` | restart entry count |
| 4 | 4 | `u32` | reserved; `0` |
| 8 | 4 | `u32` | key ordinal; exactly `restart_index * interval` |
| 12 | 4 | `u32` | reserved; `0` |
| 16 | 8 | `u64` | byte offset of the restart record in this section |

The table occupies the remainder of the keys section exactly. The reader checks its count, ordinals, monotonic offsets, record markers and each offset against the decoded stream before exposing the snapshot. Exact lookup and literal prefix lookup binary-search restart records and decode only the selected interval plus the result range; they never read payload bytes. `Reader.keyRecordsExamined()` reports the number of key records decoded by lookups, allowing a benchmark or differential test to compare actual work with a reference scan without making a timing claim.

## Postings section (kind 2)

For minor 0–3, offset 0 is the total posting count (`u64`), followed by that many record IDs as consecutive `u64` values. Minor 4 keeps this exact representation for raw fallback. In the minor-4 adaptive representation, offset 0 stores the count with bit 63 set; the remaining 63 bits are the posting count. The 16-byte extension at offset 8 is:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 8 | 8 | `u64` | global minimum record ID (`min`) |
| 16 | 4 | `u32` | packed data byte length |
| 20 | 1 | `u8` | fixed offset width in bits, `0..64` |
| 21 | 1 | `u8` | meaningful bits in the final packed byte (`0..7`; `0` means full byte) |
| 22 | 1 | `u8` | flags; currently `0` |
| 23 | 1 | `u8` | reserved; must be `0` |

Packed data begins at offset 24. Entry `i` is the fixed-width little-endian bit field at bit offset `i * width`, and its ID is `min + offset`. Width zero is valid and represents repeated `min` values; for an empty stream the minimum and packed data are zero. The packed length, tail-bit count, all reserved bits, and every unused tail bit are checked strictly. A scalar read computes its bit address directly and loads at most nine bytes, so random access remains O(1) even for unaligned 64-bit fields. The adaptive writer emits this form only when its complete header plus packed data is strictly smaller than the eight-byte count plus eight bytes per ID raw form; `.raw` forces the legacy stream. IDs remain arbitrary unsigned 64-bit values and are never renumbered.

A key's posting range is the half-open range beginning at its key-section posting start and containing its posting count IDs. IDs within a key's range are sorted ascending because records are canonically sorted by key and then ID. The current format has one posting per record, so the total posting count equals the payload atom count.

## Payload section (kind 3)

The 16-byte payload header is:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 4 | `u32` | atom count |
| 4 | 4 | `u32` | block count |
| 8 | 4 | `u32` | configured raw block target, currently `65,536` |
| 12 | 4 | `u32` | reserved; `0` |

Each atom directory record is 32 bytes, beginning at offset 16:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 8 | `u64` | record ID |
| 8 | 4 | `u32` | block index |
| 12 | 4 | `u32` | reserved; `0` |
| 16 | 8 | `u64` | byte offset within that block |
| 24 | 8 | `u64` | atom byte length |

Atoms are sorted by ID. Equal definition byte sequences are stored once and referenced by every matching record's atom directory entry. Definitions are sorted by byte sequence before block placement, so build output is deterministic.

For minor 0 and 1, the block table follows the atom table with 32 bytes per
block and all stored bytes are raw. Minor 2 uses 40 bytes per block. Minor 3
uses 48 bytes per block:

| Offset | Size | Type | Meaning |
|---:|---:|---|---|
| 0 | 8 | `u64` | absolute offset within the payload section |
| 8 | 8 | `u64` | stored block length |
| 16 | 8 | `u64` | logical/uncompressed block length |
| 24 | 8 | `u64` | stored block FNV-1a-64 checksum |
| 32 | 1 | `u8` | codec kind: `0` raw, `1` bzip3 |
| 33 | 7 | bytes | reserved; must be zero |
| 40 | 8 | `u64` | bzip3 state block size; raw blocks must store `0` |

Stored block bytes follow the block table contiguously. Normal logical blocks are
packed up to the 65,536-byte target. Empty definitions receive an explicit
zero-length block. A definition larger than the target receives a dedicated
oversized block and is not split. Minor 2 records the actual codec per block;
minor 3 additionally records the bzip3 state block size used by that block. A
bzip3 state size is within the upstream legal range and is at least the
logical block length; the reader uses this exact value when constructing its
decoder. The writer defaults to raw and only retains bzip3 when it is strictly
smaller, falling back to raw if compression expands the block or a configured
bzip3 resource limit is reached. Invalid codec configuration is reported as an
error. The logical atom offsets and lengths always refer to the uncompressed
block, so
codec choice cannot change lexical meaning. Each bzip3 block is an upstream
independent block and carries no standalone frame header; its original length
comes from the block table.

`Reader.definition` verifies a block checksum during the explicit definition
read and then verifies the codec payload. Thus a repaired section/root
checksum can still result in `Error.CorruptSection` at definition access; key
lookups remain payload-cold by design. `Reader.atomRecordsExamined()` reports
the atom-directory records inspected by each definition lookup. The atom
directory is ID-sorted and searched with checked binary search. The reader's
`Options.decode_allocator` selects where temporary bzip3 output is allocated;
it defaults to `std.heap.page_allocator`, must outlive the reader, and is
released before `definition` returns even when decoding fails. Raw blocks do
not allocate through it. The allocator itself must provide any synchronization
needed by concurrent calls on the same reader. `max_decode_memory_bytes`
remains a separate checked limit, and allocator exhaustion maps to
`Error.OutOfMemory`.

## Compatibility scope

Version checks accept major `1` and minor versions `0` through `4`; section versions must be `1`. Minor 0 snapshots use the validated scan path, minor 1 snapshots use the restart directory, minor 2 snapshots add the payload codec fields described above, minor 3 adds the bzip3 state size, and minor 4 adds adaptive postings while retaining the previous reader paths. The writer emits minor 4 deterministically. This is a prototype contract and may change before a published on-disk compatibility promise. No C ABI, DICT protocol, TEI model, semantic query language, language-analysis profile, or editor metadata is encoded by this version.
