"""Run the ordinary input-fit A/F screen with exact subprocess captures.

Unlike the frozen-prefix screen, each child trains on the exact 256 KiB slice
that it then encodes.  The serialized model is still part of every complete
frame, so this is an ordinary compression measurement and makes no prediction
claim about unseen bytes.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
if str(ROOT / "src6" / "experiments" / "bzip4" / "frontier_python") not in sys.path:
    sys.path.insert(0, str(ROOT / "src6" / "experiments" / "bzip4" / "frontier_python"))

from common import (  # noqa: E402
    CORPUS_SPECS,
    SCREEN_END,
    SCREEN_START,
    corpus_spec,
    load_corpus,
    projection_fingerprint,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", action="append", choices=sorted(CORPUS_SPECS), dest="corpora")
    parser.add_argument("--block-bytes", type=int, default=16 * 1024)
    parser.add_argument("--variants", default="AF")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, required=True)
    return parser


def _run_one(corpus_name: str, variant: str, block_bytes: int, capture_dir: Path) -> dict[str, object]:
    stem = f"{corpus_name}-{variant}-{block_bytes}"
    stdout_path = capture_dir / f"{stem}.stdout"
    stderr_path = capture_dir / f"{stem}.stderr"
    command = [
        sys.executable,
        str(HERE / "input_fit_worker.py"),
        "--corpus",
        corpus_name,
        "--variant",
        variant,
        "--block-bytes",
        str(block_bytes),
    ]
    completed = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    capture_dir.mkdir(parents=True, exist_ok=True)
    # Persist exact child streams before attempting JSON parsing.
    stdout_path.write_bytes(completed.stdout)
    stderr_path.write_bytes(completed.stderr)
    result: dict[str, object] = {
        "corpus": corpus_name,
        "variant": variant,
        "block_bytes": block_bytes,
        "selection": "measured",
        "status": completed.returncode,
        "returncode": completed.returncode,
        "command": command,
        "raw_stdout": str(stdout_path),
        "raw_stderr": str(stderr_path),
    }
    if completed.returncode == 0:
        try:
            parsed = json.loads(completed.stdout.decode("utf-8"))
            if not isinstance(parsed, dict):
                raise ValueError("worker stdout is not a JSON object")
            result.update(parsed)
            result["status"] = completed.returncode
        except Exception as exc:
            result["parse_error"] = repr(exc)
            result["status"] = 1
    elif completed.stderr:
        result["stderr_bytes"] = len(completed.stderr)
    return result


def main() -> int:
    args = _parser().parse_args()
    variants = "".join(dict.fromkeys(args.variants.upper()))
    if not variants or any(variant not in "AF" for variant in variants):
        _parser().error("--variants must contain only A or F")
    if args.block_bytes <= 0:
        _parser().error("--block-bytes must be positive")
    corpora = args.corpora or sorted(CORPUS_SPECS)
    records: list[dict[str, object]] = []
    for corpus_name in corpora:
        spec = corpus_spec(corpus_name)
        projection_fingerprint(spec)
        data = load_corpus(spec)
        if len(data) < SCREEN_END:
            raise RuntimeError(f"{corpus_name} is too short for fixed screen")
        # Keep the partition explicit in the parent process as well as the
        # child record; this prevents an accidental fit on the training prefix.
        if SCREEN_END - SCREEN_START != 256 * 1024:
            raise RuntimeError("input-fit protocol is not the fixed 256 KiB screen")
        for variant in variants:
            records.append(_run_one(corpus_name, variant, args.block_bytes, args.capture_dir))
    ledger = {
        "schema": "bwt-context-input-fit-screen-1",
        "command": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "environment": {"python": sys.version, "platform": platform.platform(), "machine": platform.machine()},
        "protocol": {
            "screen_range": [SCREEN_START, SCREEN_END],
            "screen_bytes": SCREEN_END - SCREEN_START,
            "block_bytes": args.block_bytes,
            "variants": variants,
            "training_scope": "same_screen_input",
            "ordinary_compression": True,
            "prediction_claim": False,
            "model_and_frame_bytes_charged": True,
            "raw_capture": "one exact child stdout and stderr file per corpus/variant; status is recorded before JSON parsing",
        },
        "records": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(ledger, sort_keys=True))
    return 0 if all(record["status"] == 0 for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
