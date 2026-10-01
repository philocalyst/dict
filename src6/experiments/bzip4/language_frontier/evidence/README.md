# Bzip4 language-frontier evidence lane

This directory owns storage evidence only. It does not alter `bz4/v3`, the
shared `bz4` lanes, production sources, or the existing corpus projections.
Every capture is deterministic and must contain a real encoder output, a real
decoder check, complete frame accounting, and hashes for all relevant bytes.
Timing is deliberately absent from this lane until the root agent freezes a
quiet serial schedule.

## Baseline map

The current v4 reference is the lexical-automaton backend in
`../bz4/v3`, not the older Python BWT/grammar prototype. The strongest
retained parse is Lane M's `dumps/m_*.b4sd` (B4SD v2, n-ary entries), scored
with the current v4 planner. The published real 64 KiB eval8 totals are:

| same bytes | bzip3 whole | v4 saved parse (`m_*`) | current `bz4 c` learner |
|---|---:|---:|---:|
| FreeDict eval8 (8 MiB) | 554,003 | 564,416 | 579,202 |
| GCIDE eval8 (8 MiB) | 1,243,221 | 1,276,838 | 1,324,034 |
| OMW eval8 (8 MiB) | 332,331 | 330,148 | 374,217 |

The bzip3 column above is a whole-file control, so it is not the matched
64 KiB control. The matched 64 KiB bzip3 totals are 899,408,
1,905,560, and 674,384 respectively. `results_v4.tsv` gives the complete
v4 breakdown (`header`, `delta`, `payload`, `framing`, bucket and block
counts), while this lane adds frame hashes and an independent second decode.

The `m_*` names are not evidence that the v4 learner produced those parses:
they are saved Lane M parse dumps. Lane M's own model-codec totals are a
different experiment. All comparisons here label `saved_parse` versus
`end_to_end` explicitly.

## Reproducible storage protocol

For a saved parse:

1. Read the exact input bytes and B4SD dump bytes, recording SHA-256 and
   lengths. Never retokenize, normalize, or replace a dump with an estimate.
2. Run `capture_frame saved DATA DUMP FRAME 0`. `0` means current v4
   `plan.fit` class search; a nonzero class count is a separate fixed-class
   control and must not be conflated with auto-fit.
3. The driver performs one real `plan.fit` + encode, one serial
   `decodeAll(..., workers=1)`, and an exact byte comparison. It writes a
   frame and prints only storage fields.
4. Run the public `bz4 d FRAME OUT 1` as a second decoder process and compare
   the output hash and length to the input. The frame parser checks magic,
   header, every block, the end marker, and complete `header + delta +
   payload + framing` accounting.

For end-to-end bytes, use `capture_frame raw DATA FRAME 65536`; the learner
is part of the measured frame. The same second decoder check is mandatory.
For a bzip3 control, invoke the retained `bz3base` on the same materialized
input and block size. Its historical timing fields are ignored by this lane;
only its verified total and payload bytes are retained.

No entropy estimate, guessed model cost, or external tokenizer is a result.
If a candidate lacks a complete frame or independent re-decode, it is a
diagnostic and is not promoted to the result table.

## Workloads and splits

The frozen local `bz4/data` files are byte-exact `train` (1 MiB), `eval8`
(8 MiB, the published `[1,9)` MiB slice), and `untouched` (1 MiB, the
published `[9,10)` MiB holdout). Their manifest and hashes are in
`../bz4/data/MANIFEST.tsv`.

Additional language holdouts are retained under `corpora/`:

* `ud-fi-test`: Universal Dependencies Finnish-TDT test split, CC BY-SA 4.0.
* `ud-tr-test`: Universal Dependencies Turkish-IMST test split, CC
  BY-NC-SA 3.0.
* `ud-ar-test`: Universal Dependencies Arabic-PADT test split, CC BY-NC-SA
  3.0.

`ud-manifest.json` records raw bytes, retained license bytes, pinned source
commit URLs, Git blob IDs, SHA-256, sentence/token counts, and deterministic
`form.txt`/`text.txt` projections. The local raw SHA-256 and matching Git blob
ID make the retained bytes authoritative; mutable branch URLs are not
re-fetch instructions. `form.txt` is a word workload made only from the dataset's
integer-ID FORM fields (ASCII-space within a sentence, LF between sentences);
`text.txt` is the dataset-provided `# text =` prose. Raw CoNLL-U remains
beside both projections. No source archive is compressed in these captures.

The visible test rows are now development resources. A separate bounded TRAIN
lane with a pre-inspection 80/20 sentence split is documented in
`UD_TRAIN_RESOURCE.md` and frozen in `ud-train-manifest.json`; its final 20%
confirmation files are not used by the storage harness. The existing six UD
rows' header/delta/payload/framing decomposition is in `UD_COMPONENTS.md`.

## Fairness audit

* Compare same input hash and exact bytes; do not compare a projection against
  native XML or a source archive against a normalized stream.
* Match block size for v4 and bzip3 (`65536` for the primary screen). Whole
  file bzip3 is a separate control, not a matched-block win.
* Charge v4 header, all lexical-definition deltas, all payloads, framing,
  padding, restart/block data, and buckets. The delta contains first-use
  spelling/text definitions, not merely model-header bytes. `header` is not
  free shared preparation: all deltas must be decoded serially before
  independent payload jobs can run.
* Keep class policy fixed before reading results. `classes=0` means the
  deterministic auto-fit search; `classes=64` is a distinct fixed baseline.
* Do not claim decode speed from this lane. The v3 `lab` output's repeated
  `decode_MBps` is retained only as historical context; root's quiet serial
  run owns timing claims.
* Any `est` field is labelled as such and cannot be used as a compressed-size
  result. Lane M's published `model B`/Re-Pair values are estimates or
  separate codec totals, not substitutions for the v4 frame.

## Commands

From this directory:

```sh
ZIG_GLOBAL_CACHE_DIR=/private/tmp/dictionary-bzip4-zig-cache \
  zig build-exe -O ReleaseFast --dep bz4 -Mroot=capture_frame.zig \
  -Mbz4=../../bz4/v3/src/root.zig -femit-bin=bin/capture_frame
python3 prepare_ud.py
python3 inventory.py --output manifests/inventory.json
python3 capture.py --run-id storage-screen
```

`capture.py` refuses to overwrite a run directory, persists raw subprocess
stdout/stderr before parsing, and emits `manifest.json`, `samples.json`, and
`summary.json`. It is intentionally serial and storage-only; do not add
clocking or parallel workers to it.

## Frozen weighted-emission candidate screen

`candidate_preflight.py` materializes the seven exact first-65,536-byte
development prefixes and caches matched bzip3 controls. The subsequent
`candidate_screen.py` run uses the fixed policy
`max_piece=8,min_occ=2,max_vocab=256,em_rounds=2` for both MAP and marginal
WAM modes, captures current v4 raw frames on the same bytes, and reuses a
bzip3 control only after verifying the prefix hash. WAM frames are real
serialized `WAM1` frames; `wam_decode_subprocess.py` receives only each frame
and independently byte-checks the restored output. No TRAIN confirmation
bytes are read and no harness clocks are used.

```sh
python3 candidate_preflight.py --run-id wam-screen-preflight-20260926
python3 candidate_screen.py --run-id wam-screen-final-20260926
```

The bzip3 preflight command is
`../bz4/bin/bz3base PREFIX 65536 1`; its historical timing fields are
retained only as raw provenance. Current v4 uses
`bin/capture_frame raw PREFIX FRAME 65536`, followed by
`../bz4/v3/zig-out/bin/bz4 d FRAME OUTPUT 1`.
