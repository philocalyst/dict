#!/usr/bin/env python3
"""Run one benchmark process with portable wall-time and peak-RSS capture.

The runner is deliberately one child per invocation.  The benchmark invokes
it once per fixture family and reader family, so the resulting wall/RSS
values are aggregate observations for that child rather than per-format
measurements.  macOS reports ru_maxrss in bytes; Linux and the other POSIX
targets report KiB.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--stderr", type=Path, required=True)
    parser.add_argument("--stats", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")

    args.stdout.parent.mkdir(parents=True, exist_ok=True)
    args.stderr.parent.mkdir(parents=True, exist_ok=True)
    args.stats.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter_ns()
    with args.stdout.open("wb") as stdout, args.stderr.open("wb") as stderr:
        process = subprocess.Popen(command, cwd=args.cwd, stdout=stdout, stderr=stderr)
        returncode = process.wait()
    elapsed = time.perf_counter_ns() - started
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    rss = int(usage.ru_maxrss)
    if sys.platform != "darwin":
        rss *= 1024
    args.stats.write_text(
        json.dumps(
            {
                "command": command,
                "cwd": str(args.cwd),
                "wall_ns": elapsed,
                "peak_rss_bytes": rss,
                "returncode": returncode,
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
