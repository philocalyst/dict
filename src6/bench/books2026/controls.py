#!/usr/bin/env python3
"""Paid whole-book standard-codec size controls, with fresh exact decode."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_to_file(argv: list[str], output: Path) -> dict:
    start = time.monotonic_ns()
    with output.open("wb") as sink:
        result = subprocess.run(argv, stdout=sink, stderr=subprocess.PIPE, timeout=600)
    wall = time.monotonic_ns() - start
    if result.returncode:
        raise RuntimeError(f"control failed {argv!r}: {result.stderr.decode(errors='replace')}")
    return dict(argv=argv, diagnostic_process_wall_ns=wall,
                stderr=result.stderr.decode(errors="replace"), exit_code=result.returncode)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path("/workspace/scratch/books2026-dev/manifest.json"))
    parser.add_argument("--out", type=Path, default=Path("/workspace/scratch/books2026-dev/controls"))
    parser.add_argument("--bzip3", type=Path, default=Path("/workspace/scratch/bzip3"))
    parser.add_argument("--input-kind", choices=("full", "prefix-1048576"), default="full")
    parser.add_argument("--codecs", default="bzip3,zstd,bzip2,xz")
    args = parser.parse_args()
    harness = Path(__file__).resolve()
    harness_sha = sha(harness)
    selected_codecs = args.codecs.split(",")
    if not selected_codecs or len(set(selected_codecs)) != len(selected_codecs) or any(
            name not in ("bzip3", "zstd", "bzip2", "xz") for name in selected_codecs):
        raise ValueError("unknown or repeated control codec")
    manifest_sha = sha(args.manifest)
    manifest = json.loads(args.manifest.read_text())
    if manifest["role"] != "development":
        raise ValueError("reserved books must not be compressed before candidate freeze")
    args.out.mkdir(parents=True, exist_ok=True)
    binaries = dict(bzip3=str(args.bzip3.resolve()))
    for name in ("bzip2", "zstd", "xz"):
        binary = shutil.which(name)
        if binary is None:
            raise FileNotFoundError(name)
        binaries[name] = str(Path(binary).resolve())
    versions = dict(bzip3=["-V"], bzip2=["-V"], zstd=["--version"], xz=["--version"])
    tools = []
    for name, path in binaries.items():
        version = subprocess.run([path] + versions[name], capture_output=True, check=False)
        linkage = subprocess.run(["ldd", path], capture_output=True, check=False)
        libraries = []
        for line in linkage.stdout.decode().splitlines():
            for token in line.split():
                if token.startswith("/") and Path(token).is_file():
                    libraries.append(dict(path=token, sha256=sha(Path(token))))
                    break
        tools.append(dict(name=name, path=path, sha256=sha(Path(path)),
                          version=(version.stdout + version.stderr).decode(errors="replace").strip(),
                          dynamic_libraries=libraries))
    rows = []
    report = dict(schema=1, role="development", harness=str(harness), harness_sha256=harness_sha,
                  source_manifest=str(args.manifest.resolve()),
                  source_manifest_sha256=manifest_sha, tools=tools,
                  input_kind=args.input_kind,
                  clocks="Diagnostic one-shot process wall clocks include file I/O/startup and competing experiments; no performance comparison claim.",
                  block_policy="Exact selected input in one native frame, no truncation. bzip3 uses a32MiB single block; other codecs use declared native settings.",
                  candidates=dict(bzip3="1.5.1 -b32 (pinned non-threaded CLI build)", zstd="19 --single-thread", bzip2="9 (900KiB native blocks)", xz="9 --threads=1 --check=crc64"),
                  rows=rows)
    for book in manifest["books"]:
        selected = book["full"] if args.input_kind == "full" else next(
            row for row in book["prefixes"] if row["byte_limit"] == 1048576)
        source = Path(selected["path"])
        if sha(source) != selected["sha256"] or source.stat().st_size != selected["bytes"]:
            raise ValueError("complete source differs from frozen corpus manifest")
        candidates = [
            ("bzip3", ["-c", "-b", "32"], ["-d", "-c"]),
            ("zstd", ["-q", "--no-progress", "-19", "--single-thread", "-c"], ["-q", "-d", "-c"]),
            ("bzip2", ["-9", "-c"], ["-d", "-c"]),
            ("xz", ["-9", "--threads=1", "--check=crc64", "-c"], ["-d", "-c"]),
        ]
        for name, encode_flags, decode_flags in candidates:
            if name not in selected_codecs:
                continue
            frame = args.out / (book["id"] + "." + name)
            decoded = args.out / (book["id"] + "." + name + ".decoded")
            encode = run_to_file([binaries[name]] + encode_flags + [str(source)], frame)
            decode = run_to_file([binaries[name]] + decode_flags + [str(frame)], decoded)
            if decoded.stat().st_size != source.stat().st_size or sha(decoded) != selected["sha256"]:
                raise ValueError("fresh control decode mismatches exact complete UTF8 book")
            decoded.unlink()
            row = dict(book=book["id"], codec=name, source_bytes=source.stat().st_size,
                       source_sha256=selected["sha256"], frame=str(frame.resolve()),
                       complete_frame_bytes=frame.stat().st_size, frame_sha256=sha(frame),
                       encode=encode, fresh_decode=decode, exact_source_verified=True)
            rows.append(row)
            (args.out / "controls.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps(dict(book=row["book"], codec=name, bytes=row["complete_frame_bytes"], exact=True)), flush=True)
        if sha(source) != selected["sha256"]:
            raise ValueError("input changed during controls")
    if sha(args.manifest) != manifest_sha:
        raise ValueError("manifest changed during controls")
    if sha(harness) != harness_sha:
        raise ValueError("control harness changed during capture")
    for tool in tools:
        if sha(Path(tool["path"])) != tool["sha256"]:
            raise ValueError("tool changed during controls")
        for library in tool["dynamic_libraries"]:
            if sha(Path(library["path"])) != library["sha256"]:
                raise ValueError("dynamic library changed during controls")
    report["complete"] = True
    (args.out / "controls.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(report=str((args.out / "controls.json").resolve()), sha256=sha(args.out / "controls.json"), cells=len(rows))))


if __name__ == "__main__":
    main()
