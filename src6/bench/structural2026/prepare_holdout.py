#!/usr/bin/env python3
"""Restore reserved sources; project complete sentences and lexical records."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import re
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
LOCK = HERE / "sources.json"


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def record(path):
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": digest(path)}


def write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def restore(root, item, skip_fetch):
    relative = Path(item["relative_path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("unsafe source path")
    path = root / relative
    if not path.is_file():
        if skip_fetch:
            raise ValueError(f"missing retained source: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix(path.suffix + ".partial")
        with urllib.request.urlopen(item["url"], timeout=60) as response, partial.open("wb") as target:
            shutil.copyfileobj(response, target, 1 << 20)
        if partial.stat().st_size != item["bytes"] or digest(partial) != item["sha256"]:
            raise ValueError(f"source checksum mismatch: {item['url']}")
        partial.replace(path)
    if path.stat().st_size != item["bytes"] or digest(path) != item["sha256"]:
        raise ValueError(f"retained source checksum mismatch: {path}")
    return item | record(path)


def project_ud(raw):
    """Preserve comment text exactly; use official integer-ID FORM fields."""
    prose, forms, annotations = [], [], []
    sentence_text, sentence_forms, sentence_rows = None, [], []
    sentences = tokens = 0

    def finish():
        nonlocal sentence_text, sentence_forms, sentence_rows, sentences, tokens
        if sentence_text is None and not sentence_rows:
            return
        if sentence_text is None or not sentence_rows:
            raise ValueError("sentence lacks text or integer-ID tokens")
        if [int(row[0]) for row in sentence_rows] != list(range(1, len(sentence_rows) + 1)):
            raise ValueError("noncontiguous integer token IDs")
        prose.append(sentence_text)
        forms.append(b" ".join(sentence_forms))
        annotations.append(sentence_rows)
        sentences += 1
        tokens += len(sentence_rows)
        sentence_text, sentence_forms, sentence_rows = None, [], []

    # Split only at LF. No Unicode normalization or Unicode whitespace split.
    raw.decode("utf-8")
    for line in raw.split(b"\n"):
        if line.endswith(b"\r"):
            line = line[:-1]
        if not line:
            finish()
        elif line.startswith(b"# text ="):
            if sentence_text is not None:
                raise ValueError("duplicate sentence text")
            sentence_text = line[len(b"# text ="):]
            if sentence_text.startswith(b" "):
                sentence_text = sentence_text[1:]
        elif line.startswith(b"#"):
            continue
        else:
            columns = line.split(b"\t")
            if len(columns) != 10:
                raise ValueError("expected ten CoNLL-U fields")
            token_id = columns[0]
            if re.fullmatch(rb"[1-9][0-9]*-[1-9][0-9]*|[1-9][0-9]*\.[1-9][0-9]*", token_id):
                continue
            if not re.fullmatch(rb"[1-9][0-9]*", token_id) or not columns[1]:
                raise ValueError("invalid token ID or empty FORM")
            sentence_forms.append(columns[1])
            sentence_rows.append([column.decode("utf-8") for column in columns])
    finish()
    if not sentences:
        raise ValueError("empty corpus")
    return (b"\n".join(prose) + b"\n", b"\n".join(forms) + b"\n",
            annotations, sentences, tokens)


def lane(name, path, language, kind, manifest):
    return record(path) | {"name": name, "language": language, "kind": kind,
                           "split": "structural-holdout", "source_manifest": str(manifest.resolve())}


def project(root, lock, sources):
    lanes = []
    for source in sources:
        path = Path(source["path"])
        if source["kind"] != "ud-pud" or path.suffix != ".conllu":
            continue
        lang = source["language"]
        prose, forms, annotations, sentences, tokens = project_ud(path.read_bytes())
        if sentences != 1000:
            raise ValueError(f"expected all 1000 aligned PUD sentences: {lang}")
        output = root / "ud" / lang
        output.mkdir(parents=True, exist_ok=True)
        text_path, form_path = output / "text.txt", output / "forms.txt"
        text_path.write_bytes(prose)
        form_path.write_bytes(forms)
        # Retained ten-field token annotations are an oracle, never compressor input.
        oracle = output / "annotations.jsonl"
        with oracle.open("w") as stream:
            for sentence in annotations:
                stream.write(json.dumps(sentence, ensure_ascii=False, separators=(",", ":")) + "\n")
        manifest = output / "source-manifest.json"
        write_json(manifest, {"source": source, "sentences": sentences, "tokens": tokens,
                             "text_policy": "verbatim # text = bytes, one LF per complete sentence",
                             "forms_policy": "integer-ID FORM bytes, ASCII spaces, one LF per sentence; ranges and empty nodes excluded",
                             "text": record(text_path), "forms": record(form_path), "annotations": record(oracle)})
        lanes += [lane(f"pud-{lang}-prose-holdout", text_path, lang, "prose", manifest),
                  lane(f"pud-{lang}-forms-holdout", form_path, lang, "word-form", manifest)]

    spec = importlib.util.spec_from_file_location("structural_dictionary_oracle", REPO / "src6/bench/real-world/prepare.py")
    oracle = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = oracle
    spec.loader.exec_module(oracle)
    for source in sources:
        path = Path(source["path"])
        if source["kind"] != "freedict" or path.suffix != ".tei":
            continue
        pair, lang = source["pair"], source["language"]
        with tempfile.TemporaryDirectory() as directory:
            adapter = Path(directory)
            (adapter / "eng-spa.tei").symlink_to(path)
            rows, stats = oracle.parse_freedict(adapter)
        # Whole entry selection declared before observing any codec results.
        modulus = 16 if pair == "jpn-eng" else 1
        selected = [row for row in rows if int(hashlib.sha256(row.source_entry_id.encode()).hexdigest(), 16) % modulus == 0]
        if not selected:
            raise ValueError("empty lexical holdout")
        output = root / "dictionaries" / pair
        policy = f"SHA-256(source_entry_id) modulo {modulus} == 0; complete entries, source order"
        oracle.write_projection(selected, output, corpus="freedict-" + pair + "-structural-holdout",
                                source_manifest=source, stats=stats | {"selected_records": len(selected), "selection": policy})
        text_path, word_path = output / "content.txt", output / "words.txt"
        text_path.write_bytes(b"".join(row.content.encode("utf-8") + b"\n" for row in selected))
        word_path.write_bytes(b"".join(key.encode("utf-8") + b"\n" for row in selected for key in row.keys))
        manifest = output / "projection-manifest.json"
        lanes += [lane(f"freedict-{pair}-content-holdout", text_path, lang, "dictionary-content", manifest),
                  lane(f"freedict-{pair}-words-holdout", word_path, lang, "word-form", manifest)]
    write_json(root / "manifest.json", {"schema": 1, "purpose": lock["purpose"], "caveat": lock["caveat"],
                                        "source_lock_sha256": digest(LOCK), "sources": sources, "corpora": lanes})
    return lanes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("/workspace/scratch/structural-holdout"))
    parser.add_argument("--skip-fetch", action="store_true")
    args = parser.parse_args()
    root = args.output_dir.resolve()
    lock = json.loads(LOCK.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        sources = list(pool.map(lambda item: restore(root, item, args.skip_fetch), lock["sources"]))
    lanes = project(root, lock, sources)
    print(json.dumps({"lanes": len(lanes), "bytes": sum(row["bytes"] for row in lanes),
                      "manifest_sha256": digest(root / "manifest.json")}))


if __name__ == "__main__":
    main()
