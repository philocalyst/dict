# Binding lane results (2026-09-26)

Status: **rejected as a storage candidate on the first complete screen**.
The bounded parameterized context/derivation frame round-trips exactly and
passes the synthetic repeated-binding and arbitrary-byte tests, but loses the
existing v4 compressor on every held-out dictionary.  The negative result is
retained: the model saturated at 96 templates and 512 bindings, and its
complete charged model cost outweighed any payload locality.

## Frozen screen

The command was run serially on the pinned frontier projections:

```text
PYTHONPATH=src6/experiments/bzip4 python3 -m language_frontier.binding.screen \
  --output src6/experiments/bzip4/language_frontier/binding/evidence/results.screen.json
```

Policy: training `[0, 1,048,576)`, held-out development `[1,048,576,
1,310,720)`, 64 KiB blocks, `max_templates=96`, `max_bindings=512`,
`min_uses=2`, `max_context=1024`, at most six slot occurrences, zlib level 9
diagnostic payload.  The v4 control is the retained
`bz4 c IN OUT 65536` followed by `bz4 d OUT RESTORED 1`; its output is not a
timing measurement.  The capture used Python 3.14.7 / zlib 1.2.12 and v4
binary SHA-256 `17cda3b68a1b0f8b0535c99cc77fdc0220351f210171c04620c1db6ace4f7fcc`.

| corpus | binding complete | model | payload | templates/bindings | raw zlib diagnostic | v4 control | binding vs v4 |
|---|---:|---:|---:|---:|---:|---:|---:|
| FreeDict eng-spa | 41,514 | 8,356 | 32,986 | 96 / 512 | 28,720 | 24,463 | +69.7% |
| GCIDE 054 | 82,828 | 7,381 | 75,275 | 96 / 512 | 65,877 | 57,838 | +43.2% |
| OMW Japanese | 49,736 | 23,972 | 25,592 | 96 / 512 | 21,654 | 19,227 | +158.6% |

Directory bytes are 120 B (five independent blocks).  The exact row-level
hashes and v4 compressed/restored hashes are in
[`evidence/results.screen.json`](evidence/results.screen.json).  Every binding
row and every v4 control reports `status=ok`; binding decode output SHA-256
equals the held-out input SHA-256.

## Interpretation

The anti-unification mechanism is real: synthetic records with varied words
share one ranked context, and records repeating the same word use one binding
ID across several slots.  The corpus result is nevertheless a clean negative.
On real XML-heavy lines, a byte-only scanner sees tag words as potential slots,
so useful contexts require many literal/slot fields.  The 96-template and
512-binding caps are reached, especially for OMW, and the complete model is
larger than the saving in the held-out payload.  The old byte-class experiment
failed because it destroyed word adjacency; this lane preserves adjacency but
still pays too much for learned contexts.

The v4 control is input-fit while the binding model is frozen from the prefix,
so this comparison is deliberately conservative against the candidate.  The
screen is diagnostic only and does not justify a native speed claim.  No
production codec or shared source was changed.

## Retained tests and limits

`test_codec.py` covers repeated variable identity, unseen inline bindings,
empty input, invalid UTF-8/high/control bytes, deterministic random no-repeat
data, corruption rejection, CRC/metadata checks, and exact output equality.
No full timing run was started.  The model's negative row is retained rather
than tuned per corpus.
