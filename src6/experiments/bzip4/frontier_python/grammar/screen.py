"""Fixed 256 KiB grammar screen with protocol-captured child evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
FRONTIER = ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"
if str(FRONTIER) not in sys.path:
    sys.path.insert(0, str(FRONTIER))

from common import CORPUS_SPECS, SCREEN_END, SCREEN_START, TRAIN_BYTES  # noqa: E402
from protocol.capture import run_and_save  # noqa: E402


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), dest="corpora")
    parser.add_argument("--block-bytes", type=int, default=16 * 1024)
    parser.add_argument("--variants", default="input_huff,input_fixed,training_huff")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--capture-dir", type=Path, default=None)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.block_bytes <= 0:
        raise SystemExit("--block-bytes must be positive")
    variants = [value.strip() for value in args.variants.split(",") if value.strip()]
    allowed = {"input_huff", "input_fixed", "training_huff"}
    if not variants or any(value not in allowed for value in variants):
        raise SystemExit("--variants must be input_huff,input_fixed,training_huff")
    corpora = args.corpora or sorted(CORPUS_SPECS)
    tag = str(args.block_bytes)
    output = args.output or (HERE / "results" / f"screen-{tag}.json")
    capture_dir = args.capture_dir or (HERE / "results" / "raw" / tag)
    records: list[dict[str, object]] = []
    for corpus in corpora:
        for variant in variants:
            stem = f"{corpus}-{variant}-{args.block_bytes}"
            command = [
                sys.executable,
                str(HERE / "worker.py"),
                "--corpus",
                corpus,
                "--variant",
                variant,
                "--block-bytes",
                str(args.block_bytes),
            ]
            capture = run_and_save(command, cwd=ROOT, raw_root=capture_dir, stem=stem, timeout=1200)
            row: dict[str, object] = {
                "corpus": corpus,
                "variant": variant,
                "block_bytes": args.block_bytes,
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
                    if not isinstance(parsed, dict):
                        raise ValueError("worker did not emit a JSON object")
                    row["result"] = parsed
                except Exception as exc:
                    row["status"] = "parse-failed"
                    row["parse_error"] = repr(exc)
            records.append(row)
    ledger = {
        "schema": "frontier-python-global-grammar-screen-1",
        "command": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
        "protocol": {
            "train_range": [0, TRAIN_BYTES],
            "evaluation_range": [SCREEN_START, SCREEN_END],
            "block_bytes": args.block_bytes,
            "variants": variants,
            "input_fit_is_charged": True,
            "raw_capture": "protocol.capture.run_and_save writes stdout/stderr/status before JSON parsing",
        },
        "records": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(ledger, sort_keys=True))
    return 0 if all(row["status"] == "ok" for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
