# Causal marginal copy, SCM3

Predeclared before implementation. This combines classical context prediction
and latent copy continuation; it is not a novelty claim for PPM, DMC or LZ.

At decoded prefix H, hidden state is escape E or source offset j<|H|.
Posterior masses are integers summing to Q=65536. Copy state j survives with
s=15/16 (fixed), or s=1-1/(4+min(age,60)) (confidence). Its remainder joins E.
Unavailable j joins E. E starts a copy with rate r in {1/4,1/2,3/4}, provided
context matches exist; otherwise all E emits through literal distribution L.
Starts choose decoded historical continuations matching suffix contexts of
lengths 2,4,8. Policy longest uses longest available context; blended assigns
occurrence weights 1,2,4 by matching context length. Each context retains only
its most recent K occurrences. Within a context occurrences have equal mass.
Duplicate offsets merge. Contexts with more retained occurrences consequently
have more start mass under blended initialization.

L starts with order-zero add-one byte counts (uniform before first byte).
For suffix orders 1,2,4 with observations c_b, recursively replace L by
1+normalize(Q*c_b + 16*L_b, Q-256). This is a Dirichlet backoff prior of
strength16 plus a quantized minimum byte mass;
missing suffixes leave L unchanged. Each normalization uses floor plus
deterministic largest remainder to sum to Q (byte order resolves ties).
Copy masses emit H[j] deterministically;
literal mass emits L. Sum these to one byte distribution. Arithmetic CDF has
one count per byte plus floor of probability times 65280; this is a normalized
positive distribution after its explicit count total is computed.

After observing byte b, matching copy mass advances j to j+1 and age+1;
literal mass times L[b]/Q joins E. Normalize surviving masses to Q. Retain
largest K offsets (ties newest first), moving discarded mass to E. Equal
offsets merge exactly; age uses maximum age, a deterministic approximation
whose future prediction cost is measured. Zero rounded entries vanish.
Only then append b and insert completed contexts into historical indexes.
The posterior update is an integer projection of the pre-CDF latent source,
not exact Bayes under the additionally quantized CDF. The actual generative
law is precisely the normalized positive integer CDF followed by this
deterministic update; approximation costs future predictions, never decoding.
No future continuation byte is inspected. Index j is recorded only after its
continuation byte was decoded, preventing j=|H| seeds. All models restart at
charged block boundaries. Control disables all starts and continuations but
uses identical literal source, arithmetic coder and frame.

Grid: 2 initialization policies × 2 K (8,32) × 2 survival policies × 3 start
rates = 24. Screen all at 2048 bytes on frozen development inputs. Freeze
top three aggregate complete-byte policies; confirmation uses 16384 and
65536 development prefixes, not reserved TRAIN confirmation resources.

Frame contains magic/version, all four policy parameters, block size, raw
length, raw SHA256, and per block raw/payload lengths, payload CRC32 and
arithmetic payload.
Lengths, padding, checksum, selectors and restarts count. Decoder enforces
output budget and exact framing; checksum rejects arithmetic padding damage.
Blocks are capped at64KiB; outputs at8MiB. Index and literal tables grow
linearly in block length, despite a bounded copy posterior. Each input offset
creates at most three index keys and four literal keys; each context's retained
occurrences are capped at K. These costs are reported explicitly.
This is a Python source-quality experiment, not a native speed claim.

SCM1 diagnostic frames used sparse literal add-one counts and no payload CRC;
SCM2 added CRC. SCM3 changes the source to recursive backoff and imposes bounded
block/output limits. Earlier frames are intentionally rejected by SCM3.
