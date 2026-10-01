# Richness review resolution — 2026-09-19

This follows the [adversarial report](richness-sol/report.md), which remains a
historical review of version 1. Its reproducers deliberately assert old behavior;
they are not the current regression suite. Production changes stay in src6 and
build6. Earlier implementations and benchmark evidence remain intact.

## One structural authority, not another record model

The public model still owns semantics. A reflected, bounded structural cursor
now powers both validation's identity collection and query resolution. It sees
ordinary fields, union payloads, collections and ownership pointers. The same
metadata-owner rule covers representations, features, structures, range elements,
denotations and shared values, without a second hand-maintained identity list.
The smaller lexical/inline cursor remains available for ordinary queries and
rendering; structural traversal does not burden every hot selection.

| Review concern | Resolution | Boundary |
| --- | --- | --- |
| Admitted identities missing from resolver | Typed all-node resolution shares admission's structural traversal | Resolving is a bounded scan, not a hidden index |
| Manual-only structural predicates/ancestry | Runtime-context filters compose over typed iterators; structural matches expose ancestors | Not a general query language, optimizer, reverse index or arbitrary graph-path engine |
| Two relation endpoint authorities | `endpoints` chooses binary or ordered participants | Open qualified role names remain open; citations and denotations are not flattened into one universal claim |
| Missing shared atomic value identity | `SharedValue` owns a named Value; references reuse it; value libraries are resources | Define once; repeating even the same definition pointer is rejected |
| Malformed language tags | RFC 5646 syntax, grandfathered forms and duplicate-subtag checks | No registry membership or canonicalization claim; original case retained |
| Byte-slice projection surprise | `values` rejects byte strings and non-slices at compile time | `child` still exposes the actual byte-string value |
| Undefined external target behavior | Explicit found/unavailable/unresolved follow results and bounded hops | Missing external addresses do not invalidate an otherwise valid document |

Denotations now carry occurrence metadata, so evidence can qualify a particular
denotation without conflating it with a translation citation or concept.

## Useful ownership and latency boundaries

`Archive.open` remains metadata-only. `Archive.load` remains an uncached control.
`Reader` owns one decoded page plus its validated packet boundaries and reuses
source extents. Loaded documents own separate arenas and survive page eviction
or reader/archive destruction. Cache misses check the complete page digest and
framing before any document is exposed. Failed replacement leaves no partial
cache entry. Statistics report page loads, bzip3 decodes and cache hits.

Cross-entry identity is not headword identity. `Reader.prepareLinks()` explicitly
loads/admit-checks entries and creates a derived logical-ID catalog transactionally.
This adds no on-disk index bytes, but costs a full scan and owned identity memory.
Resource lookup uses the existing catalog. A found follow result owns its packet
and fragment; callers obtain node pointers only after placing that owner at its
stable address. A local node resolves inside its loaded document. No operation
silently recursively follows links; caller-driven cycles consume the hop budget.
The allocation-free in-memory `FollowSession` borrows a library with unique
document identities and already admitted documents; it is a query helper, not
an alternate library-admission operation. Archive building and prepared archive
links enforce document-ID uniqueness.

## Verification and measurement policy

The version-2 packet codec owns decoded single-item pointers in its arena and
bounds recursive ownership edges. Old packets and archives are rejected using
explicit version markers. Tests cover the updated rich fixtures, independent
public client, source/resource scope, new query/identity cases, cache eviction,
link availability, corruption and allocation-failure cleanup. Four negative
compilation contracts cover union access and collection projection misuse.

Final implementation matrix on the frozen production revision:

| Mode | Runtime tests | Expected compile rejections |
| --- | --- | --- |
| Debug | 69/69 (68 library + 1 independent client) | 4/4 |
| ReleaseSafe | 69/69 | 4/4 |
| ReleaseFast | 69/69 | 4/4 |

`build6` formatting and `git diff --check` also pass. This includes the cached
page with a malformed later frame and recomputed digests, and every Zig
allocation-failure position in single-pointer packet decoding and link setup.
The implementation agent independently ran its nine focused tests in all modes
and reviewed the reader/packet integration read-only; root ran the full matrix.

Version-1 real-corpus storage ledgers remain baselines, not measurements of this
revision. No performance win is inferred merely from fewer decode calls. The
independent post-review timing run is maintained under `bench/real-world` and
must identify this version's source/binary hashes separately from those baselines.

## Still worth exploring

1. Compare explicit link preparation with a compact persisted logical-ID index
   on real workloads. Charge all bytes, startup work and identity memory.
2. Index selected predicates/reverse references as disposable projections over
   the same iterator semantics, without introducing another semantic authority.
3. Test source and rich-tree fragmentation for large documents. Keep exact byte
   coordinates and distinguish shared physical storage from shared claim identity.
4. Measure schema-default elision against real bzip3; do not assume an extra
   dictionary helps after entropy coding.
5. Tune page size against first-load latency, mixed-page workloads and memory,
   not compression alone. Preserve the separate raw/adaptive/forced controls.
