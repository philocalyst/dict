#!/usr/bin/env python3
"""Prepare pinned complete development books. Never run a compression codec."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

HERE = Path(__file__).resolve().parent
PREFIX_LIMITS = (128 * 1024, 1024 * 1024)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utf8_prefix(data: bytes, limit: int) -> bytes:
    """Largest valid UTF-8 byte prefix at or below limit; no padding."""
    end = min(len(data), limit)
    for back in range(4):
        cut = end - back
        if cut < 0:
            break
        try:
            data[:cut].decode("utf-8", errors="strict")
            return data[:cut]
        except UnicodeDecodeError:
            pass
    raise ValueError("input is not valid UTF-8")


def pg_projection(raw: bytes, book: dict) -> tuple[bytes, dict]:
    text = raw.decode(book["source_encoding"], errors="strict")
    if text.encode(book["source_encoding"]) != raw:
        raise ValueError("declared source encoding does not round-trip")
    starts = list(re.finditer(
        r"(?m)^\*\*\* ?START OF (?:THIS|THE) PROJECT GUTENBERG EBOOK (.+?) ?\*\*\*\r?\n",
        text))
    ends = list(re.finditer(
        r"(?m)^\*\*\* ?END OF (?:THIS|THE) PROJECT GUTENBERG EBOOK (.+?) ?\*\*\*(?:\r?\n|$)",
        text))
    if len(starts) != 1 or len(ends) != 1:
        raise ValueError("exactly one EBOOK START and END marker required")
    start, end = starts[0], ends[0]
    if start.group(1) != end.group(1) or start.end() >= end.start():
        raise ValueError("EBOOK markers differ or are unordered")
    for name, actual in (("exact_start_marker", start.group(0).rstrip("\r\n")),
                         ("exact_end_marker", end.group(0).rstrip("\r\n"))):
        if name in book and actual != book[name]:
            raise ValueError("marker differs from exact source lock")
    header = text[:start.start()]
    for key, value in (("Title", book["title"]),
                       ("Author", book["author"]),
                       ("Language", book["declared_language"])):
        if not re.search(r"(?m)^" + key + r":\s*" + re.escape(value) + r"\s*$", header):
            raise ValueError(f"missing or wrong {key} metadata")
    expected_encoding = book.get("declared_source_encoding") or {
        "utf-8-sig": "UTF-8", "utf-8": "UTF-8", "iso-8859-1": "ISO-8859-1"
    }[book["source_encoding"]]
    if not re.search(r"(?m)^Character set encoding:\s*" + re.escape(expected_encoding) + r"\s*$", header):
        raise ValueError("declared header encoding differs from source lock")
    if book.get("translator") and not re.search(
            r"(?m)^Translators?:\s*" + re.escape(book["translator"]) + r"\s*$", header):
        raise ValueError("translation metadata differs from source lock")
    if book["rights"]["source_license_marker"] not in text[end.start():]:
        raise ValueError("source license footer missing")
    body = text[start.end():end.start()]
    output = body.encode("utf-8", errors="strict")
    # utf-8-sig emits a BOM for every encoded prefix. Prefix byte lengths
    # include it, while body encoding deliberately omits it.
    byte_start = len(text[:start.end()].encode(book["source_encoding"]))
    byte_end = len(text[:end.start()].encode(book["source_encoding"]))
    source_body_encoding = "utf-8" if book["source_encoding"] == "utf-8-sig" else book["source_encoding"]
    restored = raw[:byte_start] + output.decode("utf-8").encode(source_body_encoding) + raw[byte_end:]
    if restored != raw:
        raise ValueError("full original source reconstruction failed")
    return output, dict(
        raw_body_byte_start=byte_start, raw_body_byte_end=byte_end,
        start_marker=start.group(0).rstrip("\r\n"),
        end_marker=end.group(0).rstrip("\r\n"),
        projection_inverse="UTF-8 decode, re-encode declared source codec, reinsert preserved raw header/footer",
        full_original_source_reconstruction_sha256=digest(restored),
        newline_policy="preserve source body CRLF/LF exactly", removed_body_characters=0)


def undo_deletions(output: str, deletions: list[dict]) -> str:
    restored = []
    used_output = 0
    previous_source_end = 0
    for deletion in deletions:
        offset = deletion["source_scalar_offset"]
        count = offset - previous_source_end
        if count < 0:
            raise ValueError("overlapping or unordered deletion records")
        restored.append(output[used_output:used_output + count])
        restored.append(deletion["text"])
        used_output += count
        previous_source_end = offset + len(deletion["text"])
    restored.append(output[used_output:])
    return "".join(restored)


def aozora_projection(raw: bytes, book: dict) -> tuple[bytes, dict, list[dict]]:
    text = raw.decode(book["source_encoding"], errors="strict")
    if text.encode(book["source_encoding"]) != raw:
        raise ValueError("Aozora declared encoding does not round-trip")
    header_lines = book.get("exact_header_lines", [book["title"], book["author"]])
    if text.splitlines()[:len(header_lines)] != header_lines:
        raise ValueError("Aozora title/author mismatch")
    separators = list(re.finditer(r"(?m)^-{55}\r?\n", text))
    ends = list(re.finditer(r"(?m)^底本：", text))
    if len(separators) != 2 or len(ends) != 1:
        raise ValueError("Aozora explanation delimiters or colophon differ")
    first = separators[1].end()
    last = ends[0].start()
    if first >= last:
        raise ValueError("unordered Aozora body boundaries")
    body = text[first:last]
    for heading in book["required_part_headings"]:
        if heading not in body:
            raise ValueError("complete-book part heading missing")
    # Gaiji annotations are opaque exact source placeholders. Their bytes,
    # including the leading ※, are retained; no replacement glyph is invented.
    tokens = re.compile(r"※［＃[^］\r\n]*］|《[^》\r\n]*》|［＃[^］\r\n]*］|｜")
    chunks = []
    deletions = []
    position = 0
    gaiji_count = 0
    for match in tokens.finditer(body):
        if match.group(0).startswith("※［＃"):
            gaiji_count += 1
            continue
        chunks.append(body[position:match.start()])
        deletions.append(dict(source_scalar_offset=match.start(), text=match.group(0)))
        position = match.end()
    chunks.append(body[position:])
    projected = "".join(chunks)
    if undo_deletions(projected, deletions) != body:
        raise ValueError("Aozora deletion-map inverse failed")
    # Every ruby/format opener must be recognized; reject rather than silently
    # leaving malformed markup or deleting across paragraph boundaries.
    ruby_removed = sum(row["text"].startswith("《") for row in deletions)
    format_removed = sum(row["text"].startswith("［＃") for row in deletions)
    if ruby_removed != body.count("《") or ruby_removed != body.count("》"):
        raise ValueError("unrecognized ruby markup")
    if format_removed + gaiji_count != body.count("［＃"):
        raise ValueError("unrecognized formatting markup")
    byte_start = len(text[:first].encode(book["source_encoding"]))
    byte_end = len(text[:last].encode(book["source_encoding"]))
    restored_body = undo_deletions(projected, deletions)
    restored = raw[:byte_start] + restored_body.encode(book["source_encoding"]) + raw[byte_end:]
    if restored != raw:
        raise ValueError("full original Aozora source reconstruction failed")
    return projected.encode("utf-8"), dict(
        raw_body_byte_start=byte_start, raw_body_byte_end=byte_end,
        projection_inverse="Reinsert ordered deletion map, encode Shift_JIS, reinsert preserved raw header/colophon",
        full_original_source_reconstruction_sha256=digest(restored),
        newline_policy="preserve source body CRLF/LF exactly",
        removed_body_characters=sum(len(row["text"]) for row in deletions),
        ruby_annotations_removed=ruby_removed, format_annotations_removed=format_removed,
        ruby_anchor_markers_removed=sum(row["text"] == "｜" for row in deletions),
        opaque_gaiji_annotations_retained=gaiji_count), deletions


def prepare(lock: dict, root: Path, download: bool = False) -> dict:
    if lock["role"] not in ("development", "reserved-validation"):
        raise ValueError("explicit corpus role required")
    raw_dir = root / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    output_dir = root / "books"
    output_dir.mkdir(exist_ok=True)
    rows = []
    for book in lock["books"]:
        raw_path = raw_dir / book["raw_filename"]
        if not raw_path.exists():
            if not download:
                raise FileNotFoundError(raw_path)
            request = urllib.request.Request(book["url"], headers={"User-Agent": "books2026-pinned-corpus/1"})
            with urllib.request.urlopen(request, timeout=90) as response:
                raw = response.read(lock["source_limit_bytes"] + 1)
            if len(raw) > lock["source_limit_bytes"]:
                raise ValueError("source exceeds declared 16 MiB limit")
            if len(raw) != book["source_bytes"] or digest(raw) != book["source_sha256"]:
                raise ValueError("download differs from source lock")
            raw_path.write_bytes(raw)
        if raw_path.stat().st_size > lock["source_limit_bytes"]:
            raise ValueError("source exceeds declared 16 MiB limit")
        with raw_path.open("rb") as source:
            raw = source.read(lock["source_limit_bytes"] + 1)
        if len(raw) > lock["source_limit_bytes"]:
            raise ValueError("source grew beyond declared 16 MiB limit")
        if len(raw) != book["source_bytes"] or digest(raw) != book["source_sha256"]:
            raise ValueError(f"source lock mismatch: {book['id']}")
        if book["projection"] == "pg-marked-body-v1":
            body, oracle = pg_projection(raw, book)
        elif book["projection"] == "aozora-ruby-body-v1":
            body, oracle, deletions = aozora_projection(raw, book)
            sidecar = output_dir / (book["id"] + ".projection-inverse.json")
            sidecar.write_text(json.dumps(dict(schema=1, deletion_offsets="original Unicode scalar offsets",
                                                deletions=deletions), ensure_ascii=False, indent=2) + "\n")
            oracle["deletion_map_path"] = str(sidecar.resolve())
            oracle["deletion_map_sha256"] = digest(sidecar.read_bytes())
        else:
            raise ValueError("unsupported projection policy")
        if len(body) > lock["source_limit_bytes"]:
            raise ValueError("UTF-8 full book exceeds declared 16 MiB limit")
        body.decode("utf-8", errors="strict")
        full_path = output_dir / (book["id"] + ".full.txt")
        full_path.write_bytes(body)
        prefixes = []
        for limit in PREFIX_LIMITS if lock["role"] == "development" else ():
            prefix = utf8_prefix(body, limit)
            path = output_dir / (book["id"] + f".prefix-{limit}.txt")
            path.write_bytes(prefix)
            prefixes.append(dict(path=str(path.resolve()), byte_limit=limit,
                                 bytes=len(prefix), sha256=digest(prefix),
                                 is_entire_book=prefix == body,
                                 role="diagnostic prefix of complete development book"))
        rows.append(dict(id=book["id"], role=lock["role"], title=book["title"],
                         author=book["author"], language=book["language"],
                         source=dict(book, path=str(raw_path.resolve())),
                         full=dict(path=str(full_path.resolve()), bytes=len(body),
                                   utf8_scalar_count=len(body.decode("utf-8")),
                                   sha256=digest(body)),
                         prefixes=prefixes, projection_oracle=oracle))
    return dict(schema=1, role=lock["role"], source_limit_bytes=lock["source_limit_bytes"],
                whole_books=len(rows), total_full_bytes=sum(row["full"]["bytes"] for row in rows),
                source_lock_sha256=digest(json.dumps(lock, ensure_ascii=False, indent=2).encode() + b"\n"),
                books=rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/workspace/scratch/books2026-dev"))
    parser.add_argument("--lock", type=Path, default=HERE / "complete-source-lock.json")
    parser.add_argument("--manifest", default="manifest.json")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    manifest = prepare(json.loads(args.lock.read_text()), args.root, args.download)
    # Record the exact lock file bytes, including its original formatting.
    manifest["source_lock_path"] = str(args.lock.resolve())
    manifest["source_lock_sha256"] = digest(args.lock.read_bytes())
    target = args.root / args.manifest
    target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(manifest=str(target.resolve()), sha256=digest(target.read_bytes()),
                          whole_books=manifest["whole_books"], total_full_bytes=manifest["total_full_bytes"])))


if __name__ == "__main__":
    main()
