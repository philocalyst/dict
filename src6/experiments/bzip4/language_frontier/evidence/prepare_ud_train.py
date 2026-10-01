#!/usr/bin/env python3
"""Freeze bounded UD TRAIN resources and sentence-index holdouts.

The retained raw files are fetched from commit-pinned official Universal
Dependencies URLs.  ``prepare_ud.project`` is called first to apply the
existing strict CoNLL-U validation and projection policy.  This script then
walks the same sentence records and writes only two labelled views:

* ``exploratory-80``: sentence indices ``[0, floor(0.8 * N))``;
* ``confirmation-20``: the final sentence indices, reserved as a fresh
  confirmation holdout.

The split is by sentence index before any candidate result is inspected.  No
codec is invoked here, and the confirmation files must not be benchmarked
until the root agent freezes a candidate.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

from prepare_ud import project


ROOT = Path(__file__).resolve().parent

TRAIN_CORPORA = {
    "ud-fi-train": {
        "filename": "fi_tdt-ud-train.conllu",
        "repo": "UniversalDependencies/UD_Finnish-TDT",
        "commit": "bfaae13719f249573d940edda6a0d7aa8eec620f",
        "blob_sha1": "ad70aa08b4c3aa0bec5a631c9db1222968b4cc05",
        "url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Finnish-TDT/bfaae13719f249573d940edda6a0d7aa8eec620f/fi_tdt-ud-train.conllu",
        "license": "CC BY-SA 4.0 (retained LICENSE.txt)",
        "license_source": "ud-fi-test/LICENSE.txt",
    },
    "ud-tr-train": {
        "filename": "tr_imst-ud-train.conllu",
        "repo": "UniversalDependencies/UD_Turkish-IMST",
        "commit": "0c939115d8277ecfb39e1bbc3f066b1852ab5ddc",
        "blob_sha1": "af49df52e2ba6b04ab2ea58d2a964a1efbc893c7",
        "url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Turkish-IMST/0c939115d8277ecfb39e1bbc3f066b1852ab5ddc/tr_imst-ud-train.conllu",
        "license": "CC BY-NC-SA 3.0 (retained LICENSE.txt)",
        "license_source": "ud-tr-test/LICENSE.txt",
    },
}

# Header-only size check showed this file is 40,698,415 bytes.  It is recorded
# as intentionally omitted rather than fetched, keeping this lane below the
# 25 MiB new-download budget after Finnish + Turkish (16,512,835 raw bytes).
OMITTED = {
    "id": "ud-ar-train",
    "source_repository": "UniversalDependencies/UD_Arabic-PADT",
    "source_commit": "dfb6b4c547f1fe10f1857b39e44de3f86c47a2fe",
    "source_url": "https://raw.githubusercontent.com/UniversalDependencies/UD_Arabic-PADT/dfb6b4c547f1fe10f1857b39e44de3f86c47a2fe/ar_padt-ud-train.conllu",
    "http_content_length": 40698415,
    "status": "omitted_download_budget",
    "reason": "The complete Arabic TRAIN file alone exceeds the remaining 25 MiB bounded-download budget.",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, object]:
    return {
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def git_blob(path: Path) -> str:
    return subprocess.check_output(["git", "hash-object", str(path)], text=True).strip()


def sentence_records(raw: bytes) -> list[tuple[list[str], str]]:
    """Parse sentence FORM fields and ``# text =`` comments exactly once."""

    text = raw.decode("utf-8", "strict")
    records: list[tuple[list[str], str]] = []
    sentence_forms: list[str] = []
    sentence_text: str | None = None

    def finish(line_number: int) -> None:
        nonlocal sentence_forms, sentence_text
        if not sentence_forms and sentence_text is None:
            return
        if sentence_text is None:
            raise ValueError(f"sentence ending near line {line_number} lacks # text comment")
        records.append((sentence_forms, sentence_text))
        sentence_forms = []
        sentence_text = None

    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            finish(line_number)
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
            raise ValueError(f"line {line_number}: expected 10 tab-separated fields")
        token_id = columns[0]
        if "-" in token_id or "." in token_id:
            continue
        if not token_id.isdigit():
            raise ValueError(f"line {line_number}: invalid token ID {token_id!r}")
        form = columns[1]
        if not form or "\t" in form or "\n" in form or "\r" in form:
            raise ValueError(f"line {line_number}: invalid FORM")
        sentence_forms.append(form)
    finish(len(text.splitlines()) + 1)
    if not records:
        raise ValueError("no sentences")
    return records


def projection(records: list[tuple[list[str], str]]) -> tuple[bytes, bytes]:
    forms = [" ".join(form_fields) for form_fields, _ in records]
    texts = [sentence_text for _, sentence_text in records]
    return ("\n".join(forms) + "\n").encode("utf-8"), ("\n".join(texts) + "\n").encode("utf-8")


def write_projection(directory: Path, records: list[tuple[list[str], str]]) -> dict[str, dict[str, object]]:
    directory.mkdir(parents=True, exist_ok=True)
    form, text = projection(records)
    form_path = directory / "form.txt"
    text_path = directory / "text.txt"
    form_path.write_bytes(form)
    text_path.write_bytes(text)
    return {"form": file_record(form_path), "text": file_record(text_path)}


def main() -> None:
    corpora: list[dict[str, object]] = []
    for corpus_id, meta in TRAIN_CORPORA.items():
        directory = ROOT / "corpora" / corpus_id
        raw_path = directory / str(meta["filename"])
        license_path = directory / "LICENSE.txt"
        if not raw_path.is_file() or not license_path.is_file():
            raise SystemExit(f"missing retained raw/license files for {corpus_id}")

        raw = raw_path.read_bytes()
        # Reuse the existing parser/validator and ensure the split parser sees
        # exactly the same sentence and token counts.
        full_form, full_text, checked_sentences, checked_tokens, malformed = project(raw)
        records = sentence_records(raw)
        if checked_sentences != len(records) or malformed != 0:
            raise ValueError(f"validator/split count mismatch for {corpus_id}")
        token_count = sum(len(forms) for forms, _ in records)
        if token_count != checked_tokens:
            raise ValueError(f"validator/split token mismatch for {corpus_id}")

        cut = len(records) * 8 // 10
        exploratory = records[:cut]
        confirmation = records[cut:]
        if not exploratory or not confirmation:
            raise ValueError(f"split would be empty for {corpus_id}")
        exploratory_files = write_projection(directory / "exploratory-80", exploratory)
        confirmation_files = write_projection(directory / "confirmation-20", confirmation)
        exploratory_form, exploratory_text = projection(exploratory)
        confirmation_form, confirmation_text = projection(confirmation)
        if exploratory_form + confirmation_form != full_form or exploratory_text + confirmation_text != full_text:
            raise ValueError(f"split projections do not reconstruct full projection for {corpus_id}")
        local_blob = git_blob(raw_path)
        if local_blob != meta["blob_sha1"]:
            raise ValueError(f"Git blob mismatch for {raw_path}: {local_blob} != {meta['blob_sha1']}")

        corpora.append(
            {
                "id": corpus_id,
                "role": "source_train_with_reserved_confirmation",
                "source_repository": meta["repo"],
                "source_commit": meta["commit"],
                "source_blob_sha1": meta["blob_sha1"],
                "source_url": meta["url"],
                "license": meta["license"],
                "license_source": meta["license_source"],
                "license_file": file_record(license_path),
                "raw": file_record(raw_path),
                "raw_git_blob_sha1_verified": True,
                "sentence_count": len(records),
                "integer_form_tokens": token_count,
                "split_rule": "exploratory = records[0:floor(0.8*N)], confirmation = records[floor(0.8*N):N]",
                "exploratory": {
                    "role": "exploratory_train_80",
                    "sentence_start_inclusive": 0,
                    "sentence_end_exclusive": cut,
                    "sentences": len(exploratory),
                    "files": exploratory_files,
                },
                "confirmation": {
                    "role": "confirmation_holdout_20",
                    "sentence_start_inclusive": cut,
                    "sentence_end_exclusive": len(records),
                    "sentences": len(confirmation),
                    "files": confirmation_files,
                    "policy": "Do not benchmark or expose to implementors until root freezes candidate(s).",
                },
            }
        )

    manifest = {
        "schema": 1,
        "purpose": "Bounded commit-pinned UD TRAIN resources with pre-inspection sentence-index split.",
        "download_budget": {
            "new_raw_bytes": sum(int(c["raw"]["bytes"]) for c in corpora),
            "limit_bytes": 25 * 1024 * 1024,
            "arabic_train_status": "omitted; complete file exceeds remaining budget",
        },
        "raw_policy": "Retain official CoNLL-U TRAIN bytes verbatim; no archive/source compression.",
        "projection_policy": "Use the existing prepare_ud validator; FORM fields are ASCII-space joined per sentence and LF-terminated; # text comments are LF-terminated.",
        "split_policy": "Compute floor(0.8*N) from sentence count before inspecting candidate results; first 80% exploratory, final 20% confirmation.",
        "confirmation_policy": "Confirmation paths are explicitly labelled and must remain untouched until root freezes candidates; this script performs no codec run.",
        "omitted": [OMITTED],
        "corpora": corpora,
    }
    output = ROOT / "ud-train-manifest.json"
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
