#!/usr/bin/env python3
"""Three legacy development form diagnostics, with paid SGF1/M/bzip3 sizes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
CORPORA = HERE.parent / "bzip4" / "language_frontier" / "evidence" / "corpora"


def run(args):
    proc = subprocess.run([str(x) for x in args], capture_output=True, timeout=120)
    if proc.returncode:
        raise RuntimeError(proc.stderr.decode(errors="replace")[-2000:])
    return proc


def main():
    report = HERE / "evidence" / "gen-family-old-ud-forms.jsonl"
    with tempfile.TemporaryDirectory(prefix="family-old-ud-") as folder, report.open("w") as ledger:
        tmp = Path(folder)
        for language in ("fi", "tr", "ar"):
            path = CORPORA / f"ud-{language}-test" / "form.txt"
            source = tmp / "source.bin"
            raw = path.read_bytes()
            source.write_bytes(raw)
            frame = tmp / "selected.frame"
            result = run([sys.executable, HERE / "family_auto.py", "encode", source, frame])
            diagnostic = json.loads(result.stderr.decode().splitlines()[-1])
            if not diagnostic["verified_full_and_all_pages"]:
                raise RuntimeError("parity gate missing")
            bzip3 = run(["/workspace/scratch/bzip3", "-c", source]).stdout
            if diagnostic["source_sha256"] != hashlib.sha256(raw).hexdigest() or diagnostic["raw_bytes"] != len(raw):
                raise RuntimeError("source accounting mismatch")
            row = dict(language=language, scope="legacy-development-diagnostic",
                       source=str(path), whole_bzip3_bytes=len(bzip3), **diagnostic)
            ledger.write(json.dumps(row, sort_keys=True) + "\n")
            ledger.flush()
            print(language, row["candidate_bytes"], "bzip3", len(bzip3), flush=True)


if __name__ == "__main__":
    main()
