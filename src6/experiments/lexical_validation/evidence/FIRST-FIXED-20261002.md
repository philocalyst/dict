# First fixed whole-source LTCv2 validation

This untouched validation rejects a general compression-win claim. Turkish
passes all ten native candidates but loses to both backend scopes. Arabic and
Japanese fail the frozen native family's capacity bound before its first
candidate completes. Resource failures are separate from measured size losses;
no records or later failing sources are removed from the evaluation.

The source checkpoint and corrected codec were independently audited before
any candidate outcome. All existing whole records, source order, ordered keys,
complete serialized entry material and original native groups are retained.
TR/AR include every projected record; JA retains the previously declared
SHA-256(source-entry-ID) modulo16 whole-record sample. These are complete
adapter-normalized TEI entry strings, not raw original TEI files; front matter
was excluded by the original source adapter. No linguistic analysis is inferred.

| Source | Whole records / native groups | Fixed complete-size minimum | Fixed typed/headword minimum | Matched-page bzip3 / zstd19 | Whole-flat bzip3 / zstd19 |
| --- | ---: | ---: | ---: | ---: | ---: |
| tur-eng | 1,026 / 14 | 40,960 B | 43,322 B | 31,195 / 31,820 B | 21,626 / 25,602 B |
| ara-eng | 52,996 / 719 | `WorkLimit`, no frame | `WorkLimit`, no frame | 1,813,579 / 1,858,632 B | 1,079,165 / 1,352,413 B |
| jpn-eng | 10,977 / 258 | `WorkLimit`, no frame | `WorkLimit`, no frame | 941,628 / 975,665 B | 510,812 / 668,407 B |

Turkish's size winner `global_causal_surface` carries exact canonical packets
and lacks a typed headword prefix. It costs 31.30% / 28.72% more than the
matched-page bzip3 / zstd19 controls, and 89.40% / 59.99% more than whole-flat.
The typed profile chooses `global_joint`, costing 38.87% / 36.15% more than
matched-page controls and 100.32% / 69.21% more than whole-flat. All ten variants
were encoded and admitted: 10,260 full native/source/root/group observations
and 7,182 direct typed headword projections passed. No timing is ranked.

The immutable native client exits on the first failure. Arabic and Japanese
both return `error: WorkLimit` at `global_packet_ans`; zero candidates complete
and later nine remain unattempted by the fail-fast family. The frozen absolute
ANS event cap is 8M; literal-only packet inventories exceed it at these whole
source sizes. The family cannot produce either valid fixed profile minimum.
Its source rows and all original groups were still fully admitted by the
audited native-v3 baseline producer. All four complete backend controls were
actually encoded, reopened, decoded and checked for each source, including
both failed sources. A later uniform capacity-only protocol would be a new
registered evaluation, never a retroactive correction of these failures.

All native candidates include framing, checksums, learned models/literal stock,
root offsets/streams and original group metadata. Typed queries require full
global stock resolution and semantic/source admission first. The stock contains
serialized XML source records: its resident allocation/model/index costs must
be charged; no cold or cache-free access gain is claimed. Whole-flat backend
controls pay the same source-group directory but decode a whole block for a
cold root. The dictionary page results are not whole-file compression wins.

The exact fixed codec remains SHA-256
`9544111de6f587d4d374e169f8391922dcfa7d1a10151a14c5a76e638dfc5597`;
its corrected source/policy/limits freeze is
`1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84`.
The pre-outcome source checkpoint is
`064e8b9d65c249dcf0d424bcd8a2b98fd0e3fa9ae483dc07e3ce5ef6fa0e3fbf`.
The complete ledger [`FIRST-FIXED-20261002.json`](FIRST-FIXED-20261002.json),
SHA-256 `a81f59055a0261b511100328096946b8c618bfce45aba60370b3b25c8b4687da`,
retains every source/group/frame/control hash, native row, failure and command.
The new validation client operates outside the frozen codec folder and does
not change its schema, source pin, model, candidates, selectors or limits.
