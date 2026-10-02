# PAQ8PX v217 `-0L` calibration

This is an external reference measurement, not a new dictionary codec. It runs
only the pinned PAQ8PX v217 `-0L` profile. PAQ8PX describes `-0L` as file
segmentation/transforms followed by LSTM-only compression (20–24 MiB typical
memory). Normal context-mixing levels start at a documented 583 MiB and are
outside this capture's 512 MiB address-space limit. No external weights or
trained dictionary files are allowed.

The source checkout is the unmodified GPL v217 tag at
`c84f576fc2c522194cd320743708652a154daf6b`, expected at
`/tmp/paq8px-v217`. In this environment CMake was unavailable, so the actual
build used an exact disposable copy and the upstream GCC script:

```sh
cp -a /tmp/paq8px-v217 /tmp/paq8px-v217-buildsrc
cd /tmp/paq8px-v217-buildsrc/build
bash build-linux-with-gcc.sh
```

That script builds static with bundled zlib. Its tracked source hash,
compiler executable hashes/versions, exact binary hash, and tracked-source
tree hashes for both original and disposable copy are captured. The
environment start/end records verify that the source and binary remained
identical.

Run the small fresh-process correctness gate first:

```sh
python3 src6/bench/paq_calibration/capture.py smoke \
  --out /workspace/scratch/paq8px-v217-smoke
```

After it passes, run the six fixed 1 MiB UTF-8-safe prefixes from the frozen
books2026 development manifest, matched to the existing whole-file bzip3
prefix controls:

```sh
python3 src6/bench/paq_calibration/capture.py books \
  --out /workspace/scratch/paq8px-v217-books6
```

Each encode and fresh decode runs separately with `RLIMIT_AS=512 MiB` and a
180-second timeout. Each case uses an isolated working directory and the same
input basename (`payload.txt`); the decoder gets only the produced archive.
The book input source remains outside the codec working directory and its
exact bytes/hash are checked against the pinned manifest. Raw stdout/stderr,
argv, wall time, timeout/exit state, archive hash/length, exact decoded hash,
resource limits, and source/runtime start/end identities are retained. Wall
time is diagnostic because the overall environment is not a timing quiet
window. Every book is attempted even after a resource failure; failed rows
stay durable in `rows.jsonl`.

The complete PAQ archive size, including its own headers and transformed data,
is compared only to the matched 1 MiB-prefix bzip3 frame. This profile does
not represent PAQ8PX's normal context-mixing levels or their compression
quality. It is a bounded mature neural/text-path calibration.
PAQ's printed `used ... bytes of memory` is its `ProgramChecker` allocation
counter; that source says only `Array<T>` allocations are included, so this is
not OS peak RSS. The initial capture artifact retains the original field name
and is annotated in its accompanying `provenance.json`.

The completed [two-profile results and source analysis](PAQ-BOOK-CALIBRATION-20261002.md)
also cover the separately registered `-1` context-mixing reference. Its original
timeout remains recorded alongside a clean, unchanged-policy retry. An
[independent artifact audit](evidence/ROOT-AUDIT-20261002.json) verifies the
22-file capture bundle, 702 upstream/build-copy files, actual archives, decoded
outputs and logs. The six valid `-1` archives save 9.59% in total bytes against
matched bzip3 prefixes; the language/work-balanced reduction is 9.93%. This is
a mature external reference result, not a new compressor or a full-book result
for the two longest works.
