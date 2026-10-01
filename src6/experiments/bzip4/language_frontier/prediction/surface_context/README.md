# Contextual surface quotient

This is a bounded research wire for a token-class source, not a v4 change.
At a token boundary with class `c`, the source draws `t` from a positive
integer row `P(t|c)`, emits the exact bytes of `t`, and sets the next class to
the serialized deterministic transition `g(t)`.  The marginal decoder sums
all compatible tokenizations and class paths.  Its trie frontier stores, for
each live token-prefix node, a vector of mass indexed by the token's origin
class; terminal mass is routed through `g(t)`.  Thus the class is not a
script/case hand label and no future source byte is used by the decoder.

The MAP path and marginal surface-byte modes use the same serialized token
surfaces, class IDs, row frequencies, raw length, and E3 arithmetic policy.
The only mode difference is whether the payload codes a contextual token ID
path or the marginalized next-byte CDF.  A final token may cross the charged
raw-length boundary in both modes and is truncated only at that boundary.

`codec.py` enforces the bounded frame (`raw <= 64 KiB`, `<=4096` tokens,
`<=32` bytes/token, charged model header and payload) and has an independent
`decode_frame`.  `adapter.py` exposes the root quickbench API:

```python
frame = encode(raw, block_bytes=65536, mode="marginal")
restored = decode(frame)
```

The adapter fits its model from the exact raw block, so there is no unpaid
external training model.  The marginal frontier uses floating beliefs and
then quantizes each CDF to a fixed 20-bit positive integer row; arithmetic
round trips are exact on the host, but cross-architecture bitwise frame
portability is explicitly not claimed until that belief calculation is made
canonical.

## Frozen policy and screen

The policy was fixed for the three-row screen before inspecting the results:

* train on a 64 KiB slice;
* keep all 256 singleton bytes;
* deterministic non-overlapping byte BPE, maximum 384 total tokens,
  maximum surface length 32, minimum pair count 4;
* fit `g(t)` by six deterministic Lloyd iterations on sparse next-token
  continuation signatures from the encoder-only seed Viterbi path;
* fit positive class rows with add-one counts from that same path;
* compare `C=1` iid and `C=4` contextual models with identical inventory
  policy and complete headers.

The screen used the first 64 KiB of `web2` as training and the next 64 KiB as
evaluation; FreeDict and OMW used the first 64 KiB of their frozen `.train`
files and first 64 KiB of `.eval8` files.  This is intentionally labelled
separately from same-input quickbench fitting.  No confirmation/train20 or
untouched bytes were used, and no native timing command was run here.

| input / model | tokens | header B | MAP frame B | marginal frame B | MAP exact bits | marginal exact bits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| web2-next64k C=1 | 384 | 1,941 | 35,302 | 34,966 | 266,831.45 | 264,165.09 |
| web2-next64k C=4 | 384 | 3,094 | 36,358 | 36,034 | 266,058.37 | 263,489.91 |
| FreeDict C=1 | 384 | 4,036 | 24,300 | 23,933 | 162,062.12 | 162,060.16 |
| FreeDict C=4 | 384 | 5,186 | 25,305 | 24,938 | 160,897.27 | 160,892.86 |
| OMW C=1 | 384 | 3,564 | 33,016 | 32,897 | 235,563.42 | 235,439.17 |
| OMW C=4 | 384 | 4,721 | 33,780 | 33,664 | 232,420.93 | 232,302.69 |

The contextual rows lower diagnostic model NLL, but the charged four-row
header costs 764--1,153 additional bytes and leaves every complete C=4 frame
larger than its C=1 control.  This rejects this small class clustering policy;
it does not reject a better global parse, v4 past-bucket interaction, or a
different charged state quotient.

## Reproduction

```sh
cd src6/experiments/bzip4/language_frontier/prediction/surface_context
python3 test_codec.py
python3 screen.py --json
```

The exact six-row JSON summary, input/model hashes, frame hashes, commands,
and host are retained in `results/screen_summary.json`.  The root quickbench
can import `adapter.py` without modifying the native codec.

