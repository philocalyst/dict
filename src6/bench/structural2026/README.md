# Reserved evaluation sources for deeper structural designs

These sources were restored on 2026-10-01 after the original 22-lane comparison
had been frozen. They are reserved for a new evaluation after each deeper
candidate's source, binary, format and selection policy have been frozen.
Do not use their compression results to select or adjust candidates and then
call the same results heldout evidence. A subsequent adjustment needs another
evaluation source or must be reported as exploratory.

Run from the repository:

```sh
python3 src6/bench/structural2026/prepare_holdout.py
python3 -m unittest discover -s src6/bench/structural2026 -p 'test_*.py'
```

The default output is `/workspace/scratch/structural-holdout`. Pass
`--output-dir PATH` to relocate it or `--skip-fetch` to require retained inputs.
Every source and license is checked against the byte count and SHA-256 in
[sources.json](sources.json), including on a cached run. Downloads use immutable
Git commit URLs; there is no mutable branch or unverified download fallback.
Corpus bytes are not committed.

The seven Universal Dependencies PUD treebanks use the independently checked
`r2.17` commit pins. Japanese, Chinese, Arabic, Turkish, Finnish, Korean and
Hindi each contribute their complete 1,000-sentence test treebank. PUD contains
aligned translations, so these are seven new treebanks and script/morphology
workloads, **not seven statistically independent sources**. Earlier explorations
used Finnish TDT, Turkish IMST and Arabic PADT; the first evaluation used
Japanese GSD, Chinese GSD, English EWT, Spanish AnCora and Russian SynTagRus.
Those earlier results do not become fresh holdouts by renaming them.

Each PUD treebank yields two explicitly distinct inputs: sentence-comment prose
and official integer-ID FORM fields. The projector preserves UTF-8 bytes,
combining marks, Unicode spaces and embedded Unicode separators; it removes an
optional CR at a source line ending and emits one LF per complete sentence.
FORM fields are joined by ASCII spaces. Multiword-token ranges and empty-node
decimal IDs are metadata and do not create additional FORM occurrences. All
ten integer-token annotation fields remain in a separate JSONL oracle, which is
not supplied as a hidden model or prediction table to compressors. Missing text,
invalid UTF-8, malformed rows and noncontiguous token IDs fail preparation.

The new FreeDict sources are Turkish→English, Arabic→English and
Japanese→English at commit `5bdceeac8d0dba3298c1bebe734f60d54dad30f7`.
Turkish and Arabic use all lexical records. Japanese uses complete records with
`SHA-256(source_entry_id) modulo 16 == 0`, preserving source order; this subset
rule was chosen before observing any codec results. It yields a useful full
7.67 MB lexical-content stream within the prototype input bounds. No record is
truncated and the original full source remains pinned. Stable source identities
use XML IDs when available and declared source ordinals otherwise.

FreeDict projection uses the existing independent TEI entry oracle. Its input
contract is the complete serialized entry element, its keys and mixed text,
with XML serialization and source-line-ending normalization declared. The full
raw TEI remains retained. This is **not a complete lexical TEI importer** and
does not claim preservation of original XML spelling, headers, comments or
every document-level semantic relationship in a native Entry. The native
format's richer semantic tests and exact byte-compressor roundtrips are separate
checks.

There are 20 lanes totaling 32,609,918 bytes: 14 PUD prose/FORM lanes and six
FreeDict content/key lanes. Aggregates must keep content and word-list scopes
explicit because related projections represent different workloads. Native
source/page equality, complete frame/model/index costs, strong grammar controls
and whole-file versus equal-restart controls remain required. Source and license
manifests accompany every projection. PUD licenses are CC BY-SA 3.0 except
Finnish CC BY-SA 4.0; FreeDict license files are retained verbatim, including the
Turkish GPL, Arabeyes GPL and Japanese CC BY-SA 3.0 terms.

Source restoration is preparation, not a measured compression improvement.
Development-only negative screens stay labeled development.
