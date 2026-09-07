# Benchmark entry point

Run the pinned, cross-format matrix with:

```sh
nix develop .# --command bash bench2/run.sh
```

Each successful run is committed as an immutable directory under
[`results/runs/`](results/runs/) and selected atomically by the
[`results/latest`](results/latest) symlink. The report links the lossless raw
TSV observations, JSON projection, corpus files, portable wall-time/RSS
records, SHA-256 manifest, and generated artifacts. A failed run remains in a
staging directory only long enough to be cleaned up and cannot replace
`latest`. Compressed SQLite and gzip StarDict rows are size-only and are
explicitly marked unavailable for random-access latency; no numbers are
invented for them.
