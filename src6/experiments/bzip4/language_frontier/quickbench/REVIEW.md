# Quickbench adversarial review

Date: 2026-09-26. Scope: `bench.py` and `worker.py` as a reusable,
one-command complete-frame screen. I did not change either production file.
The focused test suite is `test_bench.py`; it uses only temporary fixture
adapters, does not run the corpus suite, and makes no timing claim.

## Verification performed

```text
PYTHONPATH=src6/experiments/bzip4/language_frontier/quickbench \
  python3 -m unittest discover \
  -s src6/experiments/bzip4/language_frontier/quickbench -p 'test_*.py' -v
```

Result on the current tree: all 12 tests passed. Fixture-suite runtime is
incidental and is not a codec-speed result. The checks cover:

* content-addressed baseline cache miss/hit, with a hit decoded by a fresh
  worker and the encoder counter unchanged;
* byte-corrupt, stale-identity, and coherently tampered cache entries;
  coherent tampering is caught by the independent decode and quarantined;
* input-prefix and block-size changes producing distinct cache identities;
* candidate encodes never being cached, including explicit dependency edits
  and an unlisted sibling Python dependency edit;
* raw round-trip mismatch and non-`bytes` adapter output, with failure logs;
* timeout command/stdout/stderr logs and cleanup of a child spawned by a
  timed-out worker process group;
* a pre-existing target file not masking an encode worker that exits without
  writing output;
* source-prefix and complete-frame hashes matching the tested bytes.

The implementation labels baseline rows `bzip3-block` and `bzip3-whole`.
Invocation metadata identifies these as real vendored native bzip3 blocks in
the B3PY envelope (`32 + 16*blocks` bytes), not upstream `.bz3` framing or an
entropy estimate. Decode latency is explicitly fresh Python process + imports
+ codec startup + file I/O + decode, so it is not a native-kernel throughput
claim.

## Findings

No P1 correctness finding remains in the tested paths. The regressions that
were initially exposed by this review are now fixed in the shared production
files:

* `invoke()` removes the operation target before every worker and requires a
  newly written file at that path, so a successful worker that emits no output
  cannot reuse an old frame.
* Module provenance includes deterministic Python files below the candidate's
  directory (excluding `__pycache__`), while explicit `--dependency` paths
  cover resources outside that directory and non-Python model artifacts.
* Workers run in a fresh process group. A watchdog kills and reaps the group
  on timeout, while command, stdout, stderr, and timeout status artifacts are
  retained.
* A cache hit is independently decoded and hashed. Decode failure quarantines
  the suspect cache entry under an `invalid-*` name before re-raising, so a
  coherent frame/manifest tamper cannot poison later runs.
* Per-codec failures retain the source record, implementation provenance when
  available, artifact directory, artifact paths, and error text. Candidate
  frames are never published to the cache in the default loop.

One low-priority metadata gap remains: an input-acquisition failure that occurs
before `source` exists is recorded by the outer loop as only `{input, error}`;
there is no tested prefix hash or codec artifact to attach in that case. This
does not affect completed-frame rows or per-codec worker failures, but a future
revision could include the run/sample directory and a structured failure kind.

The worker is a trusted local experiment boundary, not a security sandbox.
Decoder specs contain only the codec identity needed to interpret a
self-contained frame; encoder options, dependency paths, and the source path
are not passed to decode.

## Checks that passed

The content key includes the tested prefix's raw SHA-256/length, block size
through codec identity, the actual v4 executable or pinned bzip3 control
library, Python executable/version/platform, harness files, candidate options,
and dependency hashes. Baseline hits are copied, decoded in a fresh process,
and rehashed; candidate frames are not cached by the default loop. Candidate
bytes must be real `bytes`, and successful rows require exact source
reconstruction.
