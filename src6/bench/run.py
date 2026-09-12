#!/usr/bin/env python3
"""Compile and run the independent LEX6/LEX5 evidence harness.

The Zig runner owns the fixture, archive construction, reader checks, and (only
after an explicit gate) the native monotonic-clock measurements.  This wrapper
owns the reproducibility boundary: it selects the frozen LEX5 root, compiles
both module roots from their current bytes, retains stdout/stderr and binary
artifacts, and refuses a run when any pinned source byte changes.

The default ``smoke`` and ``prepare`` modes never ask the runner for a clock.
``measure`` is intentionally impossible without the literal
``ROOT-EXPLICIT-QUIET-GATE`` argument.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Sequence


PROTOCOL = "LEX6-BENCH/1"
QUIET_GATE = "ROOT-EXPLICIT-QUIET-GATE"
REPO = Path(__file__).resolve().parents[2]
NEW_ROOT = REPO / "src6" / "root.zig"
OLD_ROOT = REPO / "experiments" / "frontier" / "lex5-20260909" / "borrowed-core" / "freeze-20260912" / "source" / "root.zig"
BZIP_INCLUDE = REPO / "vendor" / "bzip3" / "include"
BZIP_SOURCE = REPO / "vendor" / "bzip3" / "src" / "libbz3.c"


class HarnessError(RuntimeError):
    """A failed provenance, compile, or runner contract."""


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def path_label(path: Path) -> str:
    try:
        return path.relative_to(REPO).as_posix()
    except ValueError:
        return str(path)


def required_file(path: Path) -> Path:
    if not path.is_file():
        raise HarnessError(f"required pinned file is missing: {path}")
    return path


def source_paths() -> list[Path]:
    """Return the complete source boundary used by this runner.

    The frozen old tree is deliberately included as a read-only input.  The
    new tree includes the benchmark sources as well as production sources so a
    result cannot be detached from the exact client that consumed it.
    """

    paths: set[Path] = set()
    allowed_suffixes = {".zig", ".c", ".h", ".py"}
    for root in (REPO / "src6", OLD_ROOT.parent, BZIP_INCLUDE, BZIP_SOURCE.parent):
        if root.is_file():
            if root.suffix in allowed_suffixes:
                paths.add(root.resolve())
        elif root.is_dir():
            paths.update(
                path.resolve() for path in root.rglob("*") if path.is_file() and path.suffix in allowed_suffixes
            )
    for name in ("build6.zig", "flake.nix", "flake.lock"):
        candidate = REPO / name
        if candidate.is_file():
            paths.add(candidate.resolve())
    # These are required below; retaining the explicit checks here also makes
    # a missing vendor or old freeze fail before any compiler is launched.
    for candidate in (NEW_ROOT, OLD_ROOT, BZIP_INCLUDE / "libbz3.h", BZIP_SOURCE):
        required_file(candidate)
    return sorted(paths, key=path_label)


def source_manifest() -> dict[str, object]:
    files = []
    for path in source_paths():
        files.append({"path": path_label(path), "size": path.stat().st_size, "sha256": digest_file(path)})
    encoded = b"".join(
        f"sha256\t{row['path']}\t{row['size']}\t{row['sha256']}\n".encode("utf-8") for row in files
    )
    return {
        "algorithm": "sha256",
        "file_count": len(files),
        "manifest_sha256": hashlib.sha256(encoded).hexdigest(),
        "files": files,
    }


def binary_record(path: Path) -> dict[str, object]:
    if not path.is_file():
        return {"path": str(path), "exists": False}
    return {"path": str(path), "exists": True, "size": path.stat().st_size, "sha256": digest_file(path)}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("smoke", "prepare", "measure"), default="smoke")
    parser.add_argument("--records", type=int, default=None, help="logical entries (32 smoke default, 2048 otherwise)")
    parser.add_argument("--profile", choices=("flat", "rich"), default="flat")
    parser.add_argument("--distribution", choices=("mixed", "repetitive", "prose"), default="mixed")
    parser.add_argument("--codec", choices=("all", "raw", "adaptive", "bzip3"), default="all")
    parser.add_argument("--warmup", type=int, default=32)
    parser.add_argument("--repetitions", type=int, default=128)
    parser.add_argument("--optimize", choices=("Debug", "ReleaseFast", "ReleaseSafe", "ReleaseSmall"), default="Debug")
    parser.add_argument("--zig", default="zig", help="zig executable; the old source root is never overrideable")
    parser.add_argument("--out", type=Path, default=None, help="new, empty directory for retained evidence")
    parser.add_argument("--quiet-gate", default=None, help=f"required only for measure: {QUIET_GATE}")
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> int:
    records = 32 if args.mode == "smoke" and args.records is None else (2048 if args.records is None else args.records)
    if records <= 0 or records > 100_000:
        raise HarnessError("--records must be between 1 and 100000")
    if args.warmup < 0 or args.repetitions <= 0:
        raise HarnessError("--warmup must be non-negative and --repetitions must be positive")
    if args.mode == "measure":
        if args.quiet_gate != QUIET_GATE:
            raise HarnessError(f"measure requires --quiet-gate {QUIET_GATE}")
    elif args.quiet_gate is not None:
        raise HarnessError("--quiet-gate is accepted only in measure mode")
    return records


def new_stage(path: Path | None) -> Path:
    if path is None:
        return Path(tempfile.mkdtemp(prefix="src6-bench-"))
    stage = path.expanduser().resolve()
    if stage.exists():
        if not stage.is_dir() or any(stage.iterdir()):
            raise HarnessError(f"--out must name a new, empty directory: {stage}")
    else:
        stage.mkdir(parents=True)
    # Generated artifacts must not become inputs in the source manifest.
    try:
        stage.relative_to((REPO / "src6").resolve())
    except ValueError:
        return stage
    raise HarnessError("--out must be outside src6 so generated artifacts cannot enter the source boundary")


def command_text(command: Sequence[str]) -> list[str]:
    return [str(item) for item in command]


def compile_command(args: argparse.Namespace, stage: Path, zig: str, binary: Path) -> list[str]:
    # The C source is placed before the module graph so Zig associates it with
    # the current compilation unit.  Every -M is preceded by its own -O, which
    # keeps optimization selection explicit for root, src6, and frozen src5.
    return [
        zig,
        "build-exe",
        "--name",
        "src6-bench",
        "--cache-dir",
        str(stage / "zig-cache"),
        "-femit-bin=" + str(binary),
        "--dep",
        "src6",
        "--dep",
        "src5",
        "-O",
        args.optimize,
        "-Mroot=" + str(REPO / "src6" / "bench" / "runner.zig"),
        "-O",
        args.optimize,
        "-I" + str(BZIP_INCLUDE),
        "-cflags",
        '-DVERSION="1.5.1"',
        "-fno-sanitize=undefined",
        "--",
        str(BZIP_SOURCE),
        "-O",
        args.optimize,
        "-Msrc6=" + str(NEW_ROOT),
        "-O",
        args.optimize,
        "-Msrc5=" + str(OLD_ROOT),
        "-lc",
    ]


def runner_command(args: argparse.Namespace, binary: Path, records: int, artifacts: Path) -> list[str]:
    command = [
        str(binary),
        "--mode",
        args.mode,
        "--records",
        str(records),
        "--profile",
        args.profile,
        "--distribution",
        args.distribution,
        "--codec",
        args.codec,
        "--warmup",
        str(args.warmup),
        "--repetitions",
        str(args.repetitions),
        "--output-dir",
        str(artifacts),
    ]
    if args.quiet_gate is not None:
        command.extend(("--quiet-gate", args.quiet_gate))
    return command


def run_process(command: Sequence[str], cwd: Path, stdout_path: Path, stderr_path: Path) -> subprocess.CompletedProcess[str]:
    try:
        process = subprocess.run(
            list(command),
            cwd=cwd,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise HarnessError(f"could not start {' '.join(command)}: {exc}") from exc
    stdout_path.write_text(process.stdout, encoding="utf-8")
    stderr_path.write_text(process.stderr, encoding="utf-8")
    return process


def verify_artifacts(stdout: str, artifacts: Path) -> list[dict[str, object]]:
    """Cross-check every retained artifact against the runner's own ledger."""

    records: dict[tuple[str, str], dict[str, object]] = {}
    for line_number, line in enumerate(stdout.splitlines(), start=1):
        fields = line.split("\t")
        if len(fields) < 5 or fields[0] != "artifact":
            continue
        key = (fields[1], fields[2])
        if fields[3] == "bytes":
            try:
                records.setdefault(key, {})["bytes"] = int(fields[4])
            except ValueError as exc:
                raise HarnessError(f"invalid artifact byte row at stdout line {line_number}") from exc
        elif fields[3] == "sha256":
            records.setdefault(key, {})["sha256"] = fields[4]
    if not records:
        raise HarnessError("runner emitted no retained artifact rows")

    checked = []
    for (lane, codec), expected in sorted(records.items()):
        if "bytes" not in expected or "sha256" not in expected:
            raise HarnessError(f"incomplete artifact ledger for {lane}/{codec}")
        if lane == "old_borrowed_core":
            name = "old-borrowed-core.lex5"
        elif lane == "new":
            name = f"new-{codec}.lex6"
        else:
            raise HarnessError(f"unexpected artifact lane {lane!r}")
        path = (artifacts / name).resolve()
        try:
            path.relative_to(artifacts.resolve())
        except ValueError as exc:
            raise HarnessError(f"artifact path escapes output directory: {path}") from exc
        if not path.is_file():
            raise HarnessError(f"runner ledger names an artifact that was not retained: {path}")
        actual_size = path.stat().st_size
        actual_digest = digest_file(path)
        if actual_size != expected["bytes"] or actual_digest != expected["sha256"]:
            raise HarnessError(f"artifact ledger mismatch for {lane}/{codec}")
        checked.append({"lane": lane, "codec": codec, "path": path.relative_to(artifacts.parent).as_posix(), "bytes": actual_size, "sha256": actual_digest})
    return checked


def ensure_no_timing(stdout: str, mode: str) -> None:
    if mode == "measure":
        return
    for line in stdout.splitlines():
        if line.startswith("timing\t") and "status\tunauthorized" not in line:
            raise HarnessError(f"non-measure run emitted a timing row: {line}")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        records = validate_args(args)
        stage = new_stage(args.out)
        raw = stage / "raw"
        artifacts = stage / "artifacts"
        raw.mkdir()
        artifacts.mkdir()

        zig = shutil.which(args.zig) or args.zig
        binary = stage / "src6-bench"
        before = source_manifest()
        binary_before = binary_record(binary)
        compile_cmd = compile_command(args, stage, zig, binary)
        compile_process = run_process(compile_cmd, REPO, raw / "compile.stdout", raw / "compile.stderr")
        after_compile = source_manifest()
        if before != after_compile:
            raise HarnessError("pinned source bytes changed during compilation")
        if compile_process.returncode != 0:
            raise HarnessError(f"Zig compilation failed ({compile_process.returncode}); see {raw / 'compile.stderr'}")

        run_cmd = runner_command(args, binary, records, artifacts)
        run_process_result = run_process(run_cmd, REPO, raw / "runner.stdout", raw / "runner.stderr")
        after_run = source_manifest()
        if before != after_run:
            raise HarnessError("pinned source bytes changed during the runner process")
        if run_process_result.returncode != 0:
            raise HarnessError(f"runner failed ({run_process_result.returncode}); see {raw / 'runner.stderr'}")
        ensure_no_timing(run_process_result.stdout, args.mode)
        checked_artifacts = verify_artifacts(run_process_result.stdout, artifacts)

        provenance = {
            "protocol": PROTOCOL,
            "status": "pass",
            "mode": args.mode,
            "records": records,
            "profile": args.profile,
            "distribution": args.distribution,
            "codec": args.codec,
            "warmup": args.warmup,
            "repetitions": args.repetitions,
            "optimize": args.optimize,
            "quiet_gate_supplied": args.quiet_gate == QUIET_GATE,
            "new_root": path_label(NEW_ROOT),
            "frozen_old_root": path_label(OLD_ROOT),
            "zig": command_text([zig]),
            "compile_command": command_text(compile_cmd),
            "runner_command": command_text(run_cmd),
            "source_manifest_before": before,
            "source_manifest_after_compile": after_compile,
            "source_manifest_after_run": after_run,
            "binary_before": binary_before,
            "binary_after": binary_record(binary),
            "artifacts": checked_artifacts,
            "raw_stdout": "raw/runner.stdout",
            "raw_stderr": "raw/runner.stderr",
        }
        write_json(stage / "provenance.json", provenance)
        print(stage)
        return 0
    except HarnessError as exc:
        print(f"src6 benchmark harness: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
