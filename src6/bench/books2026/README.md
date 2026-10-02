# Complete prose books: development and reserved validation

This corpus gives the word-codec experiments actual complete literary works in
English, Spanish, French, German and Japanese. It is development data selected
before these codec experiments. Diagnostic prefixes are explicitly different
inputs. No dictionary XML, repeated padding or stitched excerpts stand in for a
book. Public book content and generated archives stay outside Git.

The six-book source pins are in `complete-source-lock.json`. The original
five-book `source-lock.json` and first-five manifest stay intact for experiments
that started before the Japanese projection was published.

| Complete work | Language | Exact UTF-8 body bytes |
| --- | --- | ---: |
| Pride and Prejudice — Jane Austen | English | 705,012 |
| War and Peace — Leo Tolstoy, Louise and Aylmer Maude translation | English | 3,339,896 |
| Don Quijote — Miguel de Cervantes Saavedra | Spanish | 2,179,216 |
| Madame Bovary — Gustave Flaubert | French | 716,472 |
| Die Verwandlung — Franz Kafka | German | 126,200 |
| こころ / Kokoro — 夏目漱石 / Natsume Sōseki | Japanese | 486,098 |
| **Total: six distinct works** | | **7,552,894** |

War and Peace is explicitly an English translation, not a Russian-language
sample. No alternative-language translation of any listed work is included.

## Prepare and verify

```sh
python3 src6/bench/books2026/prepare.py --download
python3 -m unittest discover -s src6/bench/books2026 -p test_prepare.py -v
```

The default scratch root is `/workspace/scratch/books2026-dev`. `--root` and
`--lock` are explicit overrides. Downloads use immutable GitHub commit URLs,
must match both the pinned byte count and SHA-256, and have a 16 MiB source
limit checked before allocation/read. UTF-8 output has the same 16 MiB limit;
there is no truncation to satisfy it. Every current full book fits. This limit
describes this corpus preparation tool, not a codec's capacity guarantee.

Original sources including all headers, credits, rights notices and colophons
are retained under `raw/`. Body files, projection inverse and diagnostic
prefixes are under `books/`. `manifest.json` records their exact paths, bytes,
hashes, language, source pins and whole-original-source reconstruction oracles.
The frozen six-book manifest SHA-256 is
`ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d`.

The `prefix-131072.txt` and `prefix-1048576.txt` diagnostics select the longest
UTF-8 scalar-safe prefix at or below the named byte limit. A shorter book
produces its entire actual contents, with `is_entire_book=true` and its actual
size recorded. Prefixes are never padded or repeated. Full-book and prefix
results must be reported separately.

## Exact source projection

GITenberg supplies the original Project Gutenberg files for the first five
books. English sources declare UTF-8 and have a BOM; Spanish, French and German
sources declare ISO-8859-1. Strict decoding must re-encode to the exact source
bytes. Header title, author, language, encoding and translation metadata are
checked. Exactly one matching `START OF ... PROJECT GUTENBERG EBOOK` and `END
OF ... PROJECT GUTENBERG EBOOK` marker pair is required. The body starts just
after the start marker's line ending and ends at the start of the end marker.
All intervening text, including any contents pages or producer credits,
whitespace and CRLF, is retained. The resulting body is UTF-8 without a BOM.
The source's full-license footer is required and retained in the raw file.

Kokoro comes from the pinned `aozorahack/aozorabunko_text` mirror of Aozora
plaintext. Its source is strictly Shift_JIS. Title/author and all three major
part headings are checked. The body lies after the second exact explanation
separator and before the `底本：` colophon line. Ruby readings `《…》`, ruby
anchors `｜` and editorial format annotations `［＃…］` are removed. Four
opaque gaiji placeholders `※［＃…］` in the body are retained exactly; the tool
does not invent their glyphs. Every deletion's original Unicode-scalar offset
and text is stored in the scratch projection-inverse sidecar. Ruby and format
counts must agree, so malformed markup is rejected. All remaining base text,
punctuation, ideographic spaces, line endings and paragraph boundaries remain.

For every book the oracle reconstructs the **entire original raw file** by
inverting the projection, encoding the declared source codec and reinserting
the retained header/footer. That reconstruction must match the pinned source
hash. This proves the stated projection is reversible using its sidecar; it
does not assert that the ruby-free Japanese body equals the marked-up source.

## Source rights and provenance

The five GITenberg source editions retain their Project Gutenberg full license
and public-domain notices. The literary works were first published in
1813/1869/1605/1857/1915; the War and Peace source explicitly credits its
translators. Kokoro was first published in 1914, and Natsume Sōseki died in
1916. Its original Aozora colophon identifies the source edition, initial
newspaper publication, volunteers and correction date. The mirror's README is
retained at its pinned commit and SHA-256; it describes extracting the official
plaintext ZIPs and links the [Aozora usage rules](https://www.aozora.gr.jp/guide/kijyunn.html).
The mirror contains works with different rights, so the selection records
Kokoro's rights individually instead of assigning one license to the mirror.
Source URLs, edition metadata and retained notices remain in each source lock.

## Whole-book controls

```sh
python3 src6/bench/books2026/controls.py
python3 src6/bench/books2026/controls.py --input-kind prefix-1048576 \
  --codecs bzip3 --out /workspace/scratch/books2026-dev/controls/prefix-1048576
```

Controls encode the exact selected source once into one native frame and then
freshly decode it into a separate process, checking its complete byte count and
hash. Settings are bzip3 1.5.1 with a 32 MiB block, zstd 19 with a single thread,
bzip2 9, and xz 9 with one thread and CRC64. All current sources fit one bzip3
block. bzip2's own internal block size remains 900 KiB. No control pretends to
provide independent 64 KiB access.

The report pins the corpus manifest, harness source, executable SHA-256,
version, dynamically linked library hashes, exact argv, complete archive bytes
and fresh-decode oracle. Reported process clocks are one-shot diagnostics that
include startup and I/O with other experiment jobs active. They are not a
controlled throughput comparison.

`controls.py` rejects any manifest whose role is `reserved-validation`.
Reserved complete works are separately selected and pinned before candidate
freeze, with different authors and works; their bodies must not be used for
experiments or compressed until root authorizes the frozen validation gate.

The reserved pins are in `reserved-source-lock.json`: Jane Eyre (Charlotte
Brontë, English), Les trois mousquetaires (Alexandre Dumas, French), La Regenta
(Leopoldo Alas, Spanish), Effi Briest (Theodor Fontane, German), and 河童 / Kappa
(芥川龍之介 / Ryūnosuke Akutagawa, Japanese). These are complete original works
by authors absent from development, with no translation pairs. Jane Eyre's
source declares US-ASCII and uses the older no-space EBOOK marker spelling;
both exact marker lines and the declared encoding are pinned individually.
Kappa's title/subtitle/author header is pinned explicitly. It first appeared in
1927, the year Akutagawa died. The separate scratch root is
`/workspace/scratch/books2026-reserved-validation`; no diagnostic prefixes or
compression outcomes are generated there. Its manifest SHA-256 is
`45597f778be203cc061cf2cf11b806532110148ccc0143344270ae4c62b7041a`.

```sh
python3 src6/bench/books2026/prepare.py --download \
  --lock src6/bench/books2026/reserved-source-lock.json \
  --root /workspace/scratch/books2026-reserved-validation
```
