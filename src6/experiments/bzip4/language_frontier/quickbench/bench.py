#!/usr/bin/env python3
"""One-command, complete-frame experiments against real native bzip3.

Storage is the default screen. Baseline encodes are content-addressed; every
run still independently decodes every frame, including cache hits. Candidate
encodes are never cached, so a local dependency edit cannot return an old win.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
V4 = LAB / "bz4/v3/zig-out/bin/bz4"
PROTOCOL = LAB / "frontier_python/protocol"
WORKER = HERE / "worker.py"
MAX_INPUT = 512 * 1024 * 1024


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def record(path: Path) -> dict:
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path.resolve()), "bytes": path.stat().st_size, "sha256": sha256}


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def fingerprint(codec: dict) -> dict:
    paths = [Path(__file__), WORKER]
    if codec["kind"] == "v4":
        paths.append(Path(codec["binary"]))
    elif codec["kind"] == "bzip3":
        # Reuse the pinned, hash-verified vendored control; never use a
        # payload-size estimate or accidentally substitute Python bz2.
        sys.path.insert(0, str(LAB))
        from frontier_python.protocol.native_bzip3 import control_library_record
        paths.extend(sorted(PROTOCOL.glob("*.py")))
        paths.append(Path(control_library_record()["path"]))
    elif codec["kind"] == "wam":
        paths.extend(sorted((LAB / "language_frontier/segmentation").glob("*.py")))
    else:
        # Sibling Python imports are common in rapid experiments. Include the
        # directory's source closure by default; explicitly declared resources
        # cover dependencies elsewhere and non-Python model/code artifacts.
        paths.extend(sorted(path for path in Path(codec["module"]).parent.rglob("*.py")
                            if "__pycache__" not in path.parts))
        for dependency in codec["dependencies"]:
            path = Path(dependency)
            paths.extend(sorted(p for p in path.rglob("*") if p.is_file()
                                and "__pycache__" not in p.parts) if path.is_dir() else [path])
    return {"codec": codec, "files": [record(path) for path in sorted(set(paths))],
            "python": sys.version, "executable": record(Path(sys.executable)),
            "platform": platform.platform()}


@contextmanager
def cache_lock(cache: Path, key: str):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / f"{key}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def cached_frame(cache: Path, key: str, identity: dict) -> Path | None:
    directory = cache / key
    if not directory.exists():
        return None
    try:
        manifest = json.loads((directory / "record.json").read_text())
        frame = directory / "frame.bin"
        if manifest["identity"] != identity or manifest["frame"] != record(frame):
            raise ValueError("identity or frame hash mismatch")
        return frame
    except (OSError, KeyError, ValueError) as error:
        # Preserve suspect artifacts for diagnosis and fail visibly. A later
        # invocation can rebuild; this run may not silently report a hit.
        quarantine = quarantine_cache(cache, key)
        raise ValueError(f"invalid baseline cache moved to {quarantine}: {error}") from error


def quarantine_cache(cache: Path, key: str) -> Path:
    quarantine = cache / f"{key}.invalid-{uuid.uuid4().hex}"
    (cache / key).rename(quarantine)
    return quarantine


def save_cache(cache: Path, key: str, identity: dict, source: Path) -> None:
    destination = cache / key
    with tempfile.TemporaryDirectory(prefix="pending-", dir=cache) as staging:
        temporary = Path(staging)
        frame = temporary / "frame.bin"
        shutil.copyfile(source, frame)
        frame_record = record(frame)
        frame_record["path"] = str((destination / "frame.bin").resolve())
        write_json(temporary / "record.json", {"identity": identity, "frame": frame_record})
        temporary.rename(destination)


def invoke(operation: str, spec: Path, source: Path, target: Path,
           logs: Path, timeout: float, timed: bool) -> int | None:
    argv = [sys.executable, str(WORKER), operation, str(spec), str(source), str(target)]
    # stdout/stderr are files, so a noisy experiment cannot fill a PIPE or
    # exhaust harness memory. The argv and failure logs survive a timeout.
    write_json(logs.with_suffix(".command.json"), argv)
    target.unlink(missing_ok=True)
    started = time.perf_counter_ns() if timed else 0
    with logs.with_suffix(".stdout").open("wb") as stdout, logs.with_suffix(".stderr").open("wb") as stderr:
        with subprocess.Popen(argv, stdout=stdout, stderr=stderr, start_new_session=True) as process:
            expired = threading.Event()

            def stop_group() -> None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            def deadline() -> None:
                if process.poll() is None:
                    expired.set()
                    stop_group()

            watchdog = threading.Timer(timeout, deadline)
            watchdog.daemon = True
            watchdog.start()
            try:
                # A timed wait polls with backoff and distorts short latency
                # samples. Blocking wait + an independent deadline does not.
                returncode = process.wait()
            except KeyboardInterrupt:
                stop_group()
                process.wait()
                raise
            finally:
                watchdog.cancel()
                watchdog.join()
            if expired.is_set():
                write_json(logs.with_suffix(".status.json"), {"status": "timeout", "timeout_seconds": timeout})
                raise subprocess.TimeoutExpired(argv, timeout)
    elapsed = time.perf_counter_ns() - started if timed else None
    if returncode != 0 or not target.is_file():
        raise ValueError(f"{operation} failed ({returncode}); see {logs.with_suffix('.stderr')}")
    return elapsed


def verify_output(path: Path, expected: dict) -> None:
    actual = record(path)
    if (actual["bytes"], actual["sha256"]) != (expected["bytes"], expected["sha256"]):
        raise ValueError(f"roundtrip mismatch: {path}")


def measure(codec: dict, provenance: dict, source: Path, directory: Path,
            cache: Path, timeout: float, repeats: int, cacheable: bool) -> dict:
    directory.mkdir(parents=True)
    source_record = record(source)
    identity = {"schema": 1, "raw_sha256": source_record["sha256"],
                "raw_bytes": source_record["bytes"], "implementation": provenance}
    key = digest(canonical(identity))
    spec = directory / "codec.json"
    write_json(spec, codec)
    frame = directory / "frame.bin"
    cache_hit = False
    encode_ns = None

    with cache_lock(cache, key):
        cached = cached_frame(cache, key, identity) if cacheable else None
        if cached is not None:
            shutil.copyfile(cached, frame)
            cache_hit = True
        else:
            encode_ns = invoke("encode", spec, source, frame, directory / "encode", timeout, repeats > 0)
        # Decoder gets neither source path nor encoder options/dependencies.
        decoder_spec = directory / "decoder.json"
        write_json(decoder_spec, {k: v for k, v in codec.items() if k in {"name", "kind", "binary", "module"}})
        decoded = directory / "decoded.bin"
        try:
            invoke("decode", decoder_spec, frame, decoded, directory / "verify", timeout, False)
            verify_output(decoded, source_record)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if cache_hit:
                quarantine = quarantine_cache(cache, key)
                raise ValueError(f"cached decode failed; entry moved to {quarantine}: {error}") from error
            raise
        if fingerprint(codec) != provenance:
            raise ValueError("codec changed during the run; result discarded")
        if cacheable and not cache_hit:
            save_cache(cache, key, identity, frame)

    process_ns = []
    for index in range(repeats):
        elapsed = invoke("decode", decoder_spec, frame, decoded, directory / f"decode-{index}", timeout, True)
        verify_output(decoded, source_record)
        process_ns.append(elapsed)
    # Detect an implementation edited during the run, not only stale cache.
    if fingerprint(codec) != provenance:
        raise ValueError("codec changed during the run; result discarded")
    return {"codec": codec["name"], "input": source_record, "frame": record(frame),
            "verified": True, "cache_hit": cache_hit, "identity": identity,
            "encode_process_ns": encode_ns, "decode_process_ns": process_ns,
            "decode_process_median_ns": statistics.median(process_ns) if process_ns else None}


def suite(name: str) -> list[Path]:
    data = LAB / "bz4/data"
    sources = [Path("/usr/share/dict/web2"), data / "freedict.eval8.bin", data / "omw.eval8.bin"]
    if name == "multilingual":
        sources.insert(2, data / "gcide.eval8.bin")
        sources.extend(LAB / f"language_frontier/evidence/corpora/ud-{code}-test/form.txt"
                       for code in ("fi", "tr", "ar"))
    return sources


def policies(options: dict, grid: dict) -> list[dict]:
    """Freeze a bounded Cartesian matrix; grid values override defaults."""
    for label, value in (("--options", options), ("--grid", grid)):
        if not isinstance(value, dict) or any(not isinstance(key, str) for key in value) or "block_bytes" in value:
            raise ValueError(f"{label} must be an object with string keys and without block_bytes; use --block")
        # JSON's NaN/Infinity extensions are not reproducible JSON parameters.
        json.dumps(value, allow_nan=False)
    count = 1
    for values in grid.values():
        if not isinstance(values, list) or not values:
            raise ValueError("--grid values must be nonempty arrays")
        count *= len(values)
        if count > 256:
            raise ValueError("--grid exceeds 256 policy combinations")
    keys = sorted(grid)
    return [dict(options, **dict(zip(keys, values)))
            for values in itertools.product(*(grid[key] for key in keys))]


def artifact_name(codec: dict) -> str:
    # Parameter strings are display-only; even separators cannot escape a sample.
    if "policy" in codec:
        return f"candidate-{codec['candidate']:03d}-policy-{codec['policy']:03d}"
    return codec["name"]


def candidates(names: list[str], block: int, options: dict, dependencies: list[str],
               grid: dict | None = None) -> list[dict]:
    grid = {} if grid is None else grid
    matrix = policies(options, grid)
    if grid and not names:
        raise ValueError("nonempty --grid requires at least one --candidate")
    if grid and any(name in {"wam-map", "wam-marginal"} for name in names):
        raise ValueError("built-in WAM candidates have fixed policies and reject nonempty --grid")
    if options and any(name in {"wam-map", "wam-marginal"} for name in names):
        raise ValueError("built-in WAM candidates have fixed policies and reject nonempty --options")
    result = []
    for candidate_index, name in enumerate(names, 1):
        base = {"name": Path(name).stem, "block_bytes": block}
        if name in {"wam-map", "wam-marginal"}:
            result.append(dict(base, kind="wam", mode=name.removeprefix("wam-")))
        else:
            path = Path(name).resolve(strict=True)
            resolved_dependencies = [str(Path(p).resolve(strict=True)) for p in dependencies]
            for policy_index, settings in enumerate(matrix, 1):
                codec = dict(base, kind="module", module=str(path), options=settings,
                             dependencies=resolved_dependencies)
                if grid:
                    codec.update(candidate=candidate_index, policy=policy_index,
                                 name=f"{base['name']} policy-{policy_index:03d} {canonical(settings).decode()}")
                result.append(codec)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path, nargs="*")
    parser.add_argument("--suite", choices=("quick", "multilingual"), default="quick")
    parser.add_argument("--limit", type=int, default=65536, help="exact input prefix; 0 = complete file")
    parser.add_argument("--block", type=int, default=65536)
    parser.add_argument("--candidate", action="append", default=[], help="wam-map, wam-marginal, or adapter.py; repeatable")
    parser.add_argument("--options", default="{}", help="JSON object passed only to candidate encode")
    parser.add_argument("--grid", default="{}", help="JSON object of nonempty arrays; Cartesian policies override --options (max 256)")
    parser.add_argument("--dependency", action="append", default=[], help="additional candidate provenance file/directory")
    parser.add_argument("--decode-repeats", type=int, default=0, help="fresh-process wall latency, NOT native kernel throughput")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--cache", type=Path, default=HERE / "cache")
    parser.add_argument("--output", type=Path, default=HERE / "runs")
    args = parser.parse_args()
    if args.limit < 0 or not 1 <= args.block <= 511 * 1024 * 1024 or args.decode_repeats < 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("invalid limit, block, repeat count, or timeout")
    try:
        options, grid = json.loads(args.options), json.loads(args.grid)
        matrix = policies(options, grid)
        extra = candidates(args.candidate, args.block, options, args.dependency, grid)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    run = args.output.resolve() / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    run.mkdir(parents=True)
    rows, failures = [], []
    write_json(run / "invocation.json", {"argv": sys.argv, "timing": "fresh Python worker + imports + codec startup + file I/O + full decode; verification hash outside timer",
                                        "cache": "encode only; each hit rehashed and decoded in a new process",
                                        "bzip3": "vendored 1.5.1 native blocks, B3PY envelope = 32 + 16*blocks; not upstream .bz3 framing",
                                        "matrix": {"block_bytes": args.block, "grid": grid, "defaults": options,
                                                   "policies": matrix, "candidates": extra,
                                                   "controls": [{"name": "bzip3-block", "kind": "bzip3", "block_bytes": args.block},
                                                                {"name": "bzip3-whole", "kind": "bzip3", "block_bytes": "max(1, input bytes)"},
                                                                {"name": "bzip4-v4", "kind": "v4", "block_bytes": args.block, "binary": str(V4)}],
                                                   "whole_block_rule": "max(1, input bytes)",
                                                   "inputs": [str(path.resolve()) for path in (args.inputs or suite(args.suite))],
                                                   "prefix_limit": args.limit}})
    print("Complete frame bytes; lower is better. All rows require fresh-process exact decoding.", flush=True)
    print("Bzip3 uses real vendored native blocks + the existing 32+16/block lab envelope.", flush=True)
    if grid:
        for number, settings in enumerate(matrix, 1):
            print(f"Policy {number:03d}: {canonical(settings).decode()}", flush=True)
    for number, original in enumerate(args.inputs or suite(args.suite)):
        sample = run / f"{number:02d}-{original.parent.name}-{original.stem}"
        sample.mkdir()
        try:
            with original.open("rb") as stream:
                raw = stream.read(min(args.limit or MAX_INPUT + 1, MAX_INPUT + 1))
            if len(raw) > MAX_INPUT:
                raise ValueError("input exceeds 512 MiB harness bound")
            source = sample / "input.bin"
            source.write_bytes(raw)
            write_json(sample / "source.json", {"path": str(original.resolve()), "source_bytes": original.stat().st_size,
                                                 "prefix_limit": args.limit, "sample": record(source)})
            codecs = [{"name": "bzip3-block", "kind": "bzip3", "block_bytes": args.block},
                      {"name": "bzip3-whole", "kind": "bzip3", "block_bytes": max(1, len(raw))},
                      {"name": "bzip4-v4", "kind": "v4", "block_bytes": args.block, "binary": str(V4)}, *extra]
            print(f"\n{original}: {len(raw):,} input bytes (limit={args.limit or 'whole'})", flush=True)
            sample_rows = []
            for index, codec in enumerate(codecs):
                provenance = None
                artifact_dir = sample / f"{index:02d}-{artifact_name(codec)}"
                try:
                    provenance = fingerprint(codec)
                    row = measure(codec, provenance, source, artifact_dir,
                                  args.cache.resolve(), args.timeout, args.decode_repeats, index < 3)
                    sample_rows.append(row)
                    rows.append(row)
                    baseline = sample_rows[0]["frame"]["bytes"] if sample_rows[0]["codec"] == "bzip3-block" else None
                    delta = f"{100 * (row['frame']['bytes'] / baseline - 1):+.2f}%" if baseline else "n/a"
                    latency = (f" process-decode={row['decode_process_median_ns'] / 1e6:.2f}ms"
                               if row["decode_process_median_ns"] is not None else "")
                    print(f"  {codec['name']:<20} {row['frame']['bytes']:>10,} B  vs-block={delta:>9}  {'cache' if row['cache_hit'] else 'built'} verified{latency}", flush=True)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    failure = {"source": str(original.resolve()), "input": record(source), "codec": codec["name"],
                               "implementation": provenance, "artifact_dir": str(artifact_dir),
                               "artifacts": [str(path) for path in sorted(artifact_dir.glob("*")) if path.is_file()],
                               "error": str(error)}
                    failures.append(failure)
                    print(f"  FAIL {codec['name']}: {error}", flush=True)
                write_json(run / "results.json", {"rows": rows, "failures": failures})
            pairs = {row["codec"]: row["frame"]["bytes"] for row in sample_rows}
            if "wam-map" in pairs and "wam-marginal" in pairs:
                print(f"  marginal vs same-source MAP control: {pairs['wam-marginal'] - pairs['wam-map']:+,} B", flush=True)
        except (OSError, ValueError) as error:
            failures.append({"input": str(original), "sample_dir": str(sample),
                             "kind": "input-acquisition", "error": str(error)})
            print(f"  FAIL input: {error}", flush=True)
    write_json(run / "results.json", {"rows": rows, "failures": failures})
    print(f"\nArtifacts: {run}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
