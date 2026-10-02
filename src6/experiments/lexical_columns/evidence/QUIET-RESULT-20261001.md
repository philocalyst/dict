# Frozen native dictionary construction pages: quiet results

Selective headword decoding is a measured win in this prototype. Median paired
mixed-root latency is 2.97–6.81 times faster across the five untouched natural
datasets, with exact source/model preservation. The benefit is specific to
headwords: every cold label/source probe is slower than the matched flat reader.
Encoding the three-way search also costs more. The size gains on Japanese and
Mandarin and the three other natural size losses remain unchanged.

The root coordinator granted a globally quiet interval after checking that no
other codec/build/test jobs were active. One complete warmup was discarded.
Five fresh native processes per case ran AB/BA/AB/BA/AB: three baseline-first
and two construction-first trials. Each chunk performs 512 operations. Ratios
below are medians of the five paired flat/construction time ratios; a ratio
above one means faster construction access. All five samples, raw phase times,
exact query hashes/byte counts and discarded warmup data are retained.

| Dataset | Headword same / mixed | Cold label same / mixed | Cold source same / mixed | Complete bzip3 size change |
| --- | ---: | ---: | ---: | ---: |
| Japanese OMW 2.0 | 7.559× / 6.814× | 0.871× / 0.898× | 0.878× / 0.901× | −4.70% |
| Mandarin OMW 2.0 | 7.187× / 5.491× | 0.953× / 0.933× | 0.952× / 0.931× | −6.01% |
| English GCIDE 0.54 | 6.646× / 6.411× | 0.897× / 0.909× | 0.898× / 0.909× | +2.25% |
| Spanish–English FreeDict | 3.399× / 2.969× | 0.678× / 0.729× | 0.678× / 0.733× | +10.59% |
| English–French FreeDict | 3.779× / 3.458× | 0.822× / 0.793× | 0.820× / 0.789× | +8.95% |
| Varied rich128 | 7.321× / 6.693× | 0.880× / 0.874× | 0.879× / 0.870× | +4.22% |

The mixed-root headword ratio ranges over the five samples are 6.786–6.844×
Japanese, 5.480–5.545× Mandarin, 6.336–6.449× GCIDE, 2.828–2.985×
Spanish–English, 3.417–3.518× English–French, and 6.659–6.804× rich128.
These are retained-sample ranges, not confidence intervals. The three-versus-two
order count is not perfectly balanced. The encoder's flat-first execution order
was not reversed, and the same backend context is reused inside each case.

Both compressed page sets and restored data are touched during full setup.
Original flat frames and construction pages are loaded into owned memory;
construction pages are fully inverted, checksummed and semantically admitted.
Baseline blocks are newly encoded, fully decoded and compared. Source parity
restores construction pages again, compares every canonical packet and all
direct projections, and checks the native reflected frame. An untimed expected
observation loop touches selected original raw packets before each pair. The
filesystem cache persists across processes; allocator/cache state evolves
within each process. These are resident prepared-reader measurements with
fresh decoding and no reader page cache, not cold-cache or cold-storage results.

Natural projection entries preserve an exact source record in one direct
definition `Inline.text` and have no direct sense label. Their label query is a
full cold probe with no label output. Rich128 has no first direct definition;
its source probe returns the headword only, while paying full cold
reconstruction. All cold queries decode the entire cold stream and copy the
selected root packet. No broader arbitrary-query acceleration is claimed.

Whole-corpus preparation is separately measured, in seconds:

| Dataset | Native full admission | Baseline backend encode | Complete source oracle + native reflected reencode |
| --- | ---: | ---: | ---: |
| Japanese | 2.0201 | 1.4539 | 1.8769 |
| Mandarin | 0.6310 | 0.4620 | 0.6085 |
| GCIDE | 1.3969 | 1.0112 | 1.3254 |
| Spanish–English | 0.0324 | 0.0148 | 0.0289 |
| English–French | 0.0690 | 0.0343 | 0.0616 |
| Rich128 | 0.0285 | 0.0145 | 0.0208 |

Matched encoder medians below are seconds for the complete corpus. Search pays
all literal/local/local-plus-ancestor forward trials, every hot/cold backend
encode, fallback decisions, per-page and complete outer-frame assembly,
selection, backend initialization and root-prefix preparation. Preparation
conservatively includes the frozen function's extra full restore oracle.
Explicit candidate inverse/decode verification, evidence IO and process startup
are separate. Named forward/backend subphases are not added twice.

| Dataset | Bzip3 flat / paid search | Zstd19 flat / paid search |
| --- | ---: | ---: |
| Japanese | 1.7123 / 10.5115 | 7.0833 / 23.9251 |
| Mandarin | 0.5506 / 3.7385 | 2.6803 / 9.5574 |
| GCIDE | 1.2326 / 6.2646 | 4.4233 / 15.1463 |
| Spanish–English | 0.0159 / 0.1122 | 0.3683 / 1.2467 |
| English–French | 0.0375 / 0.2503 | 0.7637 / 2.5072 |
| Rich128 | 0.0171 / 0.0551 | 0.2732 / 0.8540 |

Only bzip3 has a native query measurement here. Zstd19 remains a matched
encoder and complete-frame size control. The five natural complete zstd19 size
changes remain −3.11% Japanese, −0.97% Mandarin, +1.41% GCIDE, +10.01%
Spanish–English, and +8.36% English–French. Rich128 is +4.23%. The earlier
optional-label field-spine +19.5% bzip3 tradeoff is also retained.

All 36 case runs (six warmups, thirty measured cases) pass full source/native
admission, exact canonical packet/frame, projection, identity, query observation,
page/root count, complete size, constructor choice and source/runtime hash
guards. Every stored frame is byte-identical with clocks enabled. Each query's
five hashes, observed byte counts and operation counts agree. No frozen
encoder/format/reader/model/native-client source or binary was changed, and no
policy was tuned from FINAL outcomes or timings. The independent order client
is separately hash-frozen. Native C/C++ allocation is bounded but not
individually metered as Zig allocator calls.

Full distributions, exact observations, warmup separation, preparation and
paid encoder phases are in
[QUIET-RESULT-20261001.json](/workspace/dict/src6/experiments/lexical_columns/evidence/QUIET-RESULT-20261001.json).
The durable result manifest is
[QUIET-RESULT-MANIFEST-20261001.json](/workspace/dict/src6/experiments/lexical_columns/evidence/QUIET-RESULT-MANIFEST-20261001.json).
The immutable policy and size evidence are
[FINAL-20261001.json](/workspace/dict/src6/experiments/lexical_columns/evidence/FINAL-20261001.json).
Protocol, runtime, raw logs and private frame images remain under
`/workspace/scratch/lexical-columns-quiet-20261001`.
