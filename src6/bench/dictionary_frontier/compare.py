#!/usr/bin/env python3
"""Compare two native LEX6 runners on identical, independently checked inputs.

Builds and smoke verification precede a fixed alternating five-pair schedule.
The source projection is an explicitly limited key/identity/definition workload;
rich lexical semantics are validated separately by the library test suite.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE.parent / "real-world"))
import formats
import measure
import smoke


def file_record(path: Path) -> dict:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": digest}


def source_record(root: Path) -> list[dict]:
    paths = sorted((root / "src6").glob("*.zig"))
    paths += [root / "build6.zig", root / "src6/bench/real-world/runner.zig",
              root / "src6/bench/real-world/build.zig"]
    return [{"relative": str(path.relative_to(root)), **file_record(path)} for path in paths]


def dependencies_record() -> dict:
    """Record actual native source/toolchain and independently parsed oracle."""
    paths = sorted(HERE.glob("*.py"))
    paths += [HERE.parent / "real-world" / name for name in ("formats.py", "measure.py", "smoke.py")]
    paths += sorted((REPO / "vendor/bzip3/src").glob("*.c"))
    paths += sorted((REPO / "vendor/bzip3/include").glob("*.h"))
    zig_path = shutil.which("zig")
    if zig_path is None:
        raise RuntimeError("Zig toolchain needed for provenance")
    version = subprocess.run([zig_path, "version"], capture_output=True, text=True, check=True)
    cpu = Path("/proc/cpuinfo")
    memory = Path("/proc/meminfo")
    return {
        "files": [file_record(path) for path in paths],
        "python": {"version": sys.version, **file_record(Path(sys.executable))},
        "zig": {"version": version.stdout.strip(), **file_record(Path(zig_path).resolve())},
        "optimization": "ReleaseFast; baseline and candidate same build scripts/target",
        "host": platform.uname()._asdict(),
        "cpu_model": next((line.split(":", 1)[1].strip() for line in cpu.read_text().splitlines()
                           if line.startswith("model name")), None) if cpu.exists() else None,
        "memory_total": next((line for line in memory.read_text().splitlines() if line.startswith("MemTotal:")), None)
                        if memory.exists() else None,
    }


def capture(argv: list[str], out: Path) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.with_suffix(".stdout").open("wb") as stdout, out.with_suffix(".stderr").open("wb") as stderr:
        result = subprocess.run(argv, stdout=stdout, stderr=stderr, check=False)
    record = {"argv": argv, "exit_code": result.returncode,
              "stdout": file_record(out.with_suffix(".stdout")),
              "stderr": file_record(out.with_suffix(".stderr"))}
    out.with_suffix(".process.json").write_text(json.dumps(record, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"failed {argv!r}; see {out.with_suffix('.stderr')}")
    return record


def text_of(record: dict) -> str:
    return Path(record["stdout"]["path"]).read_text()


def summarize(samples: list[dict]) -> dict:
    result = {}
    phases = [sample["phases"] for sample in samples]
    for key in phases[0]:
        values = [sample[key] for sample in phases]
        if key.endswith("_ns") and all(isinstance(value, int) for value in values):
            result[key] = {"median_ns": statistics.median(values), "min_ns": min(values), "max_ns": max(values)}
        elif all(isinstance(value, dict) and isinstance(value.get("ns"), int) for value in values):
            timings = [value["ns"] for value in values]
            result[key] = {"median_ns": statistics.median(timings), "min_ns": min(timings), "max_ns": max(timings)}
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--before-source", required=True, type=Path)
    parser.add_argument("--after-source", type=Path, default=REPO)
    parser.add_argument("--projection", required=True, type=Path, action="append")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--size-only", action="store_true")
    parser.add_argument("--quiet-gate", required=True)
    args = parser.parse_args()
    if args.quiet_gate != measure.GATE or args.pairs < 1:
        parser.error("the existing explicit measurement gate and positive pair count are required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {"before": args.before.resolve(), "after": args.after.resolve()}
    roots = {"before": args.before_source.resolve(), "after": args.after_source.resolve()}
    initial_sources = {lane: source_record(root) for lane, root in roots.items()}
    dependencies = dependencies_record()
    report = {"schema": 1, "status": "in-progress", "platform": platform.platform(),
              "binaries": {lane: file_record(binary) for lane, binary in binaries.items()},
              "sources": initial_sources, "dependencies": dependencies,
              "schedule": {"pairs": args.pairs, "order": "AB,BA alternating", "batch_operations": 256,
                           "page_size_sweep": [16384, 65536, 262144], "timed_page_bytes": 65536,
                           "codecs": ["raw", "adaptive"], "fresh_process": True,
                           "disk_cache": "memory-resident files; no cache eviction", "warmup": "existing runner's one warmup per batch"},
              "corpora": []}
    try:
        for projection_path in args.projection:
            projection = projection_path.resolve()
            name = projection.parent.parent.name + "-" + projection.parent.name
            corpus_out = output / name
            oracle = formats.read_projection(projection)
            corpus_out.mkdir(parents=True, exist_ok=True)
            query_path, rows_path = corpus_out / "queries.tsv", corpus_out / "rows.tsv"
            measure.write_measure_plan(oracle, query_path, rows_path)
            queries, rows = measure.load_measure_plan(query_path, rows_path)
            smoke_queries = smoke.write_queries(oracle, corpus_out / "smoke-queries.tsv")
            corpus = {"name": name, "projection": file_record(projection), "records": len(oracle.records), "lanes": []}
            report["corpora"].append(corpus)
            for codec in ("raw", "adaptive"):
                comparison = {"codec": codec, "sizes": [], "samples": {"before": [], "after": []}}
                corpus["lanes"].append(comparison)
                artifacts = {}
                for page in (16384, 65536, 262144):
                    for lane, binary in binaries.items():
                        prefix = corpus_out / f"{codec}-{page}-{lane}"
                        artifact = prefix.with_suffix(".lex6")
                        built = capture([str(binary), "--mode", "build", "--input", str(projection), "--artifact", str(artifact),
                                         "--compression", codec, "--target-page-bytes", str(page)], Path(str(prefix) + "-build"))
                        checked = capture([str(binary), "--mode", "smoke", "--input", str(projection), "--artifact", str(artifact),
                                           "--queries", str(corpus_out / "smoke-queries.tsv")], Path(str(prefix) + "-smoke"))
                        validated = smoke.parse_smoke(text_of(checked), oracle, smoke_queries)
                        comparison["sizes"].append({"lane": lane, "target_page_bytes": page,
                                                    "artifact": file_record(artifact), "build": built, "smoke": checked,
                                                    "validated": validated})
                        if page == 65536:
                            artifacts[lane] = artifact
                # Verify actual frozen v2 archives with the new reader, beyond
                # synthetic packet/envelope compatibility fixtures.
                legacy = capture([str(binaries["after"]), "--mode", "smoke", "--input", str(projection),
                                  "--artifact", str(artifacts["before"]),
                                  "--queries", str(corpus_out / "smoke-queries.tsv")],
                                 corpus_out / f"{codec}-v2-with-new-reader")
                comparison["legacy_read"] = {
                    "capture": legacy,
                    "validated": smoke.parse_smoke(text_of(legacy), oracle, smoke_queries),
                }
                if not args.size_only:
                    for pair in range(args.pairs):
                        order = ("before", "after") if pair % 2 == 0 else ("after", "before")
                        for lane in order:
                            captured = capture([str(binaries[lane]), "--mode", "measure", "--quiet-gate", measure.GATE,
                                                "--input", str(projection), "--artifact", str(artifacts[lane]),
                                                "--queries", str(query_path), "--rows", str(rows_path)],
                                               corpus_out / f"{codec}-pair{pair}-{lane}")
                            phases = measure.parse_runner_output(text_of(captured))
                            measure.validate_lex6_timed_result(oracle, queries, rows, phases)
                            comparison["samples"][lane].append({"pair": pair, "order": list(order), "capture": captured, "phases": phases})
                    comparison["summary"] = {lane: summarize(samples) for lane, samples in comparison["samples"].items()}
                (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                print(f"checked {name}/{codec}", flush=True)
        final_sources = {lane: source_record(root) for lane, root in roots.items()}
        if final_sources != initial_sources:
            raise RuntimeError("source changed during comparison; rerun after freezing implementation")
        if dependencies_record() != dependencies:
            raise RuntimeError("benchmark dependencies changed during comparison")
        if any(file_record(binaries[lane]) != record for lane, record in report["binaries"].items()):
            raise RuntimeError("binary changed during comparison")
        report["status"] = "complete-verified"
    except Exception as exc:
        report["status"], report["error"] = "failed", str(exc)
        raise
    finally:
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
