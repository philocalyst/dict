# Binding lane: reusable variable-bearing contexts

This lane tests whether lexical records can share a *parameterized* context
when their word/phrase arguments differ.  A bounded ranked program stores
literal byte islands and one to six slot occurrences; a derivation stores the
exact binding for each distinct slot (including repeated variable IDs).  It is
not an exact-substring SLP, a byte-class side stream, a static row alias, or an
adaptive language model.

The implementation is `codec.py`.  It trains only on bytes supplied by the
caller, writes all learned literals/bindings into a `BNG1` frame, and has a raw
event fallback.  The zlib payload backend is explicitly diagnostic.  Run the
small correctness suite with:

```text
PYTHONPATH=src6/experiments/bzip4 python3 -m unittest language_frontier.binding.test_codec
```

Run the serial 256 KiB development screen with:

```text
PYTHONPATH=src6/experiments/bzip4 python3 -m language_frontier.binding.screen \
  --output src6/experiments/bzip4/language_frontier/binding/evidence/results.screen.json
```

The screen follows the frozen frontier protocol: train `[0, 1 MiB)`, evaluate
`[1 MiB, 1.25 MiB)`, use 64 KiB blocks, and compare complete bytes with the
existing v4 CLI.  `RESULTS.md` records the outcome and the evidence JSON keeps
input/frame hashes, model/directory/payload breakdowns, commands, and exact
round-trip statuses.
