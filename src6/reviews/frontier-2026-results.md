# Word compression and expressive dictionary frontier, October 2026

Status: production dictionary validation and final compressed-dictionary size
and five-trial quiet timing evaluations are complete. The independent stream
codec's 352-cell size evaluation and 2,448-operation quiet timing evaluation
are complete and independently rechecked. New deeper structural designs
remain development experiments, with fresh sources reserved for later validation.
Concurrent screen clocks are not final speed results.

## Delivered dictionary model and prepared reader

Production packet v4 retains the sparse declared defaults introduced in v3 without dropping
fields. It adds native morphological analyses and recursive segments with
exact byte spans, discontinuous constituents, zero-length forms, qualified
features and cross-form references. Turkish suffix chains, Arabic root and
pattern spans, CJK compounds without spaces and German multiword structure
have native tests. Exact surface spelling stays authoritative; the reader
does not apply a Unicode normalizer or infer away ambiguity. Packets v2 and v3
remain readable; legacy packets reject kinds that their schemas did not declare.

Schema 4 adds named construction programs and independently evidenced
occurrences. Programs compose exact literals, parameter slots, ordered
discontinuous copies, nested calls and zero realizations. Admission checks
forward references, unused cycles, Unicode boundaries, exact authoritative
surface equality and shared work limits. External surface identities preserve
the supplied bytes; unavailable external programs and calls carry an explicit
unverified proof state. These features do not infer a preferred morphology or
drop competing analyses.

Full canonical and semantic verification produces an immutable archive
capability. Prepared borrowed views then skip unrelated descendants and
reuse the proof. Raw views allocate nothing; a compressed reader owns one
decoded page. View lifetime ends when its owning page is evicted. The proof
is a caller contract over immutable bytes, not an authentication signature.
The optional identity catalog is paid separately and remains disabled by
default. New defaults require an intentional format version change.

The following performance results measure the frozen v3 implementation at
`6f043e245eea265e4a222524443e3ff01e09c3cb`, compared with canonical commit
`eda533210ddfa8901a4fde66b558bd84e4e3b555`.
complete natural raw archives at 64 KiB shrink by 1.35–3.25%; adaptive
bzip3 archives shrink by 0.06–0.80%. After separately charged full semantic
verification, equivalent raw-page headword-plus-definition reads improve
by roughly 14–34×. Natural compressed mixed-page reads improve only about
1.05–1.07× because bzip3 decoding still dominates. On the repeated rich
fixture, raw packet storage falls by 15.47% and prepared cached raw reads
are about 44× faster. Those rich-fixture figures do not establish natural
compressed gains; the optional rich identity index also grows compressed
storage. All losses, setup amortization estimates and five paired samples
are preserved in the [complete production evidence](evidence/dictionary-final-20261001.json).

The current v4 production build passes 124 tests in Debug, ReleaseSafe and
ReleaseFast, plus the example and independent client test. Those include external
program proof boundaries, repeated-call work charging, defaults, malformed
packets, borrowed lifetimes and full-field view parity. Historical v3 timing
results are not new measurements of construction-rich v4 data.

## New standalone word compressor

`wordfrontier.py` uses one fixed global policy. It actually encodes both
families below, selects the smallest complete archive and pays every losing
search in initial encoding time. It has no filename, language, script or
dictionary-tag rule. WPG2 and GWT1 already carry distinct wire magic, so the
selector adds no frame bytes. The underlying native v4 entropy compiler is
the repository's existing backend. These representation experiments are
new to this project; no field-wide invention or universal record is claimed.

**WPG2 exact word constructors.** A small bounded source program expresses
repeated quoted fields as slices of earlier or enclosing field values.
Constructor operands, donors and literal escapes are transmitted. Raw,
local, enclosing and combined source programs each compete through the
initial spelling graph and a conditional spelling-and-payload reparse.
The parser tiles actual source bytes using the compiled native model's
prices; it does not optimize a detached word-table proxy. Literal fallback
preserves arbitrary bytes and invalid UTF-8.

**GWT1 exact word-layout residuals.** A page-local word-width predictor
replaces eligible space/newline boundaries with space. A paid small numeric
context tree codes every exact exception. The encoder compares the actual
tree-plus-flags against a simpler two-row residual model. Decoding uses
transmitted integer probabilities and independent residual streams for each
original page. Tree proposals may use floating point at encode time; decoder
reconstruction uses integer tables and exact source checksums.

Quality and access profiles preserve independently extractable original
65,536-byte pages after shared model preparation. Access hoists the common
model ahead of payloads. Initial encoding can be expensive: every graph fit,
native reprice, transform and rejected family is charged. Input admission is
32 MiB, the M encoder requests at most 4 GiB live native allocation, and the
private prepared native decoder has a 512 MiB allocation budget. Those are
component budgets, not total process RSS. Failed candidate admission stops
the search rather than quietly disappearing from the selector.

Development evidence established two concrete wins before freezing:

| Retained 8 MiB development workload | New complete archive | Historical strong M | Whole bzip3 | Exact original pages |
| --- | ---: | ---: | ---: | ---: |
| Japanese OMW, WPG2 quality | 285,569 | 330,148 | 332,331 | 128 |
| English GCIDE, GWT1 quality | 1,232,267 | 1,276,838 | 1,243,221 | 128 |

Every model, constructor, directory, flag stream and checksum is included.
The fresh M reproduction differs slightly from the historical GCIDE/OMW
frames, so both references remain visible. Native full decoding and every
original page match independently retained source bytes. Decoder budget,
malformed metadata, context trees, exact inverse, atomic publication and
selected-page corruption were separately audited; see the
[WPG2 audit](../experiments/word_constructions/review/INDEPENDENT_WPG2_AUDIT.md),
[budget evidence](../experiments/word_constructions/evidence/DECODER_BUDGET_EVIDENCE.md)
and [GWT1 evidence](../experiments/wordgrammar/geometry/evidence/GWT1_NATIVE_EVIDENCE.md).

The first frozen final capture stopped after 128 successful cells with
`OutOfMemory` on the 22.24 MB Japanese source under the encoder's 4 GiB limit.
The original binary did not identify the failing phase or distinguish quota
denial from parent allocator failure. A separate Runtime 2 implementation
releases completed seed-learning temporary tables through an ownership-aware
allocator, while retaining the same learner, model IDs, order and allocation
limit. All fourteen development cases and six arbitrary-byte cases match the
original archive and forward grammar bytes. The 8 MiB GCIDE seed peak drops
from 3.64 GB to 107 MB; the 22 MiB Japanese development seed peak drops from
2.16 GB to 279 MB. Japanese's unchanged M-learning phase still peaks at
2.34 GB, so the seed reduction is not a whole-process memory ratio. The
[Runtime 2 proof](../experiments/wordgrammar/wgp6/RUNTIME2_RESOURCE_REPORT.md)
records this revision. The full final matrix is rerun fresh under its separate
runtime fingerprint; successful earlier frame counterparts must match exactly.
All 128 such counterparts have now matched. The previously failing Japanese
quality cell also completes: its new 1,212,617-byte WPG2 archive reconstructs
all 22,238,553 source bytes and all 340 original pages exactly. It has no
successful Runtime 1 counterpart. The paid, losing GWT1 candidate reaches
4,231,527,505 tracked allocator bytes during M learning, close to the unchanged
4 GiB limit; this is one inner encoder component, not whole-wrapper process RSS.
The Japanese access profile completes at 1,247,679 bytes. The complete
352-cell Runtime 2 comparison passes all frozen source/runtime guards,
fresh full-source and documented restart checks. All 672 frozen dependency
files, every captured frame and source, and all 128 completed Runtime 1
counterparts were independently rehashed by the report generator.

The untouched stream evaluation uses 22 source lanes: complete dictionary
content and word lists, official UD prose/forms in five languages, and
multilingual prose/tagged text. Twelve matched 64 KiB candidates include
both automatic profiles, faithful M quality/access, four WSB2 alternatives
and four native controls. Four whole-file controls are a separate group.
All 352 complete-frame cells passed frozen source/runtime guards,
full-source equality and their documented restart oracle. Seventeen lanes
received one fresh-process warmup and five serial paired full-decode/query
samples in a separate globally quiet window. All 2,448 operations completed
with exact source and query-oracle checks; the independent summary also
rehashed every frozen dependency and retained frame.

The complete heldout storage comparison includes all gains and losses:

| Untouched source | Raw bytes | WordFrontier quality | Fresh strong M | Whole bzip3 | Change vs whole bzip3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mandarin OMW | 5,717,747 | 344,455 | 467,640 | 532,934 | −35.36% |
| Japanese OMW | 22,238,553 | 1,212,617 | 1,411,704 | 1,513,632 | −19.89% |
| English GCIDE | 11,667,063 | 1,702,566 | 1,791,051 | 1,741,964 | −2.26% |
| Spanish–English | 408,134 | 11,977 | 11,907 | 12,332 | −2.88% |
| English–French | 866,208 | 30,703 | 30,903 | 30,035 | +2.22% |

Mandarin and Japanese select WPG2; GCIDE selects GWT1. No policy changed
after these outcomes. Across all 22 lanes (50,340,470 raw bytes), quality
totals 5,451,644 bytes versus whole bzip3's 5,862,542: **7.01% less**.
Access totals 5,598,546 bytes. The five dictionary-content lanes total
3,302,318 quality bytes versus 3,830,897 whole-bzip3 bytes: **13.80% less**.
The strong M quality total is 5,868,749 bytes across all 22 lanes.

Prose quality totals 477,132 versus 443,190 whole-bzip3 bytes (**7.66% more**);
the two multilingual lanes total 960,558 versus 895,228 (**7.30% more**);
word-form lanes total 711,636 versus 693,227 (**2.66% more**). These categories
contain related projections and are not independent samples. Aggregates use
ratios of complete byte sums, rather than averages of percentages. The
[complete storage evidence](evidence/wordcodec-storage-runtime2-20261001.json)
retains all 352 cells, exact model/payload/framing ledgers, rejected-family
search events, original counterpart proofs, pinned environment and per-lane
comparisons against both whole-file and matched-restart controls.

Native readers expose different timing scopes. WPG2/GWT1 full decode includes
output publication; other native full clocks exclude output file writes.
Query CRC/fold scopes and preparation file-read scopes also differ. Final
tables must identify those actual API paths instead of presenting one
uniform entropy-kernel throughput. OS high-water RSS can inherit a parent
floor and will not be used to rank decoder memory.

The completed quiet comparison exposes a real tradeoff. Quality's native
prepared-query API is 3.54–10.08× faster than the matched independent-page
bzip3 API across the seventeen lanes, but 1.24–3.96× slower than faithful
strong M. The access profile gives 3.52–10.55× against bzip3 and still loses
to M. These are medians of five same-round paired ratios, with the different
CRC/fold scopes stated above; they are not uniform entropy-kernel speedups.
Quality full-process decode is 2.55× faster than bzip3 on Japanese content
and 2.22× on Mandarin content, but only 0.205× and 0.106× as fast as M.
Wrapper startup, preparation and output publication all count in that clock.
Several small-input full-process comparisons lose to bzip3 too. Shared
grammar preparation is much more expensive than bzip3 initialization;
improved storage does not establish an across-the-board decoder win.
The [complete timing evidence](evidence/wordcodec-final-runtime2-20261001.json)
preserves all warmups, five samples, exact query oracles, clock distributions,
per-lane ratios and reader scopes. The next structural phase explicitly
targets these remaining costs as well as storage.

## Separate compressed dictionary page representation

The `lexical_columns` native prototype reflects required root identity and
headword fields into a hot stream and preserves adjacent complete nested
packets in a cold stream. The same exact constructors compete on cold bytes.
All three literal/local/local-plus-enclosing candidates are actually encoded,
and a fixed complete-frame minimum selects each page. All source bytes and
every native field remain present; the natural loader preserves source XML
inside native text rather than claiming a complete XML-to-lexical importer.

The untouched five-dictionary evaluation contains 58,717 native entries and
1,248 identical source groups. Complete bzip3 frames save 4.70% for Japanese
and 6.01% for Mandarin. GCIDE grows 2.25%, Spanish–English 10.59% and
English–French 8.95%, leaving a weighted complete-byte saving of 1.56%.
The independent zstd19 comparison saves 0.63% overall. All selected and all
candidate pages pass canonical/source-byte reconstruction and native full
semantic admission: 234,868 entry admissions.

The completed quiet study discarded one warmup and retained five native
fresh-process paired trials in AB/BA/AB/BA/AB order. Each query chunk performs
512 exact reads from resident compressed frames, freshly decoding its required
blocks every time; no decoded-page cache is present. Full source reconstruction
and semantic admission are charged separately. These are resident-frame
measurements, with three baseline-first and two construction-first trials.

| Untouched dictionary | Complete bzip3 byte change | Same-root headword speedup | Mixed-root headword speedup | Mixed-root source-query speedup |
| --- | ---: | ---: | ---: | ---: |
| Japanese OMW | −4.70% | 7.56× | 6.81× | 0.901× |
| Mandarin OMW | −6.01% | 7.19× | 5.49× | 0.931× |
| English GCIDE | +2.25% | 6.65× | 6.41× | 0.909× |
| Spanish–English | +10.59% | 3.40× | 2.97× | 0.733× |
| English–French | +8.95% | 3.78× | 3.46× | 0.789× |

Each speedup is the median of five paired flat/construction ratios; values
below one mean slower construction access. Summed across complete archives,
uncompressed hot headword streams are 13.71–33.27× smaller than full flat
streams; this is an archive-total required-stream volume ratio, not a measured
per-query byte ratio. Every measured cold label/source path is slower, because
it pays the cold inverse and selected
packet reconstruction. Thus the access gain applies to the hot headword field,
not arbitrary field reads. Natural projections have no direct sense labels,
so their label probes return the headword alone while paying full cold
reconstruction. The charged Japanese bzip3 representation/backend
search grows from 1.71 to 10.51 seconds; explicit candidate verification and
evidence I/O are recorded separately. Full construction-page admission takes
2.02 seconds, separately from the source oracle and native reencode.
The rich128 complete bzip3 alternative still loses by 4.22%, despite
7.32×/6.69× same/mixed headword speedups. Its empty direct-definition probe
does not establish natural definition-access performance. This prototype
remains separate from production archive v3. See
[all per-dictionary sizes and gates](../experiments/lexical_columns/evidence/FINAL-20261001.md)
and [the complete quiet timing evidence](../experiments/lexical_columns/evidence/QUIET-RESULT-20261001.md).

## Rejected abstractions and reproducibility

Exact dictionary DAGs cut rich raw footprint by 54% but increased complete
bzip3 pages by 134%. Recursive shape programs and root-template transposes
also lost after compression. Stem/tail word inventories lost once occurrence
entropy, classes and rank bridges were charged. Prior-word constructor rings
removed source bytes but added expensive donor indices. The narrow transient
form-cache implementation lost strongly; its standalone hapax oracle exposed
too little potential saving before operands. Those negative results are
retained in the [experiment map](../bench/frontier2026/reports/experiment-space.md).
It describes a finite explored set, not an exhausted general problem space.

Luna handled benchmark design, source/restart verification and research
checks; Sol handled the major constructor, lifetime, decoder and dictionary
representation work. The [research notes](frontier-2026-research.md) pin
reachable source citations and distinguish external-model neural bitrates
from this self-contained frame contract. No LLM weights or hidden vocabulary
are required for decoding.

See [build and reproduction commands](frontier-2026-build.md). The reviewed
production dictionary changes are pushed to canonical at
`b06bf9a` (schema 4), following `6f043e2` (schema 3). The reviewed experimental
source, book evaluation loop and retained evidence are pushed in `1bbbfe0`.

## Complete-book evaluation loop

The article-inspired [evaluation loop](../bench/frontier_loop/README.md) now
has a 27-test independent integrity review and exact, complete-source book
trials. Six complete works total 7,552,894 UTF-8 bytes across English, Spanish,
French, German and Japanese. Native bzip3 calibration reproduces all six
independently retained archive hashes. WordFrontier quality loses every book
by 3.52–8.58%, with a language/work-balanced size ratio of 1.06383. A fresh
grading replay under the corrected harness reproduces all twelve archives.
The paid encoder searches and every failure remain in the loop's evidence.
Five distinct-author validation books have no codec outcomes and remain reserved.

The class-factor, phrase, causal word/byte prediction, conditional integer
mixer, packed joint-word predictor and whole-clause edit studies are fixed
development falsifiers. Their results do not establish a new record. Removing
the word grammar's 64 KiB payload resets saves only 834 bytes across the six
fixed development prefixes and still loses bzip3. The 35% complete-book
compression aspiration remains unmet. The corrected grader separates an
incremental development keeper from that aspiration and charges learned
side information as well as every delivered frame.

For the same six complete-book frames, a separate quiet native reader study
uses bzip3 workspaces sized to retain each book in one block. Its archive sizes
and payloads are unchanged from the full-file controls. Five paired trials after
a warmup give 3.15–5.96× median command-wall speedups for WordFrontier, including
full decoding and file output; all 72 outputs are exact. Files are resident,
and inherited coordinator memory limits interpretation of the recorded RSS.
See the [report and limitations](../bench/frontier_loop/evidence/book-readers-sized-annotation-20261002.json).
This decoder improvement leaves the complete-book size failure unchanged.

The separate [joint lexical PPM diagnostic](../experiments/lexical_ppm/RESULTS.md)
tests complete successor distributions, a joint word/separator stream and
paid terminated spellings. All twelve fixed tokenizer/source rows pass their
source oracle and memory cap, but even the best optimistic size loses every
input and totals 11.58% above delivered bzip3 bytes. No native wire follows.
The [mature PAQ calibration](../bench/paq_calibration/PAQ-BOOK-CALIBRATION-20261002.md)
provides six exact `-1` archives after a separately retained timeout and clean
retry, saving 9.59% total bytes against matched development-prefix controls.
That external reference is a source of modeling evidence, not our compressor;
the two longest books are prefixes in this calibration. Its gains do not meet
the 35% aspiration or the fast-reader requirement.
