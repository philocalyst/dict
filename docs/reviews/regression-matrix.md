# Confirmed bug regression matrix

Updated 6 September 2026. A finding enters this table only after reproduction.
Design gaps and hypotheses remain in `structural-compactness-audit.md` until a
failing behavior is demonstrated. Every confirmed bug must keep a test that
exercises its former trigger; a nearby happy-path test is insufficient.

| Confirmed defect | Original trigger | Regression |
| --- | --- | --- |
| Bzip3 decoder state size absent from the wire | Encode a roughly 300 KiB definition with a 512 KiB state, then decode through the default reader | `custom bzip3 state size is carried on wire and used by lazy decode` |
| Bzip3 short probe supplied an uninitialized ninth byte to C | Probe malformed inputs of lengths 0 through 8 repeatedly | `short bzip3 probes are deterministic and never succeed` |
| Invalid bzip3 configuration silently fell back to raw | Select a block size below the native minimum | `invalid bzip3 profiles are build errors while resource limits may fall back` |
| Repaired checksums could hide malformed compressed data until lazy access, without a direct regression | Mutate the compressed CRC, repair container checksums, open, then request its definition | `bzip3 payload blocks preserve semantics and remain independently addressed` and `lazy bzip3 decode honors its allocator and releases failed output` |
| Definition lookup scanned every atom | Lookup first/last/missing IDs in shuffled, large raw and bzip directories | `definition lookup binary-searches sorted atom IDs for raw and bzip snapshots` |
| Definition decode used an implicit global allocator and did not expose its memory ceiling | Force decode allocation failure and a post-allocation codec integrity failure | `lazy bzip3 decode honors its allocator and releases failed output` |
| A processing-instruction target leaked when child-vector growth failed | Allocate the PI target, then fail the following `ArrayList.append` | `semantic builder survives every injected allocation failure` now appends 40 PI children to cross growth boundaries |
| A transferred root slice could leak when a later model-build allocation failed | Fail each allocation while building a model containing roots and both anchor arrays | `semantic builder survives every injected allocation failure` |
| Evidence attributes accepted an invalid namespace until final model validation | Add an assertion whose evidence attribute references namespace 99 | `evidence rejects invalid qualified attribute names at insertion` |
| Linking an existing document child bypassed parent/child source ownership validation | Link a source-B child below a source-A parent through `appendChild` | `appending an existing document cannot bypass source ownership validation` |
| Source-node filtering performed a nested anchor scan and charged only each array independently | One candidate plus one anchor with `max_scan_items = 1` | `source-node semijoin charges aggregate scan work and temporary bits` |
| The source-node semijoin's replacement bitmap could become unbudgeted private memory | Set `max_temporary_bytes = 0` for a nonempty candidate domain | `source-node semijoin charges aggregate scan work and temporary bits` |
| Attribute result accounting added item count to structure width instead of multiplying them | Request two attributes with a byte budget one byte below the exact structural-plus-name cost | `attribute byte budget charges every result structure` |

Writer allocation-failure coverage for encoded-block ownership and the new
adaptive postings path is being added with the minor-4 postings work. Compact
semantic v0.4 allocation-failure and malformed-pool regressions are likewise a
required acceptance condition for that branch. They must move into the table
only after passing in Debug and ReleaseSafe.

The memory costs and representation redundancy rules are recorded in
`docs/compactness-research.md`, under “Memory and redundancy ledger.” That
ledger deliberately distinguishes published bytes, peak build memory, and
private/shared query memory; one scope cannot be used to conceal another.
