# Operator reset screen

`operator_probe.py` loads the already-written latent-belief HMM teachers and
measures exact phrase operators, rank-one/reset diagnostics, and closed-rollout
NLL.  It is intentionally separate from `belief/` and `bz4/`; it does not
train, rewrite, or serialize a production frame.

From the repository root:

```sh
python3 src6/experiments/bzip4/language_frontier/operators/operator_probe.py \
  --out src6/experiments/bzip4/language_frontier/operators/results.json
python3 -m unittest discover -s src6/experiments/bzip4/language_frontier/operators \
  -p 'test_*.py'
```

The default run directory is
`belief/runs/latent-belief-dev-20260926`.  The probe reads only each case's
`train.bin`, `dev.target.bin`, and `teacher-k8.json`, with a fallback to the
highest existing teacher only if a case has no k8 file.  Inputs are capped at
64 KiB and a guard rejects `*.untouched.bin`.

See [PROPOSAL.md](PROPOSAL.md) for the matrix algebra, complete prefix-code
normalization, primary-source context, and accounting caveats.  `results.json`
is exploratory evidence: its model sizes are actual serialized diagnostic
blobs, not a complete compressed archive and not a claim against v4.

