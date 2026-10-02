#!/usr/bin/env python3
"""Register complete development books and pin runnable codec specifications."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
EXPERIMENTS = HERE.parents[1] / "experiments"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def pin(paths) -> dict[str, str]:
    paths = {Path(p).resolve() for p in paths}
    # Include ELF dynamic linkage. Static readers return a nonzero ldd code.
    for path in tuple(paths):
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        result = subprocess.run(["ldd", str(path)], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            for token in line.split():
                library = Path(token)
                if token.startswith("/") and library.is_file():
                    paths.add(library.resolve())
                    break
    return {str(p): digest(p) for p in sorted(paths)}


def file_record(record) -> dict:
    p = Path(record["path"])
    if p.is_symlink() or not p.is_file() or not p.is_absolute():
        raise ValueError("source must be an absolute regular file")
    if p.stat().st_size != record["bytes"] or digest(p) != record["sha256"]:
        raise ValueError(f"source lock mismatch: {p}")
    return {key: record[key] for key in ("path", "bytes", "sha256")}


def write(path: Path, value) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--bzip3", type=Path, required=True)
    parser.add_argument("--backend-dir", type=Path, required=True)
    parser.add_argument("--native-reader", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("role") != "development":
        raise ValueError("this tool registers development books only")
    cases = []
    for book in manifest["books"]:
        prefix = next(p for p in book["prefixes"] if p["byte_limit"] == 131072)
        cases.append({"id": book["id"], "split": "development", "kind": "book",
                      "language": book["language"], "work_id": book["id"],
                      "source": file_record(book["full"]), "prefix": file_record(prefix),
                      "author": book["author"], "title": book["title"]})
    registry = {"schema": 1, "source_manifest_sha256": digest(args.manifest),
                "source_manifest": str(args.manifest.resolve()), "cases": cases}
    python = Path(sys.executable).resolve()
    adapter = HERE / "codec_adapter.py"
    specs = {}
    for codec in ("bzip3", "bzip2", "zstd", "xz"):
        binary = args.bzip3.resolve() if codec == "bzip3" else Path(shutil.which(codec)).resolve()
        specs[codec] = {
            "id": f"{codec}-whole-native", "parent": "standard-controls",
            "mechanism": "ordinary complete native archive, no comparison wrapper",
            "hypothesis": "Reference whole-file compression on the identical exact source.",
            "decisive_test": "Every registered complete book decodes exactly in a fresh process.",
            "backend_class": "control",
            "model_accounting": {"kind": "universal_code", "data_dependencies": [],
                                 "embedded_learned_bytes": 0},
            "encode_argv": [str(python), str(adapter), "encode", codec, str(binary), "{input}", "{frame}"],
            "decode_argv": [str(python), str(adapter), "decode", codec, str(binary), "{frame}", "{output}"],
            "dependencies": pin((python, adapter, binary)),
            "limits": {"timeout_seconds": 600, "max_raw_bytes": 32 * 1024**2,
                       "max_frame_bytes": 64 * 1024**2}}
    module_path = EXPERIMENTS / "wordfrontier" / "wordfrontier.py"
    module_spec = importlib.util.spec_from_file_location("wordfrontier_specs", module_path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    dependencies = module.dependency_paths(args.backend_dir.resolve(), "encode")
    dependencies.extend((python, args.native_reader.resolve()))
    # NumPy is encoder-only. Pin its installed Python and native runtime files;
    # the standalone delivered-frame reader uses neither Python nor NumPy.
    import numpy
    numpy_root = Path(numpy.__file__).resolve().parent
    for directory in (numpy_root, numpy_root.parent / "numpy.libs"):
        if directory.is_dir():
            dependencies.extend(p for p in directory.rglob("*") if p.is_file()
                                and (p.suffix in (".py", ".so") or ".so." in p.name)
                                and "tests" not in p.parts)
    specs["wordfrontier"] = {
        "id": "wordfrontier-quality-whole-books-r0", "parent": "wordfrontier-global-1",
        "mechanism": "fixed paid WPG2/GWT1 automatic quality policy with 64KiB original pages",
        "hypothesis": "Earlier dictionary constructors may fail to predict whole-book prose; measure that gap directly.",
        "decisive_test": "Exact full delivery-frame bytes on all six complete books versus ordinary bzip3 archives.",
        "backend_class": "self_contained",
        "model_accounting": {"kind": "frame_learned_only", "data_dependencies": [],
                             "embedded_learned_bytes": 0},
        "encode_argv": [str(python), str(module_path), "encode", "{input}", "{frame}",
                        "--profile", "quality", "--backend-dir", str(args.backend_dir.resolve())],
        "decode_argv": [str(args.native_reader.resolve()), "decode", "{frame}", "{output}"],
        "dependencies": pin(dependencies),
        "limits": {"timeout_seconds": 3600, "max_raw_bytes": 32 * 1024**2,
                   "max_frame_bytes": 192 * 1024**2 + 65536}}
    args.out.mkdir(parents=True, exist_ok=True)
    write(args.out / "cases.json", registry)
    for name, spec in specs.items():
        write(args.out / f"{name}.json", spec)
    write(args.out / "registration.json", {
        "generator": str(Path(__file__).resolve()), "generator_sha256": digest(Path(__file__)),
        "files": {str(p): digest(p) for p in sorted(args.out.glob("*.json"))},
        "role": "development only; no validation outcome opened"})
    print(json.dumps({"cases": len(cases), "specifications": list(specs), "out": str(args.out)}))


if __name__ == "__main__":
    main()
