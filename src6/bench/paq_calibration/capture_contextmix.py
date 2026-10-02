#!/usr/bin/env python3
"""Resource-bounded PAQ8PX v217 level -1 context-mixing calibration."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import signal
import subprocess
import sys
import time

EXPECTED_COMMIT = "c84f576fc2c522194cd320743708652a154daf6b"
EXPECTED_MANIFEST_SHA = "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d"
EXPECTED_CONTROLS_SHA = "640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f"
PROFILE = "-1"
MEMORY_LIMIT = 1024 * 1024 * 1024
TIMEOUT_SECONDS = 180


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for part in iter(lambda: f.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def tree_fingerprint(root: Path, require_clean: bool = True) -> dict:
    """Fingerprint every tracked source file at the expected clean commit."""
    root = root.resolve()
    commit = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], check=True,
                            text=True, capture_output=True).stdout.strip()
    status = subprocess.run(["git", "-C", str(root), "status", "--porcelain"], check=True,
                            text=True, capture_output=True).stdout
    if commit != EXPECTED_COMMIT or (require_clean and status):
        raise RuntimeError(f"source checkout is not clean pinned v217: commit={commit}, status={status!r}")
    names = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True,
                           capture_output=True).stdout.split(b"\0")
    rows = []
    tree = hashlib.sha256()
    for raw in sorted(x for x in names if x):
        rel = raw.decode("utf-8", "strict")
        p = root / rel
        if not p.is_file():
            raise RuntimeError(f"tracked source missing: {rel}")
        digest = sha256_file(p)
        size = p.stat().st_size
        rows.append({"path": rel, "bytes": size, "sha256": digest})
        tree.update(raw + b"\0" + str(size).encode() + b"\0" + digest.encode() + b"\n")
    return {"commit": commit, "git_status_porcelain": status, "files": rows,
            "tree_sha256": tree.hexdigest()}


def read_json(path: Path, expected_sha: str | None = None) -> dict:
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha and digest != expected_sha:
        raise RuntimeError(f"hash mismatch for {path}: {digest} != {expected_sha}")
    return json.loads(raw)


def selected_books(manifest_path: Path, controls_path: Path) -> list[dict]:
    manifest = read_json(manifest_path, EXPECTED_MANIFEST_SHA)
    controls = read_json(controls_path, EXPECTED_CONTROLS_SHA)
    if manifest.get("role") != "development" or controls.get("role") != "development":
        raise RuntimeError("only the frozen development cohort is allowed")
    if not controls.get("complete") or controls.get("source_manifest_sha256") != EXPECTED_MANIFEST_SHA:
        raise RuntimeError("prefix controls are incomplete or refer to a different manifest")
    b3 = {r["book"]: r for r in controls["rows"] if r.get("codec") == "bzip3"}
    result = []
    for book in manifest["books"]:
        pref = next((p for p in book["prefixes"] if p["byte_limit"] == 1048576), None)
        if pref is None:
            raise RuntimeError(f"missing fixed prefix for {book['id']}")
        p = Path(pref["path"])
        if not p.is_file() or p.stat().st_size != pref["bytes"] or sha256_file(p) != pref["sha256"]:
            raise RuntimeError(f"fixed source mismatch for {book['id']}")
        control = b3.get(book["id"])
        if not control or control["source_sha256"] != pref["sha256"] or not control["exact_source_verified"]:
            raise RuntimeError(f"missing exact matched bzip3 control for {book['id']}")
        result.append({"id": book["id"], "language": book["language"], "title": book["title"],
                       "source": str(p), "source_bytes": pref["bytes"],
                       "source_sha256": pref["sha256"], "bzip3_bytes": control["complete_frame_bytes"],
                       "bzip3_frame_sha256": control["frame_sha256"]})
    if len(result) != 6:
        raise RuntimeError(f"expected six frozen books, got {len(result)}")
    return result


def _limit_memory() -> None:
    resource.setrlimit(resource.RLIMIT_AS, (MEMORY_LIMIT, MEMORY_LIMIT))


def run_command(argv: list[str], cwd: Path, raw_dir: Path, label: str) -> dict:
    raw_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic_ns()
    timed_out = False
    try:
        p = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             preexec_fn=_limit_memory, start_new_session=True)
        try:
            out, err = p.communicate(timeout=TIMEOUT_SECONDS)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            out, err = p.communicate()
            rc = p.returncode
            timed_out = True
    except OSError as e:
        timed_out = True
        rc = None
        out = b""
        err = repr(e).encode()
    wall = time.monotonic_ns() - started
    (raw_dir / f"{label}.stdout.bin").write_bytes(out)
    (raw_dir / f"{label}.stderr.bin").write_bytes(err)
    return {"argv": argv, "cwd": str(cwd), "exit_code": rc, "timeout": timed_out,
            "wall_ns": wall, "memory_limit_bytes": MEMORY_LIMIT,
            "stdout_path": str(raw_dir / f"{label}.stdout.bin"),
            "stderr_path": str(raw_dir / f"{label}.stderr.bin"),
            "stdout_sha256": hashlib.sha256(out).hexdigest(),
            "stderr_sha256": hashlib.sha256(err).hexdigest(),
            # ProgramChecker counts PAQ Array allocations; this is not OS RSS.
            "paq_programchecker_memory_kib": _reported_paq_memory_kib(out + b"\n" + err),
            "stdout_text": out.decode("utf-8", "replace"),
            "stderr_text": err.decode("utf-8", "replace")}


def _reported_paq_memory_kib(output: bytes) -> int | None:
    match = re.search(rb"used\s+(\d+)\s+MB\s+\((\d+)\s+bytes\)\s+of memory", output)
    return int(match.group(2)) // 1024 if match else None


def tool_version(name: str) -> dict:
    path = shutil.which(name)
    if not path:
        return {"name": name, "available": False}
    version = subprocess.run([path, "--version"], text=True, capture_output=True, check=False)
    return {"name": name, "path": str(Path(path).resolve()), "sha256": sha256_file(Path(path)),
            "version_stdout": version.stdout, "version_stderr": version.stderr,
            "version_exit_code": version.returncode}


def binary_runtime(binary: Path) -> dict:
    output = subprocess.run(["ldd", str(binary)], text=True, capture_output=True, check=False)
    libs = []
    for line in output.stdout.splitlines():
        m = re.search(r"(/[^ ]+)", line)
        if m and Path(m.group(1)).is_file():
            lib = Path(m.group(1)).resolve()
            libs.append({"path": str(lib), "sha256": sha256_file(lib)})
    return {"binary": str(binary.resolve()), "binary_sha256": sha256_file(binary),
            "ldd_exit_code": output.returncode, "ldd_stdout": output.stdout,
            "ldd_stderr": output.stderr, "dynamic_libraries": libs}


def capture_env(binary: Path, source_root: Path) -> dict:
    build_root = binary.parent.parent
    build_tree = tree_fingerprint(build_root, require_clean=False) if (build_root / ".git").exists() else None
    build_script = build_root / "build" / "build-linux-with-gcc.sh"
    return {"capture_schema": "PAQ8PX-CALIBRATION/2", "profile": PROFILE,
            "source": tree_fingerprint(source_root), "runtime": binary_runtime(binary),
            "build_source_copy": build_tree,
            "toolchain": {"gcc": tool_version("gcc"), "g++": tool_version("g++"),
                          "ld": tool_version("ld")},
            "python": sys.version, "platform": platform.platform(),
            "machine": platform.machine(), "processor": platform.processor(),
            "cpu_count": os.cpu_count(), "limits": {"address_space_bytes": MEMORY_LIMIT,
            "timeout_seconds_per_operation": TIMEOUT_SECONDS},
            "build": {"directory": str(binary.parent),
                      "command": "cd build && bash build-linux-with-gcc.sh",
                      "build_script_sha256": sha256_file(build_script) if build_script.is_file() else None,
                      "cmake_cache_sha256": sha256_file(binary.parent / "CMakeCache.txt")
                      if (binary.parent / "CMakeCache.txt").is_file() else None}}


def execute_case(binary: Path, source_root: Path, out: Path, case: dict) -> dict:
    name = case["id"]
    case_dir = out / name
    enc_dir, dec_dir = case_dir / "encode", case_dir / "decode"
    enc_dir.mkdir(parents=True, exist_ok=True)
    dec_dir.mkdir(parents=True, exist_ok=True)
    src = Path(case["source"])
    local_src = enc_dir / "payload.txt"
    shutil.copyfile(src, local_src)
    frame = enc_dir / "payload.paq8px217"
    enc = run_command([str(binary), PROFILE, local_src.name, frame.name], enc_dir,
                      case_dir / "raw", "encode")
    row = {**case, "profile": PROFILE, "encode": enc, "frame_path": str(frame),
           "frame_bytes": frame.stat().st_size if frame.is_file() else None,
           "frame_sha256": sha256_file(frame) if frame.is_file() else None,
           "bzip3_bytes": case["bzip3_bytes"]}
    decoded = dec_dir / "decoded.txt"
    if frame.is_file() and not enc["timeout"] and enc["exit_code"] == 0:
        # Decoder gets only the archive in its isolated working directory.
        local_frame = dec_dir / "payload.paq8px217"
        shutil.copyfile(frame, local_frame)
        dec = run_command([str(binary), "-d", local_frame.name, decoded.name], dec_dir,
                          case_dir / "raw", "decode")
        row["decode"] = dec
        row["decoded_bytes"] = decoded.stat().st_size if decoded.is_file() else None
        row["decoded_sha256"] = sha256_file(decoded) if decoded.is_file() else None
        row["exact_fresh_decode"] = (dec["exit_code"] == 0 and not dec["timeout"] and
                                     row["decoded_bytes"] == case["source_bytes"] and
                                     row["decoded_sha256"] == case["source_sha256"])
    else:
        row["decode"] = {"status": "not-run-encode-failed"}
        row["exact_fresh_decode"] = False
    row["source_guard_end"] = tree_fingerprint(source_root)["tree_sha256"]
    return row


def smoke(binary: Path, source_root: Path, out: Path) -> dict:
    base = out / "smoke"
    encdir, decdir = base / "encode", base / "decode"
    encdir.mkdir(parents=True, exist_ok=True)
    decdir.mkdir(parents=True, exist_ok=True)
    payload = b"PAQ8PX fixed level-1 context-mixing check\n" + bytes(range(256)) * 4
    (encdir / "payload.txt").write_bytes(payload)
    frame = encdir / "payload.paq8px217"
    enc = run_command([str(binary), PROFILE, "payload.txt", frame.name], encdir,
                      base / "raw", "encode")
    result = {"input_bytes": len(payload), "input_sha256": hashlib.sha256(payload).hexdigest(),
              "encode": enc, "frame_path": str(frame),
              "frame_bytes": frame.stat().st_size if frame.is_file() else None,
              "frame_sha256": sha256_file(frame) if frame.is_file() else None}
    if enc["exit_code"] == 0 and not enc["timeout"] and frame.is_file():
        shutil.copyfile(frame, decdir / frame.name)
        dec = run_command([str(binary), "-d", frame.name, "decoded.txt"], decdir,
                          base / "raw", "decode")
        decoded = decdir / "decoded.txt"
        result["decode"] = dec
        result["exact_fresh_decode"] = (dec["exit_code"] == 0 and not dec["timeout"] and
                                         decoded.is_file() and decoded.read_bytes() == payload)
    else:
        result["decode"] = {"status": "not-run-encode-failed"}
        result["exact_fresh_decode"] = False
    result["source_tree_sha256_end"] = tree_fingerprint(source_root)["tree_sha256"]
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["smoke", "books"])
    ap.add_argument("--source-root", type=Path, default=Path("/tmp/paq8px-v217"))
    ap.add_argument("--binary", type=Path, default=Path("/tmp/paq8px-v217-buildsrc/build/paq8px"))
    ap.add_argument("--manifest", type=Path, default=Path("/workspace/scratch/books2026-dev/manifest.json"))
    ap.add_argument("--controls", type=Path, default=Path("/workspace/scratch/books2026-dev/controls/prefix-1048576/controls.json"))
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    root, binary, out = args.source_root.resolve(), args.binary.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = capture_env(binary, root)
    env_path = out / "environment-start.json"
    env_path.write_text(json.dumps(env, indent=2, sort_keys=True) + "\n")
    if args.mode == "smoke":
        result = smoke(binary, root, out)
        final_env = capture_env(binary, root)
        final_env_path = out / "environment-end.json"
        final_env_path.write_text(json.dumps(final_env, indent=2, sort_keys=True) + "\n")
        ok = (result["exact_fresh_decode"] and env["source"]["tree_sha256"] ==
              final_env["source"]["tree_sha256"] == result["source_tree_sha256_end"] and
              env["runtime"] == final_env["runtime"])
        (out / "smoke.json").write_text(json.dumps({"environment_start": env, "result": result,
                                                   "environment_end": final_env,
                                                   "complete": ok}, indent=2, sort_keys=True) + "\n")
        return 0 if ok else 2
    books = selected_books(args.manifest, args.controls)
    rows = []
    path = out / "rows.jsonl"
    # Durable row append after every book, including failures.
    path.write_text("")
    for book in books:
        row = execute_case(binary, root, out, book)
        rows.append(row)
        with path.open("a") as f:
            f.write(json.dumps(row, sort_keys=True) + "\n")
    final_env = capture_env(binary, root)
    (out / "environment-end.json").write_text(json.dumps(final_env, indent=2, sort_keys=True) + "\n")
    complete = (len(rows) == 6 and env["source"]["tree_sha256"] == final_env["source"]["tree_sha256"] and
                env["runtime"] == final_env["runtime"])
    summary = {"environment_start_path": str(env_path), "environment_end_path": str(out / "environment-end.json"),
               "source_manifest": str(args.manifest), "source_manifest_sha256": EXPECTED_MANIFEST_SHA,
               "controls": str(args.controls), "controls_sha256": EXPECTED_CONTROLS_SHA,
               "profile": PROFILE, "complete": complete, "rows_path": str(path),
               "row_count": len(rows), "all_exact_fresh_decodes": all(r["exact_fresh_decode"] for r in rows),
               "all_source_guards_match": all(r["source_guard_end"] == env["source"]["tree_sha256"] for r in rows)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return 0 if complete and summary["all_exact_fresh_decodes"] and summary["all_source_guards_match"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
