#!/usr/bin/env python3
"""One attributable class-history depth probe with fixed learned class labels.

The same six full DEV sources, K32, vocabulary cap8192 and clustering are held
fixed; only class context depth 0..3 changes. Each observed row is serialized
and compressed with the vocabulary. Empirical event bits are still an oracle.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import pathlib

from estimate import (BOOKS, class_tables, cluster, entropy, model_bytes,
                      put, sidecar, tokenize, transitions, vocabulary, whole_bzip3)
import numpy as np


def context_table(sequence, k, depth):
    start = k + 1
    history = [start] * depth
    rows = defaultdict(Counter)
    for value in sequence:
        rows[tuple(history)][int(value)] += 1
        if depth:
            history = history[1:] + [int(value)]
    bits = sum(entropy(row.values()) for row in rows.values())
    body = bytearray(put(len(rows)))
    for history, counts in sorted(rows.items()):
        for value in history:
            body.extend(put(value))
        body.extend(put(len(counts)))
        for symbol, count in sorted(counts.items()):
            body.extend(put(symbol))
            body.extend(put(count))
    return bits, bytes(body), len(rows)


def evaluate_depths(data, book_id, k=32, cap=8192):
    baseline = len(whole_bzip3(data))
    words, separators, _ = tokenize(data)
    vocab, ids, counts = vocabulary(words, cap)
    k = min(k, max(1, len(vocab)))
    escapes = [word for word, index in zip(words, ids) if index == len(vocab)]
    sep_coded = sidecar(separators)[1]
    esc_coded = sidecar(escapes)[1]
    freqs = np.fromiter((counts[word] for word in vocab), dtype=np.int64)
    labels, history = cluster(transitions(ids, len(vocab)), freqs, k, 4)
    sequence, masses, _, _ = class_tables(ids, labels, k)
    rank_bits = sum(int(n) * math.log2(int(masses[labels[i]]) / int(n))
                    for i, n in enumerate(freqs))
    empty_rows = np.zeros((0, k + 1), dtype=np.int64)
    lexicon = model_bytes(vocab, labels, counts, empty_rows, k)
    fixed = 64 + len(sep_coded) + len(esc_coded)
    results = []
    for depth in range(4):
        class_bits, row_bytes, row_count = context_table(sequence, k, depth)
        model_coded = whole_bzip3(lexicon + row_bytes)
        vocab_only_coded = whole_bzip3(lexicon)
        oracle_events = math.ceil((class_bits + rank_bits) / 8)
        results.append({
            "depth": depth, "observed_rows": row_count,
            "class_oracle_bits": round(class_bits, 1), "rank_oracle_bits": round(rank_bits, 1),
            "context_plain_bytes": len(row_bytes), "model_plain_bytes": len(lexicon) + len(row_bytes),
            "model_bzip3_bytes": len(model_coded), "model_free_context_bzip3_bytes": len(vocab_only_coded),
            "optimistic_frame_with_rows": fixed + len(model_coded) + oracle_events,
            "optimistic_frame_free_rows": fixed + len(vocab_only_coded) + oracle_events,
            "delta_with_rows": fixed + len(model_coded) + oracle_events - baseline,
            "delta_free_rows": fixed + len(vocab_only_coded) + oracle_events - baseline,
        })
    return {
        "book": book_id, "raw_bytes": len(data), "source_sha256": hashlib.sha256(data).hexdigest(),
        "whole_bzip3_bytes": baseline, "vocab_types": len(vocab), "word_occurrences": len(words),
        "escape_occurrences": len(escapes), "separator_bzip3_bytes": len(sep_coded),
        "escape_bzip3_bytes": len(esc_coded), "mi_history": history,
        "fixed_nonmodel_bytes": fixed, "depths": results,
        "status": "optimistic empirical entropy, not real arithmetic frame",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=pathlib.Path, default=BOOKS)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    a = ap.parse_args()
    manifest = json.loads(a.manifest.read_text())
    a.out.parent.mkdir(parents=True, exist_ok=True)
    with a.out.open("w") as f:
        for book in manifest["books"]:
            source = book["full"]
            data = pathlib.Path(source["path"]).read_bytes()
            assert len(data) == source["bytes"] and hashlib.sha256(data).hexdigest() == source["sha256"]
            row = evaluate_depths(data, book["id"])
            f.write(json.dumps(row, sort_keys=True) + "\n")
            f.flush()
            print(book["id"], [(x["depth"], x["delta_with_rows"], x["delta_free_rows"])
                                     for x in row["depths"]], flush=True)


if __name__ == "__main__":
    main()
