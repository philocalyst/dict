# Development results and rejected mechanisms

These are screening findings from 2026-10-01, before the final `protocol.json` fingerprint. Every listed candidate produced a complete stored frame and a successful fresh-process exact decode. The same bytes were compared with low-level bzip3 payloads plus 13 bytes of file framing and 8 bytes per independent restart. Native whole-file bzip3 is a separate control. Timings from this concurrent development phase are provisional and must not be used as final speed claims.

The new development content is concatenated exact projected dictionary entries, including their original entry markup; the UD lane is natural text. It is not TSV hexadecimal or a free external vocabulary. Input hashes and source provenance are retained in the development JSON and `/workspace/scratch/frontier-corpora/manifest.json` used by the root benchmark.

## Structural changes that survived the screen

For the first 8 MiB of OMW Japanese, a generic shared Re-Pair grammar with direct class rANS used **1,212,643 bytes**, larger than matched 64 KiB bzip3's **715,076**. Adding output-surface copies reduced it to **638,354**; delivered parameter rANS reduced it to **617,524**. Header packing, class-conditioned exact joint parsing, and pricing the parameter bytes then brought the larger-inventory policy to **540,315**. Reducing the source precision from 16 to 14 bits further improved size to **539,232** while reducing class lookup-table storage by four times.

| Development input, raw bytes | 14-bit direct source, paid frame | Matched 64 KiB bzip3 | Whole bzip3 | Size vs matched |
|---|---:|---:|---:|---:|
| OMW Japanese content, 8,388,608 | 539,232 | 715,076 | 350,232 | −24.59% |
| GCIDE content, 8,388,608 | 1,504,514 | 1,908,398 | 1,242,698 | −21.16% |
| UD multilingual natural text, 2,145,015 | 575,120 | 541,536 | 444,268 | +6.20% |

The source remains larger than whole-file bzip3 in these three cells. The gain applies to identical 64 KiB independent raw access boundaries with a delivered shared source. It is not a whole-file compression record or a complete dictionary-container result. Natural prose remains an unresolved size weakness.

The 14-bit development JSON measures complete native decode including preparation and checksum at approximately 42.9 ms OMW, 83.8 ms GCIDE and 29.4 ms UD. These numbers are diagnostic; independent serial timing is required. Decoder peak RSS was approximately 25 MiB for GCIDE in the development run. The final native benchmark reports exact scope and distributions.

## Inventory capacity is a property of the representation

A prefix-rich English word list needs a different amount of shared grammar than a large prose collection. Using the same six-capacity complete-frame search for every input avoids a corpus-specific hidden choice. With the earlier 16-bit development policy:

| Word forms | Selected capacity | Complete frame | Matched bzip3 | Whole bzip3 |
|---|---:|---:|---:|---:|
| GCIDE, 1,011,358 bytes | 512 | 297,551 | 334,240 | 351,569 |
| OMW Japanese, 948,378 bytes | 2,048 | 338,234 | 325,733 | 292,096 |
| FreeDict English–French, 61,521 bytes | 0 | 28,412 | 25,512 | 25,508 |

The earlier fixed 4,096-rule, coarse parse used 388,874 bytes on GCIDE words. Capacity search plus the joint source parse materially changes that result. Japanese and the small French lane still lose to their bzip3 controls. The final frozen 14-bit auto policy is confirmed separately; these earlier values are not its final results.

## Rejected or limited ablations

* **Generic grammar/direct rANS alone:** misses OMW's repeated headword parameters despite a large inventory. It is a control, not the selected direction.
* **Sparse exact-predecessor rows:** small size improvements (about 1–2%) add tables and hurt fresh-process preparation. The frozen policy excludes them.
* **Global previous-copy source-position deltas:** OMW worsens by 12,658 bytes, GCIDE by 6,999 and UD by 1,712. A nearest-longest match changes source bindings too often for this predictor. The frozen policy codes distances.
* **Copy first, learn the literal residue:** lowers OMW encode work and shared-model size but slightly increases its total frame and materially hurts GCIDE/UD. Learner ordering is not interchangeable. The frozen policy learns from the full surface first.
* **More vocabulary without repricing:** a larger inventory can increase total size despite fewer roots. Grammar and frequency-table delivery remain part of the objective.
* **12-bit class rows:** slightly improves OMW and prepares smaller tables, but adds about 12 KiB to GCIDE relative to 14 bits. The frozen policy uses 14 bits for every file.
* **Grammar-copy commands followed by symbol BWT:** the sibling agent's complete-frame screen loses against its no-copy BWT source. The copy source and BWT source remain independent candidates; no combined gain is claimed.

`evidence/development/` retains the raw JSON outputs, controls, capacity sensitivity and test logs. Historical implementation snapshots preserve the main family transitions (`baseline.cpp`, `cache_raw.cpp`, `cache_distance.cpp`, `cache_binding_negative.cpp`, `cache_packed.cpp`, `cache_copyfirst_negative.cpp`, `cache_context.cpp`). They are experimental snapshots rather than additional promoted format modes. Some early rows lack a complete source fingerprint; use them for mechanism diagnosis, and use independent post-freeze results for claims about the final executable.

## Independent safety repair before registration

Luna's independent sanitizer audit found a supported 4 MiB restart whose copy distance required a fourth varint byte, exceeding the three parameter contexts. The initial development tests used smaller restart sizes and did not cover it. The repaired policy caps raw restarts at 64 KiB in writer and reader, checks the dominant joint-parse arrays before allocation, and applies a 4 GiB estimated encoder work budget. A valid distance above 16 KiB still round-trips; 65,537-byte and larger restart options now fail before learning. The final six-test suite adds the independent large-input regression. The repaired source and executable fingerprints replace the earlier freeze in `protocol.json`; default 16/64 KiB encoded bodies are unchanged.
