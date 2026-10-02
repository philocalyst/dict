# Exact word constructions within records

This experiment tests a word codec that **constructs** repeated field values
from bytes already present in the same or an enclosing record. The encoder
searches only bounded, exact byte relations; all marker operands are carried
in the transformed stream. Arbitrary bytes, malformed markup, invalid UTF-8,
and unfinished records pass through byte-for-byte. There is no normalization,
language rule, external vocabulary, or learned decoder weight.

`attribute_register.py` finds a quoted field whose space-separated values
share a prefix and suffix with an earlier quoted field in the same tag-like
record. It emits donor field index, overlap lengths, and the remaining word
bytes. `scope_register.py` keeps at most 32 open tags and 32 quoted fields
per tag (field bodies at most 256 bytes). A child field may copy a slice of
an ancestor field, or copy its prefix and suffix around a literal. Tag
matching is capped at 4096 bytes. Literal zero bytes are escaped before
constructors run and restored after decoding. No names such as `Synset` or
`id` are part of the reconstruction rules.

`compose_best.py` compresses all active raw/local/scope/local+scope choices
with the same pinned byte-MDL/WGP6 native backend, selects the smallest
**complete** frame, and stores the selector, original length, full native
frame, and CRC32 in `WBP1`. Its decoder can use the Python reference or the
native streaming `register_decode` command. The grammar and its probability
tables are fully stored in the native frame; the intermediate parse is an
encoder artifact only. The backend remains the repository's existing native
v4 entropy format, so this experiment does not claim a new entropy coder.

`compose_page.py` tries raw/local/scope/local+scope constructions across
original 64 KiB pages, then fits one shared native entropy model to the
concatenated transformed pages for each distinct global choice. `WPG2`
carries the selected mode, each transformed page length and original-page
CRC32, and a header CRC checked before the legacy entropy model is loaded. An
original page maps to a known transformed interval; `extract_page` decodes
only the native blocks overlapping it, trims that interval, runs the native
constructor decoder, and checks the page CRC. The current native entropy
extractor replays preceding dictionary deltas to prepare the model. A
hoisted-model profile places one model before all payload blocks.

`prepared_jobs.zig` and `prepared_wpg.cpp` implement a one-process native
reader. It checks WPG2 metadata and its CRC, prepares the unchanged v4
decoder and immutable payload Jobs once, decodes only Jobs touching the
requested original page, runs the same C++ constructors, and checks the
page CRC. Full decode also verifies the global CRC. The `bench` command
reports preparation separately from 256 first/middle/last page reads; clocks
are enabled only with the explicit quiet gate.
The private Job adapter scans native block metadata before the old decoder
allocates from it: header at most 8 MiB, one declared delta output at most
16 MiB, cumulative delta output at most 64 MiB, at most one million
definitions and 8192 blocks, and at most 64 KiB output per payload Job.
This constrains the demonstrated inflated-delta declaration. It does not
establish a whole-frame hostile-input memory bound for the inherited v4
model reader.

`compose_dp.py` also screens a conditional spelling-graph reparse of each
constructed source against its initial LaneA graph. It pays the initial
model fit, price extraction, reparse, second fit, and complete `WPG2` frame;
it is an encoder-side research option, not a decoder requirement.
`wpg_codec.py` is the stable command adapter. Its `quality` profile fits
interleaved native model deltas; its `access` profile fits one hoisted common
model before the payload jobs. Both profiles search all distinct
raw/local/scope/local+scope sources and initial/conditional spelling graphs,
then publish the smallest complete archive after a fresh native full decode.
The decoder understands either profile from the transmitted native frame.
Only original-byte 64 KiB pages are supported.
Set `WPG6_BIN_DIR` to a directory containing `m_reference`, `native`,
`native_forward`, `native_forward_hoist`, and `reparse_context` to use a
specific frozen backend build; by default, the repository's WGP6 binaries
are used. The encoder reports the exact binary SHA-256 values it executed.

Build and run the native construction decoder:

```sh
make -C src6/experiments/word_constructions test
python3 src6/experiments/word_constructions/compose_best.py INPUT OUTPUT
python3 src6/experiments/word_constructions/compose_page.py INPUT OUTPUT
python3 src6/experiments/word_constructions/compose_dp.py INPUT OUTPUT --modes 0,1,2,3
src6/experiments/word_constructions/prepared_wpg query PAGE_ARCHIVE OUTPUT --index 63
python3 src6/experiments/word_constructions/wpg_codec.py encode INPUT ARCHIVE --profile quality --block 65536
python3 src6/experiments/word_constructions/wpg_codec.py decode ARCHIVE OUTPUT
python3 src6/experiments/word_constructions/wpg_codec.py extract ARCHIVE PAGE_OUTPUT --index 63
python3 src6/experiments/word_constructions/wpg_codec.py inspect ARCHIVE LEDGER.json
```

Both encoders require the pinned `wordgrammar/wgp6/m_reference` and `native`
binaries. The constructor decoder is C++17 and streams `WBP1`'s transformed
source with a 4096-byte tag buffer and bounded ancestor registers. For
`WPG2`, the prepared native reader reads one transformed page at a time.
Python remains the encoder and reference decoder orchestrator. The native
reader is already one process for WPG2, including entropy, construction,
and integrity checks.

All measured files so far are retained **development** samples. See
`RESULTS.md` for full-frame sizes, exact comparators, and limitations.
`review/INDEPENDENT_WPG2_AUDIT.md` records the separate constructor parity,
resealed-frame, restart, and failed-output-publication audit.
