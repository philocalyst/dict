#!/usr/bin/env python3
"""Turn portable process-runner JSON (or legacy time output) into metadata."""

from __future__ import annotations

import re
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: parse_time.py TIME_FILE FIXTURE FORMAT")
    path = Path(sys.argv[1])
    text = path.read_text(errors="replace")
    if path.suffix == ".json":
        record = json.loads(text)
        print(f"meta\t{sys.argv[2]}\t{sys.argv[3]}\tprocess_wall_ns\t{record['wall_ns']}")
        print(f"meta\t{sys.argv[2]}\t{sys.argv[3]}\tprocess_peak_rss_bytes\t{record['peak_rss_bytes']}")
        if record.get("returncode", 0) != 0:
            print(f"unavailable\t{sys.argv[2]}\t{sys.argv[3]}\tprocess\treason\tchild exited {record['returncode']}")
        return 0
    rss = None
    for pattern in (
        r"peak memory footprint:\s*([0-9]+)",
        r"maximum resident set size:\s*([0-9]+)",
        r"\s*([0-9]+)\s+peak memory footprint",
        r"\s*([0-9]+)\s+maximum resident set size",
    ):
        match = re.search(pattern, text)
        if match:
            rss = int(match.group(1))
            break
    if rss is None:
        print(f"unavailable\t{sys.argv[2]}\t{sys.argv[3]}\tprocess\treason\tRSS field absent")
    else:
        print(f"meta\t{sys.argv[2]}\t{sys.argv[3]}\tprocess_peak_rss_bytes\t{rss}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
