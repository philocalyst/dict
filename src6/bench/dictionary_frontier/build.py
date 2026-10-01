#!/usr/bin/env python3
"""Build both frozen LEX6 clients and preserve source/build provenance."""
import argparse
import json
from pathlib import Path

from compare import REPO, capture, dependencies_record, file_record, source_record

EXPORT = """pub const model = @import("model.zig");
pub const query = @import("query.zig");
pub const validate = @import("validate.zig");
pub const archive = @import("archive.zig");
pub const compression = @import("compression.zig");
pub const packet = @import("packet.zig");
pub const render = @import("render.zig");
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    baseline = args.before_source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Old root.zig did not export packet. This wrapper exports unchanged old
    # modules to the identical rich client; it changes no codec/model behavior.
    wrapper = baseline / "src6/frontier_export.zig"
    if wrapper.exists() and wrapper.read_text() != EXPORT:
        raise ValueError(f"refusing to overwrite {wrapper}")
    wrapper.write_text(EXPORT)
    before = {"before": source_record(baseline), "after": source_record(REPO)}
    report = {"schema": 1, "status": "in-progress", "sources": before,
              "dependencies": dependencies_record(),
              "client_sources": [file_record(path) for path in sorted((REPO / "src6/experiments/dictionary_frontier").glob("*.zig"))],
              "builds": []}
    try:
        for lane, root in (("before", baseline), ("after", REPO)):
            real_prefix = output / f"{lane}-real"
            command = ["zig", "build", "--build-file", str(root / "src6/bench/real-world/build.zig"),
                       "-Doptimize=ReleaseFast", "--prefix", str(real_prefix)]
            built = capture(command, output / f"build-{lane}-real")
            report["builds"].append({"lane": lane, "client": "real", "capture": built,
                                     "binary": file_record(real_prefix / "bin/real-lex6")})
            rich_prefix = output / f"{lane}-rich"
            command = ["zig", "build", "--build-file", str(REPO / "src6/experiments/dictionary_frontier/build.zig"),
                       "-Doptimize=ReleaseFast", f"-Dlex-root={wrapper if lane == 'before' else REPO / 'src6/root.zig'}",
                       f"-Dvendor-root={REPO / 'vendor/bzip3'}", "--prefix", str(rich_prefix)]
            built = capture(command, output / f"build-{lane}-rich")
            report["builds"].append({"lane": lane, "client": "rich", "capture": built,
                                     "binary": file_record(rich_prefix / "bin/dictionary-frontier"),
                                     "projection_binary": file_record(rich_prefix / "bin/dictionary-projection")})
        if before != {"before": source_record(baseline), "after": source_record(REPO)}:
            raise ValueError("source changed during build")
        if report["client_sources"] != [file_record(path) for path in sorted((REPO / "src6/experiments/dictionary_frontier").glob("*.zig"))]:
            raise ValueError("client source changed during build")
        report["status"] = "complete"
    except Exception as exc:
        report["status"], report["error"] = "failed", str(exc)
        raise
    finally:
        (output / "builds.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
