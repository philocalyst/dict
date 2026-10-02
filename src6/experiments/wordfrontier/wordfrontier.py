#!/usr/bin/env python3
"""Paid automatic choice between exact word constructions and word geometry."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
EXPERIMENTS = HERE.parent
WPG = EXPERIMENTS / "word_constructions"
GWT = EXPERIMENTS / "wordgrammar" / "geometry"
DEFAULT_BACKEND = EXPERIMENTS / "wordgrammar" / "wgp6"
PAGE = 65536
MAX_RAW = 32 * 1024 * 1024
MAX_ARCHIVE = 3 * 64 * 1024 * 1024 + 48 + 12 * 1024 + 1533 + 4 * 1024
MAX_WPG_ARCHIVE = 64 * 1024 * 1024 + MAX_RAW // 64 + 4096
QUIET_GATE = "WORDZIP-READER-QUIET"
FAMILIES = ("WPG2", "GWT1")  # First wins exact size ties.
READERS = {"WPG2": WPG / "prepared_wpg", "GWT1": GWT / "prepared_geometry"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def checked_size(path: Path, limit: int) -> int:
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise ValueError(f"regular input file required, at most {limit} bytes")
    return info.st_size


def read_raw(path: Path) -> bytes:
    checked_size(path, MAX_RAW)
    with path.open("rb") as stream:
        data = stream.read(MAX_RAW + 1)
    if len(data) > MAX_RAW:
        raise ValueError("input grew past the 32 MiB encoder limit")
    return data


def family(path: Path) -> str:
    checked_size(path, MAX_ARCHIVE)
    with path.open("rb") as stream:
        magic = stream.read(4)
    try:
        name = magic.decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("unsupported archive magic") from error
    if name not in FAMILIES:
        raise ValueError("expected WPG2 or GWT1 archive")
    if name == "WPG2":
        checked_size(path, MAX_WPG_ARCHIVE)
    return name


def dependency_paths(backend: Path, operation: str, chosen: str | None = None) -> list[Path]:
    paths = {Path(__file__).resolve()}
    if operation == "encode":
        paths.update(backend / name for name in
                     ("m_reference", "native", "native_forward", "native_forward_hoist", "reparse_context"))
        paths.update(READERS.values())
        for directory in (WPG, GWT):
            paths.update(p.resolve() for p in directory.glob("*.py") if not p.name.startswith("test_"))
        for name in ("prepared_wpg.cpp", "prepared_jobs.zig", "prepared_jobs.h", "register_decode.cpp"):
            paths.add(WPG / name)
        for name in ("prepared_geometry.cpp", "geometry_residual.h"):
            paths.add(GWT / name)
        # Runtime binary identities are decisive. Sources record reproduction provenance.
        for name in ("m_reference.zig", "learner_epochs.zig", "lifetime_fit.zig", "budget.zig",
                     "native.zig", "native_forward.zig", "native_forward_hoist.zig", "reparse_context.cpp"):
            paths.add(DEFAULT_BACKEND / name)
        original = EXPERIMENTS / "bzip4" / "bz4"
        paths.update((original / "m_lexicon.zig", original / "grammar2.zig"))
        paths.update((original / "v3" / "src").glob("*.zig"))
    else:
        paths.add(READERS[chosen])
        if operation == "inspect" and chosen == "WPG2":
            paths.add(backend / "native")
            paths.update(p.resolve() for p in WPG.glob("*.py") if not p.name.startswith("test_"))
    return sorted(paths)


def fingerprint(paths: list[Path]) -> dict[str, str]:
    return {str(path): digest(path) for path in paths}


def assert_unchanged(before: dict[str, str]) -> None:
    for name, expected in before.items():
        if digest(Path(name)) != expected:
            raise ValueError(f"runtime dependency changed during operation: {name}")


def run(command: list[str | Path], env: dict[str, str] | None = None) -> tuple[dict, int]:
    began = time.perf_counter_ns()
    try:
        result = subprocess.run([str(part) for part in command], env=env, check=True,
                                capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()[-4096:]
        raise ValueError(f"{Path(command[0]).name} failed: {detail}") from error
    wall_ns = time.perf_counter_ns() - began
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError("expected one complete JSON event from family adapter")
    event = json.loads(lines[0])
    if not isinstance(event, dict):
        raise ValueError("invalid family adapter event")
    return event, wall_ns


def inspect_archive(name: str, archive: Path, output: Path, backend: Path, env: dict[str, str]) -> dict:
    if name == "WPG2":
        result, wall_ns = run([sys.executable, WPG / "wpg_codec.py", "inspect", archive, output], env)
        ledger = result["accounting"]
        if ledger["sum_bytes"] != archive.stat().st_size:
            raise ValueError("WPG2 byte ledger mismatch")
        # Metadata inspection is distinct from the complete decode integrity gate.
        scope = "outer structural CRC and unchanged native frame ledger; full payload CRCs require decode"
        raw = result["source_bytes"]
        pages = result["original_pages"]
    else:
        result, wall_ns = run([READERS[name], "inspect", archive, output])
        ledger = {key: result[key] for key in
                  ("header_bytes", "index_bytes", "geometry_model_bytes", "flags_bytes", "native_frame_bytes")}
        ledger["sum_bytes"] = sum(ledger.values())
        if ledger["sum_bytes"] != archive.stat().st_size:
            raise ValueError("GWT1 byte ledger mismatch")
        scope = result["verified_scope"]
        raw, pages = result["raw_bytes"], result["pages"]
    return {"format": name, "frame_bytes": archive.stat().st_size, "source_bytes": raw,
            "original_page_bytes": PAGE, "original_pages": pages, "accounting": ledger,
            "verified_scope": scope, "native_or_family_inspection": result,
            "inspection_adapter_wall_ns": wall_ns}


def publish(staged: Path, destination: Path) -> None:
    # All native reads and integrity gates finish before replacing an existing file.
    with staged.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(staged, destination)


def encode(args, backend: Path, env: dict[str, str], before: dict[str, str]) -> dict:
    raw = read_raw(args.input)
    began = time.perf_counter_ns()
    with tempfile.TemporaryDirectory(prefix=".wordfrontier-", dir=args.output.parent) as temp:
        directory = Path(temp)
        source = directory / "source"
        source.write_bytes(raw)
        candidates = []
        archives = {}
        search_start = time.perf_counter_ns()
        for name in FAMILIES:
            archive = directory / name
            if name == "WPG2":
                command = [sys.executable, WPG / "wpg_codec.py", "encode", source, archive,
                           "--profile", args.profile, "--block", PAGE]
            else:
                command = [sys.executable, GWT / "pages.py", "encode", source, archive,
                           "--profile", args.profile, "--reference", backend / "m_reference",
                           "--native", backend / "native"]
            event, wall_ns = run(command, env)
            if family(archive) != name:
                raise ValueError("family encoder returned another format")
            expected_bytes = event.get("frame_bytes", event.get("archive_bytes"))
            if expected_bytes != archive.stat().st_size:
                raise ValueError("family encoder complete-size mismatch")
            archives[name] = archive
            candidates.append({"format": name, "frame_bytes": expected_bytes,
                               "adapter_wall_ns": wall_ns, "encoder": event})
        search_wall_ns = time.perf_counter_ns() - search_start
        selected = min(candidates, key=lambda row: row["frame_bytes"])
        name, archive = selected["format"], archives[selected["format"]]
        verification_start = time.perf_counter_ns()
        decoded = directory / "decoded"
        full, _ = run([READERS[name], "decode", archive, decoded])
        if decoded.read_bytes() != raw:
            raise ValueError("fresh native full decode mismatch")
        pages = (len(raw) + PAGE - 1) // PAGE
        for index in range(pages):
            event, _ = run([READERS[name], "query", archive, decoded, "--index", index])
            if decoded.read_bytes() != raw[index * PAGE:(index + 1) * PAGE]:
                raise ValueError(f"fresh native original-page mismatch: {index}")
        verification_wall_ns = time.perf_counter_ns() - verification_start
        info = inspect_archive(name, archive, directory / "ledger", backend, env)
        if info["source_bytes"] != len(raw) or info["original_pages"] != pages:
            raise ValueError("selected family original-page geometry mismatch")
        frame_sha = digest(archive)
        native_codec_ns = int(candidates[0]["encoder"]["paid_native_codec_ns"])
        native_codec_ns += sum(int(row.get("codec_ns", 0)) for row in candidates[1]["encoder"]["native_events"])
        assert_unchanged(before)
        publish(archive, args.output)
    return {**info, "operation": "encode", "profile": args.profile,
            "policy": "wordfrontier-global/1", "tie_order": list(FAMILIES),
            "source_sha256": hashlib.sha256(raw).hexdigest(), "frame_sha256": frame_sha,
            "encoder_adapter_wall_ns": time.perf_counter_ns() - began,
            "all_family_search_wall_ns": search_wall_ns,
            "all_search_native_codec_ns": native_codec_ns,
            "selected_verification_wall_ns": verification_wall_ns,
            "fresh_native_full_decode_exact": True, "fresh_native_all_original_pages_exact": pages,
            "native_full_verification": full, "candidates": candidates,
            "timing_scope": "adapter wall includes all family trials and integrity gates; native codec sum includes all C++/Zig search phases, excludes Python transforms and process/file I/O"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    for operation in ("encode", "decode", "extract", "inspect", "bench"):
        p = sub.add_parser(operation)
        p.add_argument("input", type=Path)
        p.add_argument("output", type=Path)
        p.add_argument("--backend-dir", type=Path, default=DEFAULT_BACKEND)
        if operation == "encode":
            p.add_argument("--profile", choices=("quality", "access"), default="quality")
            p.add_argument("--block", type=int, default=PAGE)
        if operation == "extract":
            p.add_argument("--index", type=int, required=True)
        if operation in ("decode", "extract", "bench"):
            p.add_argument("--measure", choices=(0, 1), type=int, default=0)
            p.add_argument("--quiet-gate", default="")
    args = parser.parse_args()
    if args.operation == "encode" and args.block != PAGE:
        raise ValueError("only original-byte 65536-byte pages are supported")
    if args.operation == "extract" and args.index < 0:
        raise ValueError("page index must be nonnegative")
    if getattr(args, "measure", 0) and args.quiet_gate != QUIET_GATE:
        raise ValueError("native timing requires the explicit WORDZIP-READER-QUIET gate")
    backend = args.backend_dir.resolve()
    name = None if args.operation == "encode" else family(args.input)
    if args.operation == "encode":
        checked_size(args.input, MAX_RAW)
    before = fingerprint(dependency_paths(backend, args.operation, name))
    env = os.environ.copy()
    env["WPG6_BIN_DIR"] = str(backend)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.operation == "encode":
        result = encode(args, backend, env, before)
    else:
        archive_sha = digest(args.input)
        with tempfile.TemporaryDirectory(prefix=".wordfrontier-", dir=args.output.parent) as temp:
            staged = Path(temp) / "output"
            if args.operation == "inspect":
                result = inspect_archive(name, args.input, staged, backend, env)
                staged.write_text(json.dumps(result, indent=2) + "\n")
            else:
                command = [READERS[name], "query" if args.operation == "extract" else args.operation,
                           args.input, staged]
                if args.operation == "extract":
                    command += ["--index", args.index]
                if args.measure:
                    command += ["--measure", 1, "--quiet-gate", args.quiet_gate]
                native, wall_ns = run(command)
                result = {"format": name, "operation": args.operation,
                          "native": native, "adapter_wall_ns": wall_ns,
                          "timing_enabled": bool(args.measure),
                          "native_clock_fields": [key for key in native if key.endswith("_ns")]}
                if args.operation in ("decode", "extract"):
                    result["output_sha256"] = digest(staged)
            assert_unchanged(before)
            if digest(args.input) != archive_sha:
                raise ValueError("archive changed during operation")
            publish(staged, args.output)
        result.update({"operation": args.operation, "frame_sha256": archive_sha})
    result["runtime_sha256"] = before
    if args.operation == "encode":
        parameters = {"profile": args.profile, "original_page_bytes": PAGE,
                      "max_input_bytes": MAX_RAW, "tie_order": list(FAMILIES),
                      "backend_directory": str(backend), "verify_every_original_page": True,
                      "WPG2": {"modes": [0, 1, 2, 3], "deduplicate_identical_sources": True,
                               "graphs": ["base", "conditional_dp"], "reparse": "both", "prune": False},
                      "GWT1": {"width": 72, "residual_choices": ["two_rows", "mdl_tree"]},
                      "shared_backend": {"seed": "a-best", "max_iters": 20, "triples": True,
                                         "hoist": args.profile == "access", "class_search": "original_auto"}}
        result["policy_parameters"] = parameters
        result["policy_fingerprint"] = hashlib.sha256(json.dumps(
            {"parameters": parameters, "runtime_sha256": before}, sort_keys=True,
            separators=(",", ":")).encode()).hexdigest()
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"wordfrontier: {error}", file=sys.stderr)
        sys.exit(1)
