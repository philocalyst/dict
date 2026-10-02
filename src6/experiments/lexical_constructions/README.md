# Native typed grammar and exact surface constructions

This is an additive, unfrozen development experiment. It does not change the
production model, packet/archive v3, earlier prototypes, or repository HEAD.
The first complete DEV capture is a measured size loss; its source/binary and
frames are preserved under `evidence/DEV-1-NEGATIVE-20261001.json`. Its adaptive
frame costs 61,718 bytes on rich128 versus matched flat bzip3 36,457 and zstd19
34,456; OMW-ja DEV512 costs 282,661 versus 136,947 and 140,593. These negatives
remain evidence while the second shared-stock architecture is developed.

`construction_model.zig` adds a first-class `Document` around the unchanged
native `Entry`. Qualified programs declare ordered parameters and literal,
copy-span, slot, earlier-program-call and zero-realization instructions.
Copies may name multiple discontinuous byte spans; repeated slots express
reduplication and literal/copy sequences express edits without normalization.
Programs and instances retain native Metadata, qualified process/role names,
explicit authoritative surface references, origins, independent analyses and
ordered alternatives. These programs do not replace existing morphology.
The natural dictionary loader adds no inferred linguistic programs: every
original native value and opaque source record remains authoritative.

`construction_admission.zig` checks the complete native Entry, program DAG,
bindings, exact local surface targets, instance reconstruction and byte
realizations. UTF-8 mode requires scalar boundaries; explicit byte mode can
preserve opaque bytes. Calls only target earlier programs. Depth, total work,
arguments, instructions, output bytes and native semantic limits are bounded.
Familiar names/metadata/references/anchors are checked by the existing native
semantic rules through a temporary admission adapter, never a wire schema.
Declared external surfaces carry their transmitted bytes and explicit target;
their external linguistic truth is not inferred or fetched.

`grammar.zig` compiles the actual native type into structural choices and
value events. There is no second lexical schema, per-node offset table or
shape-template directory. Sparse default masks, union tags, sequence lengths,
optional decisions and integer/string values go directly into context rANS.
The shared native contract has an eight-byte schema fingerprint that includes
field/tag order, scalar widths and elidable default **values**. Data-dependent
probabilities, context overrides and exact lexeme programs are transmitted.
Decoder reconstruction uses bounded integers only; context-model proposals
may use floating point at encode time. Encoder proposal estimates are not
reported as bytes: all comparisons use actual complete output artifacts.

The exact shared byte lexicon deduplicates literal values. Its surface-program
variant concatenates literal runs and spans of explicitly indexed earlier
lexemes. These storage programs are distinct from asserted linguistic
analyses; equal spellings never imply equal lexical identities. Arbitrary
byte strings have a literal fallback. A greedy bounded donor search is a
proposal; complete literal, surface, typed and joint alternatives all compete.
Frequency ordering and a global-only context-model ablation are retained.
An owner-context variant conditions default masks and collection tags on
their actual containing native fields: e.g. an Analysis's content can learn a
different distribution from a Sense's content without any language rule.
Only overrides whose estimated gain pays their metadata are proposed; every
resulting complete model/frame is still actually encoded and compared.

The second architecture adds causal exact surface programs. A copy transmits
a strictly positive backward byte distance and a bounded length in the global
resolved stock. Copies can reuse the already produced prefix of their own
lexeme, span earlier lexeme boundaries, and overlap. Literal bytes always
retain an exact fallback. Four recent positions per four-byte signature bound
the encoder proposal search; there is no language-specific spelling rule.
Every reconstructed byte pays output work in addition to each entropy event.
`LTC1` version2 explicitly signals this opcode; version1 remains readable and
its earlier captures are retained. Unused version/flag aliases are rejected.

`global_bundle.zig` publishes actual `LGB1` frames: a 128-byte provenance and
checksum header, 24 bytes per original source group, and one immutable native
grammar stock. Lexemes and sparse probability models are shared across groups;
the original roots still have independent ANS states and a paid offset table.
The source group directory records canonical root-byte boundaries. Verified
preparation checks these boundaries against actual native reencoding, so a
resealed directory cannot redistribute source lengths silently. Root ordinal
access needs only its own stream once the entire shared stock is prepared.
It does not claim a compressed spelling lookup index or cold-leaf access.

Each root has its own four-byte ANS state and compressed event stream.
The paid root directory contains `roots+1` offsets. `bundle.zig` publishes
actual complete `LTB1` bundles with a 64-byte header and 24-byte page records,
contiguous seek offsets and SHA-256; each `LTC1` page has a 96-byte header,
transmitted models, a surface stream, root offsets and root streams. Header
canonical packet total/max are verified by exact native reencoding. The
original source groups remain identical to the strong flat controls.

Opening a page prepares its shared models and **fully resolves its shared
lexeme pool**. That pool, its string index and the model allocations are owned
by `Page` and their memory/setup costs are charged. Full root admission then
produces `Prepared`. A headword view reads only the native required prefix
from that root's ANS state, borrowing the resolved pool; frame and pool must
remain immutable and alive until all views are done. `Page.deinit` invalidates
all prepared capabilities and borrowed strings. This is not a claim of cold
leaf decoding or a globally zero-allocation/cache-free dictionary reader.
Ordinal root lookup uses the actual complete bundle's paid seek directory.

The initial variants are `packet_ans` (direct ANS over exact native packet
bytes), `typed`, `surface`, `joint`, `joint_frequency`, and `joint_global`.
`joint_owner` and `joint_owner_frequency` ablate containing-field context.
`screen.py` compares actual complete bundles with matched flat packet-v3
bzip3 and zstd19 controls, including raw fallback and all model/page/index
costs. Every losing encoder candidate is paid. The screen records no clocks
while the coordinator's independent reference timing is active.

The generic build defaults to the repository's current native model. Historical
LPB-v3 DEV screens **must** use the explicit `-Dlexical-core` option. A portable
historical replay can materialize the exact core into any absolute directory:

```sh
mkdir -p /tmp/dict-core-v3
git archive 6f043e245eea265e4a222524443e3ff01e09c3cb src6 | tar -x -C /tmp/dict-core-v3
```

Then substitute `/tmp/dict-core-v3/src6/root.zig` below. The environment's existing
snapshot is `/workspace/scratch/dict-core-v3-6f043`. Evidence records exact core
source and binary hashes; current-schema tests are a separate contract, never
a reason to reinterpret historical packet bytes.

After the coordinator grants a build/DEV CPU slot:

```sh
zig build --build-file src6/experiments/lexical_constructions/build.zig -Dlexical-core=/workspace/scratch/dict-core-v3-6f043/src6/root.zig -Doptimize=ReleaseSafe --prefix /workspace/scratch/lexical-constructions-global-install test
zig build --build-file src6/experiments/lexical_constructions/build.zig -Dlexical-core=/workspace/scratch/dict-core-v3-6f043/src6/root.zig -Doptimize=ReleaseSafe --prefix /workspace/scratch/lexical-constructions-global-install
/workspace/scratch/lexical-constructions-global-install/bin/lexical-constructions /workspace/scratch/lexical-pages-shape-rich128.flat.raw.lpb /workspace/scratch/lexical-constructions-v2-page-rich128 > /workspace/scratch/lexical-constructions-v2-page-rich128/native.jsonl
python3 src6/experiments/lexical_constructions/screen.py /workspace/scratch/lexical-pages-shape-rich128.flat.raw.lpb /workspace/scratch/lexical-constructions-v2-page-rich128
/workspace/scratch/lexical-constructions-global-install/bin/lexical-shared-constructions /workspace/scratch/lexical-pages-shape-rich128.flat.raw.lpb /workspace/scratch/lexical-constructions-v2-global-rich128 > /workspace/scratch/lexical-constructions-v2-global-rich128/native.jsonl
python3 src6/experiments/lexical_constructions/shared_screen.py /workspace/scratch/lexical-pages-shape-rich128.flat.raw.lpb /workspace/scratch/lexical-constructions-v2-global-rich128 --pages /workspace/scratch/lexical-constructions-v2-page-rich128 --native-binary /workspace/scratch/lexical-constructions-global-install/bin/lexical-shared-constructions --lexical-core /workspace/scratch/dict-core-v3-6f043/src6/root.zig
```

Create the output directories before redirecting logs. Use a new install/output
prefix: the initial negative binary and output artifacts are immutable. The
second screen pays all ten global candidate encodes plus the twelve paged
ablations. It compares matched original-page flat bzip3/zstd19 **and** actual
whole-flat backend frames with the same paid source-group directory. Whole-flat
controls share compressor state globally too, but require full block decoding
for a cold root. The native global reader resolves the whole shared pool during
preparation; its owned pool/model/index RAM and full admission costs must be
charged explicitly before any access-speed claim.

The same fixed candidates will be tested on pinned development projections.
Old FINAL outcomes are excluded from model design. A separate untouched
validation set is controlled by the root coordinator after source/policy
freeze. Reproduction will pin all native source/binary and source-frame hashes.
