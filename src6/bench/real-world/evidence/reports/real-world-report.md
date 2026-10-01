# Independent real-world dictionary evidence

## Status

The complete three-corpus preparation, independent core-format smoke matrix, and bounded LEX6 page/bzip3 decomposition all completed successfully.  This ledger contains correctness and storage evidence only: no latency or throughput clock was read.  The root-only `ROOT-EXPLICIT-QUIET-GATE` is still required before any timing command is valid.

All three corpora use the full pinned input selected in the manifest; no 2,048/8,192-row or other cherry-picked subset was used.  Every parser reported zero malformed records or unresolved OMW references.  The independent oracle retains source order, source IDs, every key occurrence, homographs, Unicode, empty content, and full normalized content; readers are checked against it rather than receiving expected answers.

## Corpus provenance and projection

| corpus | archive | archive checksum | license | source retained | rows / unique keys / hits | content / projection |
| --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 3,715,012 B | SHA-256 dd724fb48c570139… | CC BY-SA 3.0 | 34,974,718 B / 10 files | 64,258 / 59,253 / 64,258 | 43,700,255 B / 90,123,314 B |
| GNU GCIDE 0.54 | 14,803,080 B | SHA-256 22416f6f36175b16… | GPL-3.0-or-later | 63,323,138 B / 37 files | 124,187 / 115,327 / 131,563 | 58,808,436 B / 123,479,075 B |
| OMW Japanese 2.0 | 55,846,636 B | SHA-256 c369a2ad773a31e1… | NICT Japanese WordNet license | 55,599,059 B / 4 files | 94,002 / 91,964 / 94,002 | 112,147,272 B / 229,392,768 B |

Exact provenance URLs and full checksums are in `../corpora/manifest.json` and `../runs/environment.json`; the abbreviated table is only for readability.

### FreeDict eng-spa

Source: [https://download.freedict.org/dictionaries/eng-spa/2025.11.23/freedict-eng-spa-2025.11.23.src.tar.xz](https://download.freedict.org/dictionaries/eng-spa/2025.11.23/freedict-eng-spa-2025.11.23.src.tar.xz); archive `/private/tmp/dictionary-real-world-cache/sources/freedict-eng-spa-2025.11.23.src.tar.xz` (3,715,012 bytes, SHA-256 `dd724fb48c5701395c15d7d648a9e6f6b75d6ff4269e465dce6d3a292700198d`, SHA-512 `622e8fec6c4178cb4c21e4577701c5325670f825331b07a185b4c6b810603c337e80429738a97581f68f668667910e7ad36f27332eaee2828f1f906537852fe3`); retained license `/private/tmp/dictionary-real-world-cache/extracted/freedict-eng-spa-2025.11.23/eng-spa/COPYING` (SHA-256 `41a8f57655bae359bea4a7e99c7a2aed171687d3dfb49614214538ba6dcbe75b`).
The parser consumed the complete TEI `eng-spa.tei` entry set.  Front matter outside entries is excluded from the matched rows; each row preserves every form, pronunciation, label, sense, translation, example, and nested child as deterministic normalized TEI XML.
Projection counts: 64,258 source lexical rows, 59,253 unique keys, 64,258 key occurrences, 5,005 repeated-key hits; normalized content totals 43,700,255 B (largest row 6,142 B).  `projection.tsv` SHA-256 is `687008296b727878d26472bca5315beca8136a64365f2ac819e9e1f7f22f3865` and `rows.jsonl` retains metadata/content hashes and source IDs.

### GNU GCIDE 0.54

Source: [https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz](https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz); archive `/private/tmp/dictionary-real-world-cache/sources/gcide-0.54.tar.xz` (14,803,080 bytes, SHA-256 `22416f6f36175b160dc388b7547512514d464473cf7d7c898d738efb26c51d42`, SHA-512 `9bda8bc2e30a529bafeb3fcdd2f315025209fa2e609da707caf7b4a273221a7617a10b58d2b635e1ae980e01a790a4e09bb74ec54d6e09c9014e72b30d33b1e6`); retained license `/private/tmp/dictionary-real-world-cache/extracted/gcide-0.54/gcide-0.54/COPYING` (SHA-256 `fc82ca8b6fdb18d4e3e85cfd8ab58d1bcd3f1b29abe782895abd91d64763f8e7`).
The parser consumed all CIDE.A through CIDE.Z files and captured each complete SGML entry span through the next `<p><ent>` boundary, including every `<ent>` alias, `<hw>`, paragraphs, labels, citations, and cross-references.  26,564 source bytes of front matter/trailing editor text were outside entry rows; legacy ISO-8859-1 bytes were decoded explicitly and reported in the projection manifest.
Projection counts: 124,187 source lexical rows, 115,327 unique keys, 131,563 key occurrences, 16,236 repeated-key hits; normalized content totals 58,808,436 B (largest row 98,939 B).  `projection.tsv` SHA-256 is `4cddd7f0d23d7ef5dd923ef97b1894f7fff86cc26dbda1a9621653c1338c635b` and `rows.jsonl` retains metadata/content hashes and source IDs.

### OMW Japanese 2.0

Source: [https://github.com/omwn/omw-data/releases/download/v2.0/omw-2.0.tar.xz](https://github.com/omwn/omw-data/releases/download/v2.0/omw-2.0.tar.xz); archive `/private/tmp/dictionary-real-world-cache/sources/omw-2.0.tar.xz` (55,846,636 bytes, SHA-256 `c369a2ad773a31e182ac4cc753132fa7c31ad423586d6783bacce08090cb8d7d`, SHA-512 `5d9d5e3b086a9355b0bc9ea10d593ab843fb6d3b451cf3a91fee11c74700f86daa4966ee78f82ddd64f120bac8c2776558e3859fc0fb848ba6c681580c123325`); retained license `/private/tmp/dictionary-real-world-cache/extracted/omw-2.0/omw-2.0/omw-ja/LICENSE` (SHA-256 `a4be32a83ad0a1cff9a31c23aaa107be20eb843d97c68a2ff72e10ff5ac17cee`).
The parser consumed complete `omw-ja.xml` LexicalEntry records.  Each entry keeps its entire Lemma/Form/Sense markup and appends each referenced Synset's definitions, examples, and relation children exactly once, without recursive graph expansion.  Sense→Synset resolution was complete: 158,069 references, 57,184 unique referenced synsets, and zero unresolved references.
OMW shared-resource expansion is quantified separately: 31,470,675 B of unique referenced Synset XML becomes 86,241,878 B when charged to entries, an introduced duplicate of 54,771,203 B.  This normalized flattening is matched storage evidence; native shared synset/graph richness is not claimed by the flattened lane.
Projection counts: 94,002 source lexical rows, 91,964 unique keys, 94,002 key occurrences, 2,038 repeated-key hits; normalized content totals 112,147,272 B (largest row 19,830 B).  `projection.tsv` SHA-256 is `ff9b2f1e56912bf3874cb77377a6f97949206a3efdff7739a10f61e1f0c43c75` and `rows.jsonl` retains metadata/content hashes and source IDs.

## Format matrix and correctness boundaries

The following lanes are genuinely built/read artifacts.  Validation is independent of construction and includes every distinct exact key, every source row's content, selected prefixes, and all-hit occurrence counts.  A native tool is used for representative edge checks where available; CLI startup/transport is not silently treated as in-process reader latency.

| lane | storage/reader | FreeDict | GCIDE | OMW Japanese | boundary |
| --- | --- | --- | --- | --- | --- |
| LEX6 raw / adaptive / forced bzip3 | public src6 archive API via independent runner | smoke-ok | smoke-ok | smoke-ok | all entries/hits/content/rendering checked; page diagnostics below |
| StarDict raw | real `.ifo/.idx/.syn/.dict`; independent binary reader + genuine sdcv | ok | ok | ok | sdcv uses 8 finite representative cases; custom reader exhaustive exact/content checks |
| DICT raw | real `.dict/.index`; independent reader + `dictunformat` | ok | ok | ok | dictd server transport not started |
| dictzip | real `dict.dict.dz`; full decompression + `dictzip` range | ok | ok | ok | random-access compressed payload; whole-file gzip is not substituted |
| SLOB raw / lzma2 | real Python SLOB writer/reader, ICU recorded separately | ok | ok | ok | full identity setup/eager validation is outside any future timed fresh-open sample |
| SQLite control | real indexed SQLite key/content tables + sqlite3 CLI | ok | ok | ok | indexed control, not a dictionary-native protocol |
| LEX5 | frozen source test build probe | unavailable adapter | unavailable adapter | unavailable adapter | no corpus build/reader frontend exposed by src5/root.zig/build5.zig |
| src4 bench frontend | frozen compiled `lex4-bench` | unavailable adapter | unavailable adapter | unavailable adapter | binary accepts its semantic fixture protocol, not the full projection TSV |
| src2 bench frontend | frozen compiled `src2-bench` | unavailable adapter | unavailable adapter | unavailable adapter | binary accepts its semantic fixture protocol, not the full projection TSV |

External validation counts (per corpus) are recorded in each smoke JSON.  StarDict aliases use `.syn` with one primary payload per source row; SLOB uses one native blob with multiple keys; SQLite has explicit key-index rows; DICT shares offsets among aliases.  Where a format lacks source row identity, the validation maps occurrence multisets by key/content and never invents a persisted identity comparison.

Primary format references used for the adapters: [StarDict file format](https://github.com/huzheng001/stardict-3/blob/master/dict/doc/StarDictFileFormat), [sdcv](https://github.com/Dushistov/sdcv), [DICT RFC 2229](https://www.rfc-editor.org/info/rfc2229/), [dictzip reference](https://manpages.opensuse.org/Leap-16.0/dictd/dictzip.1.en.html), [SLOB reference implementation](https://github.com/itkach/slob), and [SQLite file format](https://www.sqlite.org/fileformat.html).  These references define the storage/reader boundaries; they do not turn custom Python readers into native implementations.

The legacy compile probes are preserved verbatim in [`legacy-availability.json`](../runs/legacy-availability.json): LEX5 returned code 0 for its tests but exposed no artifact/frontend; src4 and src2 returned code 0 and produced binaries (SHA-256 `412cabd14ef6c501` and `b588e63c769a915e` respectively), but their `--help` invocations returned `InvalidArgument` and no adapter can represent this full projection.  They are therefore not timed or presented as failed format implementations.

## 64 KiB smoke artifacts

| corpus | rows / keys / hits | LEX6 raw | adaptive | forced bzip3 | pages | external validation |
| --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 64,258/59,253/64,258 | 48,271,065 B | 6,403,150 B | 6,403,150 B | 728 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |
| GNU GCIDE 0.54 | 124,187/115,327/131,563 | 67,821,905 B | 16,272,334 B | 16,272,334 B | 1020 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |
| OMW Japanese 2.0 | 94,002/91,964/94,002 | 119,585,081 B | 12,218,478 B | 12,218,478 B | 1837 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |

Raw/adaptive/bzip3 LEX6 artifacts are byte-hashed in the smoke ledgers and retained under `/tmp/dictionary-real-world-evidence`; every LEX6 run reports `smoke-ok`, all-hit/content digests matching the external oracle, and fixed-representative query checks.  The current all-corpus `main-smoke.json` uses the fixed representative LEX6 query workload, while the independent external readers validate every distinct exact key.

An explicitly exhaustive, non-timed LEX6 query audit is retained in [`all-exact-smoke.json`](../runs/all-exact-smoke.json).  It queried every distinct exact key through each raw/adaptive/forced-bzip3 archive in addition to the fixed edge cases; the counts below include those edge cases.

| corpus | distinct exact keys | LEX6 query checks by codec |
| --- | --- | --- |
| FreeDict eng-spa | 59,253 | raw=59,258, adaptive=59,258, bzip3=59,258 |
| GNU GCIDE 0.54 | 115,327 | raw=115,331, adaptive=115,331, bzip3=115,331 |
| OMW Japanese 2.0 | 91,964 | raw=91,969, adaptive=91,969, bzip3=91,969 |

## Bzip3/adaptive decomposition

Each page-size lane first opens and fully verifies its archive and then measures the actual selected page codec, raw and encoded page lengths, page count, metadata (`header + index + directory`), payload, and probe result.  `max_page_bytes` and `max_document_bytes` stayed at 1 MiB for all targets, so the 16/64/256 KiB values are target page sizes rather than an accidental bzip3 block-limit reduction.  Oversized documents remain intact.

| corpus | target | pages | raw file | adaptive file | adaptive metadata | raw/adaptive payload | selected bzip/raw | probe |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 16 KiB | 2967 | 48,414,361 | 8,396,956 | 1,071,545 (12.76%) | 47,342,816 / 7,325,411 | 2967/0 raw | 2967 smaller; 0 limit fallback |
| FreeDict eng-spa | 64 KiB | 728 | 48,271,065 | 6,403,150 | 928,249 (14.50%) | 47,342,816 / 5,474,901 | 728/0 raw | 728 smaller; 0 limit fallback |
| FreeDict eng-spa | 256 KiB | 181 | 48,236,057 | 5,447,326 | 893,241 (16.40%) | 47,342,816 / 4,554,085 | 181/0 raw | 181 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 16 KiB | 4192 | 68,024,913 | 20,335,644 | 1,865,836 (9.18%) | 66,159,077 / 18,469,808 | 4192/0 raw | 4192 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 64 KiB | 1020 | 67,821,905 | 16,272,334 | 1,662,828 (10.22%) | 66,159,077 / 14,609,506 | 1020/0 raw | 1020 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 256 KiB | 254 | 67,772,881 | 13,957,358 | 1,613,804 (11.56%) | 66,159,077 / 12,343,554 | 254/0 raw | 254 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 16 KiB | 7840 | 119,969,273 | 19,004,701 | 1,935,807 (10.19%) | 118,033,466 / 17,068,894 | 7840/0 raw | 7840 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 64 KiB | 1837 | 119,585,081 | 12,218,478 | 1,551,615 (12.70%) | 118,033,466 / 10,666,863 | 1837/0 raw | 1837 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 256 KiB | 453 | 119,496,505 | 9,788,129 | 1,463,039 (14.95%) | 118,033,466 / 8,325,090 | 453/0 raw | 453 smaller; 0 limit fallback |

For every corpus and every target, adaptive selected bzip3 on every page: 0 raw fallbacks, 0 resource-limit fallbacks, 0 probe errors, and every bzip3 probe was smaller.  Consequently adaptive and forced-bzip3 artifacts are byte-identical within each target.  This is a measured result on these real inputs, not an assumption inherited from synthetic fixtures.

### Storage causes and losses

| corpus | normalized content | LEX6 raw payload overhead | 64 KiB metadata | adaptive selection | adaptive payload |
| --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 43,700,255 B | 47,342,816 B (+3,642,561; 8.34%) | 928,249 B / 14.50% | 728 bzip3, 0 raw | 5,474,901 B |
| GNU GCIDE 0.54 | 58,808,436 B | 66,159,077 B (+7,350,641; 12.50%) | 1,662,828 B / 10.22% | 1020 bzip3, 0 raw | 14,609,506 B |
| OMW Japanese 2.0 | 112,147,272 B | 118,033,466 B (+5,886,194; 5.25%) | 1,551,615 B / 12.70% | 1837 bzip3, 0 raw | 10,666,863 B |

The raw-payload excess over normalized content is packet/model framing and per-entry/key representation charged identically to the LEX6 lane; it is not silently attributed to bzip3.  The metadata floor is hot index/catalog/directory data and remains uncompressed in the archive.  Larger pages reduce page count and metadata (and reduce adaptive total storage here) but provide coarser random-access granularity; the report does not turn that storage trade-off into a latency claim.

GCIDE demonstrates the document-boundary limit: at 16 KiB its largest raw page is 112,754 B because an oversized source entry is retained rather than dropped or split.  OMW's many short Japanese entries produce 7,840 pages at 16 KiB, so its metadata fraction is correspondingly higher.  These are measured page distributions, not generic codec explanations.

### Whole-stream bzip3 control (storage-only)

| corpus | whole raw content | whole bzip3 | whole ratio | paged adaptive | whole digest |
| --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 43,700,255 B | 2,630,650 B | 0.060x | 6,403,150 B (64 KiB pages) | 3a6c83d9742629a2… |
| GNU GCIDE 0.54 | 58,808,436 B | 7,826,936 B | 0.133x | 16,272,334 B (64 KiB pages) | 4af9b2ba3e8419a4… |
| OMW Japanese 2.0 | 112,147,272 B | 4,415,789 B | 0.039x | 12,218,478 B (64 KiB pages) | c462e401adaad163… |

The whole-stream control concatenates normalized content only and compresses it once.  It omits LEX6 packet/model bytes, index/catalog/directory metadata, and page restart boundaries; it is therefore a storage diagnostic for compression horizon, not a random-access-equivalent dictionary format and not a query-performance result.

## Reproduction and retained evidence

All commands below are bounded and non-timed unless a future measurement command explicitly passes the root gate.  The current ledgers were produced with the Nix development environment where SLOB/PyICU and native dictionary tools are available.

```sh
python3 src6/bench/real-world/prepare.py fetch --cache-dir /tmp/dictionary-real-world-cache
python3 src6/bench/real-world/prepare.py project --cache-dir /tmp/dictionary-real-world-cache --output-dir src6/bench/real-world/evidence/corpora
python3 -m unittest -v src6/bench/real-world/test_prepare.py
/etc/profiles/per-user/mileswirht/bin/zig build -Doptimize=ReleaseSafe --build-file src6/bench/real-world/build.zig
nix develop .# --command python3 src6/bench/real-world/smoke.py --output src6/bench/real-world/evidence/runs/main-smoke.json
nix develop .# --command python3 src6/bench/real-world/smoke.py --corpus gcide-054 --reuse-lex6 --output src6/bench/real-world/evidence/runs/gcide-smoke.json
nix develop .# --command python3 src6/bench/real-world/smoke.py --corpus omw-ja-20 --reuse-lex6 --output src6/bench/real-world/evidence/runs/omw-ja-smoke.json
nix develop .# --command python3 src6/bench/real-world/sweep.py --output src6/bench/real-world/evidence/runs/page-sweep.json
nix develop .# --command python3 src6/bench/real-world/legacy_probe.py
python3 src6/bench/real-world/verification.py
nix develop .# --command python3 src6/bench/real-world/inventory.py --output src6/bench/real-world/evidence/runs/environment.json
# after the root grants the literal gate: nix develop .# --command python3 src6/bench/real-world/measure.py --quiet-gate ROOT-EXPLICIT-QUIET-GATE
python3 src6/bench/real-world/report.py --output src6/bench/real-world/evidence/reports/real-world-report.md
```

Retained ledgers: [`corpora/manifest.json`](../corpora/manifest.json), [`main-smoke.json`](../runs/main-smoke.json), [`all-exact-smoke.json`](../runs/all-exact-smoke.json), [`gcide-smoke.json`](../runs/gcide-smoke.json), [`omw-ja-smoke.json`](../runs/omw-ja-smoke.json), [`page-sweep.json`](../runs/page-sweep.json), [`legacy-availability.json`](../runs/legacy-availability.json), [`verification.json`](../runs/verification.json), and [`environment.json`](../runs/environment.json).  `environment.json` inventories every regular file beneath the retained main/sweep/timed-build/measurement-plan roots, including generated `.idx.oft` sdcv sidecars, and records source archive/license/extracted-tree byte costs plus SHA-256/SHA-512 hashes.  It also hashes the owned harness, exact LEX6 production/build inputs, vendored bzip3 source tree, and the compiled `real-lex6` binary.

The environment ledger reports Zig 0.16.0, Nix/Lix 2.95.2, sdcv 0.5.5, dictd tools 1.13.3, SQLite 3.53.3, Python 3.14.7, SLOB from the pinned Nix environment, and PyICU 2.16.2/ICU 78.3.  A nonzero `--version` return code for some dictd utilities is preserved as probe behavior; the executable path and printed version are still recorded, and actual format validation return codes are recorded separately.

## Timing gate and interpretation limits

Timing remains intentionally absent (`timing: not run` in every current ledger).  After the parent grants the literal `ROOT-EXPLICIT-QUIET-GATE`, the fixed schedule is three paired fresh-process 64 KiB runs per available format/codec, one declared warmup, 256-operation batches for fast exact/missing/load/render/snippet work, three bounded prefix batches after one all-hit correctness pass, and three startup samples.  The page sweep remains one build/open/verify/control run at 16/64/256 KiB.  Fresh process does not mean cold disk: hot OS cache versus any explicitly established cold condition will be labelled separately.

CLI process startup/transport, eager decode/identity setup, native ICU behavior, and custom in-process readers are separate operations.  No cross-language microsecond ranking will be claimed.  Losses and unavailable lanes remain visible alongside storage wins; no failed lane is eligible for timing.

