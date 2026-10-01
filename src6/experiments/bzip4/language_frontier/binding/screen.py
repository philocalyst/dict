"""Serial cheap screen for the one-hole binding hypothesis.

The screen uses the frozen frontier corpus protocol, trains on the first MiB,
and evaluates the exact 256 KiB development window.  It also invokes the
already-built v4 binary one corpus at a time as a labelled end-to-end control.
No timing result is collected; subprocess elapsed time is intentionally not
recorded as a codec benchmark.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import zlib

from frontier_python import common

from .codec import decode, encode, frame_info, model_info, train


ROOT = Path(__file__).resolve().parents[5]
V4 = ROOT / "src6" / "experiments" / "bzip4" / "bz4" / "v3" / "zig-out" / "bin" / "bz4"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _v4_control(data: bytes, directory: Path) -> dict[str, object]:
    if not V4.is_file():
        return {"status": "missing", "path": str(V4)}
    source = directory / "input.bin"
    packed = directory / "v4.bz4"
    restored = directory / "v4.restored"
    source.write_bytes(data)
    command_c = [str(V4), "c", str(source), str(packed), "65536"]
    result_c = subprocess.run(command_c, check=False, capture_output=True, text=True)
    if result_c.returncode:
        return {
            "status": "compress_failed",
            "returncode": result_c.returncode,
            "stderr": result_c.stderr[-4000:],
            "command": command_c,
        }
    command_d = [str(V4), "d", str(packed), str(restored), "1"]
    result_d = subprocess.run(command_d, check=False, capture_output=True, text=True)
    if result_d.returncode:
        return {
            "status": "decompress_failed",
            "returncode": result_d.returncode,
            "stderr": result_d.stderr[-4000:],
            "command_c": command_c,
            "command_d": command_d,
        }
    restored_bytes = restored.read_bytes()
    return {
        "status": "ok" if restored_bytes == data else "roundtrip_mismatch",
        "bytes": packed.stat().st_size,
        "sha256": _sha256(packed.read_bytes()),
        "decoded_sha256": _sha256(restored_bytes),
        "command_c": command_c,
        "command_d": command_d,
        "binary": str(V4),
    }


def run(corpora: list[str], output: Path) -> list[dict[str, object]]:
    output.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    versions = {
        "python": sys.version.split()[0],
        "zlib": zlib.ZLIB_VERSION,
        "v4_binary_sha256": _sha256(V4.read_bytes()) if V4.is_file() else None,
    }
    commands = {
        "screen": "training=[0,1048576), evaluation=[1048576,1310720), block=65536",
        "binding": "max_templates=96,max_bindings=512,min_uses=2,max_context=1024",
        "backend": "zlib-diagnostic(level=9); v4 control serial subprocess",
    }
    for corpus in corpora:
        training, evaluation = common.corpus_partition(corpus, "screen")
        model = train(training)
        frame = encode(model, evaluation, block_bytes=64 * 1024)
        decoded = decode(frame)
        if decoded != evaluation:
            raise RuntimeError(f"binding round trip failed for {corpus}")
        with tempfile.TemporaryDirectory(prefix="binding-screen-") as temporary:
            v4 = _v4_control(evaluation, Path(temporary))
        info = frame_info(frame)
        row: dict[str, object] = {
            "corpus": corpus,
            "status": "ok",
            "input_bytes": len(evaluation),
            "input_sha256": _sha256(evaluation),
            "binding_sha256": _sha256(frame),
            "binding": info,
            "model": model_info(model),
            "raw_zlib_bytes": len(zlib.compress(evaluation, 9)),
            "v4": v4,
            "commands": commands,
            "versions": versions,
        }
        rows.append(row)
    output.write_text(json.dumps({"version": 1, "rows": rows}, indent=2, sort_keys=True) + "\n")
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("results.screen.json"))
    parser.add_argument("corpus", nargs="*", default=["freedict-eng-spa", "gcide-054", "omw-ja-20"])
    args = parser.parse_args()
    rows = run(args.corpus, args.output)
    for row in rows:
        binding = row["binding"]
        v4 = row["v4"]
        print(
            row["corpus"],
            "binding=",
            binding["frame_bytes"],
            "v4=",
            v4.get("bytes", "NA"),
            "templates=",
            binding["templates"],
            "bindings=",
            binding["bindings"],
        )


if __name__ == "__main__":
    main()
