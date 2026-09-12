#!/usr/bin/env python3
"""Capture, verify, and hash the complete LEX4 benchmark input boundary.

LEX4 deliberately keeps this implementation separate from ``bench2``.  A
run's source manifest includes current ``src4`` production sources, the
LEX4 build file/driver, all benchmark scripts, optional vendor inputs, the
exact executable, command line, environment digest, flake pin, and git HEAD.
Generated results are excluded by path and are covered by the separate
artifact manifest.  Verification is fatal: a report cannot be promoted when
the source boundary changed after the run began.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
HASH_ALGORITHM = "sha256"

# Environment capture is deliberately allowlisted.  A benchmark artifact is
# often copied to CI or attached to a review; persisting the entire process
# environment would leak credentials and machine-local secrets.  Values that
# affect reproducibility are retained, while arbitrary overrides are ignored
# unless they use one of the explicit benchmark namespaces.
ENVIRONMENT_ALLOWLIST = frozenset(
    {
        "PATH",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LC_COLLATE",
        "LANGUAGE",
        "TZ",
        "SOURCE_DATE_EPOCH",
        "NIX_BUILD_CORES",
        "NIX_REMOTE",
        "ZIG_GLOBAL_CACHE_DIR",
        "ZIG_LOCAL_CACHE_DIR",
        "ZIG_LIB_DIR",
        "CC",
        "CFLAGS",
        "CXX",
        "CPPFLAGS",
        "LDFLAGS",
        "MAKEFLAGS",
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "RAYON_NUM_THREADS",
        "PYTHONHASHSEED",
        "PYTHONNOUSERSITE",
        "PYTHONUTF8",
        "MACOSX_DEPLOYMENT_TARGET",
    }
)
SECRET_KEY = re.compile(r"(?:TOKEN|SECRET|PASSWORD|PASSWD|KEY|COOKIE|AUTH|CREDENTIAL|PRIVATE)", re.IGNORECASE)


class ProvenanceError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def repo_path(root: Path, path: str | Path) -> tuple[Path, str]:
    candidate = Path(path).expanduser()
    candidate = candidate if candidate.is_absolute() else root / candidate
    candidate = candidate.resolve(strict=False)
    try:
        return candidate, candidate.relative_to(root).as_posix()
    except ValueError:
        return candidate, str(candidate)


def record_file(root: Path, path: str | Path, *, required: bool = True) -> dict[str, Any]:
    candidate, relative = repo_path(root, path)
    if not candidate.is_file():
        if required:
            raise ProvenanceError(f"required file missing: {candidate}")
        return {"path": relative, "missing": True}
    return {"path": relative, "size": candidate.stat().st_size, "sha256": digest_file(candidate)}


def resolve_executable(root: Path, executable: str | Path) -> Path:
    """Resolve repo-relative, absolute, or PATH-native executable names."""

    value = str(executable)
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        repo_candidate = (root / candidate).resolve(strict=False)
        if repo_candidate.is_file():
            return repo_candidate
        found = shutil.which(value)
        if found:
            return Path(found).resolve(strict=False)
    return candidate.resolve(strict=False)


def is_generated(relative: str) -> bool:
    parts = Path(relative).parts
    if not parts:
        return True
    if "__pycache__" in parts:
        return True
    # A caller may place results anywhere under bench4; no output can become a
    # source input merely because its extension resembles a script.
    if parts[0] in {"result", "results", "zig-out"}:
        return True
    if parts[0] == "bench4" and len(parts) > 1 and parts[1] in {"result", "results", ".staging"}:
        return True
    return False


def source_candidates(root: Path) -> set[Path]:
    candidates: set[Path] = set()
    for directory in (root / "src2", root / "src4", root / "bench4"):
        if directory.is_dir():
            candidates.update(path for path in directory.rglob("*") if path.is_file())
    for name in ("build.zig", "bench4.zig", "build4.zig"):
        path = root / name
        if path.is_file():
            candidates.add(path)
    # The production LEX4 reader may use these pinned codec inputs.  Include
    # them when present without requiring a repository that has no vendor tree.
    for directory in (root / "vendor" / "bzip3" / "src", root / "vendor" / "bzip3" / "include"):
        if directory.is_dir():
            candidates.update(path for path in directory.rglob("*") if path.is_file())
    return candidates


def source_manifest(root: Path, excluded: Iterable[str] = (), excluded_roots: Iterable[str] = ()) -> dict[str, Any]:
    excluded_set = {Path(item).as_posix() for item in excluded}
    excluded_root_set = {Path(item).as_posix().rstrip("/") for item in excluded_roots}
    files: list[dict[str, Any]] = []
    for path in source_candidates(root):
        relative = path.relative_to(root).as_posix()
        if (
            relative in excluded_set
            or any(relative == prefix or relative.startswith(prefix + "/") for prefix in excluded_root_set)
            or is_generated(relative)
        ):
            continue
        files.append({"path": relative, "size": path.stat().st_size, "sha256": digest_file(path)})
    files.sort(key=lambda item: str(item["path"]))
    manifest_rows = "".join(f"sha256\t{row['path']}\t{row['size']}\t{row['sha256']}\n" for row in files).encode("utf-8")
    return {
        "algorithm": HASH_ALGORITHM,
        "files": files,
        "file_count": len(files),
        "manifest_sha256": digest_bytes(manifest_rows),
        "excluded_paths": sorted(excluded_set),
        "excluded_roots": sorted(excluded_root_set),
        "declared_roots": ["src2", "src4", "bench4", "build.zig", "bench4.zig", "build4.zig", "vendor/bzip3"],
    }


def flake_snapshot(root: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"available": False, "files": {}, "locked_inputs": []}
    nix = root / "flake.nix"
    lock = root / "flake.lock"
    if not nix.is_file() or not lock.is_file():
        result["reason"] = "flake.nix or flake.lock missing"
        return result
    nix_record = record_file(root, nix)
    lock_record = record_file(root, lock)
    locked: list[dict[str, Any]] = []
    parse_error: str | None = None
    try:
        value = json.loads(lock.read_text(encoding="utf-8"))
        nodes = value.get("nodes", {})
        if not isinstance(nodes, dict):
            raise ValueError("nodes is not an object")
        for name in sorted(nodes):
            node = nodes[name]
            if isinstance(node, dict) and isinstance(node.get("locked"), dict):
                locked.append({"node": name, "locked": node["locked"]})
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError) as exc:
        parse_error = str(exc)
    result = {
        "available": True,
        "files": {"flake.nix": nix_record, "flake.lock": lock_record},
        "hashes": {"flake.nix": nix_record["sha256"], "flake.lock": lock_record["sha256"]},
        "locked_inputs": locked,
        "locked_inputs_sha256": digest_bytes(canonical(locked)),
    }
    if parse_error:
        result["lock_parse_error"] = parse_error
    return result


def git_snapshot(root: Path) -> dict[str, Any]:
    git = shutil.which("git")
    if git is None:
        return {"available": False, "reason": "git executable not found"}

    def run(args: Sequence[str]) -> tuple[int, str, str]:
        process = subprocess.run(
            [git, *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        return process.returncode, process.stdout, process.stderr

    code, head, error = run(["rev-parse", "HEAD"])
    if code != 0:
        return {"available": False, "reason": error.strip() or "not a git worktree"}
    code, status, error = run(["status", "--porcelain=v1", "--untracked-files=all"])
    if code != 0:
        raise ProvenanceError(error.strip() or "git status failed")
    return {"available": True, "head": head.strip(), "dirty": bool(status.strip()), "status": sorted(status.splitlines())}


def environment_snapshot(overrides: Sequence[str]) -> tuple[dict[str, str], str]:
    value = dict(os.environ)
    for item in overrides:
        if "=" not in item:
            raise ProvenanceError(f"--env must be KEY=VALUE, got {item!r}")
        key, replacement = item.split("=", 1)
        if not key:
            raise ProvenanceError("--env key cannot be empty")
        value[key] = replacement
    sanitized: dict[str, str] = {}
    for key, item in value.items():
        if SECRET_KEY.search(key):
            # Do not retain even the key name: names such as SECRET_TOKEN can
            # disclose credential conventions, and the value must never enter
            # either the JSON artifact or the reproducibility digest.
            continue
        elif key in ENVIRONMENT_ALLOWLIST:
            sanitized[key] = item
    ordered = dict(sorted(sanitized.items()))
    encoded = b"".join(f"{key}={item}\n".encode("utf-8", "surrogateescape") for key, item in ordered.items())
    return ordered, digest_bytes(encoded)


def sanitize_cli(cli: Sequence[str]) -> list[str]:
    """Retain command shape while preventing secret-bearing argv leakage."""

    sanitized: list[str] = []
    redact_next = False
    for item in cli:
        text = str(item)
        if redact_next:
            sanitized.append("<redacted>")
            redact_next = False
            continue
        if SECRET_KEY.search(text):
            # Do not preserve a credential-shaped option or assignment key;
            # argv is part of the persisted provenance just like the env map.
            sanitized.append("<redacted-arg>")
            if "=" not in text:
                redact_next = True
            continue
        sanitized.append(text)
    return sanitized


def capture(*, root: Path, output: Path, executable: str | Path | None, cli: Sequence[str], env_overrides: Sequence[str] = (), excluded_roots: Sequence[str | Path] = (), extra_executables: Mapping[str, str | Path] | None = None) -> dict[str, Any]:
    root = root.expanduser().resolve(strict=True)
    output = output.expanduser().resolve(strict=False)
    excluded: list[str] = []
    try:
        excluded.append(output.relative_to(root).as_posix())
    except ValueError:
        pass
    normalized_roots: list[str] = []
    for item in excluded_roots:
        candidate = Path(item).expanduser().resolve(strict=False)
        try:
            normalized_roots.append(candidate.relative_to(root).as_posix())
        except ValueError:
            # An output root outside the repository cannot become a source
            # candidate, so no exclusion is needed.
            continue
    env, env_digest = environment_snapshot(env_overrides)
    value: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "hash_algorithm": HASH_ALGORITHM,
        "repo_root": str(root),
        "run": {"cli": sanitize_cli(cli), "cwd": str(Path.cwd().resolve()), "environment": env, "environment_sha256": env_digest},
        "git": git_snapshot(root),
        "sources": source_manifest(root, excluded, normalized_roots),
        "executable": record_file(root, resolve_executable(root, executable), required=False) if executable else {"missing": True, "reason": "reference-only run"},
        "extra_executables": {
            name: record_file(root, resolve_executable(root, path), required=True)
            for name, path in sorted((extra_executables or {}).items())
        },
        "flake": flake_snapshot(root),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return value


def verify(*, root: Path, manifest: Path, executable: str | Path | None = None, extra_executables: Mapping[str, str | Path] | None = None) -> tuple[bool, list[str], dict[str, Any]]:
    try:
        value = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError(f"cannot read provenance manifest: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA_VERSION:
        raise ProvenanceError("unsupported or malformed provenance schema")
    root = root.expanduser().resolve(strict=True)
    mismatches: list[str] = []
    expected_sources = value.get("sources")
    if not isinstance(expected_sources, dict):
        raise ProvenanceError("provenance has no sources object")
    current_sources = source_manifest(
        root,
        expected_sources.get("excluded_paths", []),
        expected_sources.get("excluded_roots", []),
    )
    if expected_sources.get("files") != current_sources.get("files") or expected_sources.get("manifest_sha256") != current_sources.get("manifest_sha256"):
        mismatches.append("source file list, size, or digest changed")
    expected_exec = value.get("executable", {})
    if isinstance(expected_exec, dict) and not expected_exec.get("missing"):
        exec_arg = executable if executable is not None else expected_exec.get("path")
        if not exec_arg:
            mismatches.append("recorded executable disappeared")
        else:
            try:
                current_exec = record_file(root, resolve_executable(root, exec_arg))
            except ProvenanceError as exc:
                mismatches.append(f"executable changed: {exc}")
            else:
                if current_exec != expected_exec:
                    mismatches.append("executable path, size, or SHA-256 changed")
    expected_extra = value.get("extra_executables", {})
    if not isinstance(expected_extra, dict):
        mismatches.append("extra executable provenance is malformed")
    else:
        actual_extra = extra_executables or {}
        if set(expected_extra) != set(actual_extra):
            mismatches.append("extra executable set changed")
        for name, expected in expected_extra.items():
            if name not in actual_extra or not isinstance(expected, dict):
                continue
            try:
                current = record_file(root, resolve_executable(root, actual_extra[name]))
            except ProvenanceError as exc:
                mismatches.append(f"extra executable {name} changed: {exc}")
            else:
                if current != expected:
                    mismatches.append(f"extra executable {name} path, size, or SHA-256 changed")
    try:
        current_flake = flake_snapshot(root)
    except ProvenanceError as exc:
        mismatches.append(f"flake snapshot failed: {exc}")
    else:
        if current_flake != value.get("flake"):
            mismatches.append("flake.nix/flake.lock or locked input hashes changed")
    expected_git = value.get("git")
    if isinstance(expected_git, dict) and expected_git.get("available"):
        current_git = git_snapshot(root)
        if not current_git.get("available") or current_git.get("head") != expected_git.get("head"):
            mismatches.append("git HEAD changed or repository disappeared")
    return not mismatches, mismatches, value


def artifact_manifest(root: Path, output: Path) -> list[dict[str, Any]]:
    """Hash every completed run byte except the manifest writing itself."""

    root = root.resolve(strict=True)
    output = output.resolve(strict=False)
    temporary = output.with_name(output.name + ".tmp")
    records: list[dict[str, Any]] = []
    for path in sorted(path for path in root.rglob("*") if path.is_file()):
        # The manifest is self-excluded, and its atomic staging file is also
        # transient rather than a retained run byte.
        if path.resolve() in {output, temporary}:
            continue
        if path.is_symlink():
            raise ProvenanceError(f"retained run bytes cannot be symlinks: {path}")
        relative = path.relative_to(root).as_posix()
        records.append({"path": relative, "size": path.stat().st_size, "sha256": digest_file(path)})
    # pathlib's rglob does not always descend through a symlinked directory,
    # so inspect directory entries separately; otherwise an entire hidden
    # subtree could evade the complete-byte ledger.
    for path in root.rglob("*"):
        if path.is_symlink() and path.is_dir():
            raise ProvenanceError(f"retained run directory cannot be a symlink: {path}")
    return records


def write_artifact_manifest(root: Path, output: Path) -> list[dict[str, Any]]:
    records = artifact_manifest(root, output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text("".join(f"sha256\t{row['path']}\t{row['size']}\t{row['sha256']}\n" for row in records), encoding="utf-8")
    os.replace(temporary, output)
    return records


def verify_artifact_manifest(root: Path, output: Path) -> tuple[bool, list[str]]:
    """Verify every retained file against the run's non-self manifest."""

    root = root.resolve(strict=True)
    output = output.resolve(strict=False)
    try:
        expected: dict[str, tuple[int, str]] = {}
        for line in output.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) != 4 or fields[0] != HASH_ALGORITHM:
                return False, [f"malformed artifact manifest row: {line!r}"]
            _, relative, size, digest = fields
            if relative in expected:
                return False, [f"duplicate artifact manifest path: {relative}"]
            expected[relative] = (int(size), digest)
    except (OSError, UnicodeError, ValueError) as exc:
        return False, [f"cannot read artifact manifest: {exc}"]
    try:
        actual_rows = artifact_manifest(root, output)
    except (OSError, ProvenanceError) as exc:
        return False, [str(exc)]
    actual = {str(row["path"]): (int(row["size"]), str(row["sha256"])) for row in actual_rows}
    mismatches: list[str] = []
    for relative in sorted(set(expected) | set(actual)):
        if relative not in expected:
            mismatches.append(f"unmanifested retained file: {relative}")
        elif relative not in actual:
            mismatches.append(f"manifested file missing: {relative}")
        elif expected[relative] != actual[relative]:
            mismatches.append(f"retained file changed: {relative}")
    return not mismatches, mismatches


def _cli() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture")
    capture_parser.add_argument("--repo", type=Path, default=Path.cwd())
    capture_parser.add_argument("--out", type=Path, required=True)
    capture_parser.add_argument("--executable")
    capture_parser.add_argument("--env", action="append", default=[])
    capture_parser.add_argument("--cli", nargs=argparse.REMAINDER, default=[])
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--repo", type=Path)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    verify_parser.add_argument("--executable")
    verify_parser.add_argument(
        "--extra-executable",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="additional native executable recorded by a multi-reader campaign",
    )
    manifest_parser = commands.add_parser("artifact-manifest")
    manifest_parser.add_argument("--root", type=Path, required=True)
    manifest_parser.add_argument("--out", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _cli().parse_args(argv)
    try:
        if args.command == "capture":
            value = capture(root=args.repo, output=args.out, executable=args.executable, cli=args.cli, env_overrides=args.env)
            print(value["sources"]["manifest_sha256"])
            return 0
        if args.command == "verify":
            root = args.repo
            if root is None:
                root = Path(json.loads(args.manifest.read_text(encoding="utf-8"))["repo_root"])
            extras: dict[str, str] = {}
            for item in args.extra_executable:
                if "=" not in item:
                    raise ProvenanceError(f"--extra-executable must be NAME=PATH, got {item!r}")
                name, path = item.split("=", 1)
                if not name or not path or name in extras:
                    raise ProvenanceError(f"invalid or duplicate --extra-executable: {item!r}")
                extras[name] = path
            ok, mismatches, _ = verify(root=root, manifest=args.manifest, executable=args.executable, extra_executables=extras)
            if not ok:
                for mismatch in mismatches:
                    print(mismatch, file=sys.stderr)
                return 1
            print("provenance verified")
            return 0
        write_artifact_manifest(args.root, args.out)
        return 0
    except (OSError, ProvenanceError, KeyError, TypeError) as exc:
        print(f"provenance: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
