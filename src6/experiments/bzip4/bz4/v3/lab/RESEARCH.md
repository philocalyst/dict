# What the literature says that matters to bz4 (2026-09-20)

Six scouts read primary sources; this is what survived contact with our
constraint (a decoder that never adapts a probability). Numbers are the
sources' own; "LTCB" is mattmahoney.net/dc/text.html.

## Where the ceiling is

| compressor | enwik8 | decode | kind |
|---|---:|---:|---|
| zstd -22 / brotli -11 / xz -9 | 25–27 MB | 0.2–1.5 GB/s | LZ + static tables per block |
| bzip3 -b511 | 20.75 MB | ~7–25 MB/s | BWT + order-0/1 CM with fixed mixing weights + SSE |
| **GLZA 0.12** | 20.07 MB | ~106 MB/s | grammar, in-band definitions, MTF queues, order-1, adaptive coder — our closest relative |
| ppmd / deplump (sequence memoizer) | ~21 / 20.8 MB | slow | adaptive unbounded-order |
| paq8l / cmix v21 / nncp / ts_zip | 18 / 14.6 / 14.9 / ~13.8 MB | 1.5 KB/s – 1 MB/s (GPU) | context mixing, neural |
| Chinchilla-70B (Delétang et al.) | 8.3 % of enwik9 | — | the bound nobody can ship |

Nothing that decodes above 100 MB/s is below 20 MB. "−20…30 % against
bzip3" on plain prose is paq8/cmix territory, five orders of magnitude
slower than our decoder. On *structured word corpora* the gap is ours to
take, because generic byte models do not see words, records or sortedness.

## Ideas that transfer (and what we did with them)

* **Every fast production codec freezes its tables per block** (zstd FSE +
  "repeat" mode, Brotli context maps: 64 literal contexts from two bytes
  through fixed LUTs, Oodle Leviathan: 16 literal streams keyed by the
  previous byte's high nibble, >800 MB/s). Adaptive per-symbol modelling
  (LZNA, LZHAM, LZMA) costs an order of magnitude in decode speed. Our
  rows are the same idea taken to a transducer. Duda's ANS paper (§3.7)
  already notes tables can be switched per symbol; storing the next table
  *in the cell* appears to be new.
* **ROLZ / symbol ranking (SR2: three candidates per order-4 context, hit
  ⇒ 1–3 bits) have never been shipped with static probabilities.** We
  measured the word-level version (`c_ctx.zig`): +3–5 % only, because a
  phrase grammar already is the chain rule over exact contexts. Dropped.
* **GLZA's gains over plain grammars come from recency queues** (MTF for
  symbols with ≤ 15 occurrences, a 7-tier "MTFG" for the rest) plus
  capital-encoding. Our past buckets are the static equivalent of the
  queues: no moves, no counts, distance tiers.
* **Bursts are real and not predicted by frequency**: Church 2000 —
  P(second mention) ≈ p/2, not p²; adaptation ratios 40–1500× for content
  words, ~2× for function words. Altmann et al. 2009: inter-arrival times
  are stretched-exponential. Supports pricing the past by distance tier
  per row, which is what the priced walks do.
* **Kneser–Ney's lesson is free for us**: lower-order distributions should
  count contexts, not tokens. Because our counts are taken from the events
  actually coded in each row, a token the past always serves stops
  weighing on its bucket (`plan.fit` replans on measured bucket uses).
* **Two-stage models (Goldwater, Griffiths, Johnson): generator + cache.**
  DEF is "new table, draw from the generator (spelling)"; USE is "sit at an
  existing table". The spelling generator is where we are weak.
* **Word order carries ~3.3–3.6 bits/word in every language family**
  (Montemurro & Zanette 2011). Our class bigram recovers ~1.8 of them on
  freedict's prose; the rest needs more data than 1 MB of prose holds.
* **Tokenisation research**: fewer tokens is *not* better for a fixed-size
  predictor (PathPiece, 64 trained LMs); balanced token frequencies are
  (Zouhar et al., Rényi efficiency α≈2.5); crossing whitespace helps
  (SuperBPE: −33 % tokens and better models); Morfessor's MDL is exactly
  our lexicon cost + corpus cost. Lane L's failure (order-0 objective ⇒ 4×
  too deep a lexicon) is the same finding from the other side.
* **Optimal parsing against frozen statistics** (LZA: build stats with a
  cheap parse, smooth, then DP once; +1–2.6 %). Our prices are exact after
  one walk, so the learner should do the same with real prices.
* **Bits-back for multisets** (Severo et al.): saves up to log₂ n! bits on
  an unordered collection. First-use-free definitions already collect most
  of this for the lexicon; nothing to add.
* **Interleaved / SIMD ANS** (ryg_rans: ~3× from 8 lanes; Recoil: decoder-
  adaptive splits, 11 GB/s on 16 cores). Open for us: N cursors over one
  stream with per-lane rows. Not needed yet at 0.4–1 GB/s single-thread.

## Not transferable

Neural predictors at any size (L3TC, the fastest, decodes 1–4 MB/s on an
NPU/GPU); trigger pairs (state explodes); adaptive SSE/APM (no static
version exists in the literature; the static analogue is simply more rows).
