"""Charged rule-cap ablation for model-versus-payload evidence.

Each point is a real worker subprocess captured through the frozen protocol;
failed or rejected points stay in the ledger.  This is intentionally a small
screen, not a search over corpus-specific knobs.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
FRONTIER = ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from common import CORPUS_SPECS  # noqa: E402
from protocol.capture import run_and_save  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--block-bytes", type=int, default=16 * 1024)
    parser.add_argument("--max-rules", default="1024,2048,3072,4096")
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), dest="corpora")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--capture-dir", type=Path, default=None)
    args = parser.parse_args(argv)
    caps = [int(value) for value in args.max_rules.split(",") if value]
    if not caps or any(value <= 0 for value in caps):
        raise SystemExit("--max-rules must be a comma-separated list of positive integers")
    corpora = args.corpora or sorted(CORPUS_SPECS)
    output = args.output or (HERE / "results" / f"ablation-{args.block_bytes}.json")
    capture_dir = args.capture_dir or (HERE / "results" / "raw" / f"ablation-{args.block_bytes}")
    records: list[dict[str, object]] = []
    for corpus in corpora:
        for max_rules in caps:
            stem = f"{corpus}-input_huff-r{max_rules}-{args.block_bytes}"
            command = [
                sys.executable,
                str(HERE / "worker.py"),
                "--corpus",
                corpus,
                "--variant",
                "input_huff",
                "--block-bytes",
                str(args.block_bytes),
                "--max-rules",
                str(max_rules),
            ]
            capture = run_and_save(command, cwd=ROOT, raw_root=capture_dir, stem=stem, timeout=1200)
            row: dict[str, object] = {
                "corpus": corpus,
                "max_rules": max_rules,
                "command": command,
                "capture": {
                    **capture.record(),
                    "stdout_path": str(capture_dir / f"{stem}.stdout.bin"),
                    "stderr_path": str(capture_dir / f"{stem}.stderr.bin"),
                    "status_path": str(capture_dir / f"{stem}.status.json"),
                },
                "status": "failed" if capture.returncode != 0 else "ok",
            }
            if capture.returncode == 0:
                try:
                    parsed = json.loads(capture.stdout.decode("utf-8"))
                    row["result"] = parsed
                except Exception as exc:
                    row["status"] = "parse-failed"
                    row["parse_error"] = repr(exc)
            records.append(row)
    ledger = {
        "schema": "frontier-python-global-grammar-ablation-1",
        "command": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
        "protocol": {"variant": "input_huff", "block_bytes": args.block_bytes, "rule_caps": caps},
        "records": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(ledger, sort_keys=True))
    return 0 if all(row["status"] == "ok" for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
