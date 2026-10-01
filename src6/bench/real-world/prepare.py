#!/usr/bin/env python3
"""Fetch and project the pinned public dictionary corpora.

This module is deliberately independent of every format reader.  The output
projection is an oracle input, not an answer table passed to a reader: each
reader gets only the artifact and the later validator compares its observations
with this independently retained source projection.

The source formats are intentionally parsed with small, format-specific
readers instead of a shared template.  A malformed source record or unresolved
reference is a hard error; a record is never silently skipped.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator
from xml.sax.saxutils import escape, quoteattr


ROOT = Path(__file__).resolve().parent
DEFAULT_CACHE = Path("/tmp/dictionary-real-world-cache")
DEFAULT_OUTPUT = ROOT / "evidence" / "corpora"

FD_URL = (
    "https://download.freedict.org/dictionaries/eng-spa/2025.11.23/"
    "freedict-eng-spa-2025.11.23.src.tar.xz"
)
FD_SHA512 = (
    "622e8fec6c4178cb4c21e4577701c5325670f825331b07a185b4c6b810603c337e80429738a97581f68f668667910e7ad36f27332eaee2828f1f906537852fe3"
)
GCIDE_URL = "https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz"
GCIDE_MD5 = "df6c3a428f26eb3d1cfce9ed5f00bc15"
GCIDE_SHA256 = "22416f6f36175b160dc388b7547512514d464473cf7d7c898d738efb26c51d42"
OMW_URL = "https://github.com/omwn/omw-data/releases/download/v2.0/omw-2.0.tar.xz"
OMW_SHA256 = "c369a2ad773a31e182ac4cc753132fa7c31ad423586d6783bacce08090cb8d7d"


class PreparationError(RuntimeError):
    pass


def sha(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, *, url: str | None = None) -> dict[str, Any]:
    return {
        "path": str(path.resolve()),
        "bytes": path.stat().st_size,
        "sha256": sha(path, "sha256"),
        "sha512": sha(path, "sha512"),
        **({"url": url} if url else {}),
    }


def download_verified(url: str, destination: Path, *, sha512: str | None = None,
                      sha256: str | None = None, md5: str | None = None) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = {k: v for k, v in (("sha512", sha512), ("sha256", sha256), ("md5", md5)) if v}

    def check(path: Path) -> bool:
        if not path.is_file():
            return False
        return path.stat().st_size > 0 and all(sha(path, alg) == value for alg, value in expected.items())

    if not check(destination):
        if destination.exists():
            # Never treat a partial or wrong public download as valid.
            destination.unlink()
        partial = destination.with_suffix(destination.suffix + ".partial")
        if partial.exists():
            partial.unlink()
        request = urllib.request.Request(url, headers={"User-Agent": "dictionary-real-world-harness/1"})
        try:
            with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as target:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    target.write(chunk)
        except Exception as exc:  # pragma: no cover - network failure varies
            raise PreparationError(f"download failed for {url}: {exc}") from exc
        if not check(partial):
            got = {alg: sha(partial, alg) for alg in expected}
            raise PreparationError(f"checksum mismatch for {url}: expected={expected} got={got}")
        partial.replace(destination)
    return destination


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*", errorlevel=2) as source:
        for member in source.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise PreparationError(f"unsafe archive member: {member.name!r}")
            target = (destination / relative).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise PreparationError(f"archive member escapes destination: {member.name!r}")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                extracted = source.extractfile(member)
                if extracted is None:
                    raise PreparationError(f"cannot extract regular member: {member.name!r}")
                with target.open("wb") as output:
                    shutil.copyfileobj(extracted, output)
            else:
                raise PreparationError(f"unsupported archive member: {member.name!r}")


def fetch(cache: Path) -> dict[str, Any]:
    cache = cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    sources = cache / "sources"
    extracted = cache / "extracted"

    fd_archive = download_verified(FD_URL, sources / "freedict-eng-spa-2025.11.23.src.tar.xz", sha512=FD_SHA512)
    gcide_archive = download_verified(GCIDE_URL, sources / "gcide-0.54.tar.xz", sha256=GCIDE_SHA256, md5=GCIDE_MD5)
    omw_archive = download_verified(OMW_URL, sources / "omw-2.0.tar.xz", sha256=OMW_SHA256)

    fd_root = extracted / "freedict-eng-spa-2025.11.23"
    gcide_root = extracted / "gcide-0.54"
    omw_root = extracted / "omw-2.0"
    if not (fd_root / "eng-spa" / "eng-spa.tei").is_file():
        safe_extract(fd_archive, fd_root)
    if not (gcide_root / "gcide-0.54" / "CIDE.A").is_file():
        safe_extract(gcide_archive, gcide_root)
    if not (omw_root / "omw-2.0" / "omw-ja" / "omw-ja.xml").is_file():
        safe_extract(omw_archive, omw_root)

    source_entries = [
        {
            "id": "freedict-eng-spa",
            "url": FD_URL,
            "archive": file_record(fd_archive, url=FD_URL),
            "extracted_root": str((fd_root / "eng-spa").resolve()),
            "license": file_record(fd_root / "eng-spa" / "COPYING"),
        },
        {
            "id": "gcide-054",
            "url": GCIDE_URL,
            "archive": file_record(gcide_archive, url=GCIDE_URL),
            "extracted_root": str((gcide_root / "gcide-0.54").resolve()),
            "license": file_record(gcide_root / "gcide-0.54" / "COPYING"),
        },
        {
            "id": "omw-ja-20",
            "url": OMW_URL,
            "archive": file_record(omw_archive, url=OMW_URL),
            "extracted_root": str((omw_root / "omw-2.0" / "omw-ja").resolve()),
            "license": file_record(omw_root / "omw-2.0" / "omw-ja" / "LICENSE"),
        },
    ]
    manifest = {"schema": 1, "cache": str(cache), "sources": source_entries}
    (cache / "source-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def attr_name(name: str) -> str:
    if name.startswith("{"):
        namespace, _, local = name[1:].partition("}")
        if namespace == "http://www.w3.org/XML/1998/namespace":
            return "xml:" + local
        return local
    return name


def normalized_text(text: str | None) -> str:
    if not text:
        return ""
    # Source line endings are not semantic.  Keep all other whitespace in
    # nonblank text, including wrapped definitions and Unicode spaces.
    return text.replace("\r\n", "\n").replace("\r", "\n")


def xml_fragment(element: ET.Element, *, omit: set[str] | None = None) -> str:
    """Serialize an element while retaining *all* source text and names.

    ElementTree's serializer retains mixed-content tails, qualified names,
    namespace declarations, attributes, comments and empty elements.  That is
    important here: dropping whitespace-only tails can merge two inline words,
    and reducing a qualified attribute to its local spelling can change its
    meaning.  `omit` remains available for small callers, but the real corpus
    projection never omits a source child; native source bytes are retained as
    the final authority as well.
    """
    if not omit:
        return normalized_text(ET.tostring(element, encoding="unicode", short_empty_elements=True))
    # Keep a conservative recursive implementation for tests/tools that need
    # to exclude a structural child while retaining that child's tail.
    if local_name(element.tag) in omit:
        return ""
    body = normalized_text(element.text or "")
    for child in list(element):
        body += xml_fragment(child, omit=omit)
        body += normalized_text(child.tail or "")
    tag = local_name(element.tag)
    attrs = "".join(f" {attr_name(k)}={quoteattr(normalized_text(v))}" for k, v in element.attrib.items())
    return f"<{tag}{attrs}>{body}</{tag}>"


def iter_children(element: ET.Element, name: str) -> Iterator[ET.Element]:
    for child in list(element):
        if local_name(child.tag) == name:
            yield child


@dataclass
class Row:
    row_id: str
    source_entry_id: str
    source_ordinal: int
    source_file: str
    keys: list[str]
    content: str
    native_record_bytes: int
    extra: dict[str, Any]

    def metadata(self) -> dict[str, Any]:
        content_bytes = self.content.encode("utf-8")
        return {
            "row_id": self.row_id,
            "source_entry_id": self.source_entry_id,
            "source_ordinal": self.source_ordinal,
            "source_file": self.source_file,
            "keys": self.keys,
            "key_count": len(self.keys),
            "content_bytes": len(content_bytes),
            "content_sha256": hashlib.sha256(content_bytes).hexdigest(),
            "native_record_bytes": self.native_record_bytes,
            **self.extra,
        }


def require_utf8(text: str, where: str) -> str:
    try:
        text.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise PreparationError(f"invalid Unicode in {where}: {exc}") from exc
    return text


def parse_freedict(root: Path) -> tuple[list[Row], dict[str, Any]]:
    source = root / "eng-spa.tei"
    rows: list[Row] = []
    malformed = 0
    try:
        events = ET.iterparse(source, events=("end",))
        for _, element in events:
            if local_name(element.tag) != "entry":
                continue
            ordinal = len(rows)
            forms = [
                normalized_text("".join(orth.itertext()))
                for form in iter_children(element, "form")
                for orth in form.iter()
                if local_name(orth.tag) == "orth"
            ]
            if not forms:
                malformed += 1
                raise PreparationError(f"FreeDict entry {ordinal} has no orth spelling")
            if any(not require_utf8(key, f"FreeDict entry {ordinal} key") for key in forms):
                malformed += 1
                raise PreparationError(f"FreeDict entry {ordinal} has an empty/unusable key")
            content = xml_fragment(element)
            raw = ET.tostring(element, encoding="utf-8")
            source_xml_id = next((value for key, value in element.attrib.items() if attr_name(key) == "xml:id"), None)
            rows.append(Row(
                row_id=f"fd-{ordinal:07d}",
                source_entry_id=source_xml_id or f"fd-entry-{ordinal:07d}",
                source_ordinal=ordinal,
                source_file=str(source.resolve()),
                keys=forms,
                content=content,
                native_record_bytes=len(raw),
                extra={"forms": len(forms), "source_xml_id": source_xml_id, "projection": "complete normalized TEI entry XML"},
            ))
            element.clear()
    except ET.ParseError as exc:
        raise PreparationError(f"malformed FreeDict XML: {exc}") from exc
    return rows, {
        "source_bytes": source.stat().st_size,
        "records": len(rows),
        "parse_failures": malformed,
        "front_matter_excluded": True,
        "source_format": "TEI P5 XML",
    }


GCIDE_ENTRY_RE = re.compile(r"<p>\s*<ent>", re.DOTALL)
GCIDE_ENT_RE = re.compile(r"<ent>(.*?)</ent>", re.DOTALL)


def parse_gcide(root: Path) -> tuple[list[Row], dict[str, Any]]:
    rows: list[Row] = []
    files: list[dict[str, Any]] = []
    malformed = 0
    excluded_bytes = 0
    encodings: set[str] = set()
    for path in sorted(root.glob("CIDE.[A-Z]"), key=lambda p: p.name):
        raw = path.read_bytes()
        try:
            text = raw.decode("utf-8")
            source_encoding = "UTF-8"
        except UnicodeDecodeError:
            # GCIDE is predominantly ASCII but the distributed CIDE files
            # contain a handful of legacy ISO-8859-1 bytes (for example ç and
            # superscript ¹).  Preserve those source bytes and decode them
            # explicitly into Unicode for the matched projection.
            text = raw.decode("iso-8859-1")
            source_encoding = "ISO-8859-1 (legacy bytes present)"
        encodings.add(source_encoding)
        source_encode = "utf-8" if source_encoding == "UTF-8" else "iso-8859-1"
        starts = list(GCIDE_ENTRY_RE.finditer(text))
        if not starts:
            raise PreparationError(f"GCIDE {path} contains no <p><ent> records")
        excluded_bytes += len(text[: starts[0].start()].encode(source_encode))
        file_records = 0
        for index, start in enumerate(starts):
            stop = starts[index + 1].start() if index + 1 < len(starts) else len(text)
            block = text[start.start():stop]
            if "</p>" not in block:
                malformed += 1
                raise PreparationError(f"GCIDE {path}:{index} has no closing </p>")
            matches = GCIDE_ENT_RE.findall(block)
            if not matches:
                malformed += 1
                raise PreparationError(f"GCIDE {path}:{index} has malformed <ent>")
            # `<ent>` is GCIDE's native alias list: a single paragraph may
            # contain many consecutive ent nodes before its shared `<hw>` and
            # definition.  Keep them all as one record's keys[]; an ent-like
            # cross-reference inside the prose is not a record boundary.
            keys = [html.unescape(value).strip() for value in matches]
            for key in keys:
                require_utf8(key, f"GCIDE {path.name}:{index}")
            if any(not key for key in keys):
                malformed += 1
                raise PreparationError(f"GCIDE {path}:{index} has an empty <ent>")
            # The source is SGML-like, not XML.  Keep the complete span through
            # the next entry boundary, including ent/hw, forms, labels,
            # definitions, citations, sources and cross-references.  This
            # avoids silently losing an intervening paragraph.  The trailing
            # editor comments after the final entry are counted as excluded
            # bytes below, never folded into that entry.
            native_record_bytes = len(block.encode(source_encode))
            if index + 1 == len(starts):
                final_close = block.rfind("</p>")
                if final_close < 0:
                    malformed += 1
                    raise PreparationError(f"GCIDE {path}:{index} has no final closing </p>")
                trailing = block[final_close + len("</p>"):]
                excluded_bytes += len(trailing.encode(source_encode))
                block = block[: final_close + len("</p>")]
                native_record_bytes = len(block.encode(source_encode))
            content = block.replace("\r\n", "\n").replace("\r", "\n")
            ordinal = len(rows)
            rows.append(Row(
                row_id=f"gcide-{ordinal:07d}",
                source_entry_id=f"gcide-{path.name}-{index:07d}",
                source_ordinal=ordinal,
                source_file=str(path.resolve()),
                keys=keys,
                content=content,
                native_record_bytes=native_record_bytes,
                extra={"file": path.name, "file_record": index, "projection": "complete entry SGML span"},
            ))
            file_records += 1
        files.append({"file": path.name, "bytes": len(raw), "records": file_records})
    if [item["file"] for item in files] != [f"CIDE.{chr(ord('A') + i)}" for i in range(26)]:
        raise PreparationError("GCIDE does not contain the complete CIDE.A..CIDE.Z set")
    return rows, {
        "source_bytes": sum(item["bytes"] for item in files),
        "records": len(rows),
        "parse_failures": malformed,
        "front_matter_excluded_bytes": excluded_bytes,
        "files": files,
        "source_format": "GCIDE SGML-like CIDE files",
        "source_encoding": sorted(encodings),
    }


def collect_omw_synsets(source: Path) -> tuple[dict[str, dict[str, Any]], int]:
    synsets: dict[str, dict[str, Any]] = {}
    count = 0
    try:
        for _, element in ET.iterparse(source, events=("end",)):
            if local_name(element.tag) != "Synset":
                continue
            ident = element.attrib.get("id")
            if not ident or ident in synsets:
                raise PreparationError(f"OMW duplicate/missing Synset id near {ident!r}")
            children = [xml_fragment(child) for child in list(element)]
            # Preserve all child classes, including relations in a future OMW
            # revision.  We only avoid recursive graph expansion below.
            synsets[ident] = {
                "id": ident,
                "attributes": {attr_name(k): normalized_text(v) for k, v in sorted(element.attrib.items(), key=lambda pair: attr_name(pair[0]))},
                "children": children,
                "serialized": xml_fragment(element),
            }
            count += 1
            element.clear()
    except ET.ParseError as exc:
        raise PreparationError(f"malformed OMW XML while reading Synset: {exc}") from exc
    return synsets, count


def parse_omw(root: Path) -> tuple[list[Row], dict[str, Any]]:
    source = root / "omw-ja.xml"
    synsets, synset_count = collect_omw_synsets(source)
    rows: list[Row] = []
    malformed = 0
    synset_references = 0
    unique_used: set[str] = set()
    expanded_synset_bytes = 0
    unique_synset_bytes = 0
    for item in synsets.values():
        unique_synset_bytes += len(item["serialized"].encode("utf-8"))
    try:
        for _, element in ET.iterparse(source, events=("end",)):
            if local_name(element.tag) != "LexicalEntry":
                continue
            ordinal = len(rows)
            lemmas = list(iter_children(element, "Lemma"))
            senses = list(iter_children(element, "Sense"))
            if not lemmas or not senses:
                malformed += 1
                raise PreparationError(f"OMW LexicalEntry {ordinal} lacks Lemma or Sense")
            keys = []
            for lemma in lemmas:
                if "writtenForm" not in lemma.attrib:
                    malformed += 1
                    raise PreparationError(f"OMW LexicalEntry {ordinal} Lemma lacks writtenForm")
                keys.append(require_utf8(normalized_text(lemma.attrib["writtenForm"]), f"OMW entry {ordinal}"))
            references: list[dict[str, str]] = []
            ordered_synsets: list[str] = []
            for sense in senses:
                sid = sense.attrib.get("id")
                synset_id = sense.attrib.get("synset")
                if not sid or not synset_id or synset_id not in synsets:
                    malformed += 1
                    raise PreparationError(f"OMW LexicalEntry {ordinal} has unresolved Sense→Synset reference")
                references.append({"id": sid, "synset": synset_id})
                synset_references += 1
                if synset_id not in ordered_synsets:
                    ordered_synsets.append(synset_id)
            for synset_id in ordered_synsets:
                unique_used.add(synset_id)
                expanded_synset_bytes += len(synsets[synset_id]["serialized"].encode("utf-8"))
            lexical_markup = xml_fragment(element)
            sense_markup = "<senses>" + "".join(xml_fragment(sense) for sense in senses) + "</senses>"
            synset_markup = "<synsets>" + "".join(synsets[synset_id]["serialized"] for synset_id in ordered_synsets) + "</synsets>"
            # Every source Sense and all of each referenced Synset's child
            # fields are represented.  No relation target is followed.
            content = lexical_markup + synset_markup
            native = ET.tostring(element, encoding="utf-8")
            rows.append(Row(
                row_id=f"omw-ja-{ordinal:07d}",
                source_entry_id=element.attrib.get("id", f"omw-ja-entry-{ordinal:07d}"),
                source_ordinal=ordinal,
                source_file=str(source.resolve()),
                keys=keys,
                content=content,
                native_record_bytes=len(native),
                extra={
                    "lemma_count": len(lemmas),
                    "sense_count": len(senses),
                    "synset_reference_count": len(references),
                    "unique_synset_count": len(ordered_synsets),
                    "sense_references": references,
                    "synset_ids": ordered_synsets,
                    "projection": "sense refs + nonrecursive synset children",
                },
            ))
            element.clear()
    except ET.ParseError as exc:
        raise PreparationError(f"malformed OMW XML while reading LexicalEntry: {exc}") from exc
    return rows, {
        "source_bytes": source.stat().st_size,
        "records": len(rows),
        "parse_failures": malformed,
        "front_matter_excluded": True,
        "source_format": "OMW LMF XML",
        "synsets": synset_count,
        "definitions": sum(sum(1 for child in item["children"] if child.startswith("<Definition")) for item in synsets.values()),
        "examples": sum(sum(1 for child in item["children"] if child.startswith("<Example")) for item in synsets.values()),
        "synset_references": synset_references,
        "unique_synsets_referenced": len(unique_used),
        "unique_synset_serialized_bytes": unique_synset_bytes,
        "expanded_synset_serialized_bytes": expanded_synset_bytes,
        "expansion_duplication_bytes": expanded_synset_bytes - unique_synset_bytes if expanded_synset_bytes >= unique_synset_bytes else 0,
    }


def write_projection(rows: list[Row], output: Path, *, corpus: str, source_manifest: dict[str, Any], stats: dict[str, Any]) -> dict[str, Any]:
    output.mkdir(parents=True, exist_ok=True)
    projection = output / "projection.tsv"
    metadata = output / "rows.jsonl"
    with projection.open("w", encoding="ascii", newline="\n") as tsv, metadata.open("w", encoding="utf-8", newline="\n") as jsonl:
        for row in rows:
            key_hex = ",".join(key.encode("utf-8").hex() for key in row.keys)
            content_hex = row.content.encode("utf-8").hex()
            tsv.write(f"{row.row_id.encode('utf-8').hex()}\t{key_hex}\t{content_hex}\n")
            jsonl.write(json.dumps(row.metadata(), ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    key_count = sum(len(row.keys) for row in rows)
    unique_keys = len({key for row in rows for key in row.keys})
    empty_keys = sum(1 for row in rows for key in row.keys if not key)
    duplicate_key_hits = key_count - unique_keys
    report = {
        "schema": 1,
        "corpus": corpus,
        "rows": len(rows),
        "unique_keys": unique_keys,
        "key_hits": key_count,
        "empty_key_hits": empty_keys,
        "duplicate_key_hits": duplicate_key_hits,
        "projection_tsv": file_record(projection),
        "rows_jsonl": file_record(metadata),
        "stats": stats,
        "source_manifest": source_manifest,
    }
    (output / "projection-manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def project(cache: Path, output: Path) -> list[dict[str, Any]]:
    source_manifest_path = cache / "source-manifest.json"
    source_manifest = json.loads(source_manifest_path.read_text()) if source_manifest_path.is_file() else fetch(cache)
    roots = {item["id"]: Path(item["extracted_root"]) for item in source_manifest["sources"]}
    specs = [
        ("freedict-eng-spa", parse_freedict),
        ("gcide-054", parse_gcide),
        ("omw-ja-20", parse_omw),
    ]
    reports: list[dict[str, Any]] = []
    for corpus, parser in specs:
        rows, stats = parser(roots[corpus])
        corpus_output = output / corpus
        reports.append(write_projection(rows, corpus_output, corpus=corpus, source_manifest=next(item for item in source_manifest["sources"] if item["id"] == corpus), stats=stats))
        print(f"{corpus}: rows={len(rows)} key_hits={sum(len(row.keys) for row in rows)} bytes={sum(len(row.content.encode('utf-8')) for row in rows)}")
    output.mkdir(parents=True, exist_ok=True)
    overall = {"schema": 1, "corpora": reports, "output": str(output.resolve())}
    (output / "manifest.json").write_text(json.dumps(overall, ensure_ascii=False, indent=2) + "\n")
    return reports


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("fetch", "project"):
        child = sub.add_parser(command)
        child.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
        if command == "project":
            child.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    try:
        if args.command == "fetch":
            manifest = fetch(args.cache_dir)
            print(json.dumps(manifest, ensure_ascii=False, indent=2))
        else:
            reports = project(args.cache_dir, args.output_dir)
            print(json.dumps({"corpora": reports}, ensure_ascii=False, indent=2))
        return 0
    except (OSError, PreparationError, tarfile.TarError) as exc:
        print(f"prepare.py: ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
