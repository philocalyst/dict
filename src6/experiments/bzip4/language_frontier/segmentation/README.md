# Segmentation lane artifacts

This lane owns only this directory.  The initial best-path unigram/interval
prototype (`unigram_interval.zig`) is retained as a control; the bleeding-edge
experiment is exact latent segmentation marginalization.

Files:

* `PROPOSAL.md` — pre-implementation mechanism, contrast, and cheap reject
  gate.
* `marginal_gap.py` — exact bounded Viterbi-vs-forward diagnostic with an
  exhaustive tiny oracle.  It does not claim frame bytes.
* `weighted_emission_coder.py` — complete charged weighted piece-emission
  automaton: trie-frontier MAP token-path and marginal surface-byte arithmetic
  modes, E3-safe coder/parser, bounded forward/backward EM, exact short-prefix
  oracle, round-trip and truncation tests.
* `atom_marginal_coder.py` — complete charged finite atom-leaf arithmetic
  coder/decoder, including dictionary header and round-trip check.  It is an
  intentionally conservative negative control for a marginal circuit.
* `MARGINAL_GAP.md` — primary-source synthesis, raw hashes/commands, corrected
  gap measurements, and complete-frame negative evidence.
* `unigram_interval.zig` — deterministic unigram candidate/Viterbi and
  weighted interval prototype that emits the existing `bz4.Parse` shape and
  calls v4 `plan.fit`; no production source is changed.

Quick diagnostic:

```sh
python3 marginal_gap.py /usr/share/dict/web2 --limit 65536 \
  --max-vocab 2048 --mixed-control --random-control --json
```

Quick complete-frame negative control:

```sh
python3 atom_marginal_coder.py /usr/share/dict/web2 --limit 65536 \
  --max-vocab 2048 --json
```

Quick weighted-emission screen:

```sh
python3 weighted_emission_coder.py /usr/share/dict/web2 --limit 65536 \
  --max-vocab 256 --em-rounds 2 --mixed-control --json
```

The model inventory is trained only on the bytes under test.  Every result
charges its model/header; the diagnostic `log-sum` gap is never silently
subtracted from a v4 frame.  The scripts preserve invalid bytes and combining
marks exactly.  WAM frames cap raw input at 1 MiB, token vocabularies at 4096
entries, and token strings at 64 bytes; parsed frames require all 256 singleton
fallbacks and canonical arithmetic payload bits.  The prototype's floating
posterior is not yet guaranteed bitwise-portable across architectures.
