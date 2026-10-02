# PAQ8PX v217 book calibration

This is a frozen external reference result on development book prefixes. The six controls are complete bzip3 archives over the exact matching prefix; the six inputs total 4,130,934 bytes. War and Peace and Don Quijote are 1 MiB prefixes, not full-book results. The other four inputs are complete prepared books within this small corpus.

## Results

| Book | Bytes | bzip3 | PAQ `-0L` | PAQ `-1` | `-1` change vs bzip3 |
|---|---:|---:|---:|---:|---:|
| Pride and Prejudice (en) | 705,012 | 161,119 | 161,706 | 145,237 | −9.86% |
| War and Peace (en, 1 MiB prefix) | 1,048,576 | 247,364 | 245,160 | 221,722 | −10.37% |
| Don Quijote (es, 1 MiB prefix) | 1,048,576 | 252,940 | 250,286 | 230,177 | −9.00% |
| Madame Bovary (fr) | 716,472 | 179,597 | 180,847 | 162,913 | −9.29% |
| Die Verwandlung (de) | 126,200 | 35,251 | 35,890 | 30,584 | −13.24% |
| Kokoro (ja) | 486,098 | 97,505 | 100,612 | 89,779 | −7.92% |
| **Sum** | 4,130,934 | **973,776** | **974,501** | **880,412** | **−9.59%** |

The size-weighted `-1` reduction is 9.59%; the equal-book geometric reduction is 9.96%. The original `-1` capture attempted six books but only five completed exact fresh-process decoding because Bovary hit its fixed 180-second operation cap after a process pause for the authorized quiet reader measurement. That failed row and its partial output are retained. A separately authorized, same-policy Bovary retry succeeded and produced the six-book combined result above. It is not retroactively counted as a successful original capture.

`-0L` is a separate LSTM-only profile: its aggregate is 974,501 bytes, 0.074% larger than bzip3. It wins two books and loses four. `-1` reduces each of the six compared books, but its 7.92–13.24% range does not reach the project’s 35% aggregate aim or 20% per-language floor. A 35% reduction against this aggregate bzip3 total would be at most 632,954 bytes; PAQ `-1` is 880,412 bytes, so it would need another 247,458 bytes (28.1% of its current aggregate) removed. To reach the per-language 20% floor, each current PAQ frame must shrink by a further 7.8–13.1%, depending on the book.

## What the source shows

The useful difference is the predictor stack, not merely a larger neural model. With `-T` absent, PAQ’s text pretraining path is disabled; the measured `-1` run does not load the bundled English `.dic`, `.exp`, or `.emb` files. It learns online from the compressed stream and sends no external model file.

PAQ8PX v217’s `TextModel::setContexts` builds 28 contexts per bit. These contexts combine the current partial word hash and current byte with prior-word hashes, second/third previous words, a prior-word bigram/trigram, punctuation and capitalization state, word length, line position, topic state, and sentence-level verb/noun features. For example, some contexts use `(current-word-hash, previous-word-hash)`; others include current byte, older word hashes, or the last verb. `WordModelInfo::predict` adds 46 text contexts for current expression/word prefixes, previous one-to-four words, word gaps, word length/capitalization, position, and local byte groups. Both models feed many hashed context states to a shared adaptive mixer.

`ContextMap2` does not keep a separate seven-bit transition table for every partial byte prefix. It shares a context’s hashed byte history/run statistics and updates a compact bit-state tree as the eight bits of each byte arrive. `Mixer` adapts three linked layers per bit: context-selected input weights, context-selected middle weights, and a combining layer, with a skip connection. It updates weights from the previous prediction error. This lets the predictor reweight overlapping, partially redundant context experts according to local text regime. That is materially richer than the tested in-house fixed expert weights and sparse KT row scheme, whose screens lost the whole-file bzip3 controls before a decoder wire was justified.

The language asymmetry is informative. PAQ has dedicated English, French, and German stemmers/language recognition, while Japanese remains `Language::Unknown`; nevertheless Japanese gains 7.92%, but less than German’s 13.24%. Its byte-oriented text parser treats bytes above `0x7f` as word characters rather than decoding Unicode scalars, so this is not a Japanese morphological model. The source contains generic histories and match models that still capture regularity in the UTF-8 byte stream.

The remaining gap is large. PAQ `-1` frames are 7.9–13.2% smaller than the same-source bzip3 archives; the experiment does not establish that a native codec can beat bzip3 by 35%. Diagnostic `-1` encode/decode calls ranged from about 17.5 to 138.3 seconds across these sources (the Bovary retry took about 93 seconds per operation), so this is not evidence for the fast-decoder target. PAQ’s printed “used N bytes of memory” comes from its internal `ProgramChecker` allocation counter, not OS RSS. The capture imposed a 1 GiB address-space and 180-second per-operation cap; timing was diagnostic, not a quiet paired benchmark.

## Reproducibility

The machine-readable ledger includes exact source, binary, book-manifest and control hashes, raw process-call hashes, full per-attempt statuses, and the separate retry link: [PAQ-BOOK-CALIBRATION-20261002.json](evidence/PAQ-BOOK-CALIBRATION-20261002.json). The durable raw capture copies, smoke records, environment pins and exact runner/test sources are under `evidence/source-capture/`; `source-capture-files.sha256.json` verifies each copied file, and `environment-pin-verification.json` records the source/build/binary matches at both capture boundaries. PAQ source is pinned at commit `c84f576fc2c522194cd320743708652a154daf6b`; binary SHA-256 is `59ffb4c02c56a9de8c73dc5124ff086c23bdd88bb8d64dd26f93630eae5ea9ef`.
