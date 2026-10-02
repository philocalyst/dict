# WPG2 exact word constructions: development frontier

WPG2 constructs record values from earlier bytes in the same or an enclosing
tag, then fits a word-grammar entropy frame to the remaining exact byte
stream. It has no language-specific reconstruction rules, external vocabulary,
or decoder-side learned weights. Arbitrary bytes and malformed markup retain
literal fallback. The encoder searches four global constructors (raw,
same-tag, ancestor, both) and two fully fitted spelling graphs (LaneA+M base
and conditional root DP), then chooses the smallest **complete** frame. The
two fixed profiles differ only in native model placement: `quality` uses
interleaved deltas; `access` hoists one common model before every payload
job. Both retain original-byte 64 KiB reset pages and page CRCs.

## Complete development frames

The following use the same retained 8 MiB Japanese OMW development bytes,
SHA-256 `d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261`.
The pinned bzip3 1.5.1 comparator is one whole 8 MiB block, not a 64 KiB
random-access frame. These are not final holdout measurements.

| Frame | Bytes | Change from whole-block bzip3 | Original 64 KiB page access |
|---|---:|---:|---|
| bzip3 1.5.1, one block | 332,331 | — | No |
| WPG2 `quality`, global raw/base fallback | 332,642 | +0.09% | Yes |
| WPG2 `quality`, global winner | **285,569** | **−14.07%** | Yes, prepared model |
| WPG2 `access`, global winner | **294,938** | **−11.25%** | Yes, one common model |

The quality winner is local+ancestor construction with conditional spelling
DP, SHA-256 `27085257bc92909c5d4882e9a66e539d5fbb2374caee92e81b1207c447591bd1`.
Its complete byte ledger is 921 outer wrapper and page index, 6 native
header, 1,164 native directory, 122,376 native model/dictionary, and 161,102
native payload bytes. The access winner chooses the same constructor/graph,
SHA-256 `196e791e96d1e1666ac1fbe6480bc4d623ff21e9e339aa55c52646d6cd06a168`.
Its ledger is 921 + 6 + 698 + 122,629 + 170,684 = 294,938 bytes. Access
has one leading model-only native block and 86 payload-only blocks, with no
later delta replay. The quality reader prepares all model deltas once, then
reads only Jobs overlapping a requested original-byte page. Both archives
freshly decoded the full source exactly; page 63 required two payload Jobs
and passed its own CRC.

Full eight-way 8 MiB candidate sizes, source hashes, and bzip3 controls are
in `evidence/dev-omw-eval8.json`. On 1 MiB prefixes, the same global quality
policy yielded FreeDict 82,074, GCIDE 193,406, and OMW 38,829 bytes; access
yielded 83,576, 198,302, and 39,924. FreeDict/GCIDE selected raw +
conditional spelling, and their whole-block 8 MiB bzip3 controls remain
smaller than WPG2. The word-construction win here is significant but
corpus-dependent. The prior-word ring negative result and other ablations
are retained in `RESULTS.md`.

## Reproduce and inspect

From the repository root, with the pinned WGP6 binaries built:

```sh
make -C src6/experiments/word_constructions test
python3 src6/experiments/word_constructions/wpg_codec.py encode INPUT ARCHIVE --profile quality --block 65536
python3 src6/experiments/word_constructions/wpg_codec.py encode INPUT ACCESS_ARCHIVE --profile access --block 65536
python3 src6/experiments/word_constructions/wpg_codec.py inspect ARCHIVE LEDGER.json
python3 src6/experiments/word_constructions/wpg_codec.py decode ARCHIVE OUTPUT
python3 src6/experiments/word_constructions/wpg_codec.py extract ARCHIVE PAGE_OUTPUT --index 63
sha256sum -c src6/experiments/word_constructions/evidence/wpg2-final-policy-manifest.sha256
```

For the frozen development backend, prefix `encode` and `inspect` with
`WPG6_BIN_DIR=/workspace/scratch/wgp6/frozen-backend-20261001`. The adapter
reports the SHA-256 of each actual backend binary it ran. The manifest checks
both repository binaries and immutable qualified copies in that directory.
The backend's own source and original-v4 fingerprints are in that directory's
`manifest.json`.

`encode` reports all candidate bytes and distinguishes Python construction,
native model-fit/reparse codec time, child-process wall time, total search
wall time, and fresh decoder verification. `inspect` asserts exact byte
accounting across wrapper, native header, directory, dictionary, and payload.
`extract` returns and verifies one original-byte page. Only 65,536-byte
original-page requests are supported; the decoder applies no normalization.
The saved manifest fingerprints all adapter and decoder sources plus the
actual native binaries used for the measurements.

## Integrity and limits

The WPG2 reader checks header CRC and page geometry before native model
preparation, then checks each original page's CRC and full-output CRC. It
preflights native block metadata before legacy v4 allocation: header ≤8 MiB,
declared delta ≤16 MiB per block and ≤64 MiB total, ≤1 million definitions,
≤8192 blocks, and each payload Job's item count ≤decoded bytes≤64 KiB.
Full decode writes to an adjacent temporary file and publishes only after
all CRC checks pass. It keeps the entire archive and the prepared native
model in memory; the inherited v4 model reader is not claimed hostile-input
hardened. Original input is limited to 32 MiB for this research adapter;
the underlying encoder also has explicit grammar-work budgets.

An independent audit at `review/INDEPENDENT_WPG2_AUDIT.md` passed 464
constructor parity cases, four native-backed modes, real selected-page
queries, and 16 malformed/resealed-envelope cases. It independently rebuilt
the 5,613,360-byte OMW constructed source and matched the native inner
frame's decoded SHA-256
`b9ef7a952e8465979af3d889b3248b3c20bc1c50efe2cc63cc1a9c9bab15579b`.
The audit identified and closed an oversized native delta declaration,
excess payload items, an out-of-range donor index, and partial output
publication on CRC failure.
