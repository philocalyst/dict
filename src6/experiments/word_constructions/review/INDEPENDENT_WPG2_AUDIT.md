# Independent WPG2 reader and constructor audit

Audit target: the WPG2 prepared reader, C ABI Jobs wrapper, and local and
ancestor register constructors. The frozen source and binary checksums are
listed in `../evidence/wpg2-post-preflight-manifest.sha256`. The retained
8 MiB Japanese OMW archive used for adversarial tests is
`/workspace/scratch/wpg2-audit/omw-8m-strong-hoist-cb19cecf.wpg2`, SHA256
`cb19cecf34e5b0185bc9f64a5283af4461961e9dc0b3cf15a8a0c8ed56a97e05`.
Its original bytes have SHA256
`d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261`.

## Findings and closure

1. The original WPG2 prepared reader passed an attacker-declared native
   `delta_bytes` directly to the unchanged v4 decoder. An otherwise valid,
   resealed 297 KiB WPG2 archive changed that field from 1,311,926 to
   67,108,865 and still returned the exact requested page. The new WPG2-only
   preflight runs before native model preparation. It limits each delta
   output to 16 MiB, cumulative declared delta output and cumulative payload
   raw length each to 64 MiB,
   definitions to one million, blocks to 8,192, and each payload's token
   count to its nonzero raw byte count. It validates all spans and the exact
   terminal marker. The same resealed file now fails during preparation.

2. A local constructor with 256 preceding quoted fields could select donor
   index 256, then crash while encoding that index as one byte. A 1,360-byte
   valid tag reproduced the exception. `attribute_register.forward` now
   skips donors beyond index 255, leaving the field literal. Boundary cases
   with 255, 256, and 257 preceding fields all roundtrip through the Python
   and C++ constructors.

3. A failed full decode used to leave a partial or unverified destination.
   `prepared_wpg decode` now writes an adjacent temporary file and publishes
   it only after all page CRCs and the global CRC pass. A resealed wrong
   global CRC leaves an existing destination unchanged and removes the temp.

These are private WPG2 changes. The original native v4 source and frame
format remain unchanged.

## Independent checks

Run `python3 review/adversarial_review.py` from
`src6/experiments/word_constructions`, and run
`sha256sum -c src6/experiments/word_constructions/evidence/wpg2-post-preflight-manifest.sha256`
from the repository root. Both passed against prepared reader
binary SHA256
`75bf5bef7604b63d3d00468c2dcb216299d221c03091425a6d26d0f839cd74bb`:
The independent test script SHA256 is
`756889c5d3775b7b33c3bdfa4718af70e920e91bf11066e53d8d47b424187064`.

| Check | Result |
| --- | ---: |
| Python versus C++ constructor/page byte parity | 464 cases |
| Fresh native frames for WPG2 modes 0, 1, 2, 3 | 4 modes exact |
| Retained 8 MiB archive selected pages | 0, 63, 127 exact |
| Resealed/malformed envelope and native payload assertions | 16 passed |

Constructor cases include zeros, literal marker bytes, invalid UTF-8,
partial and crossed page tags, 4,095/4,096/4,097-byte tags, 256/257-byte
donors, 32/33 ancestor levels and fields, and the one-byte donor-index
boundary. An altered final entropy payload does not affect a query for page
zero; a query for its own page and full decode fail. Page query validates
only the selected page's CRC; full decode validates the global CRC too.

The rebuilt prepared reader also completed fresh full decode and CRC checks
on valid 1 MiB FreeDict, GCIDE, and OMW archives, plus 8 MiB OMW archives
using the bytes, DP, strong hoisted, and strong interleaved policies. Their
retained files are under `/tmp/wcm-screen/`; the strong and DP OMW8 fixtures
were copied to `/workspace/scratch/wpg2-audit/` for this review. Two earlier development files
that predate WPG2's header CRC reject as obsolete frames.
For the retained 8 MiB DP mode-3 archive, I also regenerated every page's
transformed bytes with the current constructor and decoded the archive's
inner native frame independently. Both byte streams are identical, with
SHA256 `b9ef7a952e8465979af3d889b3248b3c20bc1c50efe2cc63cc1a9c9bab15579b`
over 5,613,360 transformed bytes. This checks the donor-index fix against a
measured complete frame.

## Lifetime and remaining scope

The WPG2 `Reader` owns the frame byte vector throughout the prepared handle's
life. Native Jobs keep slices into those bytes and immutable decoder arena
data. The unchanged native bucket implementation grows into fresh arena
storage, retaining earlier job tables; payload Jobs therefore remain valid
after all model deltas are prepared. `wpg_read` decodes only blocks overlapping
the requested transformed interval, then the constructor resets at each
original 64 KiB page and checks its byte length and CRC.

The preflight bounds WPG2's block metadata before native delta allocation.
It does not provide a small fixed process-memory guarantee for every corrupt
native model header: the unchanged v4 model decoder admits large, internally
bounded row tables, and WPG2 does not enforce a global allocator budget on
that model. CRC32 detects accidental corruption but is not authentication;
an attacker who rewrites content and its checksums can create a different
valid archive. No comparative timing conclusion is drawn from these tests.
