# Exact restart cuts and the earlier word-aligned backend

The development artifact `geometry-gcide1m.gwp` uses the early `geometry.py`
default native word learner: 189,861 native bytes / 193,828 complete bytes.
Its 16 payload lengths range from 65,532 to 65,541 bytes; the first has
65,537 bytes. The old word learner places restart cuts on word boundaries.
It is not a faithful LaneA+M byte-block frame.

The separately named `geometry-gcide1m-strong.gwp` uses faithful LaneA+M:
184,836 native bytes / 188,803 complete bytes. All 16 payload blocks have
exactly 65,536 output bytes. The strong 8 MiB development artifact has all
128 payload blocks exactly 65,536 bytes (1,232,247 native / 1,264,120 complete).

`m_reference.zig` calls the original `m_lexicon.verifyExact` after learning.
That verifier expands each block and compares it to the exact source slice
`raw[start..min(start + block_bytes, raw.len)]`. The unchanged native compiler
sums each root's expansion length into the payload declaration. Consequently
these verified graphs preserve byte cuts through compilation. The context
reparser also checks its input graph against those exact source cuts.

The new fixed-original-page WPG2/GWT1 readers intentionally reject payloads
above 65,536 bytes. This is compatible with their declared faithful M
encoder policy; accepting legacy word-aligned frames would require a
separate interval mapping and resource policy. No frozen reader or learner
was changed to accommodate the obsolete geometry artifact.

`../evidence/restart-boundary-compatibility.json` records exact artifact
hashes and all lengths from the frozen native inspector. This investigation
used development artifacts only. Payload integrity still requires decode;
metadata inspection alone does not check all payload CRCs.
