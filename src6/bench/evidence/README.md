# Accepted LEX6 benchmark evidence

These three directories are the durable copies of the barrier-corrected
ReleaseFast runs cited by `src6/reviews/benchmark.md`.  Each contains the
runner/compiler stdout and stderr, `provenance.json`, the ReleaseFast runner
binary, and complete frozen-LEX5/LEX6 archive artifacts.  Compiler caches are
intentionally not retained.

The pinned source-manifest SHA-256 in each provenance file is
`5bee6e5ba1e27f4d25abb44159e39f971dfe3f38004e69b567494e76af62c576`, and the
manifest is unchanged before compilation and after the runner process.

The earlier unbarriered stages under `/private/tmp/` remain exploratory only;
they are superseded by these copies and are not evidence for claims.

## After-source-scope rerun

The frozen `SourceIndex` ownership fix was checked with one unchanged
ReleaseFast `N=2048` matrix for `flat-mixed`, `rich-mixed`, and `flat-prose`.
Those durable copies are under `after-source-scope/{flat-mixed,rich-mixed,flat-prose}`.
One raw-only rich/mixed run at each `N=256`, `512`, and `1024` is retained
under `after-source-scope/scaling-{256,512,1024}`.  These directories retain
the complete artifacts, raw logs, runner binary, and provenance, without Zig
compiler caches.

Every corresponding artifact in the three after-scope `N=2048` stages was
checked against its baseline for exact byte count and SHA-256; all 12 pairs
are identical.  The full ledger and the single-observation rich build/full
verify tables are in `src6/reviews/benchmark.md`.  The after-scope source
manifest is stable at
`083c2c147b1b91ea6e78bd9ae85b7ed288d17d6d0ad3fea7a80f1c4571065cbc`.
The baseline manifest predates the frozen source-scope and
query-context/compile-contract revisions; neither changed the fixture or
wire inputs.

The cold row retains the same boundary as the baseline: a fresh selected
entry load over memory-resident archive bytes, not a disk-cold read.  The old
source-backed control is narrower and does not include compressed page work.
