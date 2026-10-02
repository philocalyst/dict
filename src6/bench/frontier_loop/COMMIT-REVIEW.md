# Independent claim and commit review — 2026-10-02

**GO for publishing the reviewed experiment documentation and evidence.** No
remaining material claim blocker was found in this scope. This is approval of
the evidence and its interpretation; the complete-book compression goal remains
unmet.

The review covered this directory's [README](README.md) and
[reflection](evidence/REFLECTION-20261002.md), the
[overall results](../../reviews/frontier-2026-results.md),
[build guide](../../reviews/frontier-2026-build.md),
[structural reform report](../../reviews/frontier-2026-structural-reform.md),
[whole-word history results](../../experiments/wholeword_history/RESULTS.md),
and the grammar-automaton CCM1, CCW1, SED1 and SED2 results. Local Markdown
links in those documents resolve. This review did not run compressors, builds,
reserved cases or additional tests.

## Claims supported by the reviewed evidence

- The final evaluator's six **complete-book** development replay reproduces all
  twelve earlier candidate/control archives. WordFrontier loses every case by
  3.52–8.58%, with a language/work-balanced ratio of 1.06383. The documents
  preserve that rejection and distinguish the original grading round from its
  fresh replay under the hardened grader.
- Whole-word history, CCM1, CCW1 and the sentence-edit screens use the declared
  at-most-1 MiB development inputs. They are not full-length results for the two
  longer books. Ideal entropy and free donor/operation proxies are labelled as
  diagnostics; neither is presented as a realizable archive. Paid SED1/SED2
  constructions still lose all six cases and explicitly use bzip3 backends.
- Small dictionary-development gains and the earlier frozen dictionary-heavy
  evaluation retain their own corpus, reference and source identities. They do
  not offset the new book failures or establish a universal compression record.
- Historical dictionary timings belong to the packet-v3 core at `6f043e2`.
  The current production schema uses packet v4 inside archive v3. The
  experimental native-v4 entropy backend is another versioned format; its
  name does not make historical measurements current production-v4 timings.
- Mature PAQ/context-mixing references are research controls or motivation,
  not inventions credited to this project. No reserved-book codec outcomes,
  field-wide novelty claim or exhausted-problem-space claim appears in the
  reviewed reports. Local hillclimb promotion remains distinct from the 35%
  complete-book aspiration.

## Reader evidence after workspace correction

The [right-sized paired report](evidence/book-readers-sized-paired-20261002.json)
uses a fixed input-length policy to keep each complete book in one bzip3 block.
Its bzip3 payloads and complete sizes match the original controls. The report
contains 72 exact outputs and supports the published **3.15–5.96×** median paired
native-command wall ratios. Its captured source SHA matches its harness hash;
the [annotation](evidence/book-readers-sized-annotation-20261002.json) pins the
report SHA.

Those observations include input, preparation, full decoding and output after a
resident-file warmup. They establish neither cold-cache performance nor smaller
native memory peaks hidden below the approximately 16 MiB inherited coordinator
RSS floor. The earlier overallocated 32 MiB timing report remains unchanged as
historical diagnostic evidence and is explicitly superseded for comparisons.
Decoder latency does not reverse the compression rejection.

## Source freeze and test status

The previously independent 27-test evaluator review remains applicable: the
runner, both test files, registry builder, codec adapter and original review note
retain their approved hashes. In particular, `loop.py` remains
`d6145b89d89e3ff3fc91f67618354d4bfff45ad8cc88babe1d4fd457907372d7`.
This checkpoint verified those identities; it did not rerun the tests. The
[original review](REVIEW.md) records the integrity scope and limits, including
the absence of an OS-level malicious-code sandbox claim.

The one documentation correction identified here was the SED2 route-size unit:
3,619–42,533 bytes are 3.6–42.5 **kB**, not KiB. The owner corrected that unit.
