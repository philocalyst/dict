# Independent real-world dictionary evidence

## Status

The complete three-corpus preparation, independent core-format smoke matrix, bounded LEX6 page/bzip3 decomposition, and the fixed gated timing schedule are retained below.  Timed values are descriptive within each lane; they are not a cross-language microsecond ranking.

All three corpora use the full pinned input selected in the manifest; no 2,048/8,192-row or other cherry-picked subset was used.  Every parser reported zero malformed records or unresolved OMW references.  The independent oracle retains source order, source IDs, every key occurrence, homographs, Unicode, empty content, and full normalized content; readers are checked against it rather than receiving expected answers.

## Corpus provenance and projection

| corpus | archive | archive checksum | license | source retained | rows / unique keys / hits | content / projection |
| --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 3,715,012 B | SHA-256 dd724fb48c570139… | CC BY-SA 3.0 | 34,974,718 B / 10 files (baseline environment ledger; source paths are not claimed live) | 64,258 / 59,253 / 64,258 | 43,700,255 B / 90,123,314 B |
| GNU GCIDE 0.54 | 14,803,080 B | SHA-256 22416f6f36175b16… | GPL-3.0-or-later | 63,323,138 B / 37 files (baseline environment ledger; source paths are not claimed live) | 124,187 / 115,327 / 131,563 | 58,808,436 B / 123,479,075 B |
| OMW Japanese 2.0 | 55,846,636 B | SHA-256 c369a2ad773a31e1… | NICT Japanese WordNet license | 55,599,059 B / 4 files (baseline environment ledger; source paths are not claimed live) | 94,002 / 91,964 / 94,002 | 112,147,272 B / 229,392,768 B |

Exact provenance URLs and full checksums are in `../corpora/manifest.json` and `../runs/environment-post-review.json`; the abbreviated table is only for readability.  Extracted-source byte totals above are baseline environment ledger; source paths are not claimed live.

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
| SLOB raw / lzma2 | real Python SLOB writer/reader, ICU recorded separately | ok | ok | ok | timed reader-ready includes native open plus explicitly charged refs sidecar setup; build validation is separate |
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
| FreeDict eng-spa | 64,258/59,253/64,258 | 48,271,065 B | 6,406,243 B | 6,406,243 B | 728 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |
| GNU GCIDE 0.54 | 124,187/115,327/131,563 | 67,821,905 B | 16,274,792 B | 16,274,792 B | 1020 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |
| OMW Japanese 2.0 | 94,002/91,964/94,002 | 119,585,081 B | 12,223,578 B | 12,223,578 B | 1837 | StarDict=ok; DICT=ok; dictzip=ok; SQLite=ok; SLOB raw=ok; SLOB lzma2=ok |

Raw/adaptive/bzip3 LEX6 artifacts are byte-hashed in the smoke ledgers and retained under the artifact root recorded by `environment-post-review.json`; every LEX6 run reports `smoke-ok`, all-hit/content digests matching the external oracle, and the post-review ledger `main-smoke-post-review.json` checks every distinct exact key.  Independent external readers also validate every distinct exact key.

## Alias and payload fairness audit

The post-review fairness ledger [`fairness-audit-post-review.json`](../runs/fairness-audit-post-review.json) is non-timed and is keyed to the fresh smoke ledger `main-smoke-post-review.json` plus the retained projection hashes.  Every current native bundle path and SHA-256 matched at audit time.  Each external format stores one content payload per source row; aliases are index occurrences, not duplicated payloads.  StarDict `.syn`, DICT index entries, SQLite key rows, and SLOB identity refs are charged as their actual format or explicitly labeled harness boundaries.

| corpus | rows / key hits | multi-key rows / max aliases | payload once | occurrences | largest grouped span | status |
| --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 64,258/64,258 | 0; max 1 | ok | ok | n/a | ok |
| GNU GCIDE 0.54 | 124,187/131,563 | 5,089; max 1,179 | ok | ok | 1179 keys; ent=1179, hw=1179, paired=True, before-hw=True | ok |
| OMW Japanese 2.0 | 94,002/94,002 | 0; max 1 | ok | ok | n/a | ok |

GCIDE's 1,179-key maximum span is corroborated from the retained projection content: 1,179 `<ent>` values equal 1,179 `<hw>` values, all `<ent>` tags precede the first `<hw>`, with 2 paragraphs and 1,181 definitions.  It is a genuine grouped alias span, not an embedded cross-reference list.

## 64 KiB full artifact storage

The table below reports every retained 64 KiB lane, including competitor files that are not part of the LEX6 layout table.  `native bytes` are the format files a native reader needs; `harness sidecar` is charged separately for row/identity mapping used only to validate aliases and source-order occurrences.  `total` is the complete retained bundle for that lane, and component names preserve the exact file boundary.

| corpus | lane | native components / LEX6 breakdown | native bytes | harness sidecar | total bytes |
| --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | LEX6 raw | metadata=928,249; payload=47,342,816 | 48,271,065 | 0 | 48,271,065 |
| FreeDict eng-spa | LEX6 adaptive | metadata=928,249; payload=5,477,994 | 6,406,243 | 0 | 6,406,243 |
| FreeDict eng-spa | LEX6 bzip3 | metadata=928,249; payload=5,477,994 | 6,406,243 | 0 | 6,406,243 |
| FreeDict eng-spa | stardict | stardict.ifo=196, stardict.idx=1,200,757, stardict.syn=0, stardict.dict=43,700,255, stardict.rows.json=695,909 | 44,901,208 | 695,909 | 45,597,117 |
| FreeDict eng-spa | dict | dict.index=1,264,640, dict.dict=43,700,255, dictionary.rows.json=105 | 44,964,895 | 105 | 44,965,000 |
| FreeDict eng-spa | dict dictzip | dict.index=1,264,640, dict.dict.dz=5,408,846 | 6,673,486 | 0 | 6,673,486 |
| FreeDict eng-spa | sqlite | dictionary.sqlite=56,295,424 | 56,295,424 | 0 | 56,295,424 |
| FreeDict eng-spa | slob | dictionary.raw.slob=46,005,219, dictionary.raw.slob.refs.json=9,365,519 | 46,005,219 | 9,365,519 | 55,370,738 |
| FreeDict eng-spa | slob lzma2 | dictionary.lzma2.slob=7,315,317, dictionary.lzma2.slob.refs.json=9,365,521 | 7,315,317 | 9,365,521 | 16,680,838 |
| GNU GCIDE 0.54 | LEX6 raw | metadata=1,662,828; payload=66,159,077 | 67,821,905 | 0 | 67,821,905 |
| GNU GCIDE 0.54 | LEX6 adaptive | metadata=1,662,828; payload=14,611,964 | 16,274,792 | 0 | 16,274,792 |
| GNU GCIDE 0.54 | LEX6 bzip3 | metadata=1,662,828; payload=14,611,964 | 16,274,792 | 0 | 16,274,792 |
| GNU GCIDE 0.54 | stardict | stardict.ifo=200, stardict.idx=2,176,575, stardict.syn=104,690, stardict.dict=58,808,436, stardict.rows.json=1,783,533 | 61,089,901 | 1,783,533 | 62,873,434 |
| GNU GCIDE 0.54 | dict | dict.index=2,448,371, dict.dict=58,808,436, dictionary.rows.json=106 | 61,256,807 | 106 | 61,256,913 |
| GNU GCIDE 0.54 | dict dictzip | dict.index=2,448,371, dict.dict.dz=15,561,433 | 18,009,804 | 0 | 18,009,804 |
| GNU GCIDE 0.54 | sqlite | dictionary.sqlite=81,633,280 | 81,633,280 | 0 | 81,633,280 |
| GNU GCIDE 0.54 | slob | dictionary.raw.slob=63,304,877, dictionary.raw.slob.refs.json=18,975,030 | 63,304,877 | 18,975,030 | 82,279,907 |
| GNU GCIDE 0.54 | slob lzma2 | dictionary.lzma2.slob=18,530,020, dictionary.lzma2.slob.refs.json=18,975,032 | 18,530,020 | 18,975,032 | 37,505,052 |
| OMW Japanese 2.0 | LEX6 raw | metadata=1,551,615; payload=118,033,466 | 119,585,081 | 0 | 119,585,081 |
| OMW Japanese 2.0 | LEX6 adaptive | metadata=1,551,615; payload=10,671,963 | 12,223,578 | 0 | 12,223,578 |
| OMW Japanese 2.0 | LEX6 bzip3 | metadata=1,551,615; payload=10,671,963 | 12,223,578 | 0 | 12,223,578 |
| OMW Japanese 2.0 | stardict | stardict.ifo=196, stardict.idx=1,938,099, stardict.syn=0, stardict.dict=112,147,272, stardict.rows.json=1,023,093 | 114,085,567 | 1,023,093 | 115,108,660 |
| OMW Japanese 2.0 | dict | dict.index=2,114,970, dict.dict=112,147,272, dictionary.rows.json=105 | 114,262,242 | 105 | 114,262,347 |
| OMW Japanese 2.0 | dict dictzip | dict.index=2,114,970, dict.dict.dz=11,736,855 | 13,851,825 | 0 | 13,851,825 |
| OMW Japanese 2.0 | sqlite | dictionary.sqlite=147,197,952 | 147,197,952 | 0 | 147,197,952 |
| OMW Japanese 2.0 | slob | dictionary.raw.slob=115,711,514, dictionary.raw.slob.refs.json=14,110,633 | 115,711,514 | 14,110,633 | 129,822,147 |
| OMW Japanese 2.0 | slob lzma2 | dictionary.lzma2.slob=13,172,996, dictionary.lzma2.slob.refs.json=14,110,635 | 13,172,996 | 14,110,635 | 27,283,631 |

LEX6 metadata includes its header/index/catalog/directory and payload is the page region; external sidecars are never presented as native compression or reader storage.  DICT and dictzip each include their own index because that index is required for lookup; the dictzip row counts `.dz` rather than the raw `.dict` retained as the builder input.  SLOB `.refs.json` is the explicitly charged identity bridge, not part of the SLOB file.

## Bzip3/adaptive decomposition

Each page-size lane first opens and fully verifies its archive and then measures the actual selected page codec, raw and encoded page lengths, page count, metadata (`header + index + directory`), payload, and probe result.  `max_page_bytes` and `max_document_bytes` stayed at 1 MiB for all targets, so the 16/64/256 KiB values are target page sizes rather than an accidental bzip3 block-limit reduction.  Oversized documents remain intact.

| corpus | target | pages | raw file | adaptive file | adaptive metadata | raw/adaptive payload | selected bzip/raw | probe |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 16 KiB | 2967 | 48,414,361 | 8,402,555 | 1,071,545 (12.75%) | 47,342,816 / 7,331,010 | 2967/0 raw | 2967 smaller; 0 limit fallback |
| FreeDict eng-spa | 64 KiB | 728 | 48,271,065 | 6,406,243 | 928,249 (14.49%) | 47,342,816 / 5,477,994 | 728/0 raw | 728 smaller; 0 limit fallback |
| FreeDict eng-spa | 256 KiB | 181 | 48,236,057 | 5,448,237 | 893,241 (16.40%) | 47,342,816 / 4,554,996 | 181/0 raw | 181 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 16 KiB | 4192 | 68,024,913 | 20,341,174 | 1,865,836 (9.17%) | 66,159,077 / 18,475,338 | 4192/0 raw | 4192 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 64 KiB | 1020 | 67,821,905 | 16,274,792 | 1,662,828 (10.22%) | 66,159,077 / 14,611,964 | 1020/0 raw | 1020 smaller; 0 limit fallback |
| GNU GCIDE 0.54 | 256 KiB | 254 | 67,772,881 | 13,958,381 | 1,613,804 (11.56%) | 66,159,077 / 12,344,577 | 254/0 raw | 254 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 16 KiB | 7840 | 119,969,273 | 19,017,985 | 1,935,807 (10.18%) | 118,033,466 / 17,082,178 | 7840/0 raw | 7840 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 64 KiB | 1837 | 119,585,081 | 12,223,578 | 1,551,615 (12.69%) | 118,033,466 / 10,671,963 | 1837/0 raw | 1837 smaller; 0 limit fallback |
| OMW Japanese 2.0 | 256 KiB | 453 | 119,496,505 | 9,790,271 | 1,463,039 (14.94%) | 118,033,466 / 8,327,232 | 453/0 raw | 453 smaller; 0 limit fallback |

For every corpus and every target, adaptive selected bzip3 on every page: 0 raw fallbacks, 0 resource-limit fallbacks, 0 probe errors, and every bzip3 probe was smaller.  Consequently adaptive and forced-bzip3 artifacts are byte-identical within each target.  This is a measured result on these real inputs, not an assumption inherited from synthetic fixtures.

### Storage causes and losses

| corpus | normalized content | LEX6 raw payload overhead | 64 KiB metadata | adaptive selection | adaptive payload |
| --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 43,700,255 B | 47,342,816 B (+3,642,561; 8.34%) | 928,249 B / 14.49% | 728 bzip3, 0 raw | 5,477,994 B |
| GNU GCIDE 0.54 | 58,808,436 B | 66,159,077 B (+7,350,641; 12.50%) | 1,662,828 B / 10.22% | 1020 bzip3, 0 raw | 14,611,964 B |
| OMW Japanese 2.0 | 112,147,272 B | 118,033,466 B (+5,886,194; 5.25%) | 1,551,615 B / 12.69% | 1837 bzip3, 0 raw | 10,671,963 B |

The raw-payload excess over normalized content is packet/model framing and per-entry/key representation charged identically to the LEX6 lane; it is not silently attributed to bzip3.  The metadata floor is hot index/catalog/directory data and remains uncompressed in the archive.  Larger pages reduce page count and metadata (and reduce adaptive total storage here) but provide coarser random-access granularity; the report does not turn that storage trade-off into a latency claim.

GCIDE demonstrates the document-boundary limit: at 16 KiB its largest raw page is 112,754 B because an oversized source entry is retained rather than dropped or split.  OMW's many short Japanese entries produce 7,840 pages at 16 KiB, so its metadata fraction is correspondingly higher.  These are measured page distributions, not generic codec explanations.

### Whole-stream bzip3 control (storage-only)

| corpus | whole raw content | whole bzip3 | whole ratio | paged adaptive | whole digest |
| --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | 43,700,255 B | 2,630,650 B | 0.060x | 6,406,243 B (64 KiB pages) | 3a6c83d9742629a2… |
| GNU GCIDE 0.54 | 58,808,436 B | 7,826,936 B | 0.133x | 16,274,792 B (64 KiB pages) | 4af9b2ba3e8419a4… |
| OMW Japanese 2.0 | 112,147,272 B | 4,415,789 B | 0.039x | 12,223,578 B (64 KiB pages) | c462e401adaad163… |

The whole-stream control concatenates normalized content only and compresses it once.  It omits LEX6 packet/model bytes, index/catalog/directory metadata, and page restart boundaries; it is therefore a storage diagnostic for compression horizon, not a random-access-equivalent dictionary format and not a query-performance result.

## Reproduction and retained evidence

The commands below reproduce the preparation, smoke, sweep, and gated measurement ledgers.  The measurement command is intentionally listed with its literal root authorization.

```sh
python3 src6/bench/real-world/prepare.py fetch --cache-dir /tmp/dictionary-real-world-cache
python3 src6/bench/real-world/prepare.py project --cache-dir /tmp/dictionary-real-world-cache --output-dir src6/bench/real-world/evidence/corpora
python3 -m unittest -v src6/bench/real-world/test_prepare.py
/etc/profiles/per-user/mileswirht/bin/zig build -Doptimize=ReleaseSafe --build-file src6/bench/real-world/build.zig
nix develop .# --command python3 src6/bench/real-world/smoke.py --artifact-root /private/tmp/dictionary-real-world-current --output src6/bench/real-world/evidence/runs/main-smoke-post-review.json --all-exact-queries
nix develop .# --command python3 src6/bench/real-world/fairness_audit.py --smoke src6/bench/real-world/evidence/runs/main-smoke-post-review.json --output src6/bench/real-world/evidence/runs/fairness-audit-post-review.json
python3 src6/bench/real-world/sweep.py --artifact-root /private/tmp/dictionary-real-world-sweep-post-review --output src6/bench/real-world/evidence/runs/page-sweep-post-review.json
nix develop .# --command python3 src6/bench/real-world/legacy_probe.py
python3 src6/bench/real-world/verification.py
nix develop .# --command python3 src6/bench/real-world/inventory.py --evidence-root /private/tmp/dictionary-real-world-current --sweep-root /private/tmp/dictionary-real-world-sweep-post-review --timed-build-root /private/tmp/dictionary-real-world-timed-builds-post-review-final --measurement-plan-root /private/tmp/dictionary-real-world-measure-plans-post-review-final --output src6/bench/real-world/evidence/runs/environment-post-review.json
nix develop .# --command python3 src6/bench/real-world/measure.py --quiet-gate ROOT-EXPLICIT-QUIET-GATE --artifact-root /private/tmp/dictionary-real-world-current --output src6/bench/real-world/evidence/runs/timing-results-post-review-final.json --plan-root /private/tmp/dictionary-real-world-measure-plans-post-review-final --build-root /private/tmp/dictionary-real-world-timed-builds-post-review-final
python3 src6/bench/real-world/report.py --output src6/bench/real-world/evidence/reports/real-world-report-post-review.md
```

Retained ledgers: [`corpora/manifest.json`](../corpora/manifest.json), [`main-smoke-post-review.json`](../runs/main-smoke-post-review.json), [`fairness-audit-post-review.json`](../runs/fairness-audit-post-review.json), [`page-sweep-post-review.json`](../runs/page-sweep-post-review.json), [`timing-results-post-review-final.json`](../runs/timing-results-post-review-final.json), [`baseline-pre-refactor.json`](../runs/baseline-pre-refactor.json), [`timing-results-post-review-failed-label-collision.json`](../runs/timing-results-post-review-failed-label-collision.json), [`legacy-availability.json`](../runs/legacy-availability.json), [`verification.json`](../runs/verification.json), and [`environment-post-review.json`](../runs/environment-post-review.json).  The post-review environment ledger inventories every regular file beneath the fresh artifact, sweep, timed-build, and measurement-plan roots, including generated `.idx.oft` sdcv sidecars, and records source archive/projection/license byte costs plus SHA-256/SHA-512 hashes where retained.  It also hashes the owned harness, exact LEX6 production/build inputs, vendored bzip3 source tree, and the current compiled `real-lex6` binary.  The pre-refactor baseline manifest remains separate and is not overwritten.

The environment ledger reports Zig 0.16.0, Nix/Lix 2.95.2, sdcv 0.5.5, dictd tools 1.13.3, SQLite 3.53.3, Python 3.14.7, SLOB from the pinned Nix environment, and PyICU 2.16.2/ICU 78.3.  A nonzero `--version` return code for some dictd utilities is preserved as probe behavior; the executable path and printed version are still recorded, and actual format validation return codes are recorded separately.

## Timed results (root gate granted)

The following section is emitted only when a retained timing ledger exists.  It summarizes the raw samples; all per-sample process output, phase nanoseconds, operation counts, checksums, and artifact references remain in that JSON.  Values are descriptive within a lane, not a cross-language microsecond ranking.

Gate: `ROOT-EXPLICIT-QUIET-GATE`; process runs `3`, warmups `1`, fast batch `256`, prefix batches `3`.  Fresh processes ran with the OS cache state left untouched; this is not a cold-disk measurement.

### LEX6 in-process phases

| corpus | codec | fresh process wall | projection parse | artifact read | metadata open | post verify | reader init | first exact | prefix batch | first render | first snippet | exact batch | uncached render | uncached snippet | session cold | session same-page | session mixed render | session mixed snippet |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | raw | median 549.031 ms (min 536.941, max 572.823) | median 156.679 ms (min 153.577, max 158.577) | median 5.639 ms (min 5.506, max 13.479) | median 2.052 ms (min 2.035, max 2.532) | median 305.409 ms (min 296.591, max 310.727) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 1.46 µs/op (min 1.26, max 1.71) | median 0.05 ms (min 0.01, max 0.25) | median 0.04 ms (min 0.01, max 0.06) | median 2.38 µs/op | median 36.70 µs/op | median 35.31 µs/op | median 36.92 µs/op | median 5.64 µs/op | median 35.38 µs/op | median 35.22 µs/op |
| FreeDict eng-spa | adaptive | median 3673.932 ms (min 3661.487, max 3704.009) | median 152.896 ms (min 151.790, max 157.965) | median 1.482 ms (min 0.856, max 1.602) | median 2.016 ms (min 1.995, max 2.187) | median 1497.737 ms (min 1477.011, max 1504.531) | median 0.000 ms (min 0.000, max 0.001) | median 0.00 ms (min 0.00, max 0.01) | median 1.38 µs/op (min 1.26, max 2.22) | median 1.68 ms (min 0.29, max 1.97) | median 1.56 ms (min 0.27, max 2.03) | median 2.46 µs/op | median 1316.31 µs/op | median 1293.42 µs/op | median 1535.25 µs/op | median 5.57 µs/op | median 1276.88 µs/op | median 1313.29 µs/op |
| FreeDict eng-spa | bzip3 | median 3670.368 ms (min 3621.496, max 3722.008) | median 153.428 ms (min 153.300, max 156.201) | median 1.697 ms (min 0.841, max 1.708) | median 2.013 ms (min 2.010, max 2.027) | median 1486.263 ms (min 1484.416, max 1585.120) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 1.35 µs/op (min 1.28, max 1.50) | median 1.67 ms (min 0.29, max 1.78) | median 1.68 ms (min 0.30, max 1.80) | median 2.33 µs/op | median 1261.34 µs/op | median 1256.80 µs/op | median 1541.54 µs/op | median 5.68 µs/op | median 1280.89 µs/op | median 1280.85 µs/op |
| GNU GCIDE 0.54 | raw | median 975.713 ms (min 962.381, max 983.279) | median 213.905 ms (min 210.789, max 214.696) | median 8.598 ms (min 8.066, max 11.907) | median 3.899 ms (min 3.894, max 4.716) | median 459.934 ms (min 457.043, max 463.929) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.00, max 0.01) | median 5.40 µs/op (min 5.29, max 5.54) | median 0.06 ms (min 0.03, max 0.60) | median 0.04 ms (min 0.03, max 0.53) | median 3.88 µs/op | median 168.19 µs/op | median 156.86 µs/op | median 37.08 µs/op | median 5.10 µs/op | median 167.27 µs/op | median 158.19 µs/op |
| GNU GCIDE 0.54 | adaptive | median 17074.935 ms (min 8568.653, max 17755.345) | median 216.381 ms (min 213.802, max 384.772) | median 4.055 ms (min 3.538, max 4.198) | median 4.656 ms (min 4.119, max 5.806) | median 3753.611 ms (min 3337.508, max 10966.549) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.00, max 0.03) | median 5.46 µs/op (min 5.19, max 5.62) | median 3.79 ms (min 1.93, max 7.07) | median 2.97 ms (min 1.97, max 7.02) | median 4.89 µs/op | median 3036.70 µs/op | median 3047.06 µs/op | median 2667.62 µs/op | median 4.96 µs/op | median 3727.45 µs/op | median 6145.31 µs/op |
| GNU GCIDE 0.54 | bzip3 | median 8575.336 ms (min 8035.430, max 9955.987) | median 213.392 ms (min 208.096, max 224.866) | median 4.460 ms (min 4.170, max 6.758) | median 4.024 ms (min 3.955, max 4.106) | median 3221.098 ms (min 3175.613, max 3565.733) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.00, max 0.01) | median 5.17 µs/op (min 4.96, max 5.90) | median 2.77 ms (min 1.85, max 5.41) | median 2.81 ms (min 1.89, max 5.06) | median 3.75 µs/op | median 3734.41 µs/op | median 3034.18 µs/op | median 2489.75 µs/op | median 5.04 µs/op | median 3270.19 µs/op | median 2962.74 µs/op |
| OMW Japanese 2.0 | raw | median 1250.311 ms (min 1243.328, max 1665.481) | median 406.804 ms (min 406.746, max 416.847) | median 16.972 ms (min 13.882, max 22.492) | median 3.894 ms (min 3.172, max 4.393) | median 693.666 ms (min 660.767, max 1040.581) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.02) | median 0.89 µs/op (min 0.85, max 0.94) | median 0.08 ms (min 0.02, max 0.34) | median 0.05 ms (min 0.02, max 0.17) | median 1.65 µs/op | median 55.05 µs/op | median 52.89 µs/op | median 46.54 µs/op | median 15.77 µs/op | median 54.63 µs/op | median 53.28 µs/op |
| OMW Japanese 2.0 | adaptive | median 7409.223 ms (min 7326.696, max 8286.379) | median 395.327 ms (min 394.352, max 404.990) | median 1.934 ms (min 1.857, max 2.807) | median 3.276 ms (min 3.253, max 3.354) | median 4083.620 ms (min 4073.400, max 4643.346) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 0.89 µs/op (min 0.83, max 2.54) | median 2.25 ms (min 0.65, max 2.51) | median 2.11 ms (min 0.64, max 2.67) | median 1.66 µs/op | median 1807.00 µs/op | median 1786.40 µs/op | median 2127.71 µs/op | median 16.21 µs/op | median 1836.69 µs/op | median 1920.50 µs/op |
| OMW Japanese 2.0 | bzip3 | median 7314.736 ms (min 6983.012, max 11217.605) | median 406.799 ms (min 405.248, max 416.362) | median 1.714 ms (min 1.617, max 2.508) | median 3.339 ms (min 3.191, max 3.605) | median 3676.568 ms (min 3670.743, max 5694.792) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 0.92 µs/op (min 0.83, max 1.54) | median 2.24 ms (min 0.65, max 2.60) | median 2.08 ms (min 0.67, max 2.43) | median 1.62 µs/op | median 1961.76 µs/op | median 3067.13 µs/op | median 2254.08 µs/op | median 16.00 µs/op | median 1956.06 µs/op | median 1880.38 µs/op |

`first_exact`/`first_render`/`first_snippet` arrays in the raw ledger expose the cold-in-process first operation per fixed case (including missing and high-multiplicity exact queries); uncached batches use `Archive.load` per operation.  Stateful Reader rows expose a cold first decode, hot same-page reuse (expected zero page loads and 256 cache hits), and mixed-page cycling with page-load/decode/cache-hit counters.  Prefix rows retain hits and key bytes for each of the three batches rather than reducing them to an unqualified latency number.

### Custom Python reader phases

| corpus | lane | fresh process wall | oracle parse | plan parse | reader ready | native open | identity setup | first exact | prefix batch | first render | first snippet | exact batch | content/render | snippet |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FreeDict eng-spa | stardict | median 517.843 ms (min 514.708, max 541.880) | median 269.918 ms (min 266.708, max 271.417) | median 0.571 ms (min 0.476, max 0.764) | median 161.923 ms (min 159.618, max 165.453) | median 161.915 ms (min 159.610, max 165.428) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.03) | median 0.89 µs/op (min 0.75, max 2.71) | median 0.00 ms (min 0.00, max 0.01) | median 0.00 ms (min 0.00, max 0.00) | median 0.93 µs/op | median 0.99 µs/op | median 0.40 µs/op |
| FreeDict eng-spa | dict | median 401.743 ms (min 394.241, max 421.928) | median 265.099 ms (min 259.266, max 271.895) | median 0.442 ms (min 0.432, max 0.450) | median 59.630 ms (min 59.431, max 66.108) | median 59.626 ms (min 59.428, max 66.104) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 0.88 µs/op (min 0.75, max 2.12) | median 0.00 ms (min 0.00, max 0.00) | median 0.00 ms (min 0.00, max 0.00) | median 0.89 µs/op | median 0.98 µs/op | median 0.38 µs/op |
| FreeDict eng-spa | dictzip | median 436.797 ms (min 434.674, max 449.669) | median 267.728 ms (min 266.397, max 275.175) | median 0.455 ms (min 0.434, max 0.518) | median 56.003 ms (min 54.028, max 61.109) | median 56.000 ms (min 54.025, max 61.106) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 0.88 µs/op (min 0.76, max 3.33) | median 0.08 ms (min 0.04, max 0.14) | median 0.06 ms (min 0.03, max 0.09) | median 0.89 µs/op | median 33.85 µs/op | median 33.32 µs/op |
| FreeDict eng-spa | sqlite | median 344.975 ms (min 344.633, max 352.331) | median 262.773 ms (min 262.759, max 266.538) | median 0.461 ms (min 0.460, max 0.469) | median 0.224 ms (min 0.201, max 0.808) | median 0.222 ms (min 0.199, max 0.806) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.01, max 0.63) | median 7.47 µs/op (min 6.61, max 24.85) | median 0.02 ms (min 0.01, max 0.33) | median 0.01 ms (min 0.01, max 0.01) | median 7.32 µs/op | median 5.58 µs/op | median 5.13 µs/op |
| FreeDict eng-spa | slob-raw | median 2911.673 ms (min 2861.975, max 4222.812) | median 263.139 ms (min 261.036, max 263.200) | median 0.466 ms (min 0.429, max 0.992) | median 143.433 ms (min 135.735, max 1486.896) | median 0.223 ms (min 0.179, max 0.847) | median 107.793 ms (min 106.687, max 107.953) | median 0.00 ms (min 0.00, max 0.00) | median 1208.92 µs/op (min 1158.33, max 1322.44) | median 0.12 ms (min 0.05, max 0.44) | median 0.03 ms (min 0.02, max 0.03) | median 0.64 µs/op | median 24.78 µs/op | median 23.79 µs/op |
| FreeDict eng-spa | slob-lzma2 | median 2934.155 ms (min 2929.066, max 3415.439) | median 267.257 ms (min 256.272, max 271.551) | median 0.459 ms (min 0.450, max 0.638) | median 139.609 ms (min 135.467, max 158.961) | median 0.224 ms (min 0.201, max 0.693) | median 107.020 ms (min 106.750, max 109.445) | median 0.00 ms (min 0.00, max 0.00) | median 1258.18 µs/op (min 1168.69, max 1445.08) | median 0.46 ms (min 0.26, max 0.64) | median 0.03 ms (min 0.02, max 0.03) | median 0.63 µs/op | median 23.01 µs/op | median 22.18 µs/op |
| GNU GCIDE 0.54 | stardict | median 969.718 ms (min 969.151, max 1026.664) | median 503.924 ms (min 500.243, max 507.864) | median 0.453 ms (min 0.447, max 0.835) | median 357.020 ms (min 356.088, max 360.396) | median 357.012 ms (min 356.077, max 360.387) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.02) | median 2.12 µs/op (min 1.85, max 6.21) | median 0.00 ms (min 0.00, max 0.01) | median 0.00 ms (min 0.00, max 0.00) | median 1.36 µs/op | median 10.24 µs/op | median 0.70 µs/op |
| GNU GCIDE 0.54 | dict | median 748.760 ms (min 748.066, max 750.793) | median 491.406 ms (min 488.729, max 492.282) | median 0.468 ms (min 0.464, max 0.475) | median 159.217 ms (min 157.898, max 161.412) | median 159.211 ms (min 157.893, max 161.408) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 2.00 µs/op (min 1.79, max 4.25) | median 0.00 ms (min 0.00, max 0.01) | median 0.00 ms (min 0.00, max 0.00) | median 1.30 µs/op | median 10.61 µs/op | median 0.70 µs/op |
| GNU GCIDE 0.54 | dictzip | median 854.385 ms (min 843.178, max 860.806) | median 494.070 ms (min 489.063, max 498.465) | median 0.488 ms (min 0.481, max 0.586) | median 152.861 ms (min 147.663, max 157.149) | median 152.857 ms (min 147.660, max 157.145) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 2.02 µs/op (min 1.81, max 4.65) | median 0.14 ms (min 0.07, max 0.25) | median 0.11 ms (min 0.06, max 0.22) | median 1.32 µs/op | median 102.21 µs/op | median 95.36 µs/op |
| GNU GCIDE 0.54 | sqlite | median 605.868 ms (min 594.825, max 619.837) | median 490.409 ms (min 490.323, max 499.774) | median 0.501 ms (min 0.481, max 0.512) | median 0.212 ms (min 0.187, max 0.472) | median 0.211 ms (min 0.185, max 0.470) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.01, max 0.51) | median 12.21 µs/op (min 11.29, max 31.85) | median 0.03 ms (min 0.01, max 0.70) | median 0.01 ms (min 0.01, max 0.02) | median 8.52 µs/op | median 18.26 µs/op | median 8.89 µs/op |
| GNU GCIDE 0.54 | slob-raw | median 1052.920 ms (min 962.289, max 1135.603) | median 488.372 ms (min 485.325, max 488.978) | median 0.509 ms (min 0.464, max 0.520) | median 286.518 ms (min 284.293, max 434.608) | median 0.204 ms (min 0.203, max 0.630) | median 257.987 ms (min 256.002, max 261.542) | median 0.00 ms (min 0.00, max 0.00) | median 2536.81 µs/op (min 2443.73, max 2726.29) | median 0.12 ms (min 0.05, max 0.38) | median 0.03 ms (min 0.02, max 0.04) | median 0.96 µs/op | median 35.91 µs/op | median 26.37 µs/op |
| GNU GCIDE 0.54 | slob-lzma2 | median 987.519 ms (min 977.700, max 1014.333) | median 490.310 ms (min 488.941, max 499.852) | median 0.515 ms (min 0.445, max 0.547) | median 295.918 ms (min 288.454, max 303.240) | median 0.214 ms (min 0.203, max 0.761) | median 259.474 ms (min 257.603, max 264.211) | median 0.00 ms (min 0.00, max 0.03) | median 2611.69 µs/op (min 2377.40, max 3845.29) | median 0.71 ms (min 0.46, max 1.06) | median 0.03 ms (min 0.02, max 0.03) | median 0.99 µs/op | median 32.97 µs/op | median 24.02 µs/op |
| OMW Japanese 2.0 | stardict | median 1217.910 ms (min 962.248, max 1824.482) | median 691.501 ms (min 516.974, max 852.914) | median 1.569 ms (min 1.031, max 2.317) | median 370.241 ms (min 337.497, max 756.383) | median 370.232 ms (min 337.488, max 756.372) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.02) | median 0.72 µs/op (min 0.61, max 2.17) | median 0.01 ms (min 0.00, max 0.01) | median 0.00 ms (min 0.00, max 0.00) | median 0.72 µs/op | median 2.50 µs/op | median 0.46 µs/op |
| OMW Japanese 2.0 | dict | median 823.575 ms (min 812.844, max 824.611) | median 540.047 ms (min 539.212, max 545.026) | median 1.364 ms (min 1.102, max 1.608) | median 167.422 ms (min 165.694, max 181.662) | median 167.417 ms (min 165.690, max 181.652) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.02) | median 0.71 µs/op (min 0.57, max 2.08) | median 0.00 ms (min 0.00, max 0.01) | median 0.00 ms (min 0.00, max 0.00) | median 0.71 µs/op | median 2.53 µs/op | median 0.48 µs/op |
| OMW Japanese 2.0 | dictzip | median 812.288 ms (min 808.833, max 829.063) | median 515.948 ms (min 511.712, max 529.409) | median 1.610 ms (min 1.023, max 1.806) | median 157.492 ms (min 151.571, max 158.110) | median 157.488 ms (min 151.568, max 158.107) | median 0.000 ms (min 0.000, max 0.000) | median 0.00 ms (min 0.00, max 0.01) | median 0.72 µs/op (min 0.61, max 2.68) | median 0.09 ms (min 0.02, max 0.20) | median 0.06 ms (min 0.01, max 0.07) | median 0.74 µs/op | median 35.48 µs/op | median 37.16 µs/op |
| OMW Japanese 2.0 | sqlite | median 647.197 ms (min 634.240, max 668.199) | median 533.576 ms (min 524.515, max 544.780) | median 1.556 ms (min 1.081, max 1.743) | median 0.236 ms (min 0.213, max 0.576) | median 0.232 ms (min 0.212, max 0.574) | median 0.000 ms (min 0.000, max 0.000) | median 0.01 ms (min 0.01, max 0.66) | median 6.88 µs/op (min 6.39, max 18.24) | median 0.02 ms (min 0.01, max 2.92) | median 0.01 ms (min 0.01, max 0.01) | median 6.32 µs/op | median 8.11 µs/op | median 6.01 µs/op |
| OMW Japanese 2.0 | slob-raw | median 904.128 ms (min 893.175, max 1033.857) | median 519.408 ms (min 515.288, max 527.655) | median 1.160 ms (min 1.155, max 1.267) | median 223.215 ms (min 220.926, max 328.889) | median 0.210 ms (min 0.201, max 0.639) | median 196.328 ms (min 194.132, max 200.040) | median 0.00 ms (min 0.00, max 0.01) | median 1793.22 µs/op (min 1752.78, max 1889.31) | median 0.10 ms (min 0.05, max 3.59) | median 0.02 ms (min 0.02, max 0.03) | median 0.49 µs/op | median 22.64 µs/op | median 20.41 µs/op |
| OMW Japanese 2.0 | slob-lzma2 | median 936.937 ms (min 925.300, max 1026.474) | median 530.336 ms (min 525.466, max 629.558) | median 1.200 ms (min 1.171, max 1.643) | median 230.728 ms (min 229.846, max 235.205) | median 0.209 ms (min 0.207, max 0.654) | median 202.891 ms (min 201.059, max 205.430) | median 0.00 ms (min 0.00, max 0.01) | median 1879.47 µs/op (min 1798.44, max 1959.93) | median 0.47 ms (min 0.19, max 3.48) | median 0.02 ms (min 0.02, max 0.03) | median 0.50 µs/op | median 22.25 µs/op | median 20.27 µs/op |

These are custom Python readers with normal allocation and checksum work.  Fresh-process wall includes process startup plus oracle/plan setup and all fixed operations; the explicitly reported `reader ready` boundary excludes oracle and plan parsing.  SLOB's native open and sidecar identity setup are separate; its `native_icu` fixed cases are retained separately in the raw ledger.  Reader times include Python harness/mapping costs and must not be compared as native-language rankings.

### Native CLI process/transport samples

| corpus | lane | process wall | status |
| --- | --- | --- | --- |
| FreeDict eng-spa | sdcv_cli | median 7.652 ms (min 7.477, max 362.027) | ok |
| FreeDict eng-spa | dictzip_cli | median 5.072 ms (min 4.961, max 254.045) | ok |
| GNU GCIDE 0.54 | sdcv_cli | median 7.084 ms (min 6.834, max 509.859) | ok |
| GNU GCIDE 0.54 | dictzip_cli | median 6.203 ms (min 6.102, max 13.714) | ok |
| OMW Japanese 2.0 | sdcv_cli | median 9.525 ms (min 8.867, max 58.193) | ok |
| OMW Japanese 2.0 | dictzip_cli | median 8.175 ms (min 7.917, max 26.829) | ok |

CLI rows include process startup, command transport, and output handling.  StarDict `sdcv` and dictzip are genuine external implementations; no Python custom-reader number is merged with these process measurements.  DICT server startup/query remains unavailable because no dictd server was started.

### Build process phases

| corpus | build phase | wall | artifact | hash |
| --- | --- | --- | --- | --- |
| None | raw | median 502.528 ms (min 502.528, max 502.528) | 48271065 | 755bd42c6ddf807f… |
| None | adaptive | median 3012.198 ms (min 3012.198, max 3012.198) | 6406243 | 2d1ef42083dde1ad… |
| None | bzip3 | median 2990.574 ms (min 2990.574, max 2990.574) | 6406243 | 2d1ef42083dde1ad… |
| None | raw | median 780.087 ms (min 780.087, max 780.087) | 67821905 | 6472b07554981d0e… |
| None | adaptive | median 7929.969 ms (min 7929.969, max 7929.969) | 16274792 | a5e528964de6ba33… |
| None | bzip3 | median 7914.487 ms (min 7914.487, max 7914.487) | 16274792 | a5e528964de6ba33… |
| None | raw | median 1347.590 ms (min 1347.590, max 1347.590) | 119585081 | 2ad5b1f7017bc38f… |
| None | adaptive | median 7598.278 ms (min 7598.278, max 7598.278) | 12223578 | fe9774441c2d5b8e… |
| None | bzip3 | median 11598.779 ms (min 11598.779, max 11598.779) | 12223578 | fe9774441c2d5b8e… |
| freedict-eng-spa | stardict-build-only | 104.712 ms | bundle in build-dir | see environment inventory |
| freedict-eng-spa | dict-build-plus-dictunformat | 412.763 ms | bundle in build-dir | see environment inventory |
| freedict-eng-spa | dictzip-build-plus-full-range-validation | 844.239 ms | bundle in build-dir | see environment inventory |
| freedict-eng-spa | sqlite-build-plus-integrity-cli | 585.634 ms | bundle in build-dir | see environment inventory |
| freedict-eng-spa | slob-build-plus-identity-and-reader-validation | 34010.347 ms | bundle in build-dir | see environment inventory |
| gcide-054 | stardict-build-only | 205.266 ms | bundle in build-dir | see environment inventory |
| gcide-054 | dict-build-plus-dictunformat | 606.182 ms | bundle in build-dir | see environment inventory |
| gcide-054 | dictzip-build-plus-full-range-validation | 1827.528 ms | bundle in build-dir | see environment inventory |
| gcide-054 | sqlite-build-plus-integrity-cli | 840.272 ms | bundle in build-dir | see environment inventory |
| gcide-054 | slob-build-plus-identity-and-reader-validation | 62818.357 ms | bundle in build-dir | see environment inventory |
| omw-ja-20 | stardict-build-only | 447.296 ms | bundle in build-dir | see environment inventory |
| omw-ja-20 | dict-build-plus-dictunformat | 605.337 ms | bundle in build-dir | see environment inventory |
| omw-ja-20 | dictzip-build-plus-full-range-validation | 1972.773 ms | bundle in build-dir | see environment inventory |
| omw-ja-20 | sqlite-build-plus-integrity-cli | 1152.057 ms | bundle in build-dir | see environment inventory |
| omw-ja-20 | slob-build-plus-identity-and-reader-validation | 69600.432 ms | bundle in build-dir | see environment inventory |

LEX6 build rows are fresh-process build wall times for the 64 KiB artifacts.  External builder phase names retain their validation boundaries (dictunformat, dictzip full/range, SQLite integrity, and SLOB identity/reader validation) and therefore are not pure encoder times.


The first post-review timing pass is preserved separately in [`timing-results-post-review-failed-label-collision.json`](../runs/timing-results-post-review-failed-label-collision.json).  Its 18 rejected samples were caused by duplicate high-multiplicity query labels in the harness plan; the corrected plan uses unique labels and the selected final ledger reports zero failures.  This is a functional correction record, not a cherry-picked timing retry.
