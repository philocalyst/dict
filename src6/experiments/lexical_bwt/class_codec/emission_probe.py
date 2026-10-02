#!/usr/bin/env python3
"""Price previous-class-conditioned lexical ranks on the same fixed K32 model.

This is an empirical entropy/model-cost probe, not a compressed frame. It holds
the input, tokenization, vocabulary, class assignments, exact sidecars and
class-bigram model fixed. The sole changed event is P(word | class, prevclass)
instead of P(word | class). Its full observed frequency rows are transmitted.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import pathlib

import numpy as np

from depth_probe import context_table
from estimate import (BOOKS, class_tables, cluster, entropy, model_bytes,
                      put, sidecar, tokenize, transitions, vocabulary,
                      whole_bzip3)


def rank_rows(ids, vocab, labels, k, sequence):
    # model_bytes emits vocabulary in this grouped, lexical order.
    grouped = [i for c in range(k) for i in sorted(
        (i for i in range(len(vocab)) if labels[i] == c), key=lambda i: vocab[i])]
    rank_of = {i: rank for rank, i in enumerate(grouped)}
    rows = defaultdict(Counter)
    previous = k + 1
    for word_id, current_class in zip(ids, sequence):
        if word_id < len(vocab):
            rows[(previous, int(current_class))][rank_of[int(word_id)]] += 1
        previous = int(current_class)
    bits = sum(entropy(row.values()) for row in rows.values())
    body = bytearray(put(len(rows)))
    for (previous, current), counts in sorted(rows.items()):
        body.extend(put(previous))
        body.extend(put(current))
        body.extend(put(len(counts)))
        for rank, count in sorted(counts.items()):
            body.extend(put(rank))
            body.extend(put(count))
    return bits, bytes(body), len(rows), sum(map(len, rows.values()))


def evaluate(data, book_id, k=32, cap=8192):
    control = len(whole_bzip3(data))
    words, separators, _ = tokenize(data)
    vocab, ids, counts = vocabulary(words, cap)
    k = min(k, max(1, len(vocab)))
    rare = [word for word, word_id in zip(words, ids) if word_id == len(vocab)]
    separator_bz3 = sidecar(separators)[1]
    rare_bz3 = sidecar(rare)[1]
    frequencies = np.fromiter((counts[w] for w in vocab), dtype=np.int64)
    labels, mi_history = cluster(transitions(ids, len(vocab)), frequencies, k, 4)
    sequence, masses, _, _ = class_tables(ids, labels, k)
    class_bits, class_rows, class_count = context_table(sequence, k, 1)
    static_rank_bits = sum(int(n) * math.log2(int(masses[labels[i]]) / int(n))
                           for i, n in enumerate(frequencies))
    conditional_rank_bits, conditional_rows, row_count, parameters = rank_rows(
        ids, vocab, labels, k, sequence)
    empty_rows = np.zeros((0, k + 1), dtype=np.int64)
    lexicon = model_bytes(vocab, labels, counts, empty_rows, k)
    old_model = whole_bzip3(lexicon + class_rows)
    new_model = whole_bzip3(lexicon + class_rows + conditional_rows)
    fixed = 64 + len(separator_bz3) + len(rare_bz3)
    old_ideal = fixed + len(old_model) + math.ceil((class_bits + static_rank_bits) / 8)
    new_ideal = fixed + len(new_model) + math.ceil((class_bits + conditional_rank_bits) / 8)
    free_rows_ideal = fixed + len(old_model) + math.ceil((class_bits + conditional_rank_bits) / 8)
    return {
        "book": book_id, "source_bytes": len(data),
        "source_sha256": hashlib.sha256(data).hexdigest(),
        "whole_bzip3_bytes": control, "word_occurrences": len(words),
        "selected_types": len(vocab), "rare_occurrences": len(rare),
        "class_assignment_mi_history": mi_history,
        "class_rows": class_count, "rank_rows": row_count,
        "rank_parameters": parameters,
        "class_oracle_bits": round(class_bits, 1),
        "static_rank_oracle_bits": round(static_rank_bits, 1),
        "conditional_rank_oracle_bits": round(conditional_rank_bits, 1),
        "rank_oracle_saving_bytes": round((static_rank_bits - conditional_rank_bits) / 8, 1),
        "old_model_bzip3_bytes": len(old_model),
        "new_model_bzip3_bytes": len(new_model),
        "rank_model_plain_bytes": len(conditional_rows),
        "separator_bzip3_bytes": len(separator_bz3),
        "rare_bzip3_bytes": len(rare_bz3),
        "old_optimistic_frame_bytes": old_ideal,
        "new_optimistic_frame_bytes": new_ideal,
        "new_delta_vs_whole_bzip3": new_ideal - control,
        "free_rank_rows_optimistic_bytes": free_rows_ideal,
        "free_rank_rows_delta": free_rows_ideal - control,
        "scope": "empirical entropy event oracle; all observed rank rows paid separately; no decodable frame",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, default=BOOKS)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as output:
        for book in manifest["books"]:
            entry = book["full"]
            data = pathlib.Path(entry["path"]).read_bytes()
            assert len(data) == entry["bytes"]
            assert hashlib.sha256(data).hexdigest() == entry["sha256"]
            row = evaluate(data, book["id"])
            output.write(json.dumps(row, sort_keys=True) + "\n")
            output.flush()
            print(book["id"], row["new_optimistic_frame_bytes"], row["whole_bzip3_bytes"], flush=True)


if __name__ == "__main__":
    main()
