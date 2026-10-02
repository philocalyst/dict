# Exact compression evaluation and iteration

This loop adapts the evaluation design in Lance Martin's
[Automating eval design and hillclimbing](https://claude.dev/blog/automating-eval-design-and-hillclimbing/)
(September 28, 2026): representative tasks, an independently checked grader,
one attributable change per round, distinct development and reserved cases,
and failure analysis after stalled rounds. The original host was blocked in
this environment. Two complete public archives were read at immutable commits:
[first archive](https://raw.githubusercontent.com/ai-native-engineer/anthropic-mirror/3ac19da32cdd45be36fb1b4a971dbba65e963a5b/claude.dev/blog/automating-eval-design-and-hillclimbing.md)
and [second archive](https://raw.githubusercontent.com/kzinmr/ai-topics/ab27106dec03b61e24430e87bff798d858a94d6f/wiki/raw/articles/claude.dev--automating-eval-design-and-hillclimbing--2026-09-28.md).
Their SHA-256 values are respectively
`374c9b772ff28d1b32d24ec206b7cb1429cad75f3369e37c1c7b831aa8756ea5`
and `01cebd392b76075ee4f5af80b7fe5261da0a742c966ff8c0ea2c6c2548bc1e0d`.

The grader uses exact decoded length and SHA-256, actual delivered-frame bytes,
and actual declared side-information bytes. An LLM does not judge correctness
or compression quality. Every registered case is evaluated; failed admissions,
timeouts and cached attempts remain in the append-only ledger. Book/prose
and dictionary scorecards are separate. Language and independent work receive
equal weight; a large dictionary cannot hide a book loss.

The current development set contains six complete works in five languages,
including Japanese without space-delimited words. Prefixes are cheap diagnostic
screens only. Five distinct-author works are separately reserved for validation;
no codec outcome has been opened on them. Source preparation preserves original
body newlines and records an inverse to each original source edition. Source
definitions and rights are in [books2026](../books2026/README.md).

Register runnable specifications after building the existing codecs:

```sh
python3 src6/bench/frontier_loop/build_specs.py \
  --manifest /workspace/scratch/books2026-dev/manifest.json \
  --out /workspace/scratch/frontier-loop-books6/specs \
  --bzip3 /workspace/scratch/bzip3 \
  --backend-dir /workspace/scratch/wgp6/frozen-backend-runtime2 \
  --native-reader /workspace/scratch/wordfrontier-native/wordfrontier-decode

python3 src6/bench/frontier_loop/loop.py run \
  --spec /workspace/scratch/frontier-loop-books6/specs/wordfrontier.json \
  --baseline /workspace/scratch/frontier-loop-books6/specs/bzip3.json \
  --cases /workspace/scratch/frontier-loop-books6/specs/cases.json \
  --stage development --work /workspace/scratch/frontier-loop-books6/run \
  --report /workspace/scratch/frontier-loop-books6/wordfrontier-r0.json
```

Commands are argv vectors, never shell fragments. They must write frame and
decoded files explicitly. `codec_adapter.py` redirects standard-codec output
to an ordinary native archive without adding comparison framing. Executables,
libraries, scripts, source files and policies are pinned. `build_specs.py`
also pins the current WordFrontier encoder's NumPy runtime and frozen native
backends. All models needed by its standalone decoder are already in the frame.
The pins establish reproducibility for these reviewed programs, not a security
sandbox or a hermetic operating-system image.

Each candidate declaration states its parent, single mechanism change,
hypothesis, decisive falsifier, backend class, commands and resource limits.
Automatic policies must encode every declared trial and pay losing fits; a
failed family cannot silently disappear. External-model and transformed-standard
codec experiments can be recorded, but cannot establish a new self-contained
compressor result. Metadata explains the experiment; it is not supplied to the
decoder as a linguistic hint.

Successful artifacts are content-addressed by source, policy, dependencies and
harness. A cache hit rehashes the stored frame and decoded bytes, then repeats
the exact decode in a fresh process. It is labeled as reused encoding, not
another encoder trial. A final performance
claim additionally needs coordinated quiet paired timings and measured memory;
the loop's process wall clocks are diagnostic and never satisfy that gate.

The primary aspiration is at least 35% fewer complete book/prose bytes than
whole-file bzip3, at least 20% in every language and no losing case. A smaller
development improvement can become an incumbent after a meaningful gain and
regression checks. That is progress toward the aspiration, not the claimed
endpoint. Screens cannot promote candidates. Reserved runs require pinned
qualifying evidence and a coordinator freeze; retries must retain failed runs.

After two stalled development rounds, read the recorded failure breakdown before
another change. Diagnose prediction loss, spelling/rare-token cost, paid model
cost, framing, decoder resources, or a grader/plumbing problem. Run one finite
ablation that distinguishes those causes. Do not replace the source, drop a
language, widen a search without recording it, or present an ideal entropy
estimate as a delivered-frame result. The explored experiment set is finite;
these tests do not exhaust compression or establish a universal lower bound.

The first real round ran all six **complete** books, paying the complete
WordFrontier quality search on each. All twelve candidate/control archives
decoded exactly. WordFrontier lost every case: 3.52–8.58% more bytes, with
a language/work-balanced ratio of **1.06383**. It was rejected. The
[complete report](evidence/wordfrontier-books6-r0-20261002.json),
[trial ledger](evidence/wordfrontier-books6-r0-20261002.jsonl) and
[frozen harness/specification capture](evidence/r0-capture/) preserve that
diagnostic round, including its original harness hash. Later grader hardening
does not reinterpret its evidence as a result from the newer harness.
Independent review passed 27 tests on the final grader. Its six complete-book
bzip3 identity calibration reproduced every independently retained native frame
byte for byte. A
[fresh complete-book grading replay](evidence/wordfrontier-books6-r1-20261002.json)
under that final grader reproduced all twelve earlier archives exactly and
rejected the same 6.38% loss. This replay checks the corrected evaluator;
it is not another compressor mechanism or a new compression improvement.
The coordinating research agents propose source changes; `loop.py` executes
and grades each attributable round and emits its next action. It does not
generate compressor code or declare novelty on its own.

A separate coordinated quiet reader comparison uses the same six candidate
archives and bzip3 workspaces sized by the source length, with each complete
book still in one block. The bzip3 archive payloads and complete sizes match
the 32 MiB controls; only the workspace header changes. One warmup and five
alternating paired trials per book give **3.15–5.96×** median native-command
decode speedups, including input, preparation, full decoding and file output.
All 72 outputs match the complete source. These are resident-file observations,
not cold-cache measurements. The recorded `wait4` RSS includes an approximately
16 MiB inherited coordinator floor, so it cannot resolve smaller native decoder
peaks. The [timing report](evidence/book-readers-sized-paired-20261002.json),
[captured timing source](evidence/reader-pairs-sized-capture-20261002.py) and
[measurement limitations](evidence/book-readers-sized-annotation-20261002.json)
preserve the scope. The older overallocated 32 MiB timing control is diagnostic
only. None of these latency observations changes the compression rejection.

```sh
python3 -m unittest discover -s src6/bench/frontier_loop -p 'test_*.py'
```
