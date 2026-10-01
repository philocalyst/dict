#!/usr/bin/env python3
"""Freeze small Universal Dependencies holdouts and explicit projections.

The checked-in ``*.conllu`` files are the raw bytes fetched from the official
UniversalDependencies repositories.  This script never normalizes or
tokenizes them.  It only derives two byte streams whose policy is explicit:

* ``form.txt``: the dataset's integer-ID FORM fields, in sentence order,
  joined by one ASCII space and terminated by one LF per sentence.  This is a
  word workload using the corpus' own tokenization, not a free tokenizer.
* ``text.txt``: the dataset's ``# text =`` sentence comments, verbatim apart
  from the required LF record terminator.  This is the prose workload.

The raw CoNLL-U and license files remain beside both projections.  Every
derived stream is hashed and the result manifest records the exact source,
split, counts, and policy.  No network access occurs here.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent

CORPORA = {
    "ud-fi-test": {
        "filename": "fi_tdt-ud-test.conllu",
        "repo": "UniversalDependencies/UD_Finnish-TDT",
        "commit": "bfaae13719f249573d940edda6a0d7aa8eec620f",
        "blob_sha1": "e69e8e7a6d248b42c8624244f773ce4202eaeeb4",
        "url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Finnish-TDT/bfaae13719f249573d940edda6a0d7aa8eec620f/fi_tdt-ud-test.conllu",
        "license": "CC BY-SA 4.0 (see retained LICENSE.txt)",
    },
    "ud-tr-test": {
        "filename": "tr_imst-ud-test.conllu",
        "repo": "UniversalDependencies/UD_Turkish-IMST",
        "commit": "0c939115d8277ecfb39e1bbc3f066b1852ab5ddc",
        "blob_sha1": "55d12cf7e6e346810a1ad9328ce8598676a6fd47",
        "url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Turkish-IMST/0c939115d8277ecfb39e1bbc3f066b1852ab5ddc/tr_imst-ud-test.conllu",
        "license": "CC BY-NC-SA 3.0 (see retained LICENSE.txt)",
    },
    "ud-ar-test": {
        "filename": "ar_padt-ud-test.conllu",
        "repo": "UniversalDependencies/UD_Arabic-PADT",
        "commit": "dfb6b4c547f1fe10f1857b39e44de3f86c47a2fe",
        "blob_sha1": "a2684675edf31170ed1cc80798009a55bce58264",
        "url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Arabic-PADT/dfb6b4c547f1fe10f1857b39e44de3f86c47a2fe/ar_padt-ud-test.conllu",
        "license": "CC BY-NC-SA 3.0 (see retained LICENSE.txt)",
    },
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_record(path: Path) -> dict[str, object]:
    return {
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": digest(path),
    }


def project(raw: bytes) -> tuple[bytes, bytes, int, int, int]:
    """Return FORM and # text streams, sentence/token counts, and bad rows.

    The parser is intentionally narrow and rejects malformed UTF-8, missing
    sentence text comments, malformed token rows, duplicate sentence
    terminators, and non-integer IDs only where an integer token was expected.
    Multiword-token ranges and empty-node decimal IDs are metadata, not token
    occurrences, and are skipped exactly as the CoNLL-U format specifies.
    """

    text = raw.decode("utf-8")
    form_sentences: list[str] = []
    texts: list[str] = []
    sentence_forms: list[str] = []
    sentence_text: str | None = None
    sentences = 0
    tokens = 0
    malformed = 0

    def finish() -> None:
        nonlocal sentence_forms, sentence_text, sentences
        if not sentence_forms and sentence_text is None:
            return
        if sentence_text is None:
            raise ValueError(f"sentence {sentences} lacks # text comment")
        form_sentences.append(" ".join(sentence_forms))
        texts.append(sentence_text)
        sentence_forms = []
        sentence_text = None
        sentences += 1

    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            finish()
            continue
        if line.startswith("#"):
            if line.startswith("# text ="):
                if sentence_text is not None:
                    raise ValueError(f"duplicate # text at line {line_number}")
                value = line[len("# text =") :]
                if value.startswith(" "):
                    value = value[1:]
                sentence_text = value
            continue
        columns = line.split("\t")
        if len(columns) != 10:
            malformed += 1
            raise ValueError(f"line {line_number}: expected 10 tab-separated fields")
        token_id = columns[0]
        if "-" in token_id or "." in token_id:
            continue
        try:
            int(token_id)
        except ValueError as exc:
            malformed += 1
            raise ValueError(f"line {line_number}: invalid token ID {token_id!r}") from exc
        form = columns[1]
        if not form or "\t" in form or "\n" in form or "\r" in form:
            malformed += 1
            raise ValueError(f"line {line_number}: invalid FORM")
        sentence_forms.append(form)
        tokens += 1
    finish()
    if not sentences:
        raise ValueError("no sentences")
    form_bytes = ("\n".join(form_sentences) + "\n").encode("utf-8") if form_sentences else b""
    text_bytes = ("\n".join(texts) + "\n").encode("utf-8") if texts else b""
    return form_bytes, text_bytes, sentences, tokens, malformed


def main() -> None:
    manifest: dict[str, object] = {
        "schema": 1,
        "purpose": "Frozen multilingual holdouts for storage-only Bzip4 v4 screens.",
        "raw_policy": "Retain official CoNLL-U test split bytes verbatim; no source-archive compression.",
        "source_lock_policy": "The local raw SHA-256 is authoritative. Each raw file also matches the recorded source commit's Git blob SHA-1; reruns must use the pinned commit URL or retained bytes, never a mutable branch URL.",
        "form_policy": "Dataset integer-ID FORM fields in source sentence order, ASCII-space joined, LF sentence terminators.",
        "text_policy": "Dataset # text = sentence comments, preserving Unicode and punctuation, LF record terminators.",
        "corpora": [],
    }
    for corpus, meta in CORPORA.items():
        directory = ROOT / "corpora" / corpus
        raw_path = directory / str(meta["filename"])
        license_path = directory / "LICENSE.txt"
        if not raw_path.is_file() or not license_path.is_file():
            raise SystemExit(f"missing retained raw/license files for {corpus}")
        form_bytes, text_bytes, sentences, tokens, malformed = project(raw_path.read_bytes())
        form_path = directory / "form.txt"
        text_path = directory / "text.txt"
        form_path.write_bytes(form_bytes)
        text_path.write_bytes(text_bytes)
        manifest["corpora"].append({
            "id": corpus,
            "source_repository": meta["repo"],
            "source_commit": meta["commit"],
            "source_blob_sha1": meta["blob_sha1"],
            "source_url": meta["url"],
            "split": "test",
            "license": meta["license"],
            "raw": file_record(raw_path),
            "license_file": file_record(license_path),
            "form_projection": file_record(form_path),
            "text_projection": file_record(text_path),
            "sentences": sentences,
            "integer_form_tokens": tokens,
            "malformed_rows": malformed,
        })
    output = ROOT / "ud-manifest.json"
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
