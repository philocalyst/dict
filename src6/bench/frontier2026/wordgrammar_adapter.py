"""File-mode adapter for frozen WGP5 fast and complete-frame auto encoders."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WGR = REPO / "src6/experiments/wordgrammar/wordgrammar"
MAX_ENCODE = 64 * 1024 * 1024
MAX_FRAME = 512 * 1024 * 1024


def native_record(stderr: bytes) -> dict[str, object]:
    for line in reversed(stderr.decode("utf-8", "replace").splitlines()):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict) and "codec_ns" in record:
            return record
    return {}


def invoke(command: list[str]) -> tuple[bytes, bytes]:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError(f"wordgrammar failed ({result.returncode}): "
                           f"stdout={result.stdout.decode(errors='replace')} "
                           f"stderr={result.stderr.decode(errors='replace')}")
    return result.stdout, result.stderr


def frame_stats(frame_path: Path, raw_bytes: int, expected_block: int) -> dict[str, object]:
    inspect_path = frame_path.with_suffix(frame_path.suffix + ".inspect.json")
    _, stderr = invoke([str(WGR), "inspect", str(frame_path), str(inspect_path)])
    if stderr:
        raise RuntimeError(f"unexpected inspect stderr: {stderr.decode(errors='replace')}")
    stats = json.loads(inspect_path.read_text())
    frame_bytes = frame_path.stat().st_size
    model_bytes = int(stats["model_bytes"])
    directory_bytes = int(stats["directory_bytes"])
    payload_bytes = int(stats["payload_bytes"])
    header_bytes = frame_bytes - model_bytes - directory_bytes - payload_bytes
    records = stats["records"]
    if (int(stats["frame_bytes"]) != frame_bytes or int(stats["raw_bytes"]) != raw_bytes or
            int(stats["block_bytes"]) != expected_block or
            sum(int(record["raw_size"]) for record in records) != raw_bytes or
            header_bytes < 0 or model_bytes < 0 or directory_bytes < 0 or payload_bytes < 0 or
            header_bytes + model_bytes + directory_bytes + payload_bytes != frame_bytes):
        raise ValueError("WGP5 inspect lengths do not account for requested complete frame")
    return {"header_bytes": header_bytes, "model_dictionary_bytes": model_bytes,
            "restart_directory_bytes": directory_bytes, "payload_bytes": payload_bytes,
            "frame_bytes": frame_bytes, "blocks": len(records),
            "block_raw_lengths": [int(record["raw_size"]) for record in records],
            "block_bytes": int(stats["block_bytes"])}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("operation", choices=("encode-fast", "encode-auto", "decode", "extract"))
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--block-bytes", type=int, default=65536)
    ap.add_argument("--block-index", type=int, default=0)
    args = ap.parse_args()
    size = args.input.stat().st_size
    if args.operation.startswith("encode") and size > MAX_ENCODE:
        raise ValueError("WGP5 encoder input exceeds 64 MiB freeze limit")
    if not args.operation.startswith("encode") and size > MAX_FRAME:
        raise ValueError("WGP5 frame exceeds 512 MiB freeze limit")
    if args.operation.startswith("encode"):
        command = [str(WGR), args.operation, str(args.input), str(args.output), str(args.block_bytes)]
    elif args.operation == "decode":
        command = [str(WGR), "decode", str(args.input), str(args.output)]
    else:
        command = [str(WGR), "decode", str(args.input), str(args.output), str(args.block_index)]
    stdout, stderr = invoke(command)
    native = native_record(stderr)
    report: dict[str, object] = {"command": command, "exit_code": 0,
                                 "tool_stdout": stdout.decode("utf-8", "replace"),
                                 "tool_stderr": stderr.decode("utf-8", "replace")}
    if args.operation.startswith("encode"):
        report.update(frame_stats(args.output, size, args.block_bytes))
    report.update({key: native[key] for key in ("codec_ns", "peakrss_kib") if key in native})
    print(json.dumps(report, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"wordgrammar_adapter: {error}", file=sys.stderr)
        raise SystemExit(2)
