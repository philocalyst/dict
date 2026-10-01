# `bzip4` codec experiments

`bzip4` is a working experiment name, not an official successor to bzip1,
bzip2, or bzip3. Nothing here is wired into LEX6 production code.

## Question and bounded candidates

The retained LEX6 evidence exposes a real tension. With 64 KiB pages, bzip3
archives are 6,406,243 B (FreeDict), 16,274,792 B (GCIDE), and 12,223,578 B
(OMW Japanese); with 256 KiB pages they fall to 5,448,237 B, 13,958,381 B,
and 9,790,271 B. Every measured page selected bzip3. Yet cached same-page
renders take roughly 5–16 microseconds while uncached page work is commonly
1–4 milliseconds. Merely enlarging a page improves compression by enlarging
the amount that must be decoded on a miss.

The first prototype tests one narrower hypothesis: **can a charged, archive-wide
reference capture some long-horizon redundancy while every 16 KiB microblock
remains independently decodable?**

The implemented candidate has three deliberately modest pieces:

1. A deterministic trainer selects 64-byte fragments around frequent 8-byte
   anchors from a fixed training partition. The resulting dictionary is at
   most 32 KiB and is stored in the frame; it is never free or pretrained.
2. Each microblock is parsed into literals, local LZ matches, or matches into
   that shared dictionary. Local history is reset at every microblock.
3. An optional integer-only online model predicts each bit from the previous
   token byte and bit position and arithmetic-codes the LZ token stream. Its
   counts reset for every block, require no stored weights, and the encoder
   selects it only when it reduces that block. This is a tiny adaptive
   predictor, not a neural model.

Raw, plain-LZ, and LZ-plus-predictor modes compete per block. The initial
results retain losses: the candidate currently compresses much worse than
bzip3. That is useful evidence against promoting an ordinary shared LZ parser
as a successor.

The second bounded candidate stays in the BWT lineage rather than adding more
ad-hoc LZ machinery. Each independently decodable 16 or 64 KiB block uses a
deterministic cyclic BWT, move-to-front ranks, canonical zero-run tokens, and
a static byte rANS coder. A 512-byte frequency model is trained from the fixed
1 MiB training partition, embedded once in the frame, and charged in every
total. Raw storage competes per block. These are established components; the
experiment is an engineering composition and not a novel compression method.

The BWT candidate is the stronger measured tradeoff. At a 16 KiB access
boundary its complete size is 0.58% to 6.29% above matched bzip3 on the three
held-out corpora, while full decode is 2.08x to 2.60x faster than the
retained-state bzip3 control. At 64 KiB it is 4.54% to 22.35% larger and
1.51x to 2.08x faster to decode. This is a Pareto tradeoff, not a superiority
or production-adoption claim, and it does not provide direct indexed snippet
extraction.

## Wire and accounting

All integers are unsigned little-endian. The 32-byte header contains magic,
version, flags, header size, dictionary length, block target, block count,
raw length, and a CRC-32 over the header prefix plus dictionary and directory.
It is followed by:

- the exact dictionary bytes;
- one 16-byte restart record per block: payload offset, encoded length, raw
  length, and CRC-32 of the decoded block;
- the concatenated block payloads.

A block begins with a one-byte mode. Raw mode contains literal bytes. LZ mode
uses one control byte per eight tokens, one byte per literal, and three bytes
per match. LZ-plus-predictor mode additionally stores the four-byte LZ-token
length followed by its arithmetic code. There are no native-endian fields,
pointers, hidden model weights, corpus-specific lexical tokens, or C calls in
the codec/decoder.

`Frame.open` validates the complete metadata root, contiguous directory,
counts, lengths, resource limits, and exact payload tail. Decode validates
match distances/dictionary indices, output length, canonical arithmetic tail,
and raw block CRC. CRC detects accidental corruption; it is not authentication.

The runner reports dictionary, header, restart directory, and payload bytes
separately and as a complete total. Its cold random-access amplification
charges the dictionary plus one encoded block; warm amplification charges the
encoded block after the dictionary is resident. The logical decoder budget
charges resident output plus any temporary token and canonical-code buffers.
The online predictor has zero stored model bytes; its reset counts are working
memory, while its one-byte block selector is already part of payload bytes.

The separate BWT frame has a 40-byte little-endian header, the 512-byte rANS
model, the same 16-byte-per-block restart directory, and payloads. A BWT
payload stores mode, primary row, decoded token length, and rANS bytes; raw
mode stores mode plus literals. The metadata CRC covers the model as well as
the header and directory. Per-block CRCs cover decoded bytes. rANS decoding
requires exact input consumption and its unique final state; zero-run lengths
must be canonical and representable before any shift.

The prepared entropy table is built once for `decodeAll` and once for a cold
independent block read. Reported BWT decode accounting includes output,
worst-case tokens, one in-place MTF/BWT-last buffer, the LF map, and all fixed
entropy/inverse-BWT tables. It is a conservative logical working-byte bound,
not peak RSS or allocator-capacity proof. On this 64-bit host the bounds are
143,110 B for a cold 16 KiB block and 536,326 B for a cold 64 KiB block,
including the resident 512-byte model. BWT construction's dominant temporary
arrays are conservatively 25 times the block size on this host (four `u32`
rank arrays, `usize` counts, and BWT-last bytes), excluding the growing output
frame and allocator capacity: 409,600 B at 16 KiB and 1,638,400 B at 64 KiB.

## Reproduction

Pure Zig tests (no libc or C codec):

```sh
zig build --build-file src6/experiments/bzip4/build.zig test -Doptimize=Debug
zig build --build-file src6/experiments/bzip4/build.zig test -Doptimize=ReleaseSafe
zig build --build-file src6/experiments/bzip4/build.zig test -Doptimize=ReleaseFast
```

Build the comparison runner (the candidate stays pure Zig; this executable
links the pinned bzip3 C implementation solely for controls):

```sh
zig build --build-file src6/experiments/bzip4/build.zig -Doptimize=ReleaseSafe
```

Timing-disabled, roundtrip-checked smoke run:

```sh
zig build --build-file src6/experiments/bzip4/build.zig run -- \
  --input src6/bench/real-world/evidence/corpora/freedict-eng-spa/projection.tsv \
  --input-format projection_content \
  --candidate bwt --block-bytes 16384 \
  --max-eval-bytes 262144
```

Timing requires both flags so an accidental smoke run cannot be reported as a
clean benchmark:

```sh
zig build --build-file src6/experiments/bzip4/build.zig run -Doptimize=ReleaseFast -- \
  --input PATH --max-eval-bytes 8388608 \
  --candidate bwt --block-bytes 16384 \
  --measure --quiet-gate BZIP4-EXPERIMENT-QUIET-GATE
```

The split is fixed and disjoint: the first 1 MiB of decoded input is training
and evaluation starts immediately after it. `--max-eval-bytes` caps the
held-out prefix. `--input-format projection_content` decodes and concatenates
only the third (normalized-content) hex column, matching the whole-stream
diagnostic in the retained report. With the default `raw` format the runner
measures the bytes of that file. A raw `projection.tsv` run is therefore only
a TSV/hex representation lane. Likewise, retained `rows.jsonl` is a metadata
JSONL lane, not dictionary content or a LEX6 packet-page measurement.

## Prior art versus hypotheses here

The components are prior art:

- Burrows and Wheeler's original report describes transforming a whole block
  to make it easier for local adaptive coders, and explicitly notes that
  blocks need to be fairly large for good compression. That supports the
  observed bzip3 page-size curve; it does not solve fine-grained access.
  [Burrows & Wheeler, 1994](https://www.cs.jhu.edu/~langmea/resources/burrows_wheeler.pdf)
- Relative Lempel-Ziv factors a target against a reference and was developed
  for compressed collections with random access. The shared-reference idea is
  therefore not new. [Hoobin et al., VLDB 2012](https://www.vldb.org/pvldb/vol5/p265_christopherhoobin_vldb2012.pdf)
- Zstandard specifies dictionaries containing reference content and entropy
  tables, normally supplied out of band. This experiment instead embeds and
  charges the dictionary once per archive.
  [RFC 8878](https://datatracker.ietf.org/doc/rfc8878/)
- Brotli combines LZ commands, context-selected codes, and a static dictionary
  with transforms. Its general architecture is substantially more developed
  than this baseline. [RFC 7932](https://datatracker.ietf.org/doc/html/rfc7932)
- Neural predictors paired with statistical coders go back decades, with
  early work reporting substantial speed costs; newer integer-only learned
  compressors still identify inference latency as a deployment issue.
  [Schmidhuber & Heil, 1996](https://people.idsia.ch/~juergen/textcompression/article.html),
  [Wang et al., ICML 2022](https://proceedings.mlr.press/v162/wang22a.html)

The archive-specific hypotheses under test (not claims of novel algorithms)
are:

- an **in-frame and fully charged** trained reference may amortize useful
  cross-page phrases without extending a page's decode dependency;
- a very small resettable integer predictor may improve the mixed LZ stream
  enough to justify its setup and divisions at 16 KiB boundaries.

Neither hypothesis is established by the current implementation. In
particular, the first storage smoke loses decisively to both bzip3 controls.

### Stronger structural follow-up: BWT as a self-index

A more ambitious way to separate compression and access horizons is to stop
treating the BWT solely as a transform that must be fully inverted. The
FM-index augments a BWT with rank data and suffix-array samples so the
compressed representation also supports search; self-index variants can
reconstruct text substrings without retaining a separate original.
[Ferragina & Manzini's FM-index materials](https://people.unipmn.it/manzini/fmindex/)
Run-length FM indexes make this especially attractive when the corpus-wide
BWT has few runs, while subsampled indexes expose an explicit space/time
tradeoff for locating through bounded LF/Psi steps.
[Mäkinen & Navarro's RLFM overview](https://www.cs.helsinki.fi/u/vmakinen/papers/ssa_njc_abstract.html),
[Cobas et al., subsampled r-index](https://users.dcc.uchile.cl/~gnavarro/ps/cpm21.pdf)

Very recent work on variable-length blocking adapts BWT-CSA index detail to
local compressibility and reports a better space/query-time balance than
uniform run-based structures. Its reduced sampling is proved correct only
along valid backward-search states, however; that result cannot be reused
blindly for arbitrary LF/Psi navigation or document extraction.
[Díaz-Domínguez & Mäkinen, 2026](https://arxiv.org/abs/2602.17201)

That is prior art, not a `bzip4` invention. The archive-specific question is
whether LEX6 could reuse one large-context compressed self-index for both
content storage and some search work while extracting only the requested
document/snippet. A bounded prototype would have to charge all of the
following, not just the run-length BWT:

- BWT/run symbols and run lengths;
- rank/select directories and cumulative symbol counts;
- suffix/inverse-suffix samples and document-boundary/sentinel mapping;
- any local entropy tables, checksums, and restart metadata;
- construction memory, extraction scratch, and rank operations.

With a sample gap `s`, reaching a nearby sample can require up to roughly `s`
LF/Psi steps before producing the requested `L` bytes, after which extraction
still performs rank work per byte. The relevant access metric is therefore
rank operations and bytes touched for `s + L`, not merely compressed bytes.
This could be worse than decoding a 16 KiB page, especially for mixed binary
packet data whose BWT has many runs. The next bounded decision should first
measure BWT run counts and charged rank/sample estimates on the same fixed
1 MiB-train/8 MiB-held-out content slices. Only a favorable estimate would
justify a separate executable prototype; it should not be folded speculatively
into the shared-LZ implementation.

## Measured outcomes

The authoritative normalized-content matrix, all accepted timing samples,
dictionary/predictor ablations, and rejected-probe ledger are in
[`results/README.md`](results/README.md). The main 32 KiB-dictionary candidate
loses storage to matched-boundary bzip3 on all three corpora and also decodes
more slowly; the conclusion is to keep it isolated.

The same results document contains the complete second-round BWT matrix.
The provisional manual per-process transcription, frozen hashes, and exact
protocol are retained as
[`round2-transcription.tsv`](results/round2-transcription.tsv),
[`round2-hashes.tsv`](results/round2-hashes.tsv), and
[`round2-protocol.txt`](results/round2-protocol.txt). The BWT result is useful
but still stays isolated: it trades modest-to-large storage loss for a large
decode win, and its encoder is not consistently faster. The initial matrix
did not directly save stdout/stderr, so its timing interpretation is
provisional pending independently captured replication.

The retained development smoke below used 262,144 held-out bytes of
FreeDict's `rows.jsonl`. This file contains preparation metadata, hashes and
paths; it is retained here strictly as a **metadata-byte negative control**,
not a real dictionary-content result. Its old split trained on the disjoint
first eighth; the runner now uses the clearer fixed 1 MiB training prefix.
All rows include their complete comparison framing (32-byte header and
16-byte directory record per block); `bzip4` also includes its 32,768-byte
dictionary.

| lane | access boundary | complete bytes | ratio to input |
| --- | ---: | ---: | ---: |
| raw framed | 16 KiB | 262,432 | 100.11% |
| `bzip4` candidate | 16 KiB | 88,576 | 33.79% |
| bzip3 matched control | 16 KiB | 39,474 | 15.06% |
| bzip3 current-page control | 64 KiB | 30,687 | 11.71% |

`bzip4` decomposes into 32 B header + 32,768 B dictionary + 256 B restart
directory + 55,520 B payload. Its first block is 3,440 B for 16,384 B raw:
0.209x warm amplification, but 2.209x for a cold reader that must also fetch
the dictionary. Exact whole-input and independent-block roundtrips passed.

These are storage and functionality observations only. The run explicitly
disabled clocks. No clean performance conclusion follows from it.

## Known limitations and next decision

- The trainer's bounded hash table and 64-byte fragment selection are a crude
  reference construction method, and the match finder retains one candidate
  per hash. Both leave compression on the table.
- The online model sees mixed control/literal/distance/length bytes through a
  generic previous-byte context. Role-specific models are a plausible next
  ablation, but should be implemented only if clean measurements show the
  current model helps enough to justify its CPU cost.
- Arithmetic decode canonically re-encodes the token stream. This gives strict
  tail validation but adds work and a temporary buffer; both are charged.
- The ordinary bzip3 control uses production `encode`/`decode`, which creates
  and frees native state for every block. The runner also reports a comparison-
  only retained-state bzip3 lane with one encoder state, one decoder state, and
  a reusable buffer, separating one-time setup from hot encode/decode. This C
  lane is not production code and does not weaken the pure-Zig decoder claim.
- This is a byte-file codec experiment. It has not demonstrated an improvement
  to complete LEX6 archives, packet layouts, or query performance.
- The BWT candidate shares only an entropy model across blocks; it does not
  create a large-context self-index or decode arbitrary snippets without
  inverting their complete 16/64 KiB block. The FM/r-index cost question above
  remains deliberately unimplemented.
- BWT training and encoding use bounded prefix-doubling construction rather
  than a production suffix-array implementation. Its encode results therefore
  describe this implementation, not a limit of the transform pipeline.

Production adoption requires separate review. The present evidence says to
keep the experiment isolated.
