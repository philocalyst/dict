# Whole-file lexical BWT experiment

`LXB1` is a reversible, **transform-only** source experiment. Its vocabulary
and integer event stream are compressed with an ordinary linked zstd backend;
the project does not claim a new independent entropy coder or production
decoder. All frame bytes count. The comparison target is the same source's
complete whole-file bzip3 1.5.1 stream, not a restart-matched estimate.

This is distinct from WSB2's BWT over grammar roots in independent 64 KiB raw
blocks, and from `wordzip`'s zstd-coded token IDs without BWT. The input here
is one complete exact-byte file. It gets a whole-file suffix ordering over an
integer sequence; a unique terminal symbol and stored primary row make the
inverse unambiguous. A Fenwick-tree MTF turns preceding tokens into ranks;
zero runs have explicit canonical lengths. A direct varint token stream is
the same-model ablation. The decoder never repeats tokenization or learning.

Three token sources are charged:

* `byte`: original bytes, no learned tokens.
* `word`: repeated exact maximal word runs, with valid UTF-8 scalars and byte
  fallback for malformed input. Unselected runs and punctuation remain byte
  tokens. The model holds at most 1,024 exact spellings in the initial screen.
* `subword`: valid UTF-8 scalar seeds and up to 32 input-learned BPE pair
  merges in the initial screen. Invalid bytes stay literal. Merges cannot
  cross newline tokens, so line reversal is an exact involution.

The model can assign IDs in lexical, frequency, or first-use order. Every
vocabulary spelling is front coded against its predecessor in that delivered
order, then zstd compressed. There is no free separator, casing, language,
origin, or sentence sidecar: all source bytes reappear as literal tokens or
exact stored spellings. Whole-sequence and newline-delimited token reversal
are deterministic involutions, so they need one header selector and no
permutation list. A later sentence-specific direction selector would have to
pay its bits and boundaries explicitly; this screen does not assume it helps.

## Build and verify

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic \
  src6/experiments/lexical_bwt/lexical_bwt.cpp -lzstd \
  -o src6/experiments/lexical_bwt/lexical_bwt
python3 src6/experiments/lexical_bwt/test_codec.py
python3 src6/experiments/lexical_bwt/screen.py --stage initial \
  --out /workspace/scratch/lexical-bwt-initial-128k
```

The 486-case unit matrix covers every factorization, ordering, direction and
direct/BWT path on empty, repetitive, all-byte, malformed UTF-8, random,
Arabic, Turkish, Japanese, Chinese and newline examples. It also rejects
truncation, a trailing byte, damaged version and damaged payload. The initial
screen reads only the first 131,072 bytes of three development `content.txt`
sources (English/French, GCIDE, Japanese). Chinese has a separate development
projection; `cross_script.py` derives exact 128 KiB Arabic and Turkish lexical
streams from pinned FreeDict TEI sources. A later fixed gate can run these
without touching the structural holdout.

`screen.py` saves an immutable source copy, full bzip3 control, every complete
LXB frame, a protocol with source/binary hashes, and line-flushed per-policy
rows. It fresh-decodes each candidate and the control before recording a row.
Diagnostic process times include I/O and backend work; they are not native
codec speed rankings. The fixed initial policy is 42 candidates per corpus:
six byte controls plus 18 word and 18 subword configurations, zstd level 9.
Only complete-frame robust wins can justify a 1 MiB or 8 MiB gate. Level 19,
per-sentence direction bits, and other model changes would require new paid
protocols and source hashes.

The wire is: magic `LXB1`, canonical varints for version/kind/order/direction/
pipe/backend, raw length and CRC32, token count, primary row, exact decoded
and coded lengths for model/events, followed by the two compressed sections.
The decoder caps raw and frame bytes, vocabulary count/length, section output,
token count, alphabet indices, BWT sentinel/primary, event count, final
expansion length and source CRC. It requires every section and varint to end
exactly where declared. CRC32 detects corruption; it is not authentication.
