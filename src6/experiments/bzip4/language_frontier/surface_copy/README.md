# Surface copy experiment

This lane codes bytes from a causal copy posterior plus recursive context
backoff. It sends no source pointer or parse identity. It preserves arbitrary
byte strings and initializes only from the decoded prefix. The implementation
is experimental; no production files are changed.

`RULES.md` specifies SCM3's source and wire before the complete-frame screen.
`codec.py` is a quickbench adapter with `encode(raw, *, block_bytes, **options)`
and `decode(frame)`. Parameters, lengths, raw SHA256, payload CRC32, arithmetic
padding and every restart are charged. Blocks are limited to 64 KiB and output
to 8 MiB. Each block resets all learned context/index/posterior state.

```
python3 src6/experiments/bzip4/language_frontier/surface_copy/test_codec.py
python3 src6/experiments/bzip4/language_frontier/surface_copy/screen.py
```

The predeclared 24-policy screen uses 2 KiB development prefixes of web2,
FreeDict, OMW Japanese and Finnish/Turkish/Arabic UD forms. It records actual
frames, hashes and exact local roundtrips. `runs/screen-v3/frozen.json` ranks
aggregate frame bytes across all six corpora; no per-corpus policy is selected.
SCM1/2 diagnostic frames in earlier directories are excluded from current-wire
claims and are intentionally incompatible with the SCM3 decoder.

The same source's literal-only ablation uses `start=0`; all other arithmetic
and framing machinery is identical. Real native baseline comparisons use the
root's generic quickbench, with its cache and artifacts redirected into this
lane. Storage screens collect no latency samples under concurrent work.

Posterior support is bounded, but indexes and context tables are not constant
space: they grow with the capped block. `cost.py` records reachable Python
state bytes and actual index/frontier/context counts, rather than inferring
memory or throughput from a state-count slogan.

`SCM4.md` describes a separate cumulative-query quantizer proposed to remove
alphabet-wide probability materialization. It changes the source probabilities
and must use a different magic. It is evaluated against a dense implementation
of exactly the same cumulative law, then against SCM3 complete frames.
