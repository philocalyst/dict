# GWT1 native geometry: independently addressable original pages

The complete 8 MiB GCIDE GWT1 archive is **1,232,267 bytes** and decodes to
SHA-256 `8b93c30f4a5d659f879af5fc7db9de38ee524cc07b91ada7be2905cf5aaf519b`.
The same-source whole-file bzip3 control is 1,243,221 bytes, a 10,954-byte
(0.881%) win. This includes every model, flag stream, page index and outer
header byte. The archive SHA-256 is
`ee51cbc2d47f6a1e47cf1b68aa61ac01cc07c1e49a1e15f48079cd50e7af4fb3`.

| Charged component | Bytes |
| --- | ---: |
| Unchanged native v4 normalized-source frame | 1,229,537 |
| GWT1 header | 48 |
| 128 original-page index entries | 1,536 |
| Shared, transmitted numeric context tree | 141 |
| 128 independently terminated rANS flag segments | 1,005 |
| **Complete archive** | **1,232,267** |

The geometry transform changes only eligible single space/newline separators.
It uses numeric wrap/column/word-length/adjacent-byte features, resets the
column at each original 64 KiB boundary, and emits no language, field, or
word literals. The native frame has 128 payload Jobs with exact 65,536-byte
raw lengths. A cold selected-page query prepares all shared native model
deltas, then decodes **one** payload Job, reads **one** page flag segment,
reconstructs that page and checks its page CRC. The reader maps the archive
read-only so it does not copy other flag segments into heap memory.

`prepared_geometry.cpp` owns the immutable mapping until after `wpg_close`,
which keeps native Job references valid. It validates the fixed 48-byte
header, exact segment lengths, page count, index and model CRC, bounded tree,
every page's event/flag length and summed flag offsets before native
preparation. It also enforces one native Job per original page, the terminal
rANS state/byte position, selected-page CRC, and both global raw and
normalized CRCs on full decode. Full output is written to an adjacent
temporary file and atomically published only after every check passes.

Resource admission: original and normalized source at most 64 MiB; native
frame at most 64 MiB (the frozen prepared-Jobs API limit); at most 1,024
pages; context tree 3–1,533 bytes, 256 leaves and depth 16; each page's
flags at most `2 * events + 4` bytes. The reused frozen native-v4 preflight
additionally caps frame header bytes, delta output, definitions, blocks,
payload raw lengths and item counts before the legacy decoder allocates.
The private prepared-Jobs C ABI now also enforces a **512 MiB live allocation
cap** across the unchanged v4 Decoder arena and immutable Job directory.
The outer archive file is size-checked before mapping. A tiny, resealed
wide-header frame that passed the old scalar limits now fails with
`OutOfMemory` and leaves the budget at zero live bytes after cleanup.

On this 8 MiB source, the encoder's tracked live allocation peak was
3,535,975,142 bytes under a 4,294,967,296-byte cap. The seed, learning and
native-fitting phase peaks were 3,535,975,142, 535,214,610 and 602,382,369
bytes respectively. These counts are allocator-requested live bytes, not RSS.
The native reader reported 21,602,972 bytes of prepared model arena
reservation, 9,856 bytes of Job directory reservation, 131,072 bytes of
two-page-buffer heap scratch, and one 65,536-byte native Job stack buffer.
Its measured decoder budget peak was 21,612,924 bytes, far below the
536,870,912-byte cap; the unchanged 22 MiB Japanese native frame peaked at
28,857,302 bytes under the same cap.
Its mapped archive is 1,232,267 virtual bytes. `getrusage` high-water RSS
was 41,192 KiB in a separate process; that includes the linked runtime and
other process overhead, and is a diagnostic floor rather than the sum of
those reservations.

Validation:

* `make test` passed 180 deterministic arbitrary-byte C++/Python residual
  cases and six malformed residual rejections. With the real 8 MiB source,
  the parity set passed 188 cases, including NUL, invalid UTF-8, long tokens
  and page-boundary whitespace.
* Exact native GWT1 encode/decode also passed empty, NUL/invalid-UTF-8,
  131,072-byte uninterrupted-token and page-boundary newline inputs.
* The independent native hostile-envelope suite passed 39 cases: six valid
  and 33 rejected. It reseals changed headers, index counts and offsets,
  model kind/frequency/depth, flags, native bytes, a 67,108,865-byte native
  delta claim, a separately resealed 18-byte native wide-model header,
  global CRCs and a corrupt later page. Bad full decodes leave an existing
  destination unchanged.
* The 256 first/middle/last access sequence decoded exactly 256 payload Jobs
  and produced checksum `16229180251963240029`, independently recomputed
  from the original source pages. The full native decoder output SHA-256
  equals the source hash above.

Timing fields in the saved encoding log and reader CLI are diagnostic: the
8 MiB encoding ran alongside other research jobs. No throughput rank is
claimed from those concurrent clocks. The Python residual fit wall time was
6.47 seconds and native backend wall time 68.10 seconds in that run; the
native backend's own codec timer was 68.09 seconds. The decoder's 256-query
path can be measured separately with `--measure 1 --quiet-gate
WORDZIP-READER-QUIET` in a quiet serial run.

The reproducible source and binary dependency snapshot is
`gwt1-native-sources.sha256`, and source/corpus/archive/result artifacts are
listed in `gwt1-native-artifacts.sha256`. Verify the former from `/workspace/dict`
with `sha256sum -c src6/experiments/wordgrammar/geometry/evidence/gwt1-native-sources.sha256`.
The native reader links the frozen `word_constructions/libwpgjobs.a` without
editing its source or the native v4 codec. Build with `make` in this geometry
directory; run `prepared_geometry decode ARCHIVE OUTPUT`, `query ARCHIVE
OUTPUT --index N`, `bench ARCHIVE JSON_OUTPUT`, or `inspect ARCHIVE
JSON_OUTPUT`. Inspect validates the envelope, page index, tree, and native
model/Job directory without decoding payload pages; decode is the full CRC
and source-identity gate. Inspect works on an empty archive.
