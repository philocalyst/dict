# Latent segmentation marginalization screen (diagnostic)

Status: bounded evidence, not a compressed frame.  This experiment answers
whether replacing one best segmentation with a sum over all segmentations is
worth a wire-level prototype.

## Exact model and decoder-visible boundary

The input is split with the exact v4 byte-kind rule: ASCII letters and all
bytes >= 0x80 form one run, ASCII digits form one run, and every other byte is
a singleton.  There is no UTF-8 validation, normalization, tokenizer,
dictionary, or language model.  Inside each run, a fixed inventory of at most
2048 byte substrings (maximum length 8, minimum weighted occurrence 2) is
learned from that same bounded input.  Singleton bytes remain fallback tokens,
so every byte string has at least one derivation.

For one smoothed unigram PMF (`alpha=0.5`) over those pieces and fallback
bytes, the script computes by dynamic programming:

```
MAP(X) = -log2 max_z p(z, X)
SUM(X) = -log2 sum_{z:emit(z)=X} p(z, X)
gap    = MAP(X) - SUM(X)
```

The inventory spelling/name diagnostic is reported separately.  It is not
subtracted from the gap and is not a complete frame.  A real promotion must
encode the inventory and the surface bytes with a decoder-visible finite
weighted automaton or a fully charged bits-back protocol.

## Reproducible commands and raw results

Machine/tool: macOS Apple Silicon, Python 3.14.7, 2026-09-26.  Script:
`marginal_gap.py`; all output hashes are SHA-256 of the exact bytes read.

```
python3 src6/experiments/bzip4/language_frontier/segmentation/marginal_gap.py \
  /usr/share/dict/web2 --limit 65536 --max-vocab 2048 \
  --mixed-control --random-control --json
```

The script runs an exhaustive tiny-vocabulary oracle before every command
(unique-path, two-path, and three-path strings); it asserts exact forward
sum/max equality, nonnegative gaps, and zero gap for a unique segmentation.
Raw JSON from that command:

```
[{"path":"/usr/share/dict/web2","bytes":65536,
  "sha256":"328d13eb19288331b00baea9463133153b0383a9486fcf5ab8fb31ea3e177f5e",
  "pieces":2048,"model_bits_diagnostic":96040,
  "map_bits":230344.719816478,"marginal_bits":221446.713015445,
  "gap_bits":8898.006801033,"gap_bits_per_byte":0.135772808854,
  "gap_bits_per_atom":0.684093703470,"ambiguous_atoms":6455,
  "path_count_log10":13503.46280784},
 {"path":"<mixed-control>","bytes":14592,
  "sha256":"a1e92f39c1fc00e6776b9ca316951faa8dad87d5bc091b0f69de9ec8d822c67f",
  "pieces":148,"model_bits_diagnostic":5968,
  "map_bits":34993.079674749,"marginal_bits":33583.637397397,
  "gap_bits":1409.442277450,"gap_bits_per_byte":0.096590068356,
  "gap_bits_per_atom":0.323860817429,"ambiguous_atoms":1792,
  "path_count_log10":3080.80272545},
 {"path":"<random-control>","bytes":16384,
  "sha256":"22a707298cfd73b7d8d651b7f9114a954073774bf70787f4e1551c5dd4c32827f",
  "pieces":816,"model_bits_diagnostic":21224,
  "map_bits":128526.373682607,"marginal_bits":128181.275616404,
  "gap_bits":345.098066203,"gap_bits_per_byte":0.021063114392,
  "gap_bits_per_atom":0.041754151991,"ambiguous_atoms":381,
  "path_count_log10":483.256420594}]
```

The 256 KiB screen used the same policy except `--limit 262144`; it was
intentionally run with the same bounded inventory:

```
python3 src6/experiments/bzip4/language_frontier/segmentation/marginal_gap.py \
  /usr/share/dict/web2 --limit 262144 --max-vocab 2048 --json
```

```
bytes=262144 sha256=274400036706053b757a0fc7d95fc49a66e310aebb9d077818ec19eac896001
pieces=2048 model_bits_diagnostic=87248
map_bits=997917.256306147 marginal_bits=953296.905105480
gap_bits=44620.351200667 gap_bits_per_byte=0.170213131716
gap_bits_per_atom=0.869368752083 ambiguous_atoms=25566
path_count_log10=54302.0608053
```

The corrected diagnostic gap is measurable on a sorted word list (0.136--0.170
bits/byte) and the deliberately mixed invalid/UTF-8 fixture (0.097 bits/byte),
while a random control has a much smaller incidental ambiguity (0.021
bits/byte).  It is not evidence that a v4 frame
can simply delete those bits: current tANS rows decode one selected token
path and contain no marginal state.

## Primary-source synthesis and the next falsification

Townsend, Bird & Barber, *Practical Lossless Compression with Latent Variables
using Bits Back Coding* (ICLR 2019,
[arXiv:1901.04866](https://arxiv.org/abs/1901.04866)), makes a latent path
recoverable by coding `z` from a posterior, the surface under `p(x|z)`, then
`z` under its prior; the receiver reverses those operations.  The net rate is
the negative ELBO, not the joint MAP cost.  The paper also stresses ANS's LIFO
state and a nontrivial initial seed.  Our hidden path is a discrete
segmentation, so this is the relevant route if exact marginal coding needs a
latent sample.

Liu, Mandt & Van den Broeck, *Lossless Compression with Probabilistic
Circuits* (2021,
[arXiv:2111.11632](https://arxiv.org/abs/2111.11632)), instead uses a tractable
sum/product circuit whose exact marginal supports arithmetic coding directly.
The transferable idea is a finite weighted automaton over segment prefixes;
reported image circuits do not establish a text/frame win here.

Snæbjarnarson et al., *Transducing Language Models* (2026,
[arXiv:2603.05193](https://arxiv.org/abs/2603.05193)), gives the closest recent
formal treatment of this exact operation: compose a source distribution with a
finite-state string transducer and expose incremental next-symbol and prefix
probabilities after summing all source strings that map to the same output.
Their frontier/decomposition algorithm makes explicit why partial output
pieces must remain live, and their finiteness conditions rule out unbounded
epsilon-output cycles.  Our bounded piece emitter is the simple finite-suffix
special case; its exhaustive oracle is a useful check that the implementation
does sum partial final pieces rather than only complete token paths.

`weighted_emission_coder.py` is the bounded prefix-circuit falsification.  It
keeps only a charged vocabulary of singleton bytes plus at most 512 learned
pieces (maximum length 8), and merges all paths with the same remaining
suffix.  It never stores the distinct surface atoms.  At each byte, the
arithmetic CDF is the posterior mixture of root token starts and live suffix
states.  The raw byte length is explicitly charged in the frame, so this is a
renewal stream truncated by a decoder-visible length side channel rather than
an uncharged EOS assumption.  Both MAP token IDs and marginal surface bytes
use the same complete header, frequencies, precision, and arithmetic finish.

Promotion requires the actual round-trip frame to beat both the deterministic
MAP parse and current v4 `plan.fit`; otherwise the measured gap is preserved
as a negative result.  A fixed-length renewal variant using the independent
`oracle/renewal.py` partition function remains a follow-up, because its
length-conditioned CDF is a different probability model and must not be
silently substituted into this result.

Why BB-ANS may still fail despite the large gap: its posterior is itself a
decoder-visible finite model and its initial state/seed cannot be free at
small block sizes.  If those charged bytes plus the inventory exceed the
measured gap, the experiment will report that inequality rather than claim a
gain.  No arbitrary `log(sum)` subtraction is valid in the existing wire.

## Complete-frame weighted-emission screen

The prototype was run on the first 64 KiB of `web2` with the same learned
inventory and header in both modes:

```
python3 src6/experiments/bzip4/language_frontier/segmentation/weighted_emission_coder.py \
  /usr/share/dict/web2 --limit 65536 --max-vocab 512 --json
```

```
input sha256=328d13eb19288331b00baea9463133153b0383a9486fcf5ab8fb31ea3e177f5
mode=map       header=3,761 frame=34,415 round_trip=true
mode=marginal  header=3,761 frame=33,138 round_trip=true
frame_sha256(map)=8147301748493f928ed532b02b85d4396893f6b6f1c4fc0db556f0d98accfe66
frame_sha256(marginal)=1c78ec858e76c42edb0c62c362ee605ed3211a65e653dd6aadeb5732c45f3dba
exact_model_bits(map)=245182.7525 payload_bits=245184 overhead=1.2475
exact_model_bits(marginal)=234986.0807 payload_bits=234992 overhead=5.9193
```

For an additional exact-vs-quantized audit, the same script on an 8 KiB
prefix reports the unquantized posterior NLL and the actual byte-aligned
arithmetic payload (the encoder emits a final disambiguating bit and pads to a
minimum 64-bit decoder seed; it does not append eight terminal bytes):

```
mode=map       exact=26216.4452 bits payload=26224 bits overhead=7.5548 bits
mode=marginal  exact=25455.4825 bits payload=25456 bits overhead=0.5175 bits
header=4,194 bytes frame=7,476 / 7,378 bytes round_trip=true
```

The bit-packed finish and E3-safe renormalization leave only a small payload
overhead (the marginal stream is within 0.52 bits of its unquantized posterior
on this screen); this is not a free subtraction.  The larger marginal saving
is therefore in the model probability itself, while both modes carry exactly
the same 4,194-byte vocabulary header on this smaller screen.

Under this charged prototype, marginal byte coding is 1,277 bytes (3.71%)
smaller than coding the best *prefix* token path with the same PMF (the final
token may cross the charged raw-length boundary and is truncated by the
decoder).  This removes the unfair complete-boundary advantage from the
comparison.  This is evidence
that path ambiguity can survive a real finite prefix automaton, unlike the
atom-leaf negative control, but it is not yet a v4 win: the frame is a new
research wire, uses a floating posterior with fixed 20-bit CDF quantization,
and has not been routed through `plan.fit`; cross-architecture bitwise frame
portability is not promised until those floating CDFs are canonicalized.  The
parser rejects truncated or trailing payloads and canonical re-encoding rejects
altered payload bits.  The test oracle exhaustively checks short-prefix mass,
complete-path mass, unique-path zero gap, normalization, empty/singleton
round trips, and truncation failure.  The result is intentionally bounded;
no long timing benchmark is included.

The required non-English/mixed-script control uses the same byte-preserving
fixture as `marginal_gap.py` (combining acute accent, CJK, Cyrillic, Arabic,
mixed casing, NULs, whitespace, and deliberately invalid UTF-8 bytes).  With
`--max-vocab 512`, all 14,592 bytes round-trip and the model/header is charged:

```
sha256=a1e92f39c1fc00e6776b9ca316951faa8dad87d5bc091b0f69de9ec8d822c67f
mode=map       header=1,858 frame=6,241 exact=35023.2471 payload=35032 bits
mode=marginal  header=1,858 frame=6,062 exact=33614.2481 payload=33616 bits
```

This control is intentionally not treated as a language-specific win: the
learner sees raw bytes, preserves malformed sequences, and has no Unicode
normalization or external model.

## Bounded EM ablation

The substring-overlap frequencies above are only a seed.  To test whether the
gain survives a genuinely fitted latent unigram PMF, the prototype also has a
fixed two-round forward/backward EM policy (`--max-vocab 256 --em-rounds 2`).
The E-step uses the same renewal-prefix likelihood as the marginal coder and
counts a final piece that crosses the charged raw length; rounded expected
usages are serialized as the integer token weights.  Thus the adaptation is
charged in the header and does not rely on an external model.

On the 8 KiB `web2` prefix (SHA-256
`9ed556ac0a1da5974bc6f5202f191c23f888c14c8a3740432f56210327320e59`):

```
seed, 256 pieces: MAP 5,888 B; marginal 5,785 B; headers 2,396 B
EM×2, 256 pieces: MAP 5,499 B; marginal 5,445 B; headers 2,379 B
```

The EM marginal frame is 340 bytes below the seed at this small size, while
both modes still round-trip.  On the mixed-script/invalid-byte control above,
the same EM policy gives `header=1,683`, MAP `4,381 B`, and marginal `4,216 B`
for all 14,592 bytes.  This is a bounded ablation, not a claim that EM alone
beats v4: vocabulary selection, EM rounds, and the new arithmetic wire remain
outside `plan.fit`.

For the primary 64 KiB web2 slice, the same fixed 256-piece policy gives a
larger, still bounded comparison:

```
seed:  header=2,222  MAP=33,800  marginal=32,526
EM×2:  header=2,104  MAP=31,403  marginal=30,681
EM marginal frame hash=f2c6bf8e9d38c05a5035ce6de6aeb01f69675fa4239a71dffb4dacc53fdc77c9
```

The EM marginal frame is 1,845 bytes (5.67%) smaller than the same-vocabulary
substring seed, with exact byte equality on decode.  This is the strongest
measured result in this lane, but remains a standalone weighted-emission wire;
it has not been translated into a v4 `Parse`/`plan.fit` frame.

## Complete-frame atom-circuit audit (negative control)

`atom_marginal_coder.py` implements the next bounded check: it stores every
distinct v4 atom string, quantized weights, and an arithmetic-coded atom-ID
payload.  The leaf weight is either the exact marginal segmentation mass or
the exact Viterbi mass under the *same* piece model; all header bytes and the
64-bit arithmetic flush are charged.  It decodes every ID and byte-compares
the reconstructed input.  This is a finite weighted-circuit leaf coder, not a
claim that the current tANS wire can consume a marginal directly.

```
python3 src6/experiments/bzip4/language_frontier/segmentation/atom_marginal_coder.py \
  /usr/share/dict/web2 --limit 65536 --max-vocab 2048 --json
```

```
mode=empirical header=78,558 payload=11,932 total=90,490 round_trip=true
mode=map       header=72,283 payload=18,476 total=90,759 round_trip=true
mode=marginal  header=72,342 payload=18,537 total=90,879 round_trip=true
```

The marginal leaf mass is 61 bytes of payload-equivalent arithmetic cost
worse than the MAP leaf mass, and its 59-byte larger quantized model header
makes the complete frame 120 bytes larger.  The empirical atom-frequency
control is smaller still.  This is a clean negative result for this naive
atom-leaf circuit: a large diagnostic `log-sum` gap does not automatically
survive quantization, a finite leaf vocabulary, and a charged model.  It does
not disprove a compact prefix circuit or BB-ANS, but it prevents claiming the
diagnostic gap as a v4 saving.
