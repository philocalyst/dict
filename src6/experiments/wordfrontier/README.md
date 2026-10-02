# Automatic exact word frontier

`wordfrontier.py` is one command adapter for the two new word-representation
families. It uses a fixed global policy on every input. There is no filename,
language, script, extension or corpus branch.

The **quality** profile learns the interleaved grammar model. The **access**
profile puts one common model before all payloads. Both produce exact,
independently extractable original-byte 64 KiB pages after shared model
preparation. Encoding pays every trial:

* WPG2: all distinct raw/local-register/ancestor-register/combined sources,
  each compiled with the initial spelling graph and one joint conditional
  spelling/payload reparse. All constructors, grammar definitions, probability
  tables, selectors, original-page indices and checksums are transmitted.
* GWT1: width-72 page-local word geometry, with both the two-row residual
  model and the description-length-trained numeric context tree charged.
  Each original page has an independently terminated residual flag stream.

The adapter chooses the smallest **complete archive**. Exact size ties choose
WPG2. Each family already has a distinct wire magic, so automatic selection
adds zero framing bytes. The format identifies the decoder; both profiles
are decoded without an external model or encoder parse. The entropy compiler
is the repository's unchanged native v4 backend, not a newly invented coder.
The new abstractions are exact surface constructors, jointly re-tiled spelling
and payload graphs, and the paid word-geometry residual tree.

Build the Zig and C++ dependencies, then run:

```sh
make -C src6/experiments/wordfrontier
python3 src6/experiments/wordfrontier/wordfrontier.py encode INPUT ARCHIVE --profile quality
python3 src6/experiments/wordfrontier/wordfrontier.py encode INPUT ARCHIVE --profile access
python3 src6/experiments/wordfrontier/wordfrontier.py decode ARCHIVE OUTPUT
python3 src6/experiments/wordfrontier/wordfrontier.py extract ARCHIVE PAGE_OUTPUT --index 63
python3 src6/experiments/wordfrontier/wordfrontier.py inspect ARCHIVE LEDGER.json
python3 src6/experiments/wordfrontier/wordfrontier.py bench ARCHIVE READER.json
make -C src6/experiments/wordfrontier test
```

`make native-decoder` also builds `wordfrontier-decode`, a standalone native
reader for both delivered formats. Decompression needs no Python or NumPy:

```sh
src6/experiments/wordfrontier/wordfrontier-decode decode ARCHIVE OUTPUT
src6/experiments/wordfrontier/wordfrontier-decode query ARCHIVE PAGE_OUTPUT --index 63
```

This reader dispatches from wire magic in the same process and reuses the
bounded native readers, constructor/residual inverses and CRC checks. It
changes neither compressed bytes nor encoder policy. Full decoding preserves
an existing output until every page and the global source checksum pass.
The [native dispatch gate](evidence/native-dispatch-gate-20261001.json) binds
all 44 frozen quality/access frames to exact full sources and first/middle/last
page probes, covers both wire formats, and checks failed dispatch plus failed
full-source publication. A separate
[quiet paired comparison](evidence/native-dispatch-paired-20261002.json)
completed 264 exact operations on all 22 frozen quality frames: one warmup
and five alternating-order pairs per frame. Median paired command speedups
range from 1.17 to 22.69 times. The large Japanese frame takes 426 ms in the
native command versus 499 ms through Python; Mandarin takes 125 versus
171 ms. The improvement removes Python startup, dependency hashing and child
dispatch. It changes no compressed bytes or entropy kernel. These are fresh
processes with resident files, compared within one runtime; no cold-cache or
cross-runtime speed claim follows.

`--backend-dir DIRECTORY` explicitly selects the five frozen WGP6 binaries
(`m_reference`, `native`, `native_forward`, `native_forward_hoist`,
`reparse_context`). It overrides `WPG6_BIN_DIR`; the default is the repository's
WGP6 directory. Each JSON encode report includes the effective global policy,
its fingerprint, exact dependency hashes, both complete candidate results,
all family searches, the charged native encoder-time sum, and separate
Python/process wall times. Every native learning, fit, price extraction,
conditional reparse and refit is paid, including losing candidates. Python
transform work is in adapter wall time and is not attributed to native codec
throughput. Concurrent research clocks are diagnostic only.

The adapter verifies a fresh native full decode and every original page in a
fresh native process before publishing. It checks dependencies again at the
end. Full decode, extraction and inspection stage their outputs next to the
destination and replace it only after success, preserving an existing file
on failure. Existing format magic is the only decode dispatch. A selected
native reader performs entropy, construction/geometry realization and CRC
checks in one process. GWT1 inspect uses that prepared native reader; WPG2
inspect uses its frozen structural adapter plus the unchanged native frame
ledger. Inspection validates metadata and accounting; full decoding checks
all payload and source CRCs. The byte ledger sums to the entire archive.

Native performance clocks are disabled by default. In a coordinated serial
quiet run, add `--measure 1 --quiet-gate WORDZIP-READER-QUIET` to decode,
extract or bench. The report retains native preparation and payload/query
measurements separately from adapter wall time. The frozen WPG2 single-query
path reports bytes/jobs/CRC but has no separate native query timer; use its
prepared `bench` for that measurement. `native_clock_fields` identifies the
fields actually returned. `bench` performs 256
first/middle/last accesses with one prepared model. Empty archives support
encode/decode/inspect; an empty page query or benchmark is rejected.

Input admission is at most **32 MiB** before reading, matching the narrower
WPG2 family. Only 65,536-byte original pages are supported. The M encoder
limits requested live allocations to 4 GiB, with documented independent
22 MiB Japanese and 12 MiB English development admissions. The size limit
does not guarantee every possible input fits that allocation budget. A
family failure stops the automatic search; it does not silently discard a
failed candidate. Arbitrary bytes, invalid UTF-8 and binary inputs retain
exact bytes, but binary/random compression ratios are not optimized. The
inherited native v4 model reader has private declaration/preflight limits;
this experimental adapter does not claim an authenticated format or a
proved hostile-input bound for all legacy allocations.

Development evidence is recorded by each family in
`../word_constructions/RESULTS.md` and
`../wordgrammar/geometry/evidence/GWT1_NATIVE_EVIDENCE.md`. Those family
results are not newly measured automatic-driver results. This driver adds a
usable deterministic full-frame policy; it claims no universal compression
record. Final size, memory and latency comparisons must use this entire
paid automatic encode and the selected native reader.
