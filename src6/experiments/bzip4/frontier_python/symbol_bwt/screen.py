"""Protocol-captured 256 KiB symbol-BWT size gate at 16/64 KiB blocks."""

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
    parser.add_argument("--max-rules", type=int, default=8192)
    parser.add_argument("--max-passes", type=int, default=24)
    parser.add_argument("--pair-policy", choices=("consistent", "overlap_greedy"), default="consistent")
    parser.add_argument("--lane", choices=("screen", "final", "untouched"), default="screen")
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), dest="corpora")
    parser.add_argument("--block-bytes", action="append", type=int, dest="blocks")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--capture-dir", type=Path, default=None)
    parser.add_argument("--frame-dir", type=Path, default=None)
    args = parser.parse_args(argv)
    corpora = args.corpora or sorted(CORPUS_SPECS)
    blocks = args.blocks or [16 * 1024, 64 * 1024]
    tag = f"{args.lane}-r{args.max_rules}-p{args.max_passes}-{args.pair_policy}"
    output = args.output or (HERE / "results" / f"{tag}.json")
    capture_dir = args.capture_dir or (HERE / "results" / "raw" / tag)
    records: list[dict[str, object]] = []
    lane_bytes = {"screen": 256 * 1024, "final": 8 * 1024 * 1024, "untouched": 1024 * 1024}[args.lane]
    for corpus in corpora:
        for block_bytes in blocks:
            stem = f"{corpus}-{block_bytes}"
            command = [
                sys.executable,
                "-B",
                str(HERE / "worker.py"),
                "--corpus",
                corpus,
                "--block-bytes",
                str(block_bytes),
                "--max-rules",
                str(args.max_rules),
                "--max-passes",
                str(args.max_passes),
                "--pair-policy",
                args.pair_policy,
                "--lane",
                args.lane,
            ]
            if args.frame_dir is not None:
                command.extend(["--frame-path", str(args.frame_dir / f"{corpus}-{block_bytes}.sbw1")])
            capture = run_and_save(command, cwd=ROOT, raw_root=capture_dir, stem=stem, timeout=1800)
            row: dict[str, object] = {
                "corpus": corpus,
                "block_bytes": block_bytes,
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
        "schema": "frontier-python-symbol-bwt-size-screen-1",
        "command": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
        "protocol": {
            "lane": args.lane,
            "raw_bytes": lane_bytes,
            "training_bytes": 1048576,
            "blocks": blocks,
            "max_rules": args.max_rules,
            "max_passes": args.max_passes,
            "pair_policy": args.pair_policy,
            "fit_scope": "input",
            "frame_dir": str(args.frame_dir) if args.frame_dir is not None else None,
        },
        "raw_capture": "protocol.capture.run_and_save wrote stdout/stderr/status before JSON parsing",
        "records": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(ledger, sort_keys=True))
    return 0 if all(row["status"] == "ok" for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
