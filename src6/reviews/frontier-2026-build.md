# Reproducing the word and dictionary frontier experiments

The new standalone command is `src6/experiments/wordfrontier/wordfrontier.py`.
It chooses between fully charged WPG2 word-construction pages and GWT1
word-layout pages. The encoder uses this repository's native v4 entropy
backend. The decoder needs the transmitted archive and native reader only;
it does not require a neural network, external vocabulary or NumPy.

## Build and use the standalone codec

Install Zig **0.16.0**, a C++17 compiler, GNU make, Python 3.11 or later and
NumPy. The measured tree encoder used NumPy **2.3.5**. Encoder tree proposals
use floating point; each archive carries its actual integer probability
model, and decoding uses those integers. Different platforms may produce
different encoder choices while preserving exact reconstruction.

```sh
python3 -m venv .venv-frontier
.venv-frontier/bin/pip install numpy==2.3.5
. .venv-frontier/bin/activate
make -C src6/experiments/wordfrontier ZIG="$(command -v zig)"
ZIG="$(command -v zig)" bash src6/experiments/wordgrammar/wgp6/runtime2_build.sh src6/experiments/wordgrammar/wgp6/runtime2-backend
.venv-frontier/bin/python src6/experiments/wordfrontier/wordfrontier.py encode input.txt output.wpf --profile quality --backend-dir src6/experiments/wordgrammar/wgp6/runtime2-backend
.venv-frontier/bin/python src6/experiments/wordfrontier/wordfrontier.py decode output.wpf restored.txt
# Standalone decompression in one native process, without Python/NumPy:
src6/experiments/wordfrontier/wordfrontier-decode decode output.wpf restored-native.txt
cmp input.txt restored.txt
cmp input.txt restored-native.txt
.venv-frontier/bin/python src6/experiments/wordfrontier/wordfrontier.py extract output.wpf page.bin --index 0
make -C src6/experiments/wordfrontier test
```

`ZIG=...` is explicit because two historical Makefiles default to the Zig
installation on the measurement host. The top-level Makefile builds the
shared WPG2 reader library before the GWT1 reader. A geometry-only build must
first build `src6/experiments/word_constructions/libwpgjobs.a`.

The recommended Runtime 2 backend releases completed seed-learning temporary
allocations instead of retaining them until candidate destruction. It preserves
the exact learner, graph IDs, model order and 4 GiB budget. All fourteen
development cases and six arbitrary-byte cases match original archive and
grammar bytes. See [the resource proof](../experiments/wordgrammar/wgp6/RUNTIME2_RESOURCE_REPORT.md).
The original encoder remains available as the historical reference.

Use `--profile access` to put the common entropy model ahead of all native
payloads. Both profiles preserve original 65,536-byte page boundaries.
The shared model is prepared once; each selected page reconstructs and
checks its original source bytes without retaining decoded pages.
The input cap is 32 MiB, the native encoder live-allocation budget is 4 GiB,
and the private prepared native decoder budget is **512 MiB**. The decoder
budget covers native model and job allocations. It is not a bound on total
process RSS: mapped input, C++ metadata, output buffers and runtime state are
separate. See [the decoder-budget proof](../experiments/word_constructions/evidence/DECODER_BUDGET_EVIDENCE.md).

Some earlier frozen family READMEs predate that decoder budget. Their
statements that no whole native-model allocation cap exists are superseded
by the linked evidence. The source and binary manifests are historical
measurement identities. Absolute paths participate in the driver policy
fingerprint, so a relocated checkout will have a different run identity.
Custom `--backend-dir` binaries are hashed by the driver; the final capture
additionally hashes every source, decoder-budget module and linked library.

## Pinned comparison dependencies and corpora

The wordfrontier codec itself does not use bzip3. The dictionary production
archive and comparison controls do. Obtain the pinned upstream source:

```sh
git clone https://github.com/kspalaiologos/bzip3.git vendor/bzip3
git -C vendor/bzip3 checkout d149f093793484d8eb55900ecf09c5714e277dba
```

`vendor/` is ignored; the source is fetched, not committed to this repository.
Licensing is recorded in the root [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
The controls also need the development libraries for bzip2, zstd and liblzma.
Build the comparison library and the native control programs:

```sh
mkdir -p /workspace/scratch
cc -O3 -D_GNU_SOURCE -fPIC -shared '-DVERSION="1.5.1"' -Ivendor/bzip3/include vendor/bzip3/src/libbz3.c -o /workspace/scratch/libbzip3.so
export LEX_BZIP3_LIBRARY=/workspace/scratch/libbzip3.so
sh src6/bench/native_controls/build.sh
```

The [corpus preparation recipe](../bench/frontier2026/prepare_corpora.py)
records pinned source revisions and verifies retained source hashes:

```sh
python3 src6/bench/frontier2026/prepare_corpora.py --help
python3 src6/bench/frontier2026/prepare_corpora.py --output-dir /workspace/scratch/frontier-corpora
zig build --build-file build6.zig test test-example -Doptimize=ReleaseSafe --summary all
```

The final capture configuration records the original measurement host's
`/workspace/scratch` corpus, frozen-backend and bzip3-library paths. Replaying
that capture unchanged requires those paths and hashes, for example in a
container mounted at `/workspace`. A relocated benchmark needs an explicitly
new configuration and fingerprint. Existing final rows must never be reused
under a changed runtime fingerprint. Standalone codec commands use their
repository-local build paths and do not require the scratch corpora.

The historical capture's `git_head` pins production commit
`6f043e245eea265e4a222524443e3ff01e09c3cb`, before the experimental files were
committed. Its complete per-file SHA-256 map identifies the experimental
source actually measured. Checking out that production commit alone therefore
does not restore the experimental capture. An exact historical replay needs
that base plus the identical experimental working-tree files and runtime;
a fresh comparison from the completed canonical tree needs a new head pin,
manifests and output directory. Preserve the old evidence under its original
identity.

## Two dictionary results with different scope

Production packet v4 inside archive v3 adds exact named construction programs
and verified occurrences to the sparse defaults, multilingual analyses and
prepared borrowed field access introduced in v3. Run its tests and examples
with the Zig command above. The
[production paired evidence](evidence/dictionary-final-20261001.json) measures
the historical v3 core at `6f043e245eea265e4a222524443e3ff01e09c3cb`.

The separate `lexical_columns` native prototype reflects required root byte
fields into a small headword/identity stream and keeps complete nested values
in adjacent cold packets. It composes the same exact word constructors with
bzip3 or zstd. Its complete [final storage evidence](../experiments/lexical_columns/evidence/FINAL-20261001.md)
includes both gains and losses. Headword access may omit the cold stream;
label and definition reads must pay cold-stream reconstruction. This
prototype is separate from production archive v3 and is not an importer
that translates all original XML/RDF semantics into native lexical fields.
Native prepared reads and query timings here support bzip3; zstd19 is a
matched complete-frame size and encoder comparison. The
[prototype README and build instructions](../experiments/lexical_columns/README.md)
describe its native tests and drivers. A fresh rebuild is a new comparison;
the historical quiet stage additionally requires its exact source, binary,
input and instrumentation hashes.
The [five-trial timing evidence](../experiments/lexical_columns/evidence/QUIET-RESULT-20261001.md)
records the hot-headword gains, slower cold reads and separately charged setup.

The deeper `lexical_constructions` direct typed codec remains a separate
experiment. Its corrected global-stock development freeze explicitly uses
that historical v3 core so source packets and full native oracles keep the
same schema. Restore the core and pass it explicitly:

```sh
mkdir -p /workspace/scratch/dict-core-v3-replay
git archive 6f043e245eea265e4a222524443e3ff01e09c3cb src6 | tar -x -C /workspace/scratch/dict-core-v3-replay
zig build --build-file src6/experiments/lexical_constructions/build.zig -Dlexical-core=/workspace/scratch/dict-core-v3-replay/src6/root.zig -Doptimize=ReleaseSafe test
```

The default build instead uses the current native core, which is a separate
schema contract. Do not feed historical v3 oracle bundles into a current-core
measurement and silently reinterpret them. The
[corrected source/binary/policy freeze](../experiments/lexical_constructions/evidence/DEV-2-OWNED-FREEZE-20261001.json)
records the exact ten paid global candidates and all development parity gates.

## Complete-book evaluation and iteration

The [evaluation loop](../bench/frontier_loop/README.md) supplies reproducible
registry/specification generation, exact fresh decoding, paid frame/model
accounting, complete-book scorecards, cache verification, development promotion
and reserved-cohort gates. It adapts the cited evaluation-design article and
has an independent 27-test integrity review. Its registered six-book complete
WordFrontier run loses whole-file bzip3; the corrected grader's replay preserves
every archive byte and the same loss. This is not a successful book codec.

The [book source preparation](../bench/books2026/README.md) pins complete source
editions, original-source reconstruction metadata, exact UTF-8-safe development
prefixes, and distinct-author reserved validation sources. Reserved-book codecs
have not been run. The new causal model and clause alignment screens live in
`grammar_automaton`; their source-only proxies do not establish frame sizes.
The [uniform capacity retest](../experiments/lexical_validation/evidence/CAPACITY-RESULT-20261002.md)
is a separate admission repair of the fixed packet-v3 prototype and retains
all original failures and whole-flat size losses.
