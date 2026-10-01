"""Size-only final 8 MiB input-fit grammar screen after the lead gate."""

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
    parser.add_argument("--max-rules", type=int, default=4096)
    parser.add_argument("--max-passes", type=int, default=10)
    parser.add_argument("--pair-policy", choices=("overlap_greedy", "consistent"), default="overlap_greedy")
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), dest="corpora")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--capture-dir", type=Path, default=None)
    args = parser.parse_args(argv)
    corpora = args.corpora or sorted(CORPUS_SPECS)
    output = args.output or (HERE / "results" / f"final-input-huff-r{args.max_rules}-p{args.max_passes}-{args.pair_policy}-{args.block_bytes}.json")
    capture_dir = args.capture_dir or (HERE / "results" / "raw" / f"final-input-huff-r{args.max_rules}-p{args.max_passes}-{args.pair_policy}-{args.block_bytes}")
    records: list[dict[str, object]] = []
    for corpus in corpora:
        stem = f"{corpus}-input_huff-final-{args.block_bytes}"
        command = [
            sys.executable,
            str(HERE / "worker.py"),
            "--corpus",
            corpus,
            "--variant",
            "input_huff",
            "--lane",
            "final",
            "--block-bytes",
            str(args.block_bytes),
            "--max-rules",
            str(args.max_rules),
            "--max-passes",
            str(args.max_passes),
            "--pair-policy",
            args.pair_policy,
        ]
        capture = run_and_save(command, cwd=ROOT, raw_root=capture_dir, stem=stem, timeout=3600)
        row: dict[str, object] = {
            "corpus": corpus,
            "block_bytes": args.block_bytes,
            "lane": "final",
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
                row["result"] = json.loads(capture.stdout.decode("utf-8"))
            except Exception as exc:
                row["status"] = "parse-failed"
                row["parse_error"] = repr(exc)
        records.append(row)
    ledger = {
        "schema": "frontier-python-global-grammar-final-1",
        "command": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
        "protocol": {"lane": "final", "block_bytes": args.block_bytes, "variant": "input_huff", "max_rules": args.max_rules, "max_passes": args.max_passes, "pair_policy": args.pair_policy},
        "records": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(ledger, sort_keys=True))
    return 0 if all(row["status"] == "ok" for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
