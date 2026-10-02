# Pending quiet timing stage, 2026-10-01

This stage is prepared and has not started timed jobs. It links the immutable
dictionary source/model/binary freeze to separately hashed runtime
instrumentation. A new `timing_access.zig` clone supports chunk order; all frozen
codec, reader, native client, model and format sources remain unchanged.

From `/workspace/dict`, after an explicit globally quiet release from the root
coordinator:

```sh
python3 src6/experiments/lexical_columns/timing_stage.py --run --output /workspace/scratch/lexical-columns-quiet-20261001 --operations 512 --quiet-gate ROOT-EXPLICIT-QUIET-GATE
```

The stage runs all five untouched FINAL datasets plus rich128. One full warmup
is discarded, followed by five serial paired trials. Each case launches a fresh
native process with full admission and setup; each query chunk performs 512
fresh required-block decodes from resident immutable compressed bytes. No page
cache is used by the reader. Native headword same-root and deterministic
mixed-root distributions are retained, with admission/setup and label/source
probes recorded separately. Only bzip3 has a native query reader. Both bzip3 and
zstd19 have matched flat encoder/complete-frame controls.

**Native chunk order alternates across fresh processes.** A discarded
baseline-first warmup precedes five trials with order AB/BA/AB/BA/AB. A means the
complete flat baseline chunk; B means the complete construction chunk. Every
query/access combination within a trial follows its specified order. There are
three baseline-first and two construction-first trials, so the odd trial count
is not perfectly balanced. Both orders and all five raw distributions are
retained. The query/access order remains
headword same-root, headword mixed-root, label same-root, label mixed-root,
source same-root, source mixed-root. Cases repeat in the same order across all
trials. The encoder runs the flat control before literal, local, and
local-plus-ancestor candidates for each backend, with bzip3 before zstd19.

**Both compressed input sets have been touched before query timing.** The
native process reads original flat frames and construction files into owned
memory. It fully decompresses, hashes and semantically admits every construction
page. It then encodes each flat page into the baseline compressed block,
decompresses that block and compares its complete bytes. The source parity
stage again restores complete construction pages, loads hot blocks, compares
all original/restored canonical packets and direct projections, and checks the
native reflected frame against the encoded frame. Thus setup touches both the
baseline and construction compressed pages and their restored data; neither
page set is presented as cold or untouched.

The full corpus remains resident. Immediately before each query pair, an
untimed expected-observation loop reads the selected original flat canonical
packets. For headwords, it reads the native headword field. This loop touches
the original uncompressed reference data, rather than decoding either
compressed candidate. Baseline compressed buffers are newly encoded during
setup, while construction buffers are read from the staged files and admitted.
The filesystem cache persists across fresh processes. Allocator state and CPU
cache state evolve during each process; whichever chunk runs second may benefit
from that order. Alternating order distributes this effect, with the remaining
three-versus-two imbalance disclosed. These conditions limit the
interpretation of a latency ratio. The result is resident prepared-reader
latency with fresh decoding, not cold-cache or cold-storage latency.

Encoder search pays every candidate, every repeated hot encode, per-page frame
assembly, backend initialization, root-prefix preparation and all complete
outer-bundle assembly. Root-prefix preparation conservatively includes the
frozen function's extra exact restore oracle. Named constructor/backend phases
are subsets of the candidate pipeline and are not summed twice. Explicit
inverse/decode verification and evidence IO remain separate. The fixed client
also records label/source probes after headwords; rich128 has no first direct
definition for its source probe.

Before and after every trial, the stage checks original and staged frame hashes,
source/runtime/native binary freeze guards, original page/root counts, complete
sizes and constructor choices. Query hashes and byte counts must match every
trial. The summary retains five raw baseline times, construction times and
paired ratios for each headword access pattern, together with the median paired
ratio together with execution order. No source or policy tuning follows from
these timings.

The independent client was built with the same ReleaseSafe optimization and
the same immutable reader/model/C++ inverse imports. Untimed rich4 checks run
the original client and both new client orders. Full native/canonical/source
and all direct projection setup gates agree; all six new-client paired query
observations, decoded byte counts and constructor/copy counts agree between
orders. Every benchmark clock remains zero in this untimed exercise. The
separate source/build/native-binary/parity freeze is
[ORDER-INSTRUMENTATION-20261001.json](/workspace/dict/src6/experiments/lexical_columns/evidence/ORDER-INSTRUMENTATION-20261001.json).
The earlier fixed-order plan is preserved as a never-run historical snapshot.

Runnable protocol:
[/workspace/scratch/lexical-columns-quiet-20261001/protocol.json](/workspace/scratch/lexical-columns-quiet-20261001/protocol.json).
Its durable snapshot and the exact driver/protocol/freeze hashes are in
[QUIET-PROTOCOL-20261001.json](/workspace/dict/src6/experiments/lexical_columns/evidence/QUIET-PROTOCOL-20261001.json).
Output remains under `/workspace/scratch/lexical-columns-quiet-20261001`.
Budget approximately 10–20 minutes for the warmup and five trials, including the
frozen client's additional label/source probes. Timed work remains pending the
root quiet grant while the wordcodec size capture runs.
