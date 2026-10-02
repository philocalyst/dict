# Standalone whole-file lexical order codec

## Scope

This is a separate bet for book prose and for FreeDict/GCIDE, where the
WPG2 local record donors rarely fire. It models **which exact word comes
next** in a long stream. The sibling structural codec owns phrasal template
slots and first-use productive word forms; this experiment does not store
phrase skeletons or generate words from latent morphology.

## Exact representation

Split valid UTF-8 into Unicode letter/mark/number word runs and intervening
separator runs. Long non-ASCII runs split after eight scalars or 32 bytes, so
CJK prose does not become one enormous type. Invalid UTF-8, markup,
punctuation, spacing, and line endings remain literal bytes in their exact
positions; an empty separator represents adjacent word chunks. The archive
declares its decoded byte count and CRC. Word and separator dictionaries are
built by the encoder from that file and fully transmitted or learned online
by both sides; no external vocabulary or weights are assumed. One quality
profile carries context across the whole file. A separate reset profile can
later pay page indexes and reset state if access matters.

Unicode category boundaries are an encoder choice: the archive transmits
each exact token's bytes and placement, so its decoder needs no external
Unicode property database. The screen records the category-table version;
the native encoder will use a fixed, source-pinned tokenizer and can always
fall back to byte literals for malformed input.

## Causal word prediction

Start with a complete static word-ID + separator-ID code as a baseline,
charging spelling inventory and symbol frequencies. Then add deterministic
online predecessor-word caches: last successor and a bounded top-K successor
list for previous one, two, or three word IDs. At each eligible position,
encode a hit/rank decision; on miss code the exact global word ID. The
context cache and its admission/update rules are fixed, bounded, and fully
reconstructed from prior decoded IDs. No per-context learned table is free.
New words use a paid byte spelling path, and the corresponding ID is inserted
at the same deterministic point on both sides. Arithmetic/Huffman codes and
all model descriptions are included in the frame.

The decoder needs only the encoded lexicon/model plus bounded context state.
The encoder may search context orders and cache widths, but every resulting
candidate must be a complete frame; the chosen mode is explicit in the
wire. Exact full-output and malformed-input bounds precede any storage
comparison.

## Decision gates

1. Compute an **online prequential entropy screen** on development-only book
   and dictionary sources. It charges first-use spelling, separator bytes,
   hit/miss decisions, and global fallback IDs; it cannot claim wire bytes.
2. Build a self-contained native range/Huffman frame with raw, order-0,
   and contextual candidates. Compare the complete frame to pinned one-block
   bzip3 and WPG2 on the same exact source, including the independent full
   decoder and all dictionary/model/header/CRC bytes.
3. Only if the development book result is material, test longer books and
   multilingual development corpora. No held-out final corpus may influence
   tokenization rules, context admission, cache width, or mode selection.

The main falsifier is that high-order contexts may repeat too rarely in
literary prose, while the word spelling inventory and separator stream may
cost more than BWT already saves. If the prequential estimate leaves no
clear whole-frame margin, implement another phrase-scale model instead of
optimizing a weak cache by tiny parameter grids.
