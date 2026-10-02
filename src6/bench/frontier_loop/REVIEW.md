# Independent evaluation-loop review

**GO for complete-file development size evaluation under the declared codec
and dependency scope.** No remaining blocker was found in the reviewed runner
after the corrections below. This is an integrity review, not evidence that a
codec meets the compression goal.

The final combined run passed **27/27 tests**, including 16 independent probes
in `test_review.py`. It used synthetic byte sources only. No reserved book was
encoded or decoded. The exact audited source files stayed unchanged across the
run.

```sh
python3 -m unittest discover -s src6/bench/frontier_loop -p 'test*.py' -v
```

Raw test log: `/workspace/scratch/frontier-loop-independent-review-tests.log`,
SHA-256 `c049dff836df68480a46f1f21cd8f957549f8f111f0c7fe047c9230b3080c528`.
The test run took 28.453 seconds; this is test-suite duration, not a codec
throughput result.

## Audited source identities

| File | SHA-256 |
| --- | --- |
| `loop.py` | `d6145b89d89e3ff3fc91f67618354d4bfff45ad8cc88babe1d4fd457907372d7` |
| `test_loop.py` | `bf30606bcb82034f1e31bda87a98bfcad6561f6949f20a7c336e6268c26dc95b` |
| `test_review.py` | `1178f14e0473b163b10948f0a8f151f54f137eb9a7c28cc762e3243a4f89c085` |
| `build_specs.py` | `2f4bf65fd105891d23d3ef1559ad7470c837f686dbc259a1791e6f598bc17b2a` |
| `codec_adapter.py` | `28b138d383597b109866cdb617054d646e1d7ddbe961b0e10e1fcc1441fbe99c` |

## Concrete failures corrected during review

| Failure | Current protection and executable evidence |
| --- | --- |
| A one-byte frame could decode from an unpaid encoder sidecar. | Separate decoder work contains only its copied frame; encoder input and work tree are removed before decoding. Sidecar and predictable sibling-input probes fail closed. |
| Ambient environment could silently change a codec policy without changing the cache key. | Children receive a fixed clean environment plus explicitly declared supported library configuration. Cached and fresh runs remain identical under hostile ambient controls. |
| An absolute Python script could be omitted from dependencies. | Static absolute argv files require hashes. Backend directory arguments receive bounded recursive file inventories, compared before and after work. |
| Rewriting a cached frame and its editable metadata could certify unrelated retained output. | Every cache hit skips only encoding and freshly decodes its current frame. An undecodable one-byte replacement is rejected even with matching forged hashes and sizes. |
| Repriced incumbent/qualification artifacts still trusted an editable `fresh_decode` bit. | Prior candidate and baseline frames are freshly decoded again into isolated proof directories, with exact source hashes and retained proof logs. Forged prior frame/output correspondence is rejected. |
| A consumed validation cohort could be reused under a new work directory or after a registry-note change. | Persistent claims use selected source, work, author and declared lineage identities, independent of unrelated registry metadata. Claims survive failed validation; both replay probes fail closed. |
| Renamed cases could put a training work, author, translation lineage or identical byte source into validation. | Registry validation rejects each identity across splits. Separate probes cover all four identities independently. |
| A successful parent could leave background search or mutation work running after its clock stopped. | Process groups are cleaned up on ordinary exit as well as timeout. The delayed orphan-child marker probe stays absent. |
| Nonfinite timeouts or fractional/infinite byte limits reached process setup. | Limits require finite bounded timeouts and positive bounded integer byte counts. Invalid-limit probes reject before starting work. |
| Local improvements were conflated with the 35% goal. | A verified improvement of at least 0.5% can be a development keeper with no per-case or language regression, while `goal_met` remains false. The independent padded-codec probe demonstrates this distinction. |

Coverage also checks that failed cases remain in the expected primary
scorecard; validation cannot qualify from an unproven/wrong-stage report; and
external learned data cannot be treated as a self-contained frontier result.

## Actual standard controls

`codec_adapter.py` now passes a source filename to each native executable.
On the identical synthetic multilingual source, all four adapter frames are
**byte-identical** to the direct ordinary CLI frames, and every fresh decode
returns the exact original bytes. Settings are bzip3 with a 32 MiB block,
bzip2 9, zstd 19 with one thread, and xz 9 with one thread and CRC64. The
adapter adds no WCTR or other comparison wrapper.

The earlier stdin variant's zstd frame omitted known source-size information;
that difference was identified and corrected. bzip3's ordinary-frame bytes
were identical before and after that correction.

The real registry generator verifies complete source and prefix hashes and
retains work/author/language metadata. It registers development books only.
The candidate's fixed WPG2/GWT1 encoder, helper modules, backend executables,
readers, NumPy runtime and discovered ELF libraries are declared dependencies.
The standalone delivered-frame decoder receives the frame and output paths,
with no original source argument.

## Scope of this GO

Size is the selected complete frame plus declared side-information and embedded
learned-data charges. Ordinary runtime code is distinguished from learned
data by a required declaration and source audit. The loop does not infer that
classification from executable bytes. Every current frame and every retained
prior frame used for promotion receives a fresh exact decode.

The runner enforces command timeouts, per-file size bounds and process-group
cleanup. Candidate-native decoder memory/work limits remain codec obligations;
this runner does not impose a generic RSS ceiling. Its anonymous input and
decoder work separation prevent the demonstrated accidental source oracles,
but do not create an operating-system filesystem sandbox. Dependency pinning
verifies declared runtime files and explicit argv directories; transitive
imports and data classification remain registration/source-audit obligations.

Validation and final are coordinator-controlled one-use stages with a verified
preceding-stage goal report. The claim files coordinate trusted operators;
someone deliberately moving the registry and deleting all coordinator state is
outside that mechanism. Work, author and translation-lineage split identities
must be supplied truthfully by the source registry.

Process wall times are diagnostic, include command startup and I/O, and are
not paired quiet measurements. `performance_final_ready` remains false.
Neither a local keeper nor this review's GO establishes a 35% whole-book win;
the actual complete development and sealed validation rounds must establish
their own results.
