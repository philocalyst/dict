# Runtime 2 resource correction: development proof

## Incident and cause

The frozen WPG2 quality run on the 22,238,553 byte final Japanese content
failed inside the frozen `m_reference` process with `error.OutOfMemory` after
526.6 seconds. The frozen binary did not print a phase or allocator request,
so this record alone cannot identify whether seed learning, LaneM learning,
or native fitting reached the limit. The archive and policy were not changed,
and no large final run was made while investigating.

The original LaneA seed learner gives each of its five candidates an arena.
`grammar2.build`, `mdlDelete`, and `optimalReparse` free large temporary
tables and token vectors during their work, but arena `free` does not return
those allocations. The final 22 MiB *development* Japanese input reached
2,163,318,974 accounted bytes in the original seed phase. GCIDE 8 MiB
development reached 3,641,298,390 bytes. This is avoidable lifetime overlap:
each candidate's surviving grammar is cloned into the seed arena before its
scratch allocator is destroyed.

Runtime 2 replaces only those candidate arenas with the already present
`Scope` allocator, which forwards individual frees to the same bounded
parent. Its ownership map remembers each original allocation length, including
when the original grammar learner frees a shortened sequence view. LaneM
epochs, candidate order, IDs, floating point costs, fitting, and the 4 GiB
live allocation limit are unchanged. The new Budget wrapper reports phase,
live and peak bytes, request size, and quota versus parent allocation denial
if an error occurs. This is allocation and diagnostic work; it introduces no
new model or wire format.

## Byte identity and memory

Every development archive below has exact frame bytes and exact `P6F1`
forward grammar bytes against the frozen backend. A fresh native decoder also
reconstructed every input exactly. The 1 MiB and 8 MiB checks covered
FreeDict, GCIDE, and OMW, each with default and hoisted models: 12 cases.
The separate 22 MiB Japanese development check covered both model layouts.

| Development input | Original seed peak | Runtime 2 seed peak | Unchanged LaneM peak | Archive bytes, default / hoist |
| --- | ---: | ---: | ---: | ---: |
| FreeDict 8 MiB | 1,350,742,082 | 74,399,906 | 600,313,540 | 564,416 / 581,487 |
| GCIDE 8 MiB | 3,641,298,390 | 106,775,504 | 540,976,752 | 1,279,033 / 1,309,827 |
| OMW 8 MiB | 763,396,574 | 126,846,622 | 723,629,898 | 331,721 / 349,137 |
| Japanese 22 MiB development | 2,163,318,974 | 278,828,421 | 2,335,229,020 | 906,545 / 949,206 |

The final formatted ReleaseFast Runtime 2 build separately reproduced all
14 development cases byte for byte against both ReleaseSafe Runtime 2 and
the frozen backend. Its fresh native decode was exact in each case. One
complete Debug OMW 1 MiB encode matched the same frame and graph. Empty
input, invalid UTF-8 with NUL bytes, and deterministic arbitrary binary
data crossing a 64 KiB boundary each matched the frozen frame and graph in
both layouts and decoded exactly. `reclaim_scope_tests.zig` passed in
Debug and ReleaseSafe, including reallocating a shortened view, releasing a
shortened view with the original allocation length, and returning the parent
Budget's live count to zero. `budget_reclaim.zig` tests exercised quota and
parent allocator failures with the recorded phase and requested bytes.

The four unchanged Runtime 2 helper binaries rebuilt to the exact SHA-256
hashes of the frozen helpers. The corrected `m_reference` is distinct. Full
source, binary, corpus, frame, and graph hashes and all 47 verification rows
are in `evidence/runtime2-dev-proof.json`.

## Limits and next step

This is a resource correction backed by development input. The failed final
input has a different byte distribution from the 22 MiB development input,
and its failure phase was not recorded by the frozen binary. A final run may
still reach the unchanged 4 GiB bound in LaneM or fitting. The benchmark owner
should run the final corpus once under a separately recorded Runtime 2 backend
version after this proof is frozen; any failure will now report a phase and
allocator request. No result on the final corpus is claimed here.
