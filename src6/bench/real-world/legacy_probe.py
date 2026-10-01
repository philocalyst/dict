#!/usr/bin/env python3
"""Record non-timed availability probes for frozen LEX5/src2/src4 APIs.

The probe uses isolated cache/prefix directories and never edits the legacy
source or benchmark trees.  A successful compile is not silently promoted to
a real-corpus lane: the old frontends still need an explicit semantic adapter,
which this real-world harness does not invent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parents[3]
OWNED = Path(__file__).resolve().parent


def file_hash(path: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            size += len(chunk)
            digest.update(chunk)
    return {"path": str(path.resolve()), "bytes": size, "sha256": digest.hexdigest()}


def run_capture(argv: Sequence[str], *, cwd: Path, env: dict[str, str]) -> dict[str, Any]:
    try:
        process = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return {"argv": list(argv), "cwd": str(cwd), "returncode": None, "stdout": "", "stderr": str(exc), "error": str(exc)}
    return {"argv": list(argv), "cwd": str(cwd), "returncode": process.returncode, "stdout": process.stdout.decode("utf-8", "replace"), "stderr": process.stderr.decode("utf-8", "replace")}


def source_inventory() -> list[dict[str, Any]]:
    paths: list[Path] = []
    for directory in (ROOT / "src5", ROOT / "src4", ROOT / "src2"):
        paths.extend(sorted(directory.rglob("*.zig")))
    paths.extend(path for path in (ROOT / "build5.zig", ROOT / "build4.zig", OWNED.parent / "build_src2.zig", OWNED.parent / "src2_main.zig", OWNED.parent / "bench_main.zig") if path.is_file())
    return [file_hash(path) for path in paths]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OWNED / "evidence" / "runs" / "legacy-availability.json")
    parser.add_argument("--isolation-root", type=Path, default=Path("/tmp/dictionary-real-world-legacy-probe"))
    args = parser.parse_args(argv)
    args.isolation_root.mkdir(parents=True, exist_ok=True)
    zig = shutil.which("zig") or "/etc/profiles/per-user/mileswirht/bin/zig"
    env = dict(os.environ)
    commands = [
        {
            "lane": "lex5-tests",
            "cwd": ROOT,
            "argv": [zig, "build", "--build-file", "build5.zig", "test", "-Doptimize=ReleaseSafe", "--prefix", str(args.isolation_root / "lex5-prefix"), "--cache-dir", str(args.isolation_root / "lex5-cache"), "--global-cache-dir", str(args.isolation_root / "global-cache")],
            "artifact": None,
            "interpretation": "LEX5 source tests only; no current real-corpus reader/build frontend is exposed by src5/root.zig or build5.zig",
        },
        {
            "lane": "src4-bench-frontend",
            "cwd": ROOT,
            "argv": [zig, "build", "--build-file", "build4.zig", "bench4", "-Doptimize=ReleaseSafe", "--prefix", str(args.isolation_root / "src4-prefix"), "--cache-dir", str(args.isolation_root / "src4-cache"), "--global-cache-dir", str(args.isolation_root / "global-cache")],
            "artifact": args.isolation_root / "src4-prefix" / "bin" / "lex4-bench",
            "interpretation": "src4 executable build probe; its bench4 protocol requires a semantic fixture adapter, not the real projection TSV",
        },
        {
            "lane": "src2-bench-frontend",
            "cwd": ROOT / "bench4",
            "argv": [zig, "build", "--build-file", "build_src2.zig", "-Doptimize=ReleaseSafe", "--prefix", str(args.isolation_root / "src2-prefix"), "--cache-dir", str(args.isolation_root / "src2-cache"), "--global-cache-dir", str(args.isolation_root / "global-cache")],
            "artifact": args.isolation_root / "src2-prefix" / "bin" / "src2-bench",
            "interpretation": "src2 executable build probe; its bench4 protocol requires a semantic fixture adapter, not the real projection TSV",
        },
    ]
    results: list[dict[str, Any]] = []
    for command in commands:
        result = run_capture(command["argv"], cwd=command["cwd"], env=env)
        artifact = command["artifact"]
        result["lane"] = command["lane"]
        result["interpretation"] = command["interpretation"]
        if artifact is not None and artifact.is_file():
            result["artifact"] = file_hash(artifact)
            result["status"] = "compiled-but-no-real-corpus-adapter"
        elif result["returncode"] == 0:
            result["status"] = "compiled-artifact-path-not-found"
        else:
            result["status"] = "unavailable-build-failure"
        results.append(result)

    executable_probes: list[dict[str, Any]] = []
    for result in results:
        artifact = result.get("artifact", {}).get("path") if isinstance(result.get("artifact"), dict) else None
        if artifact:
            executable_probes.append({"lane": result["lane"], "help_or_usage": run_capture([artifact, "--help"], cwd=Path(artifact).parent, env=env)})

    report = {
        "schema": 1,
        "status": "probe-complete",
        "timing": "not run",
        "platform": {"system": platform.platform(), "python": sys.version, "zig": run_capture([zig, "version"], cwd=ROOT, env=env)},
        "isolation_root": str(args.isolation_root.resolve()),
        "source_inventory": source_inventory(),
        "commands": results,
        "executable_usage": executable_probes,
        "lane_policy": "Successful frozen src2/src4 compilation is retained as availability evidence only. No adapter is claimed until the real projection's full identities, aliases, payloads, query semantics, and content are represented without loss; LEX5 has no benchmark frontend in this repository.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "output": str(args.output.resolve()), "lanes": [{"lane": item["lane"], "status": item["status"], "returncode": item["returncode"]} for item in results]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
