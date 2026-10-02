# PAQ8PX v217 level `-1` context-mixing calibration

This is a separate external reference stage from the fixed `-0L` screen. It
uses one PAQ8PX profile only: level `-1`, with no `L`, `T`, or `E` flags and
no model/lexicon files. In particular, `-T` is omitted because upstream says
it pretrains on `english.dic`/`english.exp`, which are not carried in the
archive. Upstream reports 583 MiB typical for level `-1`; this stage therefore
uses a 1 GiB virtual-address-space limit (not the smaller 512 MiB `-0L` cap),
plus the same 180-second per-operation timeout.

The code and input corpus are exactly those in `README.md`: the clean GPL v217
tag at commit `c84f576fc2c522194cd320743708652a154daf6b` and the frozen six
1 MiB development prefixes. This is a mature whole-file context-mixing
reference, not a proposed new wire format. The decoder is a fresh process in
an isolated directory with only the produced PAQ archive available.

Run a tiny fresh-process exactness gate first:

```sh
python3 src6/bench/paq_calibration/capture_contextmix.py smoke \
  --source-root /tmp/paq8px-v217 \
  --binary /tmp/paq8px-v217-buildsrc/build/paq8px \
  --out /workspace/scratch/paq8px-v217-level1-smoke
```

Then capture all six fixed development prefixes:

```sh
python3 src6/bench/paq_calibration/capture_contextmix.py books \
  --source-root /tmp/paq8px-v217 \
  --binary /tmp/paq8px-v217-buildsrc/build/paq8px \
  --out /workspace/scratch/paq8px-v217-level1-books6
```

`rows.jsonl` retains success, timeout, and resource failure per book. The
reported memory counter comes from PAQ's `ProgramChecker` (its source notes
that only its `Array<T>` allocations report there); it is not OS peak RSS.
The process wall times are diagnostic, not a quiet-window speed ranking.
