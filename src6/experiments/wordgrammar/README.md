# WordGrammar 5: a shared source with local surface arguments

WGP5 is an experimental, native, exact-byte compressor. Its shared grammar emits recurring fragments; an independent restart block can also emit a copy of an earlier output surface. The latter makes a repeated headword or stem reusable even when its surrounding fragment segmentation changes. The decoder restores commands directly with static rANS and expands them with bounded bulk copies. It needs no external tokenizer, model, dictionary, or compression library.

The two representation choices matter together. A fixed phrase inventory is economical for common scaffolding, while a local surface reference expresses a repeated parameter without assigning every complete construction its own global phrase. The encoder jointly chooses grammar fragments and surface copies using their delivered source probabilities. A second fit/reparse step prices the copy's length and distance under its actual parameter models too. This composition is the hypothesis under test; Re-Pair, Viterbi parsing, LZ output references, finite-state context models, and rANS are established methods.

## Build and interface

```sh
make -C src6/experiments/wordgrammar
src6/experiments/wordgrammar/wordgrammar encode-fast INPUT OUTPUT [BLOCK_BYTES]
src6/experiments/wordgrammar/wordgrammar encode-auto INPUT OUTPUT [BLOCK_BYTES]
src6/experiments/wordgrammar/wordgrammar decode FRAME OUTPUT [BLOCK_INDEX]
src6/experiments/wordgrammar/wordgrammar inspect FRAME JSON_OUTPUT
make -C src6/experiments/wordgrammar test
make -C src6/experiments/wordgrammar sanitize
```

The implementation requires C++17 and POSIX `getrusage`/environment functions. The default and maximum raw restart is 65,536 bytes; 16,384-byte restarts are also supported. `decode` without an index reconstructs the whole file. A zero-based index reconstructs one independent restart. `inspect` validates header, model and directory bounds and reports exact offsets and paid byte totals; payload entropy, copies and checksums are verified by decoding. Final comparisons require a fresh full decode and fresh extraction of every restart.

`encode-fast` freezes one policy: at most 16,128 pair rules, phrases at most 128 bytes, minimum pair count 8, 32 learned predecessor classes, two class-fit rounds, a 24-bit local-row inclusion threshold, two extra joint parse/refit rounds, and 14-bit class rANS precision. Copies have a minimum length of 6, maximum length 4,096, a four-byte hash, and at most 16 candidate predecessors. Six delivered byte models code length/distance varints by argument kind and byte position. A delivered zero-order byte rANS model compresses the complete shared header.

`encode-auto` evaluates the same policy at rule capacities `0, 128, 512, 2048, 8192, 16128`, then emits the smallest complete frame. Ties choose the first capacity. The candidate set is identical for every input. Its reported time pays for all six searches. The chosen frame itself delivers its grammar and source; a decoder does not reproduce this search. Auto accepts only the optional restart size. This slow encoder avoids forcing a large phrase inventory onto a sorted word list that mostly benefits from prefix copies.

Both profile commands normalize all consulted experimental environment options, including setting the class precision to 14; inherited `WGR_*` overrides cannot silently change their policy. The legacy `encode` command and environment controls remain for reproducible ablations. Additional numeric options on `encode-fast` are explicitly experimental overrides; the frozen benchmark command passes only the restart size. See [protocol.json](protocol.json) for the exact policy and source/binary fingerprints.

## Stored source and execution

1. A linked occurrence learner merges byte pairs within raw restart boundaries. The inventory is shared across the file. Learned phrases are topological binary productions; preparation flattens each phrase once within a checked dictionary budget.
2. Root transitions train a finite-state source: every preceding symbol has a delivered class; each class has a sparse local distribution and escape to the global distribution. Class assignment uses successor distributions, independent of English labels. All 256 literal bytes remain available.
3. A trie enumerates grammar fragments. A bounded match finder proposes earlier output surfaces. Exact Viterbi search over `(byte position, previous source class)` selects the command stream. The encoder then refits and reparses twice, including the delivered probability of each parameter byte.
4. The frame stores the grammar, class map, normalized frequency rows, parameter models, compressed-header model, restart directory, rANS states, parameters and block checksums. All are charged.
5. A decoder prepares the supplied model, restores commands in output order, bulk-copies a grammar expansion or an earlier surface, checks exact output size, verifies FNV-1a, and requires both rANS streams to terminate exactly.

No Unicode normalization is performed. Combining marks, casing, diacritics, invalid UTF-8, whitespace, mixed scripts and binary bytes round-trip exactly. Initial classes use a coarse byte-end grouping as a seed; the delivered fitted classes determine actual prediction. No morphology or language inference is claimed from this grouping. Copied arguments preserve surfaces rather than discarding any linguistic information.

## Bounds and practical limits

The encoder checks the file size before allocation and caps input at 64 MiB. Before grammar learning, a conservative estimate of `64 × raw bytes + joint-parse arrays + 64 MiB` must fit a 4 GiB work budget. The joint parser also checks its dominant arrays against a 128 MiB budget before allocating. These are explicit estimates, not an operating-system memory quota; they allow the 22 MiB whole-OMW confirmation scope. Grammar learning retains input-sized arrays and occurrence lists; compression uses substantially more memory than decompression. Both encoder and decoder cap raw restarts at 64 KiB, keeping distances within the three delivered varint-byte contexts and bounding per-block Viterbi scratch. The native decoder caps the frame at 512 MiB, raw output at 256 MiB, expanded shared header at 16 MiB, total flattened phrases at 32 MiB, phrases at 4,096 bytes, rules at 16,128 and classes at 64. The frozen encoder uses the tighter 128-byte phrase and 32-class limits. References are strictly backward, copy distance/output bounds are checked, varints are canonical, row frequencies sum exactly, and expansion is iterative.

File commands materialize the complete frame, and selected-block commands prepare the shared model anew and scan the directory. Those startup costs are included in `codec_ns`. A reusable prepared-model API and mapped directory would be useful future work; current cold selected-block latency must be measured as implemented. FNV-1a detects ordinary reconstructed-output corruption. The format does not authenticate metadata: a modification to an unused model description can still decode to the identical original bytes.

The stderr JSON reports `codec_ns` for complete encode or decode, excluding file reads/writes. Encode includes learning, all parsing/refitting, entropy coding and header packing; auto includes every candidate. Decode includes header/model preparation, command reconstruction, expansion and checksums. `peakrss_kib` is process peak RSS on Linux and includes file buffers. `model + directory_bytes + root_payload_bytes + copy_parameter_bytes` equals the actual frame size. Inspect separately reports `model_bytes + directory_bytes + payload_bytes` and per-restart offsets.

## Evidence and research basis

[RESULTS.md](RESULTS.md) preserves the development findings and rejected directions. Those screening times were collected while other agents were running and are provisional. The independent post-freeze harness, including every restart and untouched confirmation data, establishes final performance. Development records predating the frozen source hash must not be presented as measurements of the final binary.

The research basis includes [Larsson and Moffat's grammar compression](https://doi.org/10.1109/DCC.1999.755679), [Duda's asymmetric numeral systems](https://arxiv.org/abs/1311.2540), [Sennrich et al.'s subword units](https://aclanthology.org/P16-1162/), [Kudo's unigram segmentation model](https://aclanthology.org/P18-1007/), and [Delétang et al., Language Modeling Is Compression](https://arxiv.org/abs/2309.10668). These motivate sharing exact recurring pieces and pricing alternative derivations under a source. This experiment delivers small integer probability tables rather than a neural model at decode time. It measures complete files rather than subtracting a tokenization entropy estimate from another codec's output.
