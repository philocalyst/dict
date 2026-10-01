# Quick experiments against bzip3

From the repository root:

```sh
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py
```

That is the whole quick storage screen: exact 64 KiB development prefixes of
the word list, FreeDict, and Japanese OMW. It prints complete frame sizes for
native bzip3 at the requested block size, native bzip3 with one whole-input
block, and the existing native Bzip4 v4 CLI. On a single 64 KiB sample the two
bzip3 controls are intentionally identical. Use `--suite multilingual` to add
GCIDE and Finnish, Turkish, and Arabic UD forms. These are development samples,
not untouched confirmation data. No text normalization is performed.

## Try a candidate

```sh
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py \
  /path/to/input --candidate /path/to/adapter.py
```

The adapter has exactly two entry points:

```python
def encode(raw: bytes, *, block_bytes: int, **options) -> bytes:
    ...  # Return the entire self-contained frame, not a payload estimate.

def decode(frame: bytes) -> bytes:
    ...  # Reconstruct exactly; no raw input, dictionary, or options argument.
```

`--options '{"contexts":4}'` configures only the encoder. Repeat `--candidate`
to compare a proposed mechanism with a simpler control on identical bytes.
Python sources beneath the adapter directory are fingerprinted automatically.
List outside imports and non-Python resources with `--dependency FILE_OR_DIRECTORY`
to record their hashes and catch mid-run edits. Candidate encodes are **never cached**.
The runner is not a sandbox: manually review candidate imports to exclude
external/unpaid models or reading the source from the filesystem.

Compare a matrix of encoder policies with one command:

```sh
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py \
  /path/to/input --candidate /path/to/adapter.py \
  --options '{"rounds":2}' --grid '{"contexts":[1,4,8],"pieces":[64,128,256]}'
```

`--grid` is a JSON object of nonempty arrays. Its Cartesian product follows
sorted keys and each array's supplied order, with at most 256 combinations.
Grid values override matching `--options` defaults. Every module candidate
receives the same matrix; policy numbers and effective parameters are printed
once before inputs and frozen in `invocation.json`. All configurations retain
their raw results and complete frames. Parameter strings never become artifact
paths. Candidate encodes run once per input per policy, while the three native
controls run once per input and their frames serve every policy comparison.
Baseline cache reuse and independent decode verification remain unchanged.
`block_bytes` is forbidden in both objects: `--block` separately controls block
size. A nonempty grid requires at least one candidate. Built-in WAM adapters
reject nonempty grids and options because their policy is fixed, including when
they appear alongside module candidates.
An empty grid preserves the existing single-policy command and display.

The existing weighted-emission experiment has built-in adapters:

```sh
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py \
  /usr/share/dict/web2 --candidate wam-map --candidate wam-marginal
```

Both use the frozen 256-piece, maximum-length-8, two-round EM policy. The table
also prints marginal minus same-source MAP bytes; that ablation is distinct
from improvement over bzip3 or Bzip4. This research codec uses floating-point
posteriors and does not promise cross-architecture bitstream portability.

## Size, latency, and accounting

- The default samples **the first 65,536 bytes**, prominently reported. Use
  `--limit 0` for the full input or `--limit N` for a different exact prefix.
- `--block 65536` sets requested baseline block boundaries. A candidate adapter
  must disclose whether it honors the boundary; a whole-input model is not
  evidence of independent random access. Native v4 has shared frame-level
  preparation; payload blocks are not cold-independent dictionaries.
- Real vendored bzip3 1.5.1 is used through the existing pinned native helper.
  Its **B3PY lab envelope**, not upstream `.bz3` framing, charges 32 header bytes
  plus 16 bytes per independently compressed block. Both full frames and
  exact-decoded bytes are saved. This matches the earlier lab size convention.
- Baseline encodes are cached by input hash, effective block size, implementation
  and executable hashes, Python runtime, and platform. Each hit verifies the
  retained frame hash **and decodes it again in a fresh process**. A damaged
  entry is preserved under an `.invalid-*` name and makes that run fail.
- `--decode-repeats 5` reports serial **fresh-process full-decode wall latency**,
  including worker/interpreter startup, imports, codec initialization and I/O.
  These are not kernel throughput numbers or hardware-cold page-cache timings.
  Python versus Zig adapters therefore cannot be used to infer codec-kernel
  speed. Encodes on cache hits have no fabricated time. Run without other CPU
  work when collecting timing evidence; the harness does not assert idle hardware.
- `--timeout 120` bounds each subprocess. Failures are recorded, other codecs
  continue, and the command exits nonzero. Timeout cleanup includes child
  processes in the worker's process group.

Every run retains `results.json`, exact input prefixes, complete frames,
fresh decoded output, implementation fingerprints, argv, and failure logs in
`quickbench/runs/`. Storage-only runs do not collect latency samples. The full
JSON is checkpointed after every codec, so interrupted work remains inspectable.
The runner does not select a best policy per file or declare a new record.

The native v4 executable must already exist at `bz4/v3/zig-out/bin/bz4`;
the harness identifies that exact executable, not an assumed source revision.
The bzip3 helper reuses its verified vendored library, building with the local
C compiler if absent. No production codec or root build file is changed.
