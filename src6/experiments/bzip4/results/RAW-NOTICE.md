# Round-one raw-output retention notice

The round-one runner stdout was captured by the interactive tool session but
was not written verbatim to workspace files at execution time. It cannot be
retroactively represented as an original raw log or hashed runner artifact.

`round1-storage.tsv` and `round1-timing.tsv` transcribe the numeric fields from
those captured outputs, including all accepted samples and the rejected
concurrent probe. `README.md` supplies protocol and interpretation. No missing
raw transcript or original measured executable is claimed.

The input files remain the immutable retained corpora with hashes in
`src6/bench/real-world/evidence/corpora/manifest.json`. Future rounds must save
stdout, source hashes, binary hash, exact command, and input hash before any
summary is written.
