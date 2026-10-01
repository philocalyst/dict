#!/usr/bin/env python3
"""Run bounded non-timed harness checks and retain their exact output."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
ZIG = Path("/etc/profiles/per-user/mileswirht/bin/zig")


def run(argv: Sequence[str], *, cwd: Path) -> dict[str, Any]:
    try:
        result = subprocess.run(
            list(argv), cwd=cwd, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"argv": list(argv), "cwd": str(cwd), "returncode": None, "stdout": "", "stderr": str(exc), "error": type(exc).__name__}
    return {
        "argv": list(argv), "cwd": str(cwd), "returncode": result.returncode,
        "stdout": result.stdout.decode("utf-8", "replace"),
        "stderr": result.stderr.decode("utf-8", "replace"),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "evidence" / "runs" / "verification.json")
    args = parser.parse_args(argv)
    checks = [
        run([sys.executable, "-m", "unittest", "-v", "test_prepare.py"], cwd=ROOT),
        run([sys.executable, "-m", "py_compile", "prepare.py", "formats.py", "smoke.py", "sweep.py", "legacy_probe.py", "inventory.py", "measure.py", "report.py", "fairness_audit.py", "verification.py"], cwd=ROOT),
        run([str(ZIG), "build", "-Doptimize=ReleaseSafe"], cwd=ROOT),
    ]
    status = "verification-ok" if all(check.get("returncode") == 0 for check in checks) else "verification-failed"
    report = {
        "schema": 1,
        "status": status,
        "timing": "not run",
        "platform": platform.platform(),
        "checks": checks,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": status, "output": str(args.output.resolve())}, indent=2))
    return 0 if status == "verification-ok" else 2


if __name__ == "__main__":
    raise SystemExit(main())
