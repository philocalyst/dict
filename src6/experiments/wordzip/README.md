# Native word and phrase compression experiments

`sbwt` is a standalone lossless native experiment. It has no external
dictionary, tokenizer, weights, or compression library. It is not selected by
production LEX6 archives. `wordzip` is a separate reversible lexical-transform
control using Zstandard; its results must not be described as a new entropy
coder.

The frozen WSB2 policy learns a shared phrase grammar over the entire input,
then independently codes 16/64 KiB raw blocks. The important changes relative
to the older Python symbol-BWT experiment are:

1. Phrase spelling determines the BWT alphabet order. The decoder derives this
   order from delivered spellings, so there is no unpaid permutation.
2. Two encoder-only rounds refit root prices and use dynamic programming to
   choose among overlapping spellings. The decoder receives only the selected
   roots, never an external analysis or parse model.
3. Both the grammar and the entropy-table representation are compressed by a
   fully delivered byte rANS model. All model and model-of-model bytes count.
4. A tiered move-to-front decoder uses 64-symbol circular segments. Moving a
   high rank shifts at most one short segment and one value per earlier
   segment, rather than the entire alphabet prefix. This changes execution,
   not the bitstream.

The primitives are established prior art: grammar precompression, word/symbol
BWT, move-to-front, dynamic programming, and rANS. The measured composition
and its encoder/decoder choices are the experiment; no mathematical novelty
or universal compression record is claimed.

## Build and exact restart extraction

```sh
make -C src6/experiments/wordzip
src6/experiments/wordzip/sbwt encode INPUT OUTPUT --block 65536 \
  --cap 16384 --passes 64 --policy 0 --order 1 --dp 2 --contexts 1 --dict 0
src6/experiments/wordzip/sbwt decode OUTPUT DECODED
src6/experiments/wordzip/sbwt decode OUTPUT BLOCK_7 --index 7
python3 src6/experiments/wordzip/test_codec.py
```

The primary encoder source and executable were frozen for independent Luna
benchmarking. The registered SHA-256 values are:

- `sbwt.cpp`: `9bfde6b3746c0315c16eda3b7336cd3b9c33c0288de4a7634251181e2eb01745`
- executable: `36eed15d57777c7ec5329842af2a01bc1c99e25ebbf72c9d139977da3f40aebe`

The executable emits codec-only nanoseconds, microseconds, byte counts, and
Linux `getrusage` peak RSS. Process startup, input/output, model preparation,
and per-block timings must be reported separately where relevant. Full decode
includes shared model preparation once. Independent `--index` decode includes
cold model preparation and never decodes another block's payload.

The other three fixed policies are independently registered:

| Policy | Source SHA-256 | Executable SHA-256 |
| --- | --- | --- |
| Complete-frame capacity choice | `40a3df52ef1d65f97b1753661be77a6422b1f8d5a4b6a36c374ed943a3d3eeeb` | `6bb063d3ffc9add0865e2bb6c4de99d0123858453b9c51ed6c0521d90b629b39` |
| Plain roots versus surface bindings | `9bcf0d3ec29906599eedebdebae78324ace0a1c311f72530240916dfc754dfd1` | `3f744b175de55e33f2ae29023d50b10bcb41f09e0c8aa63eedadde882ac51388` |
| Byte versus Unicode-scalar capacity choice | `aa9f6cbe61ffa34283c0892df10dec2d5b048ea64b92ef142b5d2a7b9d85b4d1` | `0cfaf2af2987af7c4b51e49df347eaf72ebc804e164d8ba73a9409765084402d` |

`sbwt-auto encode INPUT OUTPUT --auto 1` uses the primary policy's other
defaults and tries capacities 0, 512, 2,048, 8,192, and 16,384. It compares
complete delivered frame bytes and resolves ties in favor of the first
capacity. All five complete encodes count in its encode time; the selected
frame is readable by the primary decoder.

`sbwt-select encode INPUT OUTPUT --choice 1` encodes both plain lexical roots
and roots with productive exact-surface bindings, choosing the smaller complete
frame. A binding refers to prior output bytes in the same raw restart block,
independent of earlier token boundaries. Its argument lengths and distances
use a fully delivered byte rANS model. The fixed parser price of 12 bits per
parameter byte is an encoder search choice; measured frame bytes decide which
variant survives. Ties select the plain representation. Both complete encodes
count in encode time.

Surface frames retain WSB2's header and directory and set flag mask `0x10` (the
frozen policy therefore emits flags 1 or 17). Their compressed block payload
starts with two little-endian u32 values: main-code byte length and decoded
parameter-stream byte length. Main rANS bytes and parameter rANS bytes follow.
Parameter pairs are canonical varints for length and distance in restored
command order. The delivered entropy container includes both model families.
The dedicated `sbwt-select` decoder checks parameter consumption, copy lengths
6–4,096, positive distances within already reconstructed output, output bounds,
and raw CRC. Use that decoder for all surface-choice frames; the primary
decoder intentionally accepts its own frozen flag domain.

`sbwt-unicode-auto encode INPUT OUTPUT --unicode-auto 1` compares ten complete
frames: byte atoms and valid Unicode scalar atoms, each at capacities 0, 512,
2,048, 8,192, and 16,384. Scalar seeds represent exact 2/3/4-byte UTF-8 spellings;
overlong encodings, surrogates, out-of-range codepoints, truncated scalars, and
rare characters retain byte fallback. The decoder receives only exact stored
spellings and the ordinary WSB2 frame, so it requires no Unicode database.
Ties favor byte atoms and then the earlier capacity. Encode time includes all
ten complete trials; the primary decoder remains compatible. This policy was
frozen from development evidence before reading final results. Its useful
development gains are currently specific to Russian, not a universal Unicode
improvement.

Run `make -C src6/experiments/wordzip test-all` to validate all four fixed
policies in independent processes. Forced binding mode was also checked with
`WORDZIP_EXE=.../sbwt-lab WORDZIP_ENCODER_OPTIONS='["--copy","12"]'`.

## WSB2 accounting and validation

The fixed 40-byte little-endian header contains magic/version, raw block
target, block count, total raw length, delivered grammar and entropy lengths,
metadata CRC32, and flags. It is followed by the two complete models, one
32-byte directory record per raw block, and contiguous payloads. Each record
contains a payload-relative offset, encoded/raw/root/event lengths, cyclic
BWT primary row, and decoded-byte CRC32. A primary of `UINT32_MAX` selects
literal raw storage. All framing, dictionaries, nested entropy tables,
checksums, directories, raw fallbacks, and rANS final states count.

The parser validates metadata CRC before using the grammar; canonical
integers, backward rule references, rule expansion sizes, entropy frequency
sums, alphabet bounds, directory continuity, exact raw boundaries, payload
lengths, BWT primary values, zero-run limits, exact rANS input/final state,
decoded lengths, and raw CRCs. CRC32 detects accidental corruption and is not
authentication. The fresh-process suite also checks every restart, invalid
UTF-8/random bytes, deterministic encoding, all prefix truncations, extra
tails, 1,024 fixed mutations, and resealed invalid directories.

The byte grammar preserves every script and arbitrary input bytes. It does
not claim to infer a linguistic analysis. Earlier whole-word seeding and
reverse-spelling order are retained as rejected development alternatives;
their linguistic intuition did not consistently repay delivered bytes.

## Development findings, not final acceptance

On the prior fixed 8 MiB normalized-content development streams at identical
64 KiB restart boundaries, the frozen policy produced these complete frames:

| Corpus | WSB2 | Matched bzip3 | Difference |
| --- | ---: | ---: | ---: |
| FreeDict English–Spanish | 713,783 B | 899,408 B | −20.6% |
| GCIDE | 1,622,022 B | 1,905,560 B | −14.9% |
| OMW Japanese | 536,324 B | 674,384 B | −20.5% |

These are development observations over normalized text, not complete
dictionary archives, final untouched evidence, or comparisons with bzip3
using one much larger block. Independent Luna results own the final outcome.
Development timing under concurrent work is diagnostic and is not a speed
ranking. Larger grammars initially slowed MTF decoding; the tiered decoder
removes much of that cost without changing encoded bytes.

`sbwt-lab.cpp` contains isolated alternatives, including directly shared
prefix/suffix spellings and a surface-copy residual before BWT. On the examined
large development streams, binding mode loses slightly on FreeDict and GCIDE
and saves another 3% on OMW Japanese. This is why the separate fixed policy
charges both searches and chooses by the entire frame. See the development
ledger for unsuccessful ordering, model, parsing, and seeding alternatives.

The CLI checks its 576 MiB file limit before allocation; decoded data is capped
at 512 MiB. Shared uncompressed model serialization is capped at 8 MiB, each
stored model at 9 MiB, rule expansions at 256 bytes, and directories at one
million blocks. The encoder's price fitting uses floating-point `log2`, while
the decoder is integer-only. A reader integration needs an
explicit shared-model ownership and memory contract and complete archive/query
benchmarks. This experiment does not silently change that production contract.
