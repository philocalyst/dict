#!/usr/bin/env python3
"""Prepare real, licensed, pinned multilingual frontier workloads.

The dictionary oracle is the existing independent real-world parser. All fields,
keys, citations, examples and cross-references in that projection are retained.
Compression inputs contain decoded UTF-8 content rather than hexadecimal TSV.
Dictionary development/final partitions use whole source records, assigned before
codec results by SHA-256(source entry ID) mod 5. UD uses official train/dev/test
splits, preserving # text prose and independently exposing integer-ID FORM words.
No corpus is repeated or synthesized to meet a size threshold.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
FD_COMMIT = "5bdceeac8d0dba3298c1bebe734f60d54dad30f7"
UD = [
    ("zh", "UD_Chinese-GSD", "e0d85a020182e264d6384be2a59c0f4879a1cc35", "zh_gsd", "CC BY-SA 4.0"),
    ("ja", "UD_Japanese-GSD", "0f221451aaee08fa03949888ab9d37d0c929299b", "ja_gsd", "CC BY-SA 4.0"),
    ("ru", "UD_Russian-SynTagRus", "6377522610550b696fcc70d39074d2ce03da0e7b", "ru_syntagrus", "CC BY-NC-SA 4.0"),
    ("es", "UD_Spanish-AnCora", "f503b2dfb4bca0a4224668ca31a24f5b9092bd63", "es_ancora", "CC BY 4.0"),
    ("en", "UD_English-EWT", "c5baffde1e106bcd828c520109eb905bfc3ac06f", "en_ewt", "CC BY-SA 4.0"),
]
ARCHIVES = [
    ("omw-2.0.tar.xz", "https://github.com/omwn/omw-data/releases/download/v2.0/omw-2.0.tar.xz", "c369a2ad773a31e182ac4cc753132fa7c31ad423586d6783bacce08090cb8d7d"),
    ("dict-gcide_0.54.tar.xz", "https://deb.debian.org/debian/pool/main/d/dict-gcide/dict-gcide_0.54.tar.xz", "a8aae77ad72a911259e06f066a3ecdeb763ef2f0f0096e84187c82596575a8bd"),
]
# Filled with retained-source hashes after the initial commit-pinned acquisition.
SOURCE_HASHES = {'https://deb.debian.org/debian/pool/main/d/dict-gcide/dict-gcide_0.54.tar.xz': 'a8aae77ad72a911259e06f066a3ecdeb763ef2f0f0096e84187c82596575a8bd',
 'https://github.com/omwn/omw-data/releases/download/v2.0/omw-2.0.tar.xz': 'c369a2ad773a31e182ac4cc753132fa7c31ad423586d6783bacce08090cb8d7d',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/e0d85a020182e264d6384be2a59c0f4879a1cc35/LICENSE.txt': '899b1804a12ebc090b96339614eede1b64b686721b650a71430b55b5235f7f79',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/e0d85a020182e264d6384be2a59c0f4879a1cc35/README.md': 'f9748d8a752833c4fba6ecac6a15e1c87520c5f7ec39db73f6d84d3834e254f4',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/e0d85a020182e264d6384be2a59c0f4879a1cc35/zh_gsd-ud-dev.conllu': '09374c8361400861a536ae94a1d7710e1cdd72285c32b9764d94d2d956b4ae02',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/e0d85a020182e264d6384be2a59c0f4879a1cc35/zh_gsd-ud-test.conllu': 'ff01a3d01d62b623756396085e78bdaeefb7c2b7935a890dde5b18e92712d54f',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Chinese-GSD/e0d85a020182e264d6384be2a59c0f4879a1cc35/zh_gsd-ud-train.conllu': 'de36e605a4786edb00097165cfc0ee425ab668a2dfc1da7ce4652ba4d2585b1e',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/c5baffde1e106bcd828c520109eb905bfc3ac06f/LICENSE.txt': 'b3d1b0f4c6ae151f7eb78738f46ebd5ee140f8a7f76501ba26af123140d35ae7',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/c5baffde1e106bcd828c520109eb905bfc3ac06f/README.md': 'dd74b1b70a6daa0ab3c7d6e53d2048aec1610c55071135ed619734e37500e463',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/c5baffde1e106bcd828c520109eb905bfc3ac06f/en_ewt-ud-dev.conllu': 'de507882611c54f19934f9a65d654b37f55a5c315da1794b9f13348b28b39c12',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/c5baffde1e106bcd828c520109eb905bfc3ac06f/en_ewt-ud-test.conllu': 'b837531faddd54f5c89cf5259cfe5306b075556a9ff19b2271393df29c6b02f8',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/c5baffde1e106bcd828c520109eb905bfc3ac06f/en_ewt-ud-train.conllu': '6fe5692f2e02198262483daba0626efe346dd19f0ce6c3ee7728b08af9b90a9c',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/0f221451aaee08fa03949888ab9d37d0c929299b/LICENSE.txt': '899b1804a12ebc090b96339614eede1b64b686721b650a71430b55b5235f7f79',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/0f221451aaee08fa03949888ab9d37d0c929299b/README.md': '5256741c40fb99fc673967bcbc35c28d09666fb8cee992ee7c20d553a1c0b380',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/0f221451aaee08fa03949888ab9d37d0c929299b/ja_gsd-ud-dev.conllu': '01a371062c5a1cf1ef6cb2c80e9ae53349354cad835ee7c3f3204edd86d18e80',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/0f221451aaee08fa03949888ab9d37d0c929299b/ja_gsd-ud-test.conllu': 'c65d2e7473493cfb3b918638885a4059aa1ffe6848fbe7fae39cd4f9a6fa03e7',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Japanese-GSD/0f221451aaee08fa03949888ab9d37d0c929299b/ja_gsd-ud-train.conllu': 'ccc2ae8c190a33ca69dce2538c69eb28d9b8b4facb90d8b1e4aa6b077b9d1c23',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Russian-SynTagRus/6377522610550b696fcc70d39074d2ce03da0e7b/LICENSE.txt': '3258892bc0af40c43a686e7f7267782778ffacf334acf25301f8f0fdab6c9cbe',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Russian-SynTagRus/6377522610550b696fcc70d39074d2ce03da0e7b/README.md': '15cdbba19238d971c842b0a73944939172e33d802e20c8b4958785aa16027d28',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Russian-SynTagRus/6377522610550b696fcc70d39074d2ce03da0e7b/ru_syntagrus-ud-dev.conllu': '0bde121e58b7daebe7510d52b61154decadb6a42579cbd9abe66fb549fe6cc87',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Russian-SynTagRus/6377522610550b696fcc70d39074d2ce03da0e7b/ru_syntagrus-ud-test.conllu': '97f473474d1aa8c007572cd122f90030bc7dc1707579d56b0b354c19b64af258',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Russian-SynTagRus/6377522610550b696fcc70d39074d2ce03da0e7b/ru_syntagrus-ud-train-a.conllu': '72be9449d83462917410e8d156ea46daeebad06a856c13a7e8bfea636c59d97c',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Spanish-AnCora/f503b2dfb4bca0a4224668ca31a24f5b9092bd63/LICENSE.txt': '653702c7fdee69f7d7a439c9ba4c178c26e745479f6e6d2943bed1a9b9c7bf67',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Spanish-AnCora/f503b2dfb4bca0a4224668ca31a24f5b9092bd63/README.md': '2c5005d1aa9639648356af1f6865185e67e133cf655750990ae06b88762fc2c9',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Spanish-AnCora/f503b2dfb4bca0a4224668ca31a24f5b9092bd63/es_ancora-ud-dev.conllu': 'a7a6f19880955c59f2f7420ffd4739ad4d8b36221e03a4196fc33cf67bf741e9',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Spanish-AnCora/f503b2dfb4bca0a4224668ca31a24f5b9092bd63/es_ancora-ud-test.conllu': 'abee215c3e8ae605421afdcd776986439e1d049e5e25aba89843ad01045a1165',
 'https://raw.githubusercontent.com/UniversalDependencies/UD_Spanish-AnCora/f503b2dfb4bca0a4224668ca31a24f5b9092bd63/es_ancora-ud-train.conllu': 'f235c5dcad8a2c48e71459d66433bbab9e867d13c25c32cd5bc20e7c57f34bca',
 'https://raw.githubusercontent.com/freedict/fd-dictionaries/5bdceeac8d0dba3298c1bebe734f60d54dad30f7/eng-fra/COPYING': '91df39d1816bfb17a4dda2d3d2c83b1f6f2d38d53e53e41e8f97ad5ac46a0cad',
 'https://raw.githubusercontent.com/freedict/fd-dictionaries/5bdceeac8d0dba3298c1bebe734f60d54dad30f7/eng-fra/eng-fra.tei': '5b7e1f657c5902f10ace0a31a6ffa3702ac0b5a49dfcc66883040c2a5e05a9a6',
 'https://raw.githubusercontent.com/freedict/fd-dictionaries/5bdceeac8d0dba3298c1bebe734f60d54dad30f7/spa-eng/COPYING': '91df39d1816bfb17a4dda2d3d2c83b1f6f2d38d53e53e41e8f97ad5ac46a0cad',
 'https://raw.githubusercontent.com/freedict/fd-dictionaries/5bdceeac8d0dba3298c1bebe734f60d54dad30f7/spa-eng/spa-eng.tei': 'd1a48cd5b1fb5111d36243a9ee4a226d2e29b70f0f8a8262b9f334b2b8f6c47c'}


EXTRACTED_HASHES = {'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.A': 'eaf9da63dc67bfc1211365f369723635688f5a91f98a6ec70eb6eb83209bd065',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.B': 'fdef9178fd79759f92c0888a122a98ede1542535a7254a7cd4db1ad303a991d4',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.C': '3931e5db099b7f441eb55ad50cac134a27d5a894a282c4711f6f408c1725c623',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.D': 'f7a35c34c7df563970eabfbacdd9ab21b0e3e2181413ea452f2240091f3bb7d9',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.E': 'c9503ed484ffcbc63e68b80ff10914cca346f049e9584044d15969af15da979e',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.F': '40f247273e986bd3a7a4eff19dd5f5b4e0b0c53bb498a9c44301f7b540bab73f',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.G': 'bab74e9a7da29aa018c91e979e636b7960ecb8446b8745af6f388143695a7f82',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.H': '80be0cba4df4af48390bcbc19f3dc7ac80806a8d62a85f40d39d064cf7393603',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.I': '55df365efb71fd11fb53dbc008854a39a40cdb073d485efe06351c77d9a248ba',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.J': 'bcbe90cb34a7c352fef30efb5aea6651328d760e7c086fb922332e3f75fffad4',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.K': '9b561e2fa2b59e1ce4114348b541bd7f59c98f0f93dd82509192b7f7576fbd58',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.L': 'b0769221ffcf4854669a5e61f2275dd9bd034821a69e215ebef1c0fb7d22fa92',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.M': '38c019f7ee488d6d1a7e89d595da244593908b302b4e9b6bdd352fe96f5cda3e',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.N': 'e3deec6f7c3957f4db1b652335017ca56c2b7f1b776aef2a52b9414a13df602a',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.O': '5986f308cc6e5f4bb9aa1690f0125c948c4d4c155ec48c083c6f767d4c2b3b62',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.P': '60c2490ae5bea27baeb80ef4bcb2fac01c9f2df426ac6ae40d6691b465e37837',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.Q': '095fc85e32df1a88f686508c4c69ff885bd5184fa58331f678342b358ea54fb3',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.R': 'bc8598b13c1efb932ce48897c2b00c16f60c0b5c136f8c7983f28f9ce107f4a5',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.S': 'ecaca2b68f27a7ed4938776a73ca8ad371f635204ef2941edae9655e63c3f4a8',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.T': 'e900170e06ebfc5cad7b2ebf4e1fb692a26b043bd2a3aa2765c2e63355c25189',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.U': '5090d6fd8ea1369eaba84393706e01d58f099bbf140b5a4bb8ba03526a2adb97',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.V': 'a88a9bccd5a4fdd1075654c8e74d26ac3e66d109e6700da9d13e17de6b0ee090',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.W': '09393d101869d5e74e4a2ee2fb2a38014f67f9e94e6c6428ba5d0fd09a91279a',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.X': '2fcd2b2a1dd9934b8ae3002f206543c86888f0b55d28d9f25c6fd79251dfdf03',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.Y': '3341e50f7a792f7cefce80c14a6b486e4bb0bcb7fa6550703cab102707a491de',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/CIDE.Z': 'f965881942cc058071f2db3c9bc3ea3f01d179e04ff9441862a7854687884072',
 'extracted/gcide-debian-054/github-rickysarraf-gcide/debian/copyright': 'd128d33faba7c017487e2770efaa8ee2f0c4f6eb423ae1d06a2d21b6ac303f91',
 'extracted/omw-2.0/omw-2.0/omw-cmn/LICENSE': '81a3cb1f97e120581d67c71424f2de5dd96325d951f991e8a092147a2a4b2321',
 'extracted/omw-2.0/omw-2.0/omw-cmn/omw-cmn.xml': 'c02b74ef813380f2a1de089d6d5aad6c58b50bb06a3ed3c4a8d963160ac40909',
 'extracted/omw-2.0/omw-2.0/omw-ja/LICENSE': 'a4be32a83ad0a1cff9a31c23aaa107be20eb843d97c68a2ff72e10ff5ac17cee',
 'extracted/omw-2.0/omw-2.0/omw-ja/omw-ja.xml': '218b75db8cccf2c64440a18e600692f1eba42b1b619d31e90071ebae91172355'}

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


ORACLE = module("frontier_real_world_oracle", ROOT.parent / "real-world" / "prepare.py")
UD_ORACLE = module("frontier_ud_oracle", REPO / "src6/experiments/bzip4/language_frontier/evidence/prepare_ud.py")


def record(path):
    return ORACLE.file_record(path)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def fetch_one(url, path, expected=None):
    expected = expected or SOURCE_HASHES.get(url)
    if path.is_file() and (not expected or ORACLE.sha(path, "sha256") == expected):
        return record(path) | {"url": url}
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".partial")
    with urllib.request.urlopen(url, timeout=120) as source, partial.open("wb") as target:
        shutil.copyfileobj(source, target, 1 << 20)
    if expected and ORACLE.sha(partial, "sha256") != expected:
        raise ValueError(f"source checksum mismatch: {url}")
    partial.replace(path)
    return record(path) | {"url": url}


def fetch(root):
    jobs = [(url, root / "sources" / name, checksum) for name, url, checksum in ARCHIVES]
    for name in ("spa-eng", "eng-fra"):
        for filename in (name + ".tei", "COPYING"):
            url = f"https://raw.githubusercontent.com/freedict/fd-dictionaries/{FD_COMMIT}/{name}/{filename}"
            jobs.append((url, root / "sources" / "freedict" / name / filename, None))
    for lang, repo, commit, prefix, license_name in UD:
        for filename in ("LICENSE.txt", "README.md", f"{prefix}-ud-dev.conllu", f"{prefix}-ud-test.conllu", f"{prefix}-ud-train{'-a' if lang == 'ru' else ''}.conllu"):
            url = f"https://raw.githubusercontent.com/UniversalDependencies/{repo}/{commit}/{filename}"
            jobs.append((url, root / "sources" / repo / filename, None))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        result = list(pool.map(lambda args: fetch_one(*args), jobs))
    for item in result:
        item["relative_path"] = str(Path(item["path"]).relative_to(root))
    write_json(root / "source-lock.json", {"schema": 1, "sources": result})
    return result


def verify_retained_sources(root):
    # Every archive, raw CoNLL-U, license, source XML/SGML is checked even
    # when a caller reuses the cache with --skip-fetch.
    lock = json.loads((root / "source-lock.json").read_text())
    for item in lock["sources"]:
        expected = SOURCE_HASHES[item["url"]]
        relative = Path(item["relative_path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe retained source path")
        path = root / relative
        if ORACLE.sha(path, "sha256") != expected:
            raise ValueError(f"retained source checksum mismatch: {path}")
    if len(lock["sources"]) != len(SOURCE_HASHES) or {r["url"] for r in lock["sources"]} != set(SOURCE_HASHES):
        raise ValueError("incomplete retained source lock")
    for relative, expected in EXTRACTED_HASHES.items():
        path = root / relative
        if ORACLE.sha(path, "sha256") != expected:
            raise ValueError(f"extracted source checksum mismatch: {path}")


def lane(name, path, language, kind, split, manifest):
    r = record(path)
    return {"name": name, "path": r["path"], "language": language, "kind": kind,
            "split": split, "source_manifest": str(manifest.resolve()), "sha256": r["sha256"], "bytes": r["bytes"]}


def project_dictionary(root, name, language, source_root, parser, source_meta):
    rows, stats = parser(source_root)
    output = root / "dictionaries" / name
    full_report = ORACLE.write_projection(rows, output, corpus=name, source_manifest=source_meta, stats=stats)
    manifests = {"all": full_report}
    lanes = []
    for split in ("all", "development", "final"):
        selected = rows if split == "all" else [r for r in rows if (int(hashlib.sha256(r.source_entry_id.encode()).hexdigest(), 16) % 5 == 0) == (split == "final")]
        dest = output if split == "all" else output / split
        if split != "all":
            manifests[split] = ORACLE.write_projection(selected, dest, corpus=name + "-" + split, source_manifest=source_meta, stats={**stats, "records": len(selected), "split_rule": "SHA-256(source_entry_id) mod 5 == 0 is final; other buckets development"})
        content = dest / "content.txt"
        words = dest / "words.txt"
        with content.open("wb") as out:
            for row in selected:
                out.write(row.content.encode("utf-8")); out.write(b"\n")
        with words.open("wb") as out:
            for row in selected:
                for key in row.keys:
                    out.write(key.encode("utf-8")); out.write(b"\n")
        manifest = dest / "projection-manifest.json"
        if split != "all":
            lanes += [lane(name + "-content-" + split, content, language, "dictionary-content", split, manifest), lane(name + "-words-" + split, words, language, "word-form", split, manifest)]
        print(f"{name} {split}: records={len(selected)} content_bytes={content.stat().st_size}", flush=True)
    write_json(output / "splits-manifest.json", {"schema": 1, "corpus": name, "partitions": manifests})
    return lanes


def project_ud(root):
    lanes = []
    reports = []
    for lang, repo, commit, prefix, license_name in UD:
        source = root / "sources" / repo
        license_record = record(source / "LICENSE.txt")
        for official, split in (("train", "training"), ("dev", "development"), ("test", "final")):
            filename = f"{prefix}-ud-{official}{'-a' if lang == 'ru' and official == 'train' else ''}.conllu"
            raw_path = source / filename
            forms, prose, sentences, tokens, errors = UD_ORACLE.project(raw_path.read_bytes())
            out = root / "ud" / lang / split
            out.mkdir(parents=True, exist_ok=True)
            prose_path = out / "text.txt"; forms_path = out / "forms.txt"
            prose_path.write_bytes(prose); forms_path.write_bytes(forms)
            report = {"schema": 1, "repository": "UniversalDependencies/" + repo, "commit": commit, "ref": "r2.17", "license": license_name, "license_file": license_record, "readme": record(source / "README.md"), "raw": record(raw_path), "official_split": official, "split": split, "sentences": sentences, "tokens": tokens, "malformed_rows": errors,
                      "source_url": f"https://raw.githubusercontent.com/UniversalDependencies/{repo}/{commit}/{filename}",
                      "subset": "official training shard a only" if lang == "ru" and official == "train" else "complete official split", "text_policy": "verbatim # text = sentence comment; one LF per sentence", "forms_policy": "integer-ID FORM fields; ASCII space joined; one LF per sentence", "prose": record(prose_path), "forms": record(forms_path)}
            manifest = out / "source-manifest.json"; write_json(manifest, report); reports.append(report)
            lanes += [lane(f"ud-{lang}-prose-{split}", prose_path, lang, "prose", split, manifest), lane(f"ud-{lang}-forms-{split}", forms_path, lang, "word-form", split, manifest)]
            print(f"UD {lang} {split}: sentences={sentences} prose_bytes={len(prose)}", flush=True)
    for split in ("training", "development", "final"):
        components = [l for l in lanes if l["split"] == split and l["kind"] == "prose"]
        out = root / "ud" / "multilingual" / split; out.mkdir(parents=True, exist_ok=True)
        text = out / "text.txt"; tagged = out / "tagged.txt"
        with text.open("wb") as stream, tagged.open("wb") as tags:
            for part in components:
                data = Path(part["path"]).read_bytes()
                stream.write(data)
                for line in data.splitlines(keepends=True): tags.write(f"[{part['language']}] ".encode() + line)
        report = {"schema": 1, "components": components, "construction": "concatenate en/es/ja/ru/zh official prose once per split, in source table order; tagged lane adds [ISO-language] plus ASCII space per sentence", "bytes_synthesized": "language labels only in tagged lane", "text": record(text), "tagged": record(tagged)}
        manifest = out / "source-manifest.json"; write_json(manifest, report)
        lanes += [lane(f"ud-multilingual-prose-{split}", text, "mul", "multilingual", split, manifest), lane(f"ud-multilingual-tagged-{split}", tagged, "mul", "multilingual", split, manifest)]
    write_json(root / "ud-manifest.json", {"schema": 1, "sources": reports})
    return lanes


def parse_omw_cmn(root):
    rows, stats = ORACLE.parse_omw(root)
    for row in rows:
        row.row_id = f"omw-cmn-{row.source_ordinal:07d}"
    return rows, stats


def project(root):
    extracted = root / "extracted"
    omw_root = extracted / "omw-2.0" / "omw-2.0" / "omw-ja"
    if not all((extracted / "omw-2.0" / "omw-2.0" / name / (name + ".xml")).is_file() for name in ("omw-ja", "omw-cmn")):
        # Extract only declared dictionary sources from the verified release.
        with tarfile.open(root / "sources/omw-2.0.tar.xz", "r:xz") as source:
            for member in source:
                if not member.isfile() or not member.name.startswith(("omw-2.0/omw-ja/", "omw-2.0/omw-cmn/")):
                    continue
                if ".." in Path(member.name).parts:
                    raise ValueError("unsafe source archive member")
                target = extracted / "omw-2.0" / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
    gcide_root = extracted / "gcide-debian-054" / "github-rickysarraf-gcide"
    if not (gcide_root / "CIDE.Z").is_file(): ORACLE.safe_extract(root / "sources/dict-gcide_0.54.tar.xz", extracted / "gcide-debian-054")
    verify_retained_sources(root)
    omw_meta = {"id": "omw-ja-20", "url": ARCHIVES[0][1], "archive": record(root / "sources" / ARCHIVES[0][0]), "license": record(omw_root / "LICENSE"), "version": "2.0", "license_name": "NICT Japanese WordNet license; retained LICENSE", "citation": record(omw_root / "citation.bib")}
    gcide_meta = {"id": "gcide-debian-054", "url": ARCHIVES[1][1], "archive": record(root / "sources" / ARCHIVES[1][0]), "license": record(gcide_root / "debian/copyright"), "version": "Debian dict-gcide 0.54 repack", "license_name": "GPL-3.0-or-later dictionary; see retained debian/copyright", "comparison_note": "different archive from original GNU 0.54; source is declared independently"}
    lanes = project_dictionary(root, "omw-ja-20", "ja", omw_root, ORACLE.parse_omw, omw_meta)
    cmn_source = extracted / "omw-2.0" / "omw-2.0" / "omw-cmn"
    cmn_adapter = extracted / "omw-cmn-adapter"
    cmn_adapter.mkdir(parents=True, exist_ok=True)
    cmn_link = cmn_adapter / "omw-ja.xml"
    if not cmn_link.exists():
        cmn_link.symlink_to((cmn_source / "omw-cmn.xml").resolve())
    cmn_meta = {"id": "omw-cmn-20", "url": ARCHIVES[0][1], "archive": record(root / "sources" / ARCHIVES[0][0]), "license": record(cmn_source / "LICENSE"), "version": "2.0", "license_name": "Chinese Open Wordnet license; retained LICENSE", "citation": record(cmn_source / "citation.bib"), "projection": "same independent complete LMF parser; only technical row ID prefix changes"}
    lanes += project_dictionary(root, "omw-cmn-20", "zh", cmn_adapter, parse_omw_cmn, cmn_meta)
    lanes += project_dictionary(root, "gcide-debian-054", "en", gcide_root, ORACLE.parse_gcide, gcide_meta)
    for name, lang in (("spa-eng", "es"), ("eng-fra", "en")):
        source = root / "sources/freedict" / name
        # The existing parser's filename parameter is fixed. Resolve a source
        # symlink to preserve its true path in every independent oracle row.
        adapter = extracted / ("freedict-" + name); adapter.mkdir(parents=True, exist_ok=True)
        link = adapter / "eng-spa.tei"
        if not link.exists(): link.symlink_to((source / (name + ".tei")).resolve())
        meta = {"id": "freedict-" + name, "repository": "freedict/fd-dictionaries", "commit": FD_COMMIT, "url": f"https://raw.githubusercontent.com/freedict/fd-dictionaries/{FD_COMMIT}/{name}/{name}.tei", "native": record(source / (name + ".tei")), "license": record(source / "COPYING"), "license_name": "GPL-2.0-or-later", "comparison_note": "new source/language pair; not the older eng-spa benchmark"}
        lanes += project_dictionary(root, "freedict-" + name, lang, adapter, ORACLE.parse_freedict, meta)
    lanes += project_ud(root)
    manifest = {"schema": 1, "purpose": "Pinned natural word/prose/dictionary workloads; screen only development; final after candidate freeze", "dictionary_split_rule": "SHA-256(source_entry_id) mod 5 == 0 final, all other buckets development; preserve whole source records", "ud_split_rule": "official train/dev/test, no mixing", "corpora": lanes}
    write_json(root / "manifest.json", manifest)
    print(root / "manifest.json", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output-dir", type=Path, default=Path("/workspace/scratch/frontier-corpora"))
    ap.add_argument("--skip-fetch", action="store_true")
    args = ap.parse_args(); root = args.output_dir.resolve(); root.mkdir(parents=True, exist_ok=True)
    if not args.skip_fetch: fetch(root)
    project(root)


if __name__ == "__main__": main()
