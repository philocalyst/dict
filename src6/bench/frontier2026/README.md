# Frontier 2026 benchmark harness

This directory is an isolated benchmark runner for word and dictionary
compressors. It does not change src6 codecs. Candidates are configured in
`candidates.json`. The native controls and word-oriented candidates write
complete file-mode frames; the harness also supports simpler stdin/stdout
member codecs by wrapping their members in a common frame. The native control
frame charges a 32-byte header and 16 bytes per restart record. Candidate
frames charge their actual model, dictionary, header, directory, payload, and
checksums in full.

The controls are native libbz2 level 9, pinned bzip3 1.5.1, libzstd level 19,
and liblzma level 9 extreme. Each codec resets at the same raw restart
boundary, while retaining its native window/block behavior. This avoids the
100 KiB command-line minimum of bzip2 and keeps codec framing overhead explicit.
The sbwt grammar candidate and BZ4 v3 may share charged model state across
independently decodable blocks. Each whole-frame encoder receives the complete
input and `{block_bytes}` and emits its complete archive; a fresh decoder gets
the complete frame. Reports read the exact frame size and parse the metadata
breakdown from the output. Candidate-reported header, directory, and model
bytes are components of the frame total, not additional bytes.

## Corpora already present

The repo has full 8 MiB dictionary byte lanes used in earlier development
screens at
`src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/`:
`freedict-eval8-saved/external-decoded.bin`,
`gcide-eval8-saved/external-decoded.bin`, and
`omw-eval8-saved/external-decoded.bin`. The corresponding source projections
are described in `src6/bench/real-world/evidence/corpora/*/projection-manifest.json`.
These are normalized definition-content bytes, not original XML archives.

Finnish, Turkish, and Arabic form and sentence inputs from earlier test lanes
are available as text files and complete CoNLL-U files at
`src6/experiments/bzip4/language_frontier/evidence/corpora/ud-{fi,tr,ar}-test/`.
The earlier prepared screen also contains exact 64 KiB inputs named
`ud-{fi,tr,ar}-test-form.prefix65536.bin`, `web2.prefix65536.bin`, and
`omw-eval8.prefix65536.bin` under
`.../evidence/runs/wam-screen-preflight-20260926/inputs/`.
These old dictionary and Finnish/Turkish/Arabic inputs are development
diagnostics; earlier experiments already examined them. The restored, pinned
current corpus manifest is
`/workspace/scratch/frontier-corpora/manifest.json`. It includes development
and source-ID-partitioned final splits for the five dictionary content/word
lanes in `CORPORA.md`. Official Universal Dependencies v2.17 adds Chinese,
Japanese, Russian, Spanish, and English forms/prose, plus prose and explicitly
tagged multilingual lanes. Those dictionary finals and UD zh/ja/ru/es/en finals
are the untouched 2026 evaluation set. The manifest records dataset licenses,
source hashes, exact split rules, and byte counts. Keep `--split final` out of
development screens and parameter selection; use it only for frozen-candidate
comparisons.

## Running

Example size screen across the existing dictionary lanes and Finnish,
Turkish, and Arabic forms:

```sh
python3 src6/bench/frontier2026/bench.py --mode screen --use-cache \
  --input freedict=src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/freedict-eval8-saved/external-decoded.bin \
  --input gcide=src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/gcide-eval8-saved/external-decoded.bin \
  --input omw-ja=src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/omw-eval8-saved/external-decoded.bin \
  --input fi-form=src6/experiments/bzip4/language_frontier/evidence/corpora/ud-fi-test/form.txt \
  --input tr-form=src6/experiments/bzip4/language_frontier/evidence/corpora/ud-tr-test/form.txt \
  --input ar-form=src6/experiments/bzip4/language_frontier/evidence/corpora/ud-ar-test/form.txt \
  --block-bytes 16384 --block-bytes 65536 --out /tmp/luna-screen
```

For the restored development set, use exact manifest entries and an 8 MiB
prefix cap while candidates are still being tuned:

```sh
python3 src6/bench/frontier2026/bench.py --mode screen \
  --manifest /workspace/scratch/frontier-corpora/manifest.json \
  --corpus omw-ja-20-content-development \
  --corpus gcide-debian-054-content-development \
  --corpus omw-cmn-20-content-development \
  --corpus ud-fi-forms-development --corpus ud-tr-forms-development \
  --corpus ud-ar-forms-development --corpus ud-zh-prose-development \
  --corpus ud-ja-prose-development --corpus ud-multilingual-tagged-development \
  --max-input-bytes 8388608 --block-bytes 16384 --block-bytes 65536 \
  --out /tmp/luna-development
```

Final evaluation selects the exact same corpus names with `--split final` only
after codec policy and all parameters are frozen.

The strongest retained BZ4 v3 encoder can be built without keeping a generated
binary in the repository:

```sh
sh src6/bench/frontier2026/build_bzip4_v3.sh
```

Use `--block-bytes whole` with `--candidate bzip2-9 --candidate bzip3-1.5.1
--candidate zstd-19 --candidate xz-9-extreme` for a one-frame whole-input
comparison (currently bounded to 64 MiB). Keep this separate from
the matched 16 KiB and 64 KiB restart rows. The BZ4 v3 format replays prior
dictionary deltas before decoding a selected block; its extractor verifies
the exact block in a fresh process, while reports label that replay cost.
Its raw block sizes can vary by token-boundary slack and appear as min/max and
per-block lengths in the result rows. The harness checks the overshoot against
the longest input atom, matching the BZ4 v3 learner's word-aligned fence rule:
ASCII-letter runs, digit runs, high-byte runs, and single-byte delimiters.
Because its archive access replays prior dictionary deltas, BZ4 v3 is treated
as a legacy size reference: full-frame decode and all raw block boundaries are
checked, plus up to 16 evenly spaced fresh-process block extractions (first,
middle, and last included). New candidates and native controls are extracted
at every restart.

The frozen WSB2 family currently includes fixed-cap grammar-symbol BWT,
five-capacity complete-frame MDL, a lexical-versus-surface-copy choice, and
byte-versus-UTF-8-scalar MDL. The frozen WGP5 family includes a fixed
16,128-rule word-grammar encoder and a six-capacity complete-frame MDL choice.
WGP5 restart sizes are capped at 64 KiB by the codec; both formats store and
charge their full shared model, restart directory, checksums, and payload.
Every WGP5 block is decoded independently after a fresh full-frame decode.

The `--manifest` option accepts a JSON document with a `corpora` array. Each
row should have `name`, `path`, `language`, `kind`, `split`, and
`source_manifest`; `sha256` is optional but checked when provided. Relative
paths resolve beside the manifest. This provides the durable corpus interface
for restored inputs and multilingual builders.

The run environment records host/CPU and Python identity, corpus manifest and
input hashes, candidate commands/source hashes, runtime codec-library hashes,
declared model/dictionary bytes, and restart policy. The screen cache key
includes the complete input SHA-256, candidate command and executable hashes,
declared external model/dictionary bytes, and block size.
`screen` is for size and roundtrip evidence; any candidate-supplied clock
fields retained with those rows are diagnostic only and must not be used for
performance claims. `--max-input-bytes 8388608` makes bounded prefix screens
for development corpora. `measure` bypasses the cache and
performs serial paired trials per corpus and block, rotating which candidate
runs first on each repetition; `--warmups` runs the same schedule before
recording. Every trial decodes the complete frame in a fresh process, compares
all raw bytes and SHA-256, and invokes a separate fresh-process block extractor
for every restart. Member controls are independently decoded one member at a
time. Native whole-frame candidates must declare exact frame/header/directory/
model byte accounting and provide an extraction command. Process wall time and
any candidate-reported codec-only time are kept as separate columns.

Raw subprocess command, stdout, stderr, and exit status are written to a
per-cell JSONL log below `raw_logs/`; completed screen rows, cache entries, and
status are atomically checkpointed after each candidate. The
complete output frames are verified in memory and represented in result rows
by byte count and SHA-256; they are not copied into the repo by default. Avoid
parallel runs during final timing.

Run the harness unit tests with:

```sh
python3 -m unittest discover -s src6/bench/frontier2026 -p 'test_*.py'
```
