#!/usr/bin/env python3
"""Optimistic class-code headroom screen, not a compressed frame or codec claim.

Only the encoder trains class assignments. Every model and exact surface lane is
priced as a transmitted bzip3 frame. Class/rank events get ideal empirical
arithmetic-code lengths, deliberately understating a real finite coder.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
import pathlib
import subprocess
import tempfile
import unicodedata

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
import numpy as np
from scipy import sparse
from sklearn.cluster import KMeans

BZIP3 = pathlib.Path("/workspace/scratch/bzip3")
BOOKS = pathlib.Path("/workspace/scratch/books2026-dev/first-five-manifest.json")


def put(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return out


def whole_bzip3(data):
    with tempfile.TemporaryDirectory(prefix="class-est-") as folder:
        path = pathlib.Path(folder) / "input.bin"
        path.write_bytes(data)
        p = subprocess.run((str(BZIP3), "-c", str(path)), capture_output=True, check=True)
        return p.stdout


def word_char(char):
    category = unicodedata.category(char)
    return category[0] in "LNM" or char == "_"


def tokenize(data):
    text = data.decode("utf-8", "surrogateescape")
    if not text:
        return [], [], False
    runs = []
    active = word_char(text[0])
    chunks = []
    for char in text:
        isword = word_char(char)
        if isword != active:
            runs.append((active, "".join(chunks).encode("utf-8", "surrogateescape")))
            chunks = []
            active = isword
        chunks.append(char)
    runs.append((active, "".join(chunks).encode("utf-8", "surrogateescape")))
    assert b"".join(b for _, b in runs) == data
    assert all(runs[i][0] != runs[i + 1][0] for i in range(len(runs) - 1))
    return [b for yes, b in runs if yes], [b for yes, b in runs if not yes], runs[0][0]


def sidecar(chunks):
    plain = bytearray()
    for value in chunks:
        plain.extend(put(len(value)))
        plain.extend(value)
    return bytes(plain), whole_bzip3(plain) if plain else b""


def entropy(counts):
    total = sum(counts)
    return 0.0 if not total else sum(x * math.log2(total / x) for x in counts if x)


def vocabulary(words, limit):
    counts = Counter(words)
    selected = [w for w, n in counts.most_common() if n >= 2][:limit]
    lookup = {w: i for i, w in enumerate(selected)}
    ids = np.fromiter((lookup.get(w, len(selected)) for w in words), dtype=np.int32, count=len(words))
    return selected, ids, counts


def transitions(ids, vocabulary_size):
    if len(ids) < 2:
        return sparse.csr_matrix((vocabulary_size + 1, vocabulary_size + 1), dtype=np.int32)
    matrix = sparse.coo_matrix(
        (np.ones(len(ids) - 1, dtype=np.int32), (ids[:-1], ids[1:])),
        shape=(vocabulary_size + 1, vocabulary_size + 1),
    ).tocsr()
    matrix.sum_duplicates()
    return matrix


def cluster(matrix, type_counts, k, rounds):
    size = len(type_counts)
    labels = np.arange(size, dtype=np.int32) % k
    # Frequency seeding and context co-clustering are encoder proposals only.
    best = labels.copy()
    best_mi = -1.0
    history = []
    for step in range(rounds + 1):
        mi = mutual_information(matrix, labels, k)
        history.append(round(mi, 6))
        if mi > best_mi:
            best_mi = mi
            best = labels.copy()
        if step == rounds:
            break
        assigned = np.concatenate((labels, np.array([k], dtype=np.int32)))
        onehot = sparse.csr_matrix(
            (np.ones(size + 1, dtype=np.float32), (np.arange(size + 1), assigned)),
            shape=(size + 1, k + 1),
        )
        past = (matrix @ onehot).toarray()[:size]
        future = (matrix.T @ onehot).toarray()[:size]
        # Hellinger-normalized incoming/outgoing class profiles reduce the
        # tendency to cluster only by absolute type frequency.
        past = np.sqrt(past / np.maximum(past.sum(axis=1, keepdims=True), 1))
        future = np.sqrt(future / np.maximum(future.sum(axis=1, keepdims=True), 1))
        features = np.concatenate((past, future), axis=1)
        km = KMeans(n_clusters=k, random_state=731 + step, n_init=1, max_iter=30)
        labels = km.fit_predict(features, sample_weight=np.sqrt(np.maximum(type_counts, 1))).astype(np.int32)
    return best, history


def mutual_information(matrix, labels, k):
    size = len(labels)
    group = np.empty(size + 1, dtype=np.int32)
    group[:size] = labels
    group[size] = k
    rows, cols = matrix.nonzero()
    values = np.asarray(matrix[rows, cols]).ravel()
    class_pairs = np.zeros((k + 1, k + 1), dtype=np.int64)
    np.add.at(class_pairs, (group[rows], group[cols]), values)
    total = class_pairs.sum()
    if not total:
        return 0.0
    past = class_pairs.sum(axis=1)
    future = class_pairs.sum(axis=0)
    positive = np.nonzero(class_pairs)
    joint = class_pairs[positive].astype(np.float64)
    return float(np.sum(joint * np.log2(joint * total / (past[positive[0]] * future[positive[1]]))) / total)


def class_tables(ids, labels, k):
    classes = np.full(k + 1, 0, dtype=np.int64)
    sequence = np.empty(len(ids), dtype=np.int32)
    for i, idx in enumerate(ids):
        sequence[i] = k if idx == len(labels) else labels[idx]
        classes[sequence[i]] += 1
    bigrams = np.zeros((k + 2, k + 1), dtype=np.int64)
    prev = k + 1
    for now in sequence:
        bigrams[prev, now] += 1
        prev = now
    class_bits = sum(entropy(row) for row in bigrams)
    return sequence, classes, bigrams, class_bits


def model_bytes(vocab, labels, counts, bigrams, k):
    model = bytearray()
    model.extend(put(k))
    model.extend(put(len(vocab)))
    for group in range(k):
        members = sorted((vocab[i], counts[vocab[i]]) for i in range(len(vocab)) if labels[i] == group)
        model.extend(put(len(members)))
        previous = b""
        for spelling, frequency in members:
            common = 0
            while common < min(len(previous), len(spelling)) and previous[common] == spelling[common]:
                common += 1
            model.extend(put(common))
            model.extend(put(len(spelling) - common))
            model.extend(spelling[common:])
            model.extend(put(frequency))
            previous = spelling
    # Full observed bigram rows: a real coder can prune them later, but they
    # are explicitly charged here instead of assuming an invisible context LM.
    for row in bigrams:
        nonzero = np.flatnonzero(row)
        model.extend(put(len(nonzero)))
        for symbol in nonzero:
            model.extend(put(int(symbol)))
            model.extend(put(int(row[symbol])))
    return bytes(model)


def evaluate(data, book_id, k=32, cap=8192, rounds=4):
    raw_control = whole_bzip3(data)
    words, separators, starts_word = tokenize(data)
    vocab, ids, counts = vocabulary(words, cap)
    k = min(k, max(1, len(vocab)))
    escaped = [w for w, idx in zip(words, ids) if idx == len(vocab)]
    sep_plain, sep_coded = sidecar(separators)
    esc_plain, esc_coded = sidecar(escaped)
    matrix = transitions(ids, len(vocab))
    type_counts = np.fromiter((counts[w] for w in vocab), dtype=np.int64)
    labels, mi_history = cluster(matrix, type_counts, k, rounds)
    classes, mass, rows, class_bits = class_tables(ids, labels, k)
    word_counts = np.fromiter((counts[w] for w in vocab), dtype=np.int64)
    rank_bits = sum(int(n) * math.log2(int(mass[labels[i]]) / int(n))
                    for i, n in enumerate(word_counts))
    plain_model = model_bytes(vocab, labels, counts, rows, k)
    coded_model = whole_bzip3(plain_model)
    optimistic_frame = 64 + len(sep_coded) + len(esc_coded) + len(coded_model) + math.ceil((class_bits + rank_bits) / 8)
    return {
        "book": book_id, "raw_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        "whole_bzip3_bytes": len(raw_control), "word_occurrences": len(words),
        "separator_runs": len(separators), "starts_word": starts_word,
        "selected_types": len(vocab), "escape_occurrences": len(escaped),
        "class_count": k, "class_mi_bits_per_transition_history": mi_history,
        "ideal_class_bigram_bits": round(class_bits, 1),
        "ideal_within_class_rank_bits": round(rank_bits, 1),
        "vocab_and_context_plain_bytes": len(plain_model),
        "vocab_and_context_bzip3_bytes": len(coded_model),
        "exact_separator_plain_bytes": len(sep_plain),
        "exact_separator_bzip3_bytes": len(sep_coded),
        "exact_escape_plain_bytes": len(esc_plain),
        "exact_escape_bzip3_bytes": len(esc_coded),
        "optimistic_frame_bytes": optimistic_frame,
        "optimistic_delta_vs_whole_bzip3": optimistic_frame - len(raw_control),
        "scope": "source-only optimistic empirical Shannon payload; no arithmetic state/quantization/pruned-model implementation",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=pathlib.Path, default=BOOKS)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--classes", type=int, default=32)
    ap.add_argument("--vocab", type=int, default=8192)
    a = ap.parse_args()
    manifest = json.loads(a.manifest.read_text())
    if not (2 <= a.classes <= 64 and 16 <= a.vocab <= 65536):
        ap.error("resource limits")
    a.out.parent.mkdir(parents=True, exist_ok=True)
    with a.out.open("w") as f:
        for book in manifest["books"]:
            spec = book["full"]
            data = pathlib.Path(spec["path"]).read_bytes()
            assert len(data) == spec["bytes"] and hashlib.sha256(data).hexdigest() == spec["sha256"]
            row = evaluate(data, book["id"], a.classes, a.vocab)
            f.write(json.dumps(row, sort_keys=True) + "\n")
            f.flush()
            print(book["id"], row["optimistic_frame_bytes"], row["whole_bzip3_bytes"], flush=True)


if __name__ == "__main__":
    main()
