# Frozen UD TRAIN resource lane

`prepare_ud_train.py` freezes commit-pinned official Universal Dependencies
TRAIN files and splits each by sentence index before candidate inspection:

* `exploratory-80`: records `[0, floor(0.8*N))`, safe for future candidate
  development;
* `confirmation-20`: records `[floor(0.8*N), N)`, a new untouched
  confirmation holdout.

The confirmation directories are explicitly labelled in
`ud-train-manifest.json` and must not be benchmarked or shown to implementors
until root freezes candidate(s).  No codec run has used either TRAIN resource.
The existing test corpora remain separate and are now development resources
because their bytes/results have been visible.

Downloaded new raw bytes are 16,512,835 of the 25 MiB cap:

* Finnish-TDT TRAIN: 13,375,770 bytes, raw SHA-256
  `07217d128d3752e61f1249c1e57de402ca17b31d2fba479d4f857ff78e28b40d`;
  pinned commit `bfaae13719f249573d940edda6a0d7aa8eec620f`, Git blob
  `ad70aa08b4c3aa0bec5a631c9db1222968b4cc05`.
* Turkish-IMST TRAIN: 3,139,065 bytes, raw SHA-256
  `d7d65fb10bd0f6ed6ecb0258938d6d126a2b93b409582759d2b52195dd5b7313`;
  pinned commit `0c939115d8277ecfb39e1bbc3f066b1852ab5ddc`, Git blob
  `af49df52e2ba6b04ab2ea58d2a964a1efbc893c7`.

Arabic-PADT TRAIN was intentionally not downloaded: the commit-pinned raw
file is 40,698,415 bytes and would exceed the bounded budget by itself.  The
omission, URL, commit, and size are recorded in `ud-train-manifest.json`.
