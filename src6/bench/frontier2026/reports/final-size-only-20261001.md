# Frontier 2026 final-set size results

Status: **complete size and correctness screens; no timing rankings**.

The final source-ID split includes 22 lanes: five dictionary word inventories,
five dictionary content projections, ten UD forms/prose lanes, and two
multilingual lanes. Aggregate raw bytes are 50,340,470. The candidate registry
SHA-256 is `6f393b6e970f81c7c596f883d49b46adf85d632a9f13189f9dfc45b4ca2af4f2`.

## Matched restart blocks

The complete screen contains 484 cells (22 lanes × 11 candidates × 2 block
targets). Every frame was freshly decoded and compared byte-for-byte. Native
candidates were independently extracted at every restart: 3,083 extractions
at 16 KiB and 782 at 64 KiB. The legacy BZ4 v3 row was freshly decoded and
hash-checked; all raw block boundaries were parsed and 16 uniform restart
indices (including first, middle, last when applicable) were replay-extracted.
BZ4 v3 replay cost grows with the selected block's position, so these size rows
are a legacy reference, not an equivalent direct-random-access format.

| Candidate | 16 KiB frame bytes | Ratio | 64 KiB frame bytes | Ratio |
|---|---:|---:|---:|---:|
| BZ4 v3 lexical reference | 6,227,518 | 0.1237 | 6,170,568 | 0.1226 |
| WGP5 auto-MDL | 7,355,652 | 0.1461 | 7,151,702 | 0.1421 |
| WGP5 fast | 7,432,886 | 0.1477 | 7,271,664 | 0.1444 |
| SBWT Unicode-MDL | 8,047,508 | 0.1599 | 7,691,844 | 0.1528 |
| SBWT surface-choice | 8,177,514 | 0.1624 | 7,803,183 | 0.1550 |
| SBWT auto-MDL | 8,173,014 | 0.1624 | 7,855,367 | 0.1560 |
| SBWT fixed | 8,208,874 | 0.1631 | 7,913,692 | 0.1572 |
| bzip3 1.5.1 | 10,762,471 | 0.2138 | 8,499,937 | 0.1688 |
| bzip2 -9 | 10,735,468 | 0.2133 | 8,734,870 | 0.1735 |
| xz -9 extreme | 11,205,884 | 0.2226 | 9,350,996 | 0.1858 |
| zstd -19 | 11,133,866 | 0.2212 | 9,515,621 | 0.1890 |

WGP5 auto-MDL is the strongest new candidate by size in both matched rows. It
is about 31–34% smaller than stock controls at 16 KiB and 16–25% smaller at
64 KiB. BZ4 v3 remains 13.7–15.3% smaller than WGP5 auto-MDL, with the access
policy caveat above.

## One-frame whole-input controls

Whole-input is a separate policy: each lane is one independently checked
frame, with its full 32-byte header and 16-byte one-record directory charged.
The 22 lanes were captured in two completed screen batches (17 content/prose
lanes and five word-inventory lanes). All 88 cells passed full decode and
single-record extraction.

| Native control | Total frame bytes | Ratio |
|---|---:|---:|
| bzip3 1.5.1 | 5,862,542 | 0.1165 |
| xz -9 extreme | 6,727,828 | 0.1336 |
| zstd -19 | 6,995,626 | 0.1390 |
| bzip2 -9 | 7,255,251 | 0.1441 |

These whole-input control sizes are not directly ranked against 16/64 KiB
restart rows: whole input avoids per-restart overhead and reset boundaries.
Screen-clock fields are diagnostic observations only.

## Timing status

The attempted paired timing capture was interrupted before any candidate cell
was committed to `results.json`; its raw logs are retained for diagnostics at
`/workspace/scratch/frontier2026-final-timing-20261001/`. Do not use them for
performance claims. A fresh serial timing capture is required for codec speed
comparisons.

## Raw evidence

- Matched restart screen: `/workspace/scratch/frontier2026-final-size-20261001/`
- Whole-input controls, 17 content/prose lanes:
  `/workspace/scratch/frontier2026-final-whole-size-20261001/`
- Whole-input controls, five word-inventory lanes:
  `/workspace/scratch/frontier2026-final-whole-words-size-20261001/`
