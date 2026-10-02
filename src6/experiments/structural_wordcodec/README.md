# Structural word codec development

This directory contains two private, self-contained codec experiments. Nothing
here changes the frozen production codecs or the final capture. All comparisons
use development inputs. The experiments do not claim a compression record or
field-wide novelty.

## SWC2: independent native word/sequence grammar

`swc.cpp` has its own arithmetic coder. It tokenizes exact bytes into repeated
word forms, Unicode scalars, and literal bytes. It transmits a sorted lexicon
whose entries are raw or prefixes of earlier entries plus literal tails. A
bounded four-form cache may construct a new surface from an exact slice of an
earlier surface plus bytes on each side. It learns token-pair rules, optionally
reparses the source with the learned rule inventory, and directly entropy-codes
frequency-ranked roots in 64 KiB independent blocks. No bzip/M backend,
external vocabulary, normalizer, or language-specific dictionary is required.
Invalid UTF-8 remains byte-exact.

The complete SWC2 frame pays its header, arithmetic-coded lexicon and rules,
rank map, per-block root and construction parameter streams, block directory,
and 64-bit reconstruction checksums. `decode FRAME OUTPUT [BLOCK_INDEX]`
reconstructs the full source or one original 64 KiB block; `inspect` reports
the complete byte ledger. The reader bounds word sizes, grammar expansion,
expansion work, block output, and frame sizes, and validates its compressed
model stream canonically. It is a research prototype, not an authenticated
format or a fully audited hostile-input reader.

Build and use:

```sh
make -C src6/experiments/structural_wordcodec
src6/experiments/structural_wordcodec/swc encode INPUT FRAME
src6/experiments/structural_wordcodec/swc decode FRAME OUTPUT
src6/experiments/structural_wordcodec/swc decode FRAME PAGE_OUTPUT PAGE_INDEX
src6/experiments/structural_wordcodec/swc inspect FRAME LEDGER.json
```

The explicit development ablations in `run_dev.py` set `SWC_RULE_CAP`,
`SWC_WORD_CAP`, `SWC_COPY_MIN`, and `SWC_SCALARS` before encoding. Setting
`SWC_REPARSE=1` or `2` applies one or two frequency-priced grammar reparses.
These settings are encoder-only choices: the frame carries every construction,
rule, and symbol needed by the fixed decoder. Run the development suite with
`python3 run_dev.py --output evidence/dev-prefix256k.jsonl`; it takes pinned
*development* source prefixes from the corpus manifest, compares complete
frames with whole-file bzip3, and checks fresh full and every-block parity.

The first seven-profile 256 KiB study spans Japanese, Mandarin, GCIDE, two
FreeDict dictionaries, and Chinese/Japanese/Russian/Spanish/English plus
multilingual UD prose. Every SWC2 profile loses to whole-file bzip3 on every
lane. The pair grammar pays for itself against no grammar, but the flat root
source and word inventory remain too expensive. Exact recent-surface
construction does not recover the deficit. The Japanese development word
list is 379,535 bytes in the initial SWC2 cache variant versus 292,096 bytes
for whole bzip3; one joint grammar reparse yields 376,649 bytes. This is a
negative result and is retained as evidence, not represented as a frontier
gain. Timings collected under concurrent development work are diagnostic.

## Private native GEN experiment

`native_v3/` is a private copy of the repository's v3 lexical automaton
source at canonical HEAD `6f043e2`. The source-copy origin is
`src6/experiments/bzip4/bz4/v3/src/`; all edits are contained here. A private
`sgn\x02` wire adds a first-class GEN event to the native tANS source. A GEN
constructs an exact first-use token from literal prefix, a scalar-aligned
span of a recent token, and literal suffix. Its donor and edit operands use the native adaptive binary
coder in separately paid delta and payload streams. The constructed token
enters the ordinary 4096-token PAST window, so a repeated form inside reach
uses the unchanged distance tiers and its resumed successor row. A form that
ages out can be generated again or defined normally. The generator's
eligibility test accepts ASCII letters/digits, arbitrary high bytes, and
common internal punctuation without normalizing the source.

The private model/plan/encoder/decoder and wire include GEN explicitly. A
GEN inside a definition writes to the bounded delta output; one in a payload
writes to the original block output and remains addressable by PAST. Payload
blocks without GEN keep the existing batched decoder; GEN blocks use a scalar
path while building output-backed slices. The native planner trains frequency
tables for the event, and every sidecar byte is in the frame. The private
`private_fit.zig` planner tests exact-span thresholds of 12, 16, and 24 bytes
and a no-GEN control; every mode sweeps all declared native class counts and
emits the smallest complete archive. Each rejected fit counts toward initial
encoding time. Per-form proposals still use a bounded surrogate rather than
native event prices. The earlier `evidence/gen-dev1m.jsonl` was produced by
the original `lifetime_fit.zig`, which bypassed this search; it is a valid
threshold-12, early-stop, fully decoded diagnostic only. The corrected search
requires a new build and development screen. No final-lane result is claimed.

Build the private generic backend from this directory:

```sh
/home/agent/.local/bin/zig build-exe -O ReleaseFast --dep bz4 \
  -Mroot=native_v3/main.zig -Mbz4=native_v3/root.zig -femit-bin=./gen_native
```

`build_private.sh` builds the private backend and a copied WGP6 M learner
wrapper that uses `private_fit.zig`. Original M source and binaries remain
untouched. `gen_auto.py` encodes both untouched Runtime2 M and private GEN,
verifies full source and every original page for each, emits the smaller frame
with its original wire magic, and dispatches decode by that magic. Its report
charges both encodes and exposes the GEN sidecar ledger and selected mode.
The exact source-level GEN proposal may lose to unchanged M and whole bzip3;
the outer selector retains unchanged M when it does.

The corrected 1 MiB Japanese OMW development gate selected no GEN: 51,336
bytes for the private wire versus 51,272 for unchanged M, with exact whole
source and all 16 original pages. A forced class-16, threshold-12 GEN frame
is 51,623 bytes. `native_typed/` tests a distinct `sgt\x01` wire that omits
copy-span operands inferable from the donor (whole, prefix, suffix, interior).
It saves 15 bytes across 25 GEN events on the same parse: 51,608 bytes. Its
complete search still selects no GEN. Even deleting all 329 operand bytes
from that forced frame would leave 51,279 bytes, 7 above unchanged M; no
operand-only change can win that fixed parse. The full ledgers and selected
policies are in `evidence/gen-omw1m-exhaustive.json` and
`evidence/gen-typed-omw1m.json`. Diagnostic timing shared the machine.

`native_family/` is a deeper private construction-graph experiment using a
third wire magic, `sgf\x01`. A paid frame-global family template stores exact
byte prefix/suffix edits and how many bytes to delete from each end of a
recent donor. Each GEN event may bind one donor to a template ID, construct
the exact surface, and insert it in ordinary PAST. The four-pass native walk
seeds candidate families from bounded exact prefix/suffix alignments across
materialized M lexeme surfaces before any GEN, then uses repeated family
identities when choosing donor alignments. Family-only copy spans start at
4/6/8 scalar-safe bytes; shorter spans require a reusable family identity.
The transmitted table, template references, fallback
operands, native rows, and all unused trial encodes count toward the result.
The `family_fit.zig` policy compares no GEN, ordinary GEN, and family GEN at
three span thresholds over all seven class counts. The revised policy built,
and all 11 native-family ReleaseSafe tests passed. A test-only forced-table
path exercises the paid family decoder without changing production frame
selection; the ordinary whole-frame argmin chose zero tables on that synthetic
sample.

The prior min-12 family sources compiled and their three operand/family unit
tests passed.
The first full 7-mode × 7-class Mandarin OMW development fit was interrupted
by an execution-environment restart before it produced an SGF1 candidate;
it has no size result. A bounded fixed-class-16 rerun reused its retained
byte-exact M graph and compared all seven modes. It selected no GEN/no
families, 86,890 bytes versus 86,824 bytes for unchanged M; both full source
and all 16 pages decode exactly. The private wire's 66-byte overhead explains
the difference. `evidence/gen-family-cmn1m-fixed16.json` holds source/graph/
frame hashes, byte ledger and resource bound. A separate forced-family run
exercised the short-span lexical seeding on the same
Mandarin graph: class 16/minimum copy 4 yields 89,914 bytes against M's
86,824 bytes. It has 70 definition and 292 payload GEN events, but exact
whole-frame template-count selection chose zero families. Full decode and
all 16 page restarts pass. This is a forced ablation, and the prior min-12
class-16 no-GEN selection remains a separate policy. See
`evidence/gen-family-cmn1m-forced4.json` for hashes and the paid byte ledger.

`run_family_old_ud.py` then ran the already used Finnish, Turkish and Arabic
form development diagnostics. It used 4 GiB address-space/120 s CPU limits
per child, a 110 s child timeout, whole-file bzip3 controls, and fresh
whole-source/every-page decode for both M and SGF1. The complete frame bytes
were respectively SGF1/M/bzip3: Finnish 54,927/54,913/49,368; Turkish
24,624/24,617/21,588; Arabic 49,509/49,491/45,855. The exact SGF1 argmin
selected no GEN and no family table in all three; the outer selector chose M.
`evidence/gen-family-old-ud-forms.jsonl` preserves source hashes, selected
policies, component byte ledgers, and diagnostic wall time. These results
argue against continued surface-only constructor tuning on this development
set. `PHRASE_HYPOTHESES.md` and `phrase_skeleton/probe.py` start a distinct
exact word/sentence variable-slot skeleton line; it has no codec result yet.

## Exact phrase skeleton density

Before adding a native skeleton wire, `phrase_skeleton/probe.py` and
`probe_two.py` screened the six complete hash-pinned development books in
`/workspace/scratch/books2026-dev/manifest.json`. They verify byte-exact
tokenization and source hashes. Their scores are **source-only diagnostics**:
the word-slot price is assumed to cancel against an unchanged token model,
fixed anchors are priced at static unigram surprisal, and a template-ID,
ID-table, mode-selector and fixed row allowance are subtracted. They do not
measure a codec frame, and native M's grammar/context may already code the
anchors for less.

The asymmetric one-slot screen (`evidence/phrase-books-six-one-slot-asym.jsonl`)
estimates 2.74%, 5.37%, 4.73%, 2.34%, negative and negative of whole-file
bzip3 size for Pride and Prejudice, War and Peace, Don Quijote, Madame
Bovary, Die Verwandlung and Kokoro, respectively. The exact two
varying-whole-word-slot screen (`evidence/phrase-books-six-two-slot.jsonl`)
is smaller: 0.22%, 1.42%, 0.94%, 0.35%, negative and negative. The earlier
symmetric one-slot screen is retained at
`evidence/phrase-books-six-one-slot.jsonl` as an attributable shape ablation.
Each ledger records the full source/probe/manifest hashes. The one-slot
ledger includes independently computed whole-file bzip3 controls; those
bytes match the book corpus owner's fresh-decoded controls. Scalar-word
mode may show a larger proxy, but its top English/Spanish patterns leave
letter-sized holes inside words, and Kokoro's top patterns leave a single
character inside inflected forms. Those are subword/morphology patterns
rather than the proposed whole-word sentence structure.

The exact-anchor one/two-slot source family has too little paid token
structure to plausibly deliver the requested >20% whole-file bzip3 gain.
A native SKEL wire for this family was therefore not added; the density
screens cannot be promoted to an archive result.
