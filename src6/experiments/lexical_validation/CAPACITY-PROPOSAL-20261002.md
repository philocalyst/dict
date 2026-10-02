# Uniform capacity-only follow-up proposal

Status: proposed, not executed. The first fixed validation remains authoritative
under its original bounds, including the Arabic and Japanese `WorkLimit`
failures. No compression policy may change in this follow-up.

The proposed profile keeps the 32 MiB canonical packet aggregate and decoded
literal pool, 64 MiB frame, 65,535 roots, 8,192 models, native-v3 schema, all ten
candidate options and their order, both selectors and ties, transmitted wire,
source checkpoint and every whole-record source/group unchanged. It changes
only three resource ceilings: lexemes from 100,000 to 500,000, absolute entropy
events from 8,000,000 to 128 MiB, and native/dictionary work from 64,000,000 to
128 MiB. Per-root input/allocation/slice/depth and semantic limits stay fixed.
The new capacity still rejects inventories above 500,000 distinct lexemes;
this is an explicit bounded profile, not a promise to accept every 32 MiB input.

These ceilings follow the wire's existing operand bounds. Let C be the sum of
canonical packet bytes, B the unique decoded literal bytes, K the distinct
lexemes and S the sum of byte-string occurrence lengths in canonical values.
C and B are at most 33,554,432, K is at most 500,000 and S is at least B.
Lexeme IDs occupy at most three varint events; pool lengths, copy lengths,
starts and backward distances occupy at most four.

The typed grammar serializes scalars, tags, lengths, optional markers and
default masks identically to native packet v3. Only a byte-string field changes
from length-plus-bytes to an ID. Its ID costs at most three times its original
length varint. Thus typed root events are at most 3(C-S); packet headers make
this conservative. The ordinary packet-root profile costs at most three events
per root instead.

For causal surfaces, a copy consumes at least six output bytes and costs at most
nine events (opcode, distance and length). Each literal run costs its bytes plus
at most five overhead events; there are at most K plus the number of copies
literal runs. Every lexeme length costs at most four events. Consequently the
surface stream has at most (7/3)B + 9K events. Earlier-lexeme copies consume at
least twelve bytes, giving the tighter (17/12)B + 9K bound. Literal-only surfaces
cost B + 4K. These are bounds on the unchanged encoder, not new parsing rules.

For typed candidates, combined model-training events are therefore at most
3(C-S) + (7/3)B + 9K <= 3C + 9K = 105,163,296. For packet-root candidates the
looser surface bound plus 3*65,535 is below 82,990,280. The dictionary's paid
output bytes plus entropy events are below 116,348,108. All fit within the
proposed 134,217,728 ceiling without using any heldout compression outcome.
Native structural work remains independently bounded; this argument does not
remove that admission limit or predict allocator peak memory.

Implementation must be additive: copy the independently audited owned source
snapshot into a new capacity directory and change only these resource constants
and the corresponding runner profile. Retain a machine-readable exact diff,
source/binary/old-core hashes, tests and this protocol before fresh fits. Re-encode
the unchanged two DEV sources and require all twenty complete candidate frames
to equal their retained bytes, with every full native/source/root/headword/group
gate repeated. A changed DEV frame is a hard failure, never a tuning signal.

After independent registration and audit, run all three complete reserved
sources once with the same ten candidates and both complete backend scopes.
Retain new failures, fully charge all trials and resident stock/model/index
costs, and stop. A capacity repair is not a compression improvement. The first
fixed failures and the measured Turkish size loss remain in the final ledger.

The evidence linkage is the corrected source freeze
`1f524079af2a999550f0cf2c633cf6db16bdc6ee41a4b6d48d621fe7ccdced84`,
source checkpoint
`064e8b9d65c249dcf0d424bcd8a2b98fd0e3fa9ae483dc07e3ce5ef6fa0e3fbf`
and first fixed ledger
`a81f59055a0261b511100328096946b8c618bfce45aba60370b3b25c8b4687da`.
