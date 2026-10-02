#!/usr/bin/env python3
"""Paid SGN2 vs unchanged M vs whole bzip3; development inputs only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MANIFEST = Path("/workspace/scratch/frontier-corpora/manifest.json")
NAMES = [
    "omw-ja-20-content-development", "omw-cmn-20-content-development",
    "gcide-debian-054-content-development", "freedict-spa-eng-content-development",
    "freedict-eng-fra-content-development", "ud-zh-prose-development",
    "ud-ja-prose-development", "ud-ru-prose-development", "ud-es-prose-development",
    "ud-en-prose-development", "ud-multilingual-prose-development",
]
OLD_UD = {
    f"ud-{lang}-old-form-development-diagnostic":
    REPO / f"src6/experiments/bzip4/language_frontier/evidence/corpora/ud-{lang}-test/form.txt"
    for lang in ("fi", "tr", "ar")
}


def run(cmd):
    process = subprocess.run([str(x) for x in cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if process.returncode:
        raise RuntimeError(f"{cmd}: {process.stderr.decode(errors='replace')[-2000:]}")
    return process


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cap", type=int, default=1048576)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    selected = {row["name"]: row for row in manifest["corpora"]
                if row["name"] in NAMES and row["split"] == "development"}
    if set(selected) != set(NAMES):
        raise ValueError("missing development corpus")
    sources = [(name, Path(selected[name]["path"]), "pinned-development") for name in NAMES]
    sources.extend((name, path, "legacy-development-diagnostic") for name, path in OLD_UD.items())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gen-dev-") as directory, args.output.open("w") as ledger:
        tmp = Path(directory)
        for name, path, scope in sources:
            raw = path.read_bytes()[:args.cap]
            source = tmp / "source.bin"
            frame = tmp / "selected.frame"
            source.write_bytes(raw)
            process = run([sys.executable, HERE / "gen_auto.py", "encode", source, frame])
            report = json.loads(process.stderr.decode().splitlines()[-1])
            if not report["verified_full_and_all_pages"]:
                raise RuntimeError("parity gate missing")
            whole = run(["/workspace/scratch/bzip3", "-c", source]).stdout
            row = dict(name=name, scope=scope, source=str(path), prefix_cap=args.cap,
                       sha256=hashlib.sha256(raw).hexdigest(), raw=len(raw),
                       whole_bzip3=len(whole), **report)
            ledger.write(json.dumps(row, sort_keys=True) + "\n")
            ledger.flush()
            print(name, row["candidate_bytes"], "bzip3", len(whole), flush=True)


if __name__ == "__main__":
    main()
