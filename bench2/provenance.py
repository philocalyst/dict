#!/usr/bin/env python3
"""Capture and verify the inputs to a benchmark run.

The benchmark writes a fair amount of generated data below ``bench2/results``.
That data is intentionally *not* part of the source manifest in this module.
The manifest is instead a sorted, byte-oriented list of the Zig and benchmark
inputs, the pinned bzip3 source/include tree, the flake files, and the exact
benchmark executable.  A run can therefore be checked after it completes
without hashing (or accidentally hashing) the report it is producing.

Typical use from ``bench2/run.sh`` is::

    python3 bench2/provenance.py capture \
        --repo "$root_dir" \
        --out "$staging/provenance.json" \
        --meta-tsv "$raw_dir/provenance.tsv" \
        --cli "$0" "$@"
    # ... run the benchmark ...
    python3 bench2/provenance.py verify \
        --repo "$root_dir" \
        --manifest "$staging/provenance.json" \
        --meta-tsv "$raw_dir/provenance.tsv"

The ``capture`` command should run after the benchmark executable has been
built and immediately before the measured workload.  ``verify`` exits non-zero
if an input, the executable, the flake, or the git HEAD changed in the
meantime.  The optional TSV contains scalar metadata understood by the existing
``tsv_to_json.py`` converter.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 1
HASH_ALGORITHM = "sha256"
DEFAULT_EXECUTABLE = "zig-out/bin/bench2"


class ProvenanceError(RuntimeError):
    """A requested provenance fact could not be collected."""


def _canonical_json(value: Any) -> str:
    """Return stable JSON suitable for hashing or a single TSV field."""

    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ProvenanceError(f"cannot read {path}: {exc}") from exc
    return digest.hexdigest()


def _normalise_repo(path: Path) -> Path:
    try:
        return path.expanduser().resolve(strict=True)
    except OSError as exc:
        raise ProvenanceError(f"repository root is not readable: {path}: {exc}") from exc


def _relative_path(root: Path, path: Path) -> str:
    """Return a POSIX path, rejecting paths outside the repository."""

    try:
        return path.resolve(strict=False).relative_to(root).as_posix()
    except ValueError as exc:
        raise ProvenanceError(f"path is outside repository {root}: {path}") from exc


def _path_for_record(root: Path, path_arg: str | Path) -> tuple[Path, str]:
    """Resolve a user path and retain a stable repository-relative spelling."""

    supplied = Path(path_arg).expanduser()
    path = supplied if supplied.is_absolute() else root / supplied
    path = path.resolve(strict=False)
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError:
        # A custom executable outside the source tree is useful for testing and
        # is still unambiguous when its absolute path is recorded.
        relative = str(path)
    return path, relative


def _record_file(root: Path, path_arg: str | Path, *, required: bool = True) -> dict[str, Any]:
    path, relative = _path_for_record(root, path_arg)
    if not path.is_file():
        if required:
            raise ProvenanceError(f"required file is missing: {path}")
        return {"path": relative, "missing": True}
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise ProvenanceError(f"cannot stat {path}: {exc}") from exc
    return {"path": relative, "size": size, "sha256": _sha256_file(path)}


def _is_generated_path(relative: str) -> bool:
    """Defence in depth for output trees, even if a glob is broadened later."""

    parts = Path(relative).parts
    return bool(parts) and (
        parts[0] in {"zig-out", "result", "results"}
        or (len(parts) >= 2 and parts[0] == "bench2" and parts[1] == "results")
    )


def _source_candidates(root: Path) -> set[Path]:
    """Collect only the declared source-input classes.

    All paths are explicit rather than a repository-wide walk.  In particular,
    benchmark reports, corpora, and external-reader artifacts cannot enter the
    source hash merely because a new generated file appeared.
    """

    candidates: set[Path] = set()

    for directory in (root / "src", root / "src2"):
        if directory.is_dir():
            candidates.update(path for path in directory.rglob("*.zig") if path.is_file())

    candidates.update(path for path in root.glob("build*.zig") if path.is_file())

    bench_driver = root / "bench2.zig"
    if bench_driver.is_file():
        candidates.add(bench_driver)

    bench2 = root / "bench2"
    if bench2.is_dir():
        candidates.update(path for path in bench2.glob("*.py") if path.is_file())
        candidates.update(path for path in bench2.glob("*.sh") if path.is_file())

    for name in ("flake.nix", "flake.lock"):
        path = root / name
        if path.is_file():
            candidates.add(path)

    # The benchmark links only against bzip3's C source and public headers.
    # Hash every regular file below both trees so a future helper/header cannot
    # be changed without invalidating the run.
    for directory in (root / "vendor" / "bzip3" / "src", root / "vendor" / "bzip3" / "include"):
        if directory.is_dir():
            candidates.update(path for path in directory.rglob("*") if path.is_file())

    return candidates


def _source_manifest(root: Path, excluded: Iterable[str] = ()) -> dict[str, Any]:
    excluded_set = {Path(item).as_posix() for item in excluded}
    records: list[dict[str, Any]] = []
    for path in _source_candidates(root):
        relative = _relative_path(root, path)
        if relative in excluded_set or _is_generated_path(relative):
            continue
        try:
            size = path.stat().st_size
        except OSError as exc:
            raise ProvenanceError(f"cannot stat source input {path}: {exc}") from exc
        records.append({"path": relative, "size": size, "sha256": _sha256_file(path)})

    records.sort(key=lambda item: item["path"])
    rows = "".join(
        f"sha256\t{record['path']}\t{record['size']}\t{record['sha256']}\n" for record in records
    ).encode("utf-8")
    return {
        "algorithm": HASH_ALGORITHM,
        "files": records,
        "file_count": len(records),
        "manifest_sha256": _sha256_bytes(rows),
        "excluded_paths": sorted(excluded_set),
    }


def _flake_snapshot(root: Path) -> dict[str, Any]:
    nix = _record_file(root, "flake.nix")
    lock = _record_file(root, "flake.lock")
    locked_inputs: list[dict[str, Any]] = []
    parse_error: str | None = None
    lock_path = root / "flake.lock"
    try:
        lock_value = json.loads(lock_path.read_text(encoding="utf-8"))
        nodes = lock_value.get("nodes", {}) if isinstance(lock_value, dict) else {}
        if not isinstance(nodes, dict):
            raise ValueError("nodes is not an object")
        for name in sorted(nodes):
            node = nodes[name]
            if not isinstance(node, dict) or not isinstance(node.get("locked"), dict):
                continue
            # Keep the complete locked object.  Besides narHash and rev, fields
            # such as lastModified and flake URL type are part of the pin.
            locked_inputs.append({"node": name, "locked": node["locked"]})
    except (OSError, UnicodeError, ValueError, TypeError) as exc:
        parse_error = str(exc)

    locked_digest = _sha256_bytes(_canonical_json(locked_inputs).encode("utf-8"))
    result: dict[str, Any] = {
        "files": {"flake.nix": nix, "flake.lock": lock},
        "hashes": {
            "flake.nix": nix["sha256"],
            "flake.lock": lock["sha256"],
        },
        "locked_inputs": locked_inputs,
        "locked_inputs_sha256": locked_digest,
    }
    if parse_error is not None:
        result["lock_parse_error"] = parse_error
    return result


def _git_snapshot(root: Path) -> dict[str, Any]:
    """Capture HEAD and a stable, human-readable dirty status."""

    git = shutil.which("git")
    if git is None:
        return {"available": False, "reason": "git executable not found"}

    def run(args: Sequence[str]) -> tuple[int, bytes, bytes]:
        try:
            process = subprocess.run(
                [git, *args],
                cwd=root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "LC_ALL": "C", "LANG": "C"},
            )
        except OSError as exc:
            return 127, b"", str(exc).encode("utf-8", "replace")
        return process.returncode, process.stdout, process.stderr

    head_code, head_bytes, head_stderr = run(["rev-parse", "HEAD"])
    if head_code != 0:
        return {
            "available": False,
            "reason": head_stderr.decode("utf-8", "replace").strip() or "not a git worktree",
        }

    status_code, status_bytes, status_stderr = run(
        ["status", "--porcelain=v1", "--untracked-files=all"]
    )
    if status_code != 0:
        raise ProvenanceError(
            "git status failed: " + (status_stderr.decode("utf-8", "replace").strip() or "unknown error")
        )
    status_lines = sorted(
        line for line in status_bytes.decode("utf-8", "replace").splitlines() if line
    )
    head = head_bytes.decode("ascii", "replace").strip()
    return {
        "available": True,
        "head": head,
        "dirty": bool(status_lines),
        "status": status_lines,
    }


def _environment_snapshot(overrides: Sequence[str]) -> tuple[dict[str, str], str]:
    environment = dict(os.environ)
    for item in overrides:
        if "=" not in item:
            raise ProvenanceError(f"--env must be KEY=VALUE, got {item!r}")
        key, value = item.split("=", 1)
        if not key:
            raise ProvenanceError("--env key cannot be empty")
        environment[key] = value
    canonical = "".join(f"{key}={environment[key]}\n" for key in sorted(environment)).encode(
        "utf-8", "surrogateescape"
    )
    return dict(sorted(environment.items())), _sha256_bytes(canonical)


def _run_context(cli: Sequence[str], env_overrides: Sequence[str]) -> dict[str, Any]:
    environment, env_digest = _environment_snapshot(env_overrides)
    return {
        "cli": [str(item) for item in cli],
        "cwd": str(Path.cwd().resolve()),
        "environment": environment,
        "environment_sha256": env_digest,
    }


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except OSError as exc:
        raise ProvenanceError(f"cannot write provenance JSON {path}: {exc}") from exc


def _meta_rows(snapshot: dict[str, Any], *, phase: str, verified: bool, mismatches: Sequence[str] = ()) -> list[str]:
    source = snapshot.get("sources", {})
    executable = snapshot.get("executable", {})
    flake = snapshot.get("flake", {})
    git = snapshot.get("git", {})
    context = snapshot.get("run", {})
    hashes = flake.get("hashes", {}) if isinstance(flake, dict) else {}
    rows = [
        ("schema_version", snapshot.get("schema_version", SCHEMA_VERSION)),
        ("phase", phase),
        ("verified", int(verified)),
        ("source_file_count", source.get("file_count", 0)),
        ("source_manifest_sha256", source.get("manifest_sha256", "")),
        ("executable_sha256", executable.get("sha256", "")),
        ("flake_nix_sha256", hashes.get("flake.nix", "")),
        ("flake_lock_sha256", hashes.get("flake.lock", "")),
        ("flake_locked_inputs_sha256", flake.get("locked_inputs_sha256", "")),
        ("git_head", git.get("head", "")),
        ("git_dirty", int(bool(git.get("dirty", False)))),
        ("environment_sha256", context.get("environment_sha256", "")),
        ("cli_json", _canonical_json(context.get("cli", []))),
        ("mismatch_count", len(mismatches)),
    ]
    return [f"meta\tprovenance\t{name}\t{value}\n" for name, value in rows]


def _write_meta(path: Path, snapshot: dict[str, Any], *, phase: str, verified: bool, mismatches: Sequence[str] = ()) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text("".join(_meta_rows(snapshot, phase=phase, verified=verified, mismatches=mismatches)), encoding="utf-8")
    except OSError as exc:
        raise ProvenanceError(f"cannot write provenance TSV {path}: {exc}") from exc


def capture(
    *,
    root: Path,
    output: Path,
    executable: str,
    cli: Sequence[str],
    env_overrides: Sequence[str] = (),
    meta_tsv: Path | None = None,
) -> dict[str, Any]:
    root = _normalise_repo(root)
    output = output.expanduser().resolve(strict=False)
    excluded: list[str] = []
    for generated_path in (output, meta_tsv):
        if generated_path is None:
            continue
        try:
            excluded.append(generated_path.expanduser().resolve(strict=False).relative_to(root).as_posix())
        except ValueError:
            pass

    executable_record = _record_file(root, executable)
    context = _run_context(cli, env_overrides)
    snapshot: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "hash_algorithm": HASH_ALGORITHM,
        "repo_root": str(root),
        "run": context,
        "git": _git_snapshot(root),
        "sources": _source_manifest(root, excluded),
        "executable": executable_record,
        "flake": _flake_snapshot(root),
    }
    _write_json(output, snapshot)
    if meta_tsv is not None:
        _write_meta(meta_tsv, snapshot, phase="capture", verified=False)
    return snapshot


def _same_json(left: Any, right: Any) -> bool:
    return _canonical_json(left) == _canonical_json(right)


def verify(*, root: Path, manifest: Path, meta_tsv: Path | None = None, executable: str | None = None) -> tuple[bool, list[str], dict[str, Any]]:
    try:
        value = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError(f"cannot read provenance JSON {manifest}: {exc}") from exc
    if not isinstance(value, dict):
        raise ProvenanceError(f"provenance JSON is not an object: {manifest}")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise ProvenanceError(
            f"unsupported provenance schema {value.get('schema_version')!r}; expected {SCHEMA_VERSION}"
        )

    root = _normalise_repo(root)
    mismatches: list[str] = []
    expected_sources = value.get("sources")
    if not isinstance(expected_sources, dict):
        raise ProvenanceError("provenance JSON has no sources object")
    excluded = expected_sources.get("excluded_paths", [])
    if not isinstance(excluded, list) or not all(isinstance(item, str) for item in excluded):
        raise ProvenanceError("provenance sources.excluded_paths is invalid")
    current_sources = _source_manifest(root, excluded)
    if not _same_json(expected_sources.get("files", []), current_sources.get("files", [])):
        mismatches.append("source file list or file digest changed")
    if expected_sources.get("manifest_sha256") != current_sources.get("manifest_sha256"):
        mismatches.append("source manifest SHA-256 changed")

    expected_executable = value.get("executable")
    if not isinstance(expected_executable, dict) or not isinstance(expected_executable.get("path"), str):
        raise ProvenanceError("provenance JSON has no executable record")
    executable_arg = executable if executable is not None else expected_executable["path"]
    try:
        current_executable = _record_file(root, executable_arg)
    except ProvenanceError as exc:
        mismatches.append(f"executable changed: {exc}")
    else:
        if not _same_json(expected_executable, current_executable):
            mismatches.append("benchmark executable SHA-256 or size changed")

    expected_flake = value.get("flake")
    if not isinstance(expected_flake, dict):
        raise ProvenanceError("provenance JSON has no flake object")
    try:
        current_flake = _flake_snapshot(root)
    except ProvenanceError as exc:
        mismatches.append(f"flake.nix/flake.lock changed or is missing: {exc}")
    else:
        if not _same_json(expected_flake, current_flake):
            mismatches.append("flake.nix/flake.lock or locked input hashes changed")

    expected_git = value.get("git")
    if isinstance(expected_git, dict) and expected_git.get("available"):
        current_git = _git_snapshot(root)
        if not current_git.get("available"):
            mismatches.append("git repository is no longer available")
        elif expected_git.get("head") != current_git.get("head"):
            mismatches.append("git HEAD changed")

    if meta_tsv is not None:
        _write_meta(meta_tsv, value, phase="verify", verified=not mismatches, mismatches=mismatches)
    return not mismatches, mismatches, value


def _write_fixture(path: Path, data: bytes | str, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
    if executable:
        path.chmod(path.stat().st_mode | 0o111)


def self_test() -> int:
    """Exercise deterministic capture plus source/deletion/drift failures."""

    with tempfile.TemporaryDirectory(prefix="lex2-provenance-") as temporary:
        root = Path(temporary)
        files: dict[str, bytes | str] = {
            "src/main.zig": "const main = 1;\n",
            "src2/root.zig": "const root = 2;\n",
            "build.zig": "pub fn build() void {}\n",
            "build2.zig": "pub fn build() void {}\n",
            "bench2.zig": "const bench = 3;\n",
            "bench2/run.sh": "#!/bin/sh\ntrue\n",
            "bench2/reader.py": "print('reader')\n",
            "flake.nix": "{ description = \"self-test\"; }\n",
            "flake.lock": '{"nodes":{"root":{"inputs":{},"locked":{"type":"path"}}},"root":"root"}\n',
            "vendor/bzip3/src/libbz3.c": "int bz3(void) { return 0; }\n",
            "vendor/bzip3/include/libbz3.h": "int bz3(void);\n",
            # This file is intentionally outside the declared source inputs.
            "bench2/results/generated-report.json": "generated\n",
        }
        for name, data in files.items():
            _write_fixture(root / name, data)
        executable = root / DEFAULT_EXECUTABLE
        _write_fixture(executable, b"#!/bin/sh\nexit 0\n", executable=True)

        output_a = root / "bench2" / "results" / "run-a" / "provenance.json"
        output_b = root / "bench2" / "results" / "run-b" / "provenance.json"
        first = capture(
            root=root,
            output=output_a,
            executable=DEFAULT_EXECUTABLE,
            cli=("bench2/run.sh", "--records", "2"),
            env_overrides=("LEX2_SELF_TEST=1",),
        )
        second = capture(
            root=root,
            output=output_b,
            executable=DEFAULT_EXECUTABLE,
            cli=("bench2/run.sh", "--records", "2"),
            env_overrides=("LEX2_SELF_TEST=1",),
        )
        # The output path is recorded as an exclusion so a manifest cannot
        # hash itself.  The exclusion list is therefore allowed to differ
        # between these two output locations; the actual source records and
        # their digest must remain byte-for-byte deterministic.
        for key in ("executable", "flake"):
            if not _same_json(first[key], second[key]):
                raise AssertionError(f"self-test is not deterministic for {key}")
        for key in ("algorithm", "files", "file_count", "manifest_sha256"):
            if first["sources"].get(key) != second["sources"].get(key):
                raise AssertionError(f"self-test is not deterministic for sources.{key}")
        if any(record["path"].startswith("bench2/results/") for record in first["sources"]["files"]):
            raise AssertionError("generated result entered source manifest")

        ok, mismatches, _ = verify(root=root, manifest=output_a)
        if not ok:
            raise AssertionError(f"fresh verification failed: {mismatches}")

        # Also exercise the explicit self-reference guard: both outputs use
        # source-looking suffixes but must remain outside the bench2/*.py/*.sh
        # input set after they are written.
        self_ref_output = root / "bench2" / "generated-provenance.py"
        self_ref_meta = root / "bench2" / "generated-provenance.sh"
        capture(
            root=root,
            output=self_ref_output,
            meta_tsv=self_ref_meta,
            executable=DEFAULT_EXECUTABLE,
            cli=("bench2/run.sh",),
        )
        ok, mismatches, _ = verify(root=root, manifest=self_ref_output, meta_tsv=self_ref_meta)
        if not ok:
            raise AssertionError(f"self-referential outputs entered source manifest: {mismatches}")

        def expect_drift(path: Path, replacement: bytes | str, label: str) -> None:
            original = path.read_bytes()
            try:
                path.write_bytes(replacement.encode("utf-8") if isinstance(replacement, str) else replacement)
                changed, reasons, _ = verify(root=root, manifest=output_a)
                if changed or not reasons:
                    raise AssertionError(f"{label} drift was not detected")
            finally:
                path.write_bytes(original)

        expect_drift(root / "src" / "main.zig", "const main = 99;\n", "source")

        deleted = root / "src2" / "root.zig"
        deleted_bytes = deleted.read_bytes()
        deleted.unlink()
        try:
            changed, reasons, _ = verify(root=root, manifest=output_a)
            if changed or not reasons:
                raise AssertionError("source deletion was not detected")
        finally:
            _write_fixture(deleted, deleted_bytes)

        expect_drift(executable, b"#!/bin/sh\nexit 7\n", "executable")
        expect_drift(root / "flake.lock", '{"nodes":{},"root":"root"}\n', "flake")
    print("provenance self-test: ok")
    return 0


def _cli_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture_parser = subparsers.add_parser("capture", aliases=["begin", "start"], help="capture run-start provenance")
    capture_parser.add_argument("--repo", "--root", type=Path, default=Path.cwd())
    capture_parser.add_argument("--out", "--output", "--json", type=Path, required=True)
    capture_parser.add_argument("--meta-tsv", "--tsv", "--tsv-meta", type=Path)
    capture_parser.add_argument("--executable", default=DEFAULT_EXECUTABLE)
    capture_parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE")
    capture_parser.add_argument(
        "--cli",
        "--command",
        "--argv",
        dest="cli",
        nargs=argparse.REMAINDER,
        help="exact benchmark argv; all arguments after --cli belong to the recorded command",
    )
    capture_parser.add_argument(
        "run_cli",
        nargs=argparse.REMAINDER,
        help="argv after a conventional '--' separator (alternative to --cli)",
    )

    verify_parser = subparsers.add_parser("verify", aliases=["check"], help="verify run-end provenance")
    verify_parser.add_argument("--repo", "--root", type=Path)
    verify_parser.add_argument("--manifest", "--in", dest="manifest", type=Path, required=True)
    verify_parser.add_argument("--meta-tsv", "--tsv", "--tsv-meta", type=Path)
    verify_parser.add_argument("--executable")

    subparsers.add_parser("self-test", aliases=["test"], help="run deterministic/drift self-tests")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _cli_parser()
    args = parser.parse_args(argv)
    try:
        if args.command in {"capture", "begin", "start"}:
            if args.cli is not None and args.run_cli:
                parser.error("provide either --cli or a '--' separated command, not both")
            cli = list(args.cli if args.cli is not None else args.run_cli)
            # argparse retains the conventional separator in a REMAINDER
            # positional.  It is syntax for this wrapper, not part of the
            # benchmark command whose exact argv is being recorded.
            if cli and cli[0] == "--":
                cli = cli[1:]
            snapshot = capture(
                root=args.repo,
                output=args.out,
                executable=args.executable,
                cli=cli,
                env_overrides=args.env,
                meta_tsv=args.meta_tsv,
            )
            print(
                "provenance captured: "
                + snapshot["sources"]["manifest_sha256"]
                + " executable="
                + snapshot["executable"]["sha256"]
            )
            return 0
        if args.command in {"verify", "check"}:
            root = args.repo
            if root is None:
                try:
                    manifest_value = json.loads(args.manifest.read_text(encoding="utf-8"))
                    root = Path(manifest_value["repo_root"])
                except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
                    raise ProvenanceError(f"--repo is required when manifest repo_root is unavailable: {exc}") from exc
            ok, mismatches, snapshot = verify(
                root=root,
                manifest=args.manifest,
                meta_tsv=args.meta_tsv,
                executable=args.executable,
            )
            if ok:
                print("provenance verified: " + snapshot["sources"]["manifest_sha256"])
                return 0
            print("provenance verification failed:", file=sys.stderr)
            for mismatch in mismatches:
                print("  - " + mismatch, file=sys.stderr)
            return 1
        if args.command in {"self-test", "test"}:
            return self_test()
        raise ProvenanceError(f"unknown command {args.command!r}")
    except (OSError, ProvenanceError, AssertionError) as exc:
        print(f"provenance: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
