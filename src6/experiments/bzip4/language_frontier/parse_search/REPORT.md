# Outcome: bounded source-DAG search is negative

Two explicit policies were tested without production changes or confirmation-20
access. The first explores 24 graphs plus six full-byte coordinate refits and a
native incumbent. It introduces variable-length shared spelling fragments and
variable-arity phrase rules. The second regenerates three additional graphs
using actual native aggregate use charges and fitted literal-row costs, then
accepts only a smaller complete native frame. This is an encoder search experiment,
not a marginal surface model or a proposed production mode.

| Exact prefix and language | Native v4 | Search selected | Best new graph | Real bzip3 |
|---|---:|---:|---:|---:|
| OMW 8KiB, first policy | 1449 | 1449 | 1611 | not measured in this screen |
| Finnish UD 8KiB, first policy | 4241 | 4186 | 4186 | not measured in this screen |
| Turkish UD 8KiB, first policy | 4146 | 4142 | 4142 | not measured in this screen |
| OMW 16KiB, first policy | 2027 | 2027 | intermediate sizes not retained by quickbench | 1575 |
| Finnish UD 16KiB, first policy | 7941 | 7941 | intermediate sizes not retained by quickbench | 6500 |
| Turkish UD 16KiB, first policy | 7508 | 7508 | intermediate sizes not retained by quickbench | 6184 |
| OMW 64KiB, first policy | 6493 | 6493 | 7296 | 5032 |
| Finnish UD 64KiB, first policy | 27344 | 27344 | 27884 | 22522 |
| Turkish UD 64KiB, first policy | 26067 | 26067 | 26665 | 21265 |
| OMW 16KiB, native-priced V2 | 2027 | 2027 | priced refits 2241/2243/2293 | 1575 |
| Finnish UD 16KiB, native-priced V2 | 7941 | 7941 | priced refits 8229/8693/8401 | 6500 |
| Turkish UD 16KiB, native-priced V2 | 7508 | 7508 | priced refits 8160/8844/8553 | 6184 |

The Finnish 8KiB improvement is 1.30%; Turkish improves 0.10%. These tiny gains
do not transfer to 16KiB or 64KiB. Native-priced regeneration also loses clearly.
There is no winning graph to justify 128–256KiB scaling or integration. Bzip3
figures are complete real native B3PY lab frames (32+16 bytes/block charged),
not payload estimates. Whole and matched-block controls coincide at these sizes.

The actual native encoder checks every trial against the exact raw input. Final
frames are independently decoded with the public native CLI. Graph tests cover
all 24 configurations on empty input, all 256 byte values, invalid UTF-8,
combining marks, multiple scripts and multiple blocks. All entry references are
strictly earlier, graph depth is bounded, and no CUT is generated. Three unit
tests passed again after the final implementation; an additional native-priced
all-byte/multiblock external roundtrip passed. Unknown options, negative/outside
config IDs and incorrect boolean types are rejected.

First-policy full encoder effort was 1.7–3.1 seconds at 8KiB and 15/34/25 seconds
at 64KiB. Native-priced V2 was 13.8/13.2/18.1 seconds at 16KiB. These observations
include complete search and subprocess work, with concurrent activity; they are
not controlled performance or decoder-kernel measurements. V2 uses 35 capture
processes and one two-encode stats process, with additional native auto-class
fitting work inside each capture.

## Evidence and provenance

`dev-8k-frozen/results.json`, `frozen-64k/results.json`, and
`priced-frozen-v2-16k/results.json` retain trial outcomes and real
header/delta/payload/framing byte breakdowns. The 16KiB quickbench run is
`quick-16k/20260926T163849Z-f9dc69ef/`; the 64KiB baseline run is
`baselines-64k/20260926T164001Z-34f2350e/`. Quickbench preserves fresh independent
decodes and dependency fingerprints for capture/public binaries. V2 additionally
checks source and external binary hashes before/after encoding, saves source
snapshots, and preserves exact hashes in `implementation.json`.

The V2 adapter SHA256 is
`26c203c244d4df8bbcb6904d07bd38369ebf5266fdc32d0d4c662c22cd6e046e`.
The stats executable SHA256 is
`09de792acba99fe2e71e405d927f8ce82d0c154c14aea07093badd990a706ca0`.
Capture/public hashes are
`0a566e101fabcd0bccd3bd95eac265f6c9dbf288819601e4e9b7f35536708c83` and
`17cda3b68a1b0f8b0535c99cc77fdc0220351f210171c04620c1db6ace4f7fcc`.
All three V2 input/frame hashes are in its results JSON. First-policy standalone
screen files predate the snapshot/fingerprint mechanism; their provenance is
weaker than V2 and the independent quickbench records. Do not reconstruct missing
historical fingerprints from the current source and call them contemporaneous.

`dev-2k/` predates longer substring proposals and coordinate refits and ended
after three successful inputs when an unprepared Arabic training path was
encountered. `priced-dev-8k/` used the predecessor alias-price/fixed-literal
fallback policy, not V2. `priced-frozen-16k/` is an incomplete failed start while
the stats executable was being rebuilt; it has no successful measured result.
All are retained and explicitly excluded from frozen V2 conclusions.

## Reproduction

From repository root, an owned-output quickbench run can use:

```
python3 src6/experiments/bzip4/language_frontier/quickbench/bench.py INPUT --limit 16384 --candidate src6/experiments/bzip4/language_frontier/parse_search/adapter.py --options '{"priced_refit":true}' --dependency src6/experiments/bzip4/language_frontier/evidence/bin/capture_frame --dependency src6/experiments/bzip4/bz4/v3/zig-out/bin/bz4 --dependency src6/experiments/bzip4/language_frontier/parse_search/prices --cache src6/experiments/bzip4/language_frontier/parse_search/cache --output src6/experiments/bzip4/language_frontier/parse_search/NEW_RUN
```

Use `--options '{"priced_refit":false}'` for the first policy. `screen.py` accepts
`--limit`, `--out` and `--priced-refit`; it reads only OMW development data and
Finnish/Turkish exploratory-80. Run `test_adapter.py` for the unit checks. Build
instructions and algorithm budgets are in `README.md`.

Actual-price proposals still approximate the objective: entry averages omit past
uses and definition/name overhead; the literal body row does not represent every
incoming context. New pieces use a frequency prior. The full-frame oracle pays
all those costs, but cannot discover graphs absent from the proposal set. This
negative result rejects this bounded family and its price-refit extension,
not the broader possibility of better shared-source graphs.
