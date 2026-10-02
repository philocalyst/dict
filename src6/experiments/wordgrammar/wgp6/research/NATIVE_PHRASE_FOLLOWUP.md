# Native-priced phrase follow-up

Status: research hypothesis only. The standalone order-0 phrase-MDL parse
replaces the current greedy learner poorly on all three retained 1 MiB DEV
corpora: FreeDict is 83,807 bytes (native 82,873; maximal spelling DAG
81,400), GCIDE 205,574 (197,039; 195,631), and OMW 55,416 (49,619; 46,474).
Those results reject its surrogate objective as a selection rule; they do not
reject native-priced local phrase alternatives.

## Why the surrogate missed

`phrase_mdl.hpp` estimates a unigram token cost and charges new rules with
ULEB IDs, arity, and child IDs. The bz4 learner's actual event cost is a
fitted automaton: a row and symbol determine a price and successor row, and
the planner assigns tokens to classes and buckets. The past is also part of
the model. The v4 design gives each stream a 4096-token history; a copy uses
the original token's successor row. A phrase edit can change both the row
path and which expanded tokens enter that history. Thus a per-type scalar
price misses real savings and a DP that treats edges independently can
misprice later references. Definitions also pay through the codec's real
ARITY/child/NAME path, not through the research header's ULEB estimate.

## One implementable next probe

Keep the present greedy parse as the starting point and search only bounded
maximal repeated intervals in that parsed stream, fenced exactly as the
baseline. Fit the existing native planner once and export, for every
reachable compiler row and candidate symbol/reference, the exact event price
and successor row. Price a candidate's first use by running its actual
definition through the same compiler path, including nested child events,
ARITY, and NAME; price later uses as native references. For proposal scoring,
replay the baseline past-cache trace at each occurrence and update it with
the candidate's exact expansion. Recompute those traces after every accepted
edit, since an accepted phrase changes future cache contents and recency.

Use these stateful prices in a bounded interval tiler (or a small beam over
overlapping intervals). Do not build a free occupied-pair table: candidate
spans come from repeated intervals in the current source, and every retained
definition is serialized by the existing grammar path. A frozen baseline
trace is only a proposal score; accept an edit only when a fresh complete
native plan/encode/decode round produces fewer bytes. This keeps planner
changes and model-table changes in the final gate. Start with one add-only
round after greedy phrase learning, then stop if it cannot improve the
complete frame. It is a small, falsifiable test of whether native successor
and cache costs rescue a few missed long intervals, not a reason to rerun
the rejected global order-0 tiler.

## Morphology and cache outlook

General stem/tail factorization is unlikely to beat whole-word identity by
itself. The retained direct-factor inventory screen lost on every 1 MiB and
8 MiB slice after charging front-coded stem/signature tables and paired
occurrence operands; the native spelling-DAG results also show that the
existing whole-word identity plus recent-surface machinery is already a
strong control. A native model could reduce some paired-event cost through
conditional rows or a repeated generated surface in the past, but that gain
must exceed the extra stem/tail events, class tables, and factor-map cost.

The only plausible morphology probe is sparse and fallback-safe: propose
exact stem/tail families from observed repeated substrings, factor only a
family whose *native* conditional savings pay its tables and every emitted
operand, and leave all other forms as identity literals. Do not transmit a
per-word or occupied-pair list; occurrences emit the stem and tail operands
directly, so any combinations allowed by the delivered class map are
decodable. Include the full native past recurrence and complete archive
length in selection. If that charged test does not beat the spelling-DAG
control, the measured evidence favors retaining identity spelling and
spending the remaining search budget on native-priced interval edits.
