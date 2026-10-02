#!/usr/bin/env python3
"""Make development-only lexical text streams from pinned FreeDict TEI sources."""
import argparse
import hashlib
import json
import pathlib
import xml.etree.ElementTree as ET

SOURCES = pathlib.Path("/workspace/scratch/frontier-corpora/sources/fd-dictionaries")
DATASETS = {
    "arabic": SOURCES / "eng-ara/eng-ara.tei",
    "turkish": SOURCES / "eng-tur/eng-tur.tei",
}
NS = "{http://www.tei-c.org/ns/1.0}"


def project(path, cap):
    output = bytearray()
    entries = 0
    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag != NS + "entry":
            continue
        orth = next(("".join(e.itertext()).strip() for e in element.iter(NS + "orth")), "")
        quotes = ["".join(e.itertext()).strip() for e in element.iter(NS + "quote")]
        if orth or quotes:
            record = (orth + "\t" + " | ".join(quotes) + "\n").encode("utf-8")
            output.extend(record)
            entries += 1
        element.clear()
        if len(output) >= cap:
            break
    return bytes(output[:cap]), entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--bytes", type=int, default=131072)
    a = ap.parse_args()
    if not 1 <= a.bytes <= 1048576:
        ap.error("bytes must be in 1..1048576")
    a.out.mkdir(parents=True, exist_ok=False)
    manifest = {"projection": "first <bytes> of source-order orth TAB quote(s) LF; XML text unescaped by ElementTree",
                "max_bytes": a.bytes, "corpora": {}}
    for name, path in DATASETS.items():
        data, entries = project(path, a.bytes)
        target = a.out / (name + ".bin")
        target.write_bytes(data)
        manifest["corpora"][name] = {
            "source": str(path), "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "projection": str(target), "projection_sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data), "entries": entries,
        }
    (a.out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
