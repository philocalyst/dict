# Frontier corpus preparation

Run `python3 src6/bench/frontier2026/prepare_corpora.py` from the repository. The default output is `/workspace/scratch/frontier-corpora`; use `--output-dir PATH` to relocate it. Downloads use immutable Git commits or checksum-pinned releases. `--skip-fetch` reuses retained files and still verifies their checksums.

No corpus data is committed. `corpora-sources.json` retains source URLs, hashes, licenses and citations. The script emits `manifest.json` for `run_bench.py --manifest`, per-source manifests, native source bytes and independent dictionary `projection.tsv` / `rows.jsonl` oracles.

Dictionary content is projected with the existing independent `real-world/prepare.py` parser. All keys and entry content, including forms, senses, definitions, examples, citations and cross-references, are retained. Compression lanes use decoded UTF-8 `content.txt` or original keys in `words.txt`; the hex TSV oracle is never the compression input. OMW Sense references include each directly referenced Synset once per lexical record, without recursive expansion. Shared Synsets retain their ordinary source duplication.

The complete Japanese OMW projection matches the prior canonical projection SHA-256 `ff9b2f1e56912bf3874cb77377a6f97949206a3efdff7739a10f61e1f0c43c75`. The Debian GCIDE 0.54 archive is a different repack, while its complete entry projection matches the prior canonical GNU 0.54 projection SHA-256 `4cddd7f0d23d7ef5dd923ef97b1894f7fff86cc26dbda1a9621653c1338c635b`. The two FreeDict pairs are declared new sources, distinct from the older eng-spa corpus.

| Dictionary | Records | Complete content bytes | Development bytes | Final bytes |
|---|---:|---:|---:|---:|
| OMW Japanese 2.0 | 94,002 | 112,241,274 | 90,002,721 | 22,238,553 |
| Chinese Open WordNet 2.0 | 63,339 | 28,829,995 | 23,112,248 | 5,717,747 |
| GCIDE 0.54 (Debian repack) | 124,187 | 58,932,623 | 47,265,560 | 11,667,063 |
| FreeDict spa-eng | 4,502 | 2,074,922 | 1,666,788 | 408,134 |
| FreeDict eng-fra | 8,799 | 4,306,751 | 3,440,543 | 866,208 |

Whole dictionary records are partitioned before experiments: `SHA-256(source_entry_id) mod 5 == 0` is final; other buckets are development. Both partitions retain the independent oracle and metadata under `dictionaries/NAME/{development,final}/`.

Universal Dependencies v2.17 adds English EWT, Spanish AnCora, Russian SynTagRus, Japanese GSD and Chinese GSD. `# text =` sentence comments produce faithful prose; integer-ID FORM fields produce an explicitly tokenized word stream. Official train/dev/test map to training/development/final. Russian training contains only official shard a, declared in its manifest; all dev and test splits are complete. Chinese/Japanese UD final prose is small (54,783 / 62,803 bytes), with larger independent WordNet dictionary lanes providing additional coverage.

A multilingual lane concatenates each language's prose once, preserving the source-table order (Chinese, Japanese, Russian, Spanish, English). Training is 9,274,401 bytes, development 2,145,015 and final 2,164,862. A separate, explicitly tagged lane adds `[ISO-language] ` to each sentence. No stream is repeated or fabricated to enlarge it.

Experiments should use development lanes. Freeze candidates before evaluating final lanes. Corpus validation checks all input hashes and lengths, disjoint dictionary record IDs and exact reconstruction of complete record sets and content byte totals. Source licensing remains attached to its original corpus; see the retained license text and citations in `corpora-sources.json`.

The historical 8 MiB dictionary lanes and Finnish/Turkish/Arabic test corpora
mentioned in the benchmark README have appeared in earlier experiments; use
them as development diagnostics only. The untouched 2026 evaluation scope is
the five dictionary final partitions plus official UD zh/ja/ru/es/en final
forms/prose and the two multilingual final lanes listed in the manifest.
