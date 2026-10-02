#!/usr/bin/env python3
"""Durable frozen final size and prepared-access capture driver."""
from __future__ import annotations

import argparse
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zlib
from typing import Any

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_MANIFEST = Path("/workspace/scratch/frontier-corpora/manifest.json")
DEFAULT_BACKEND = Path("/workspace/scratch/wgp6/frozen-backend-20261001")
PAGE = 65536
PINNED_HEAD = "6f043e245eea265e4a222524443e3ff01e09c3cb"
WORD_FRONTIER = REPO / "src6/experiments/wordfrontier/wordfrontier.py"
WPG_CODEC = REPO / "src6/experiments/word_constructions/wpg_codec.py"
SBWT_ADAPTER = HERE / "sbwt_adapter.py"
NATIVE_CONTROLS = REPO / "src6/bench/native_controls/native-controls"
NATIVE_READER = REPO / "src6/bench/native_controls/native-controls-reader"
SBWT_SESSION = REPO / "src6/experiments/wordzip/sbwt-session"
WPG_READER = REPO / "src6/experiments/word_constructions/prepared_wpg"
GWT_READER = REPO / "src6/experiments/wordgrammar/geometry/prepared_geometry"
BZ4_READER = Path("/tmp/frontier2026-bz4-reader")
BZ4_CLI = Path("/tmp/frontier2026-bzip4-v3")
BACKEND_MANIFEST = DEFAULT_BACKEND / "manifest.json"
WORD_FRONTIER_MANIFEST = REPO / "src6/experiments/wordfrontier/evidence/frozen-manifest.json"
WORD_FRONTIER_MANIFEST_SHA256 = "4c6007d38290a1752f607d57c389eac3153d2adb3ac3baddfb1fb20dd6362891"
WPG_POST_BUDGET_MANIFEST = REPO / "src6/experiments/word_constructions/evidence/wpg2-post-budget-manifest.sha256"
GWT_NATIVE_MANIFEST = REPO / "src6/experiments/wordgrammar/geometry/evidence/gwt1-native-sources.sha256"
WPG_POST_BUDGET_MANIFEST_SHA256 = "0a257b4de3bc553826a8c7072eca7af8e73f1c300a29cf7e5c30a9d65e57059e"
GWT_NATIVE_MANIFEST_SHA256 = "916aa0e5c46b9cb3f3eb5b777c505cc6c49606f3f9109e56818a0ae142c08af9"
CAPTURE_REGISTRY = HERE / "final_capture_registry.json"

CORE_NAMES = {
    "omw-ja-20-content-final", "omw-cmn-20-content-final",
    "gcide-debian-054-content-final", "freedict-spa-eng-content-final",
    "freedict-eng-fra-content-final",
    "ud-zh-prose-final", "ud-ja-prose-final", "ud-ru-prose-final",
    "ud-es-prose-final", "ud-en-prose-final",
    "ud-zh-forms-final", "ud-ja-forms-final", "ud-ru-forms-final",
    "ud-es-forms-final", "ud-en-forms-final",
    "ud-multilingual-prose-final", "ud-multilingual-tagged-final",
}

WSB_NAMES = (
    "sbwt-word-grammar", "sbwt-word-grammar-auto-mdl",
    "sbwt-word-grammar-surface-choice", "sbwt-word-grammar-unicode-mdl",
)
CONTROL_NAMES = ("bzip2-9", "bzip3-1.5.1", "zstd-19", "xz-9-extreme")


class CaptureError(RuntimeError):
    pass


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def append_jsonl(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("._")


def resolve_token(token: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        token = token.replace("{" + key + "}", value)
    if "{" in token or "}" in token:
        raise CaptureError(f"unresolved command placeholder in {token!r}")
    if token.startswith("${WPG6_BIN_DIR}/"):
        token = str(DEFAULT_BACKEND / token.removeprefix("${WPG6_BIN_DIR}/"))
    path = Path(token)
    if not path.is_absolute() and (REPO / path).exists():
        token = str((REPO / path).resolve())
    return token


def source_list(candidate_rows: list[dict[str, Any]]) -> set[Path]:
    paths: set[Path] = {
        WORD_FRONTIER, WORD_FRONTIER_MANIFEST, BACKEND_MANIFEST,
        WPG_POST_BUDGET_MANIFEST, GWT_NATIVE_MANIFEST,
        REPO / "src6/bench/frontier2026/access_capture.py",
        CAPTURE_REGISTRY,
        REPO / "src6/bench/frontier2026/access_profiles.json",
        REPO / "src6/bench/frontier2026/candidates.json",
        REPO / "src6/bench/native_controls/build.sh",
        REPO / "src6/bench/frontier2026/sbwt_adapter.py",
        REPO / "src6/bench/native_controls/codec.c",
        REPO / "src6/bench/native_controls/reader.c",
        REPO / "src6/experiments/wordzip/sbwt_session.cpp",
        REPO / "src6/experiments/word_constructions/prepared_wpg.cpp",
        REPO / "src6/experiments/word_constructions/prepared_jobs.zig",
        REPO / "src6/experiments/word_constructions/prepared_jobs.h",
        REPO / "src6/experiments/wordgrammar/geometry/prepared_geometry.cpp",
        REPO / "src6/bench/native_controls/bz4_reader.zig",
        REPO / "src6/bench/frontier2026/bzip4_v3_adapter.zig",
        REPO / "src6/experiments/bzip4/bz4/v3/src/root.zig",
    }
    for row in candidate_rows:
        paths.update((Path(p) if Path(p).is_absolute() else REPO / p).resolve()
                     for p in row.get("source_files", []))
    if WORD_FRONTIER_MANIFEST.exists():
        doc = json.loads(WORD_FRONTIER_MANIFEST.read_text())
        paths.update(Path(path).resolve() for path in doc.get("source_sha256", {}))
    for manifest in (WPG_POST_BUDGET_MANIFEST, GWT_NATIVE_MANIFEST):
        if manifest.is_file():
            for line in manifest.read_text().splitlines():
                pieces = line.split(None, 1)
                if len(pieces) == 2:
                    path = Path(pieces[1].strip())
                    paths.add(path.resolve() if path.is_absolute() else (REPO / path).resolve())
    if BACKEND_MANIFEST.exists():
        manifest = json.loads(BACKEND_MANIFEST.read_text())
        for name, value in manifest.items():
            if not isinstance(value, str):
                continue
            paths.add((DEFAULT_BACKEND / name).resolve())
    return paths


def resolved_fingerprint(paths: set[Path], runtime_libraries: list[str]) -> dict[str, Any]:
    fingerprint: dict[str, Any] = {"git_head": git_head(), "python": sys.version,
                                   "platform": platform.platform(), "zig": tool_version("zig")}
    rows = {}
    for path in sorted(paths):
        if not path.is_file():
            raise CaptureError(f"frozen dependency missing: {path}")
        rows[str(path)] = {"bytes": path.stat().st_size, "sha256": file_sha(path)}
    fingerprint["files"] = rows
    runtime = {}
    for name in sorted(set(runtime_libraries)):
        path = Path(name)
        if path.is_file():
            resolved = path.resolve()
        else:
            soname = ctypes.util.find_library(name) or name
            out = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True, check=False).stdout
            resolved = None
            for line in out.splitlines():
                if line.strip().startswith(soname + " ") and "=>" in line:
                    resolved = Path(line.split("=>", 1)[1].strip()).resolve()
                    break
            if resolved is None:
                raise CaptureError(f"cannot resolve runtime dependency {name}")
        runtime[name] = {"path": str(resolved), "bytes": resolved.stat().st_size,
                         "sha256": file_sha(resolved)}
    fingerprint["runtime_libraries"] = runtime
    for binary in (NATIVE_CONTROLS, NATIVE_READER, SBWT_SESSION, WPG_READER,
                   GWT_READER, BZ4_READER, BZ4_CLI, DEFAULT_BACKEND / "m_reference",
                   Path(sys.executable), Path(shutil.which("python3") or sys.executable),
                   WORD_FRONTIER, REPO / "src6/experiments/wordzip/sbwt",
                   REPO / "src6/experiments/wordzip/sbwt-auto",
                   REPO / "src6/experiments/wordzip/sbwt-select",
                   REPO / "src6/experiments/wordzip/sbwt-unicode-auto"):
        if binary.is_file():
            fingerprint.setdefault("executables", {})[str(binary)] = executable_fingerprint(binary)
    return fingerprint


def executable_fingerprint(path: Path) -> dict[str, Any]:
    linked = subprocess.run(["ldd", str(path)], capture_output=True, text=True, check=False)
    deps = []
    for line in linked.stdout.splitlines():
        try:
            target = line.split("=>", 1)[1].strip().split()[0]
            dep = Path(target).resolve()
            if dep.is_file():
                deps.append({"path": str(dep), "bytes": dep.stat().st_size, "sha256": file_sha(dep)})
        except (IndexError, OSError):
            continue
    return {"bytes": path.stat().st_size, "sha256": file_sha(path), "ldd": deps}


def verify_declared_manifests() -> None:
    if file_sha(WORD_FRONTIER_MANIFEST) != WORD_FRONTIER_MANIFEST_SHA256:
        raise CaptureError("wordfrontier frozen manifest hash changed")
    word = json.loads(WORD_FRONTIER_MANIFEST.read_text())
    driver = str(WORD_FRONTIER.resolve())
    if word.get("source_sha256", {}).get(driver) != file_sha(WORD_FRONTIER):
        raise CaptureError("wordfrontier driver does not match its frozen manifest")
    for manifest, expected_sha in ((WPG_POST_BUDGET_MANIFEST, WPG_POST_BUDGET_MANIFEST_SHA256),
                                   (GWT_NATIVE_MANIFEST, GWT_NATIVE_MANIFEST_SHA256)):
        if not manifest.is_file() or file_sha(manifest) != expected_sha:
            raise CaptureError(f"post-budget reader manifest changed: {manifest}")
        for line in manifest.read_text().splitlines():
            pieces = line.split(None, 1)
            if len(pieces) != 2:
                continue
            expected, name = pieces[0], pieces[1].strip()
            path = Path(name)
            if not path.is_absolute():
                path = REPO / path
            if not path.is_file() or file_sha(path) != expected:
                raise CaptureError(f"post-budget reader dependency mismatch: {path}")
    backend = json.loads(BACKEND_MANIFEST.read_text())
    for name, expected in backend.items():
        if isinstance(expected, str):
            path = DEFAULT_BACKEND / name
            if not path.is_file() or file_sha(path) != expected:
                raise CaptureError(f"WPG6 backend manifest dependency mismatch: {path}")


def git_head() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                            capture_output=True, text=True, check=True)
    return result.stdout.strip()


def tool_version(name: str) -> str:
    executable = shutil.which(name)
    if not executable:
        return "missing"
    result = subprocess.run([executable, "version"], capture_output=True, text=True, check=False)
    return (result.stdout or result.stderr).splitlines()[0] if result.returncode == 0 and (result.stdout or result.stderr) else "present"


def load_corpora(path: Path) -> list[dict[str, Any]]:
    rows = json.loads(path.read_text()).get("corpora")
    if not isinstance(rows, list):
        raise CaptureError("corpus manifest schema")
    finals = [row for row in rows if row.get("split") == "final"]
    if len(finals) != 22 or {row["name"] for row in finals} != {
        "omw-ja-20-content-final", "omw-ja-20-words-final", "omw-cmn-20-content-final",
        "omw-cmn-20-words-final", "gcide-debian-054-content-final", "gcide-debian-054-words-final",
        "freedict-spa-eng-content-final", "freedict-spa-eng-words-final",
        "freedict-eng-fra-content-final", "freedict-eng-fra-words-final",
        "ud-zh-prose-final", "ud-zh-forms-final", "ud-ja-prose-final", "ud-ja-forms-final",
        "ud-ru-prose-final", "ud-ru-forms-final", "ud-es-prose-final", "ud-es-forms-final",
        "ud-en-prose-final", "ud-en-forms-final", "ud-multilingual-prose-final",
        "ud-multilingual-tagged-final"}:
        raise CaptureError("expected exact 22-lane final manifest")
    for row in finals:
        path = Path(row["path"])
        if not path.is_file() or path.stat().st_size != row["bytes"] or file_sha(path) != row["sha256"]:
            raise CaptureError(f"final corpus source identity mismatch: {row['name']}")
    return sorted(finals, key=lambda row: row["name"])


def load_smoke_lane(path: Path, name: str) -> list[dict[str, Any]]:
    rows = json.loads(path.read_text()).get("corpora", [])
    matches = [row for row in rows if row.get("name") == name and row.get("split") == "development"]
    if len(matches) != 1:
        raise CaptureError("smoke lane must name exactly one development corpus")
    row = matches[0]
    source = Path(row["path"])
    if not source.is_file() or source.stat().st_size != row["bytes"] or file_sha(source) != row["sha256"]:
        raise CaptureError("development smoke source identity mismatch")
    return matches


def load_codec_rows() -> dict[str, dict[str, Any]]:
    doc = json.loads((HERE / "candidates.json").read_text())
    return {row["name"]: row for row in doc["candidates"]}


def candidates() -> list[dict[str, Any]]:
    codec_rows = load_codec_rows()
    missing = (set(WSB_NAMES) | set(CONTROL_NAMES)) - codec_rows.keys()
    if missing:
        raise CaptureError(f"candidate registry missing {sorted(missing)}")
    result = [
        {"name": "wordfrontier-quality", "kind": "wordfrontier", "profile": "quality",
         "source_files": [str(WORD_FRONTIER), str(WPG_CODEC)]},
        {"name": "wordfrontier-access", "kind": "wordfrontier", "profile": "access",
         "source_files": [str(WORD_FRONTIER), str(WPG_CODEC)]},
        {"name": "laneA-plus-M-quality-raw", "kind": "raw-m", "hoist": 0,
         "source_files": [str(DEFAULT_BACKEND / "m_reference.zig")]},
        {"name": "laneA-plus-M-hoisted-raw", "kind": "raw-m", "hoist": 1,
         "source_files": [str(DEFAULT_BACKEND / "m_reference.zig")]},
    ]
    for name in WSB_NAMES:
        row = codec_rows[name]
        result.append({"name": name, "kind": "wsb2", "registry": row,
                       "source_files": row.get("source_files", [])})
    for name in CONTROL_NAMES:
        row = codec_rows[name]
        result.append({"name": name, "kind": "native-control", "registry": row,
                       "codec": row["encode"][2], "source_files": row.get("source_files", [])})
    return result


def core_lane(row: dict[str, Any]) -> bool:
    return row["name"] in CORE_NAMES


def candidate_key(raw_sha: str, candidate: str, block: str) -> str:
    wire = json.dumps([raw_sha, candidate, block], separators=(",", ":")).encode()
    return hashlib.sha256(wire).hexdigest()


def run_process(command: list[str], env: dict[str, str], log_path: Path,
                *, stage: str, capture_stdout: bool = True) -> tuple[subprocess.CompletedProcess[bytes], int]:
    start = time.perf_counter_ns()
    result = subprocess.run(command, cwd=REPO, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    wall_ns = time.perf_counter_ns() - start
    event = {"stage": stage, "argv": command, "cwd": str(REPO),
             "returncode": result.returncode, "wall_ns": wall_ns,
             "stdout_bytes": len(result.stdout), "stderr_bytes": len(result.stderr),
             "stdout": result.stdout.decode("utf-8", "replace"),
             "stderr": result.stderr.decode("utf-8", "replace"),
             "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    append_jsonl(log_path, event)
    if result.returncode != 0:
        raise CaptureError(f"{stage} failed ({result.returncode}): {command!r}: "
                           f"{event['stderr'][-2000:]}")
    return result, wall_ns


def parse_stdout(result: subprocess.CompletedProcess[bytes], stage: str) -> dict[str, Any]:
    lines = [line for line in result.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
    if len(lines) != 1:
        raise CaptureError(f"{stage} expected one JSON stdout record, got {len(lines)}")
    try:
        value = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise CaptureError(f"{stage} JSON parse: {error}") from error
    if not isinstance(value, dict):
        raise CaptureError(f"{stage} JSON object required")
    return value


def direct_command(candidate: dict[str, Any], raw: Path, frame: Path,
                   graph: Path, extra: dict[str, str] | None = None) -> list[str]:
    kind = candidate["kind"]
    values = {"input": str(raw), "raw": str(raw), "output": str(frame), "frame": str(frame),
              "block_bytes": str(PAGE), "graph": str(graph), **(extra or {})}
    if kind == "wordfrontier":
        return [sys.executable, str(WORD_FRONTIER), "encode", str(raw), str(frame),
                "--profile", candidate["profile"], "--backend-dir", str(DEFAULT_BACKEND)]
    if kind == "raw-m":
        return [str(DEFAULT_BACKEND / "m_reference"), str(raw), str(frame), str(graph),
                str(PAGE), "20", "a-best", "1", str(candidate["hoist"])]
    if kind == "native-control":
        return [str(NATIVE_CONTROLS), "encode", candidate["codec"], str(raw), str(frame),
                "--block", str(PAGE)]
    if kind == "wsb2":
        row = candidate["registry"]
        command = [str(token) for token in row["encode"]]
        return [resolve_token(token, values) for token in command]
    raise CaptureError(f"unknown candidate kind {kind}")


def exact_ledger(kind: str, frame: Path, event: dict[str, Any], raw_size: int) -> dict[str, Any]:
    size = frame.stat().st_size
    if kind == "wordfrontier":
        ledger = event.get("accounting")
        if not isinstance(ledger, dict) or int(ledger.get("sum_bytes", -1)) != size:
            raise CaptureError("wordfrontier complete family ledger mismatch")
        if int(event.get("source_bytes", -1)) != raw_size:
            raise CaptureError("wordfrontier source byte count mismatch")
        return ledger
    if kind == "raw-m":
        fields = ("header_bytes", "directory_bytes", "model_dictionary_bytes", "payload_bytes")
        if int(event.get("frame_bytes", -1)) != size or int(event.get("raw_bytes", -1)) != raw_size:
            raise CaptureError("LaneA+M frame/source count mismatch")
        ledger = {key: int(event[key]) for key in fields}
        ledger["sum_bytes"] = sum(ledger.values())
        if ledger["sum_bytes"] != size:
            raise CaptureError("LaneA+M byte accounting mismatch")
        return ledger
    if kind == "wsb2":
        from sbwt_adapter import inspect
        parsed = inspect(frame.read_bytes())
        if parsed["raw_bytes"] != raw_size or parsed["frame_bytes"] != size:
            raise CaptureError("WSB2 raw/frame count mismatch")
        ledger = {"header_bytes": parsed["header_bytes"],
                  "model_dictionary_bytes": parsed["model_dictionary_bytes"],
                  "directory_bytes": parsed["directory_bytes"],
                  "payload_bytes": parsed["payload_bytes"]}
        ledger["sum_bytes"] = sum(ledger.values())
        if ledger["sum_bytes"] != size:
            raise CaptureError("WSB2 byte accounting mismatch")
        return ledger
    if kind == "native-control":
        data = frame.read_bytes()
        if len(data) < 32 or data[:8] != b"WCTR26\0\0" or data[8] != 1:
            raise CaptureError("WCTR26 magic/header mismatch")
        count = int.from_bytes(data[24:28], "little")
        total_raw = int.from_bytes(data[16:24], "little")
        header, directory = 32, count * 16
        payload = size - header - directory
        ledger = {"header_bytes": header, "directory_bytes": directory,
                  "model_dictionary_bytes": 0, "payload_bytes": payload,
                  "blocks": count, "sum_bytes": header + directory + payload}
        if total_raw != raw_size or ledger["sum_bytes"] != size:
            raise CaptureError("WCTR26 complete accounting/source mismatch")
        return ledger
    raise CaptureError(f"no ledger reader for {kind}")


def decoder_command(candidate: dict[str, Any], frame: Path, output: Path,
                    operation: str = "decode", index: int | None = None) -> list[str]:
    kind = candidate["kind"]
    if kind == "wordfrontier":
        command = [sys.executable, str(WORD_FRONTIER), operation, str(frame), str(output),
                   "--backend-dir", str(DEFAULT_BACKEND)]
        if index is not None:
            command.extend(["--index", str(index)])
        return command
    if kind == "raw-m":
        if operation != "decode":
            raise CaptureError("legacy raw LaneA+M restart extraction is checked by its prepared reader")
        return [str(BZ4_CLI), "decode", str(frame), str(output)]
    if kind == "wsb2":
        registry = candidate["registry"]
        key = "decode" if operation == "decode" else "extract"
        command = [str(token) for token in registry[key]]
        extra = {"input": str(frame), "output": str(output), "block_index": str(index or 0),
                 "block_bytes": str(PAGE)}
        return [resolve_token(token, extra) for token in command]
    if kind == "native-control":
        return [str(NATIVE_CONTROLS), "decode", candidate["codec"], str(frame), str(output)]
    raise CaptureError(f"no decoder for {kind}")


def verify_cell(candidate: dict[str, Any], lane: dict[str, Any], raw: Path,
                frame: Path, cell_dir: Path, env: dict[str, str], log_path: Path,
                encoder_event: dict[str, Any]) -> dict[str, Any]:
    source = raw.read_bytes()
    frame_sha = file_sha(frame)
    full_output = cell_dir / "decoded.full"
    if candidate["kind"] == "native-control" and not candidate.get("whole"):
        command = [str(NATIVE_READER), candidate["codec"], str(frame), str(raw),
                   str(cell_dir / "verification.json"), "--mode", "verify", "--measure", "0"]
        result, _ = run_process(command, env, log_path, stage="verify-all-native-restarts")
        event = parse_stdout(result, "native restart verifier")
        if event.get("all_blocks_oracle_verified") is not True:
            raise CaptureError("native-control reader did not certify all blocks")
        count = int(event["blocks"])
        return {"fresh_full_exact": True, "fresh_restart_oracle_exact": count,
                "verification_protocol": "native-controls-reader mode=verify", "frame_sha256": frame_sha}

    command = decoder_command(candidate, frame, full_output)
    result, _ = run_process(command, env, log_path, stage="fresh-full-decode")
    full_event = parse_stdout(result, "full decoder")
    if not full_output.is_file() or full_output.read_bytes() != source:
        raise CaptureError("fresh full decoder differs from exact corpus source")
    # The decoded oracle is a transient gate artifact. Keep the immutable
    # compressed frame and its verification report, not a second copy of the
    # corpus for every candidate cell.
    full_output.unlink()
    pages = (len(source) + PAGE - 1) // PAGE
    checked = 0
    if candidate["kind"] in ("wordfrontier", "wsb2"):
        for index in range(pages):
            page_out = cell_dir / f"verify-page-{index:06d}.bin"
            command = decoder_command(candidate, frame, page_out, "extract", index)
            result, _ = run_process(command, env, log_path, stage=f"fresh-page-{index}")
            expected = source[index * PAGE:(index + 1) * PAGE]
            if not page_out.is_file() or page_out.read_bytes() != expected:
                raise CaptureError(f"fresh page mismatch at index {index}")
            page_event = parse_stdout(result, f"extract page {index}")
            page_out.unlink()
            checked += 1
        return {"fresh_full_exact": True, "fresh_restart_oracle_exact": checked,
                "fresh_full_decoder": full_event, "frame_sha256": frame_sha}
    if candidate["kind"] == "native-control":
        return {"fresh_full_exact": True,
                "fresh_restart_oracle_exact": int(encoder_event.get("blocks", -1)),
                "verification_protocol": "native-controls full decode with per-block CRC",
                "fresh_full_decoder": full_event, "frame_sha256": frame_sha}
    # The legacy learner's native atom fences are not 64 KiB page boundaries.
    # Its full native decode has already checked every encoded restart and the
    # independent source comparison above gates every reconstructed byte.
    return {"fresh_full_exact": True,
            "fresh_restart_oracle_exact": int(encoder_event.get("blocks", -1)),
            "fresh_full_decoder": full_event,
            "legacy_page_extraction_policy": "logical 64 KiB ranges are handled by retained Jobs in timing; whole output source-verified",
            "frame_sha256": frame_sha}


class Store:
    def __init__(self, out: Path):
        self.out = out
        self.results = out / "results.jsonl"
        self.status = out / "status.json"
        self.completed: dict[str, dict[str, Any]] = {}
        if self.results.is_file():
            for line in self.results.read_text().splitlines():
                if line.strip():
                    row = json.loads(line)
                    if row.get("status") == "complete":
                        self.completed[row["cell_key"]] = row

    def checkpoint(self, phase: str, active: str | None, finished: int,
                   total: int, fingerprint: dict[str, Any], error: str | None = None) -> None:
        atomic_json(self.status, {"schema": 1, "phase": phase, "active_cell": active,
                                  "completed_cells": finished, "total_cells": total,
                                  "updated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                  "fingerprint_sha256": sha_bytes(json.dumps(fingerprint, sort_keys=True).encode()),
                                  "error": error})

    def done(self, key: str, frame: Path | None = None,
             fingerprint_sha256: str | None = None) -> bool:
        old = self.completed.get(key)
        return bool(old and old.get("status") == "complete" and frame and frame.is_file()
                    and old.get("frame_sha256") == file_sha(frame)
                    and old.get("frozen_fingerprint_sha256") == fingerprint_sha256)

    def commit(self, row: dict[str, Any]) -> None:
        append_jsonl(self.results, row)
        self.completed[row["cell_key"]] = row


def run_size(args) -> None:
    verify_declared_manifests()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    corpora = (load_smoke_lane(args.manifest.resolve(), args.smoke_development)
               if args.smoke_development else load_corpora(args.manifest.resolve()))
    cand = candidates()
    registry = json.loads(CAPTURE_REGISTRY.read_text())
    actual_names = [candidate["name"] for candidate in cand]
    if actual_names != registry["size_candidates"]:
        raise CaptureError("size candidate list differs from frozen capture registry")
    if not args.smoke_development and [row["name"] for row in corpora if core_lane(row)] != sorted(registry["timing_lanes"]):
        raise CaptureError("core timing lane registry does not match final manifest")
    if args.whole_controls:
        whole_rows = [row for row in cand if row["kind"] == "native-control"]
        if [row["name"] for row in whole_rows] != registry["whole_control_candidates"]:
            raise CaptureError("whole controls differ from frozen registry")
        cand += [{**row, "whole": True, "name": row["name"] + "-whole"} for row in whole_rows]
    total = len(corpora) * len(cand)
    store = Store(out)
    verification_cache_path = out / "verified-frames.json"
    verification_cache = json.loads(verification_cache_path.read_text()) if verification_cache_path.is_file() else {}
    paths = source_list([r.get("registry", r) for r in cand])
    paths.add(args.manifest.resolve())
    libs = ["libbz2.so.1.0", "libzstd.so.1", "liblzma.so.5",
            "/workspace/scratch/libbzip3.so"]
    fingerprint = resolved_fingerprint(paths, libs)
    fingerprint_sha256 = sha_bytes(json.dumps(fingerprint, sort_keys=True).encode())
    if fingerprint["git_head"] != PINNED_HEAD:
        raise CaptureError(f"canonical source commit mismatch: {fingerprint['git_head']}")
    atomic_json(out / "environment-start.json", fingerprint)
    env = os.environ.copy()
    env["WPG6_BIN_DIR"] = str(DEFAULT_BACKEND)
    finished = 0
    for lane in corpora:
        raw = Path(lane["path"])
        raw_sha = lane["sha256"]
        raw_bytes = raw.stat().st_size
        for candidate in cand:
            mode = "whole" if candidate.get("whole") else "64k"
            block = raw_bytes if candidate.get("whole") else PAGE
            key = candidate_key(raw_sha, candidate["name"], mode)
            base = out / "cells" / safe_name(lane["name"]) / safe_name(candidate["name"])
            frame = base / "frame.bin"
            cell_dir = base
            logs = base / "calls.jsonl"
            if store.done(key, frame, fingerprint_sha256):
                finished += 1
                store.checkpoint("size", None, finished, total, fingerprint)
                continue
            base.mkdir(parents=True, exist_ok=True)
            store.checkpoint("size", key, finished, total, fingerprint)
            if file_sha(raw) != raw_sha or raw.stat().st_size != raw_bytes:
                raise CaptureError(f"source changed before cell {key}")
            graph = base / "parse.graph"
            command = direct_command(candidate, raw, frame, graph)
            if candidate.get("whole"):
                if candidate["kind"] != "native-control":
                    raise CaptureError("whole capture only supports the four native controls")
                command[-1] = str(block)
            try:
                proc, wall_ns = run_process(command, env, logs, stage="encode-size")
                event = parse_stdout(proc, "encoder")
                if file_sha(raw) != raw_sha:
                    raise CaptureError("source changed during candidate encode")
                ledger = exact_ledger(candidate["kind"], frame, event, raw_bytes)
                if ledger["sum_bytes"] != frame.stat().st_size:
                    raise CaptureError("ledger total differs from encoded frame bytes")
                frame_sha = file_sha(frame)
                prior_verification = verification_cache.get(frame_sha)
                if (prior_verification and prior_verification.get("source_sha256") == raw_sha
                        and prior_verification.get("frozen_fingerprint_sha256") == fingerprint_sha256):
                    validation = {"reused_verified_frame_sha256": frame_sha,
                                  "source_sha256": raw_sha,
                                  "prior_verification": prior_verification["verification"]}
                else:
                    validation = verify_cell(candidate, lane, raw, frame, cell_dir, env, logs, event)
                    verification_cache[frame_sha] = {"source_sha256": raw_sha,
                                                     "candidate": candidate["name"],
                                                     "verification": validation,
                                                     "frozen_fingerprint_sha256": fingerprint_sha256}
                    atomic_json(verification_cache_path, verification_cache)
                if file_sha(frame) != frame_sha:
                    raise CaptureError("encoded frame changed during fresh verification")
                current = resolved_fingerprint(paths, libs)
                if current != fingerprint:
                    raise CaptureError("source, binary, or dynamic dependency changed during size capture")
                row = {"schema": 1, "status": "complete", "phase": "size",
                       "cell_key": key, "candidate": candidate["name"], "kind": candidate["kind"],
                       "corpus": lane, "block_mode": mode, "block_bytes": block,
                       "frame_path": str(frame), "frame_bytes": frame.stat().st_size,
                       "frame_sha256": file_sha(frame),
                       "capture_scope": ("development-smoke" if args.smoke_development else "final-storage"),
                       "frozen_fingerprint_sha256": fingerprint_sha256,
                       "encode_wall_ns": wall_ns, "native_encoder_event": event,
                       "accounting": ledger, "verification": validation,
                       "verified_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                store.commit(row)
                finished += 1
                store.checkpoint("size", None, finished, total, fingerprint)
            except Exception as error:
                store.commit({"schema": 1, "status": "failed", "phase": "size",
                              "cell_key": key, "candidate": candidate["name"],
                              "corpus": lane["name"], "error": str(error)})
                store.checkpoint("size", key, finished, total, fingerprint, str(error))
                raise
    final = resolved_fingerprint(paths, libs)
    if final != fingerprint:
        raise CaptureError("end-of-phase frozen dependency guard failed")
    atomic_json(out / "environment-end.json", final)
    store.checkpoint("size", None, finished, total, fingerprint)


def recursive_values(obj: Any, key: str) -> list[Any]:
    found = []
    if isinstance(obj, dict):
        if key in obj:
            found.append(obj[key])
        for value in obj.values():
            found.extend(recursive_values(value, key))
    elif isinstance(obj, list):
        for value in obj:
            found.extend(recursive_values(value, key))
    return found


def expected_query_checksum(raw: bytes) -> int:
    pages = (len(raw) + PAGE - 1) // PAGE
    if not pages:
        raise CaptureError("timed query lane must not be empty")
    indices = (0, pages // 2, pages - 1)
    checksum = 1469598103934665603
    for access in range(256):
        index = indices[access % 3]
        data = raw[index * PAGE:min((index + 1) * PAGE, len(raw))]
        checksum = ((checksum ^ (zlib.crc32(data) & 0xFFFFFFFF)) * 1099511628211) & ((1 << 64) - 1)
    return checksum


def timing_command(candidate: dict[str, Any], frame: Path, raw: Path,
                   report: Path, output: Path, operation: str,
                   measure: int) -> list[str]:
    kind = candidate["kind"]
    if operation == "query":
        if kind == "wordfrontier":
            return [sys.executable, str(WORD_FRONTIER), "bench", str(frame), str(report),
                    "--backend-dir", str(DEFAULT_BACKEND), "--measure", str(measure),
                    "--quiet-gate", "WORDZIP-READER-QUIET"]
        if kind == "wsb2":
            return [str(SBWT_SESSION), "bench-reader", str(frame), str(report),
                    "--measure", str(measure), "--quiet-gate", "WORDZIP-READER-QUIET"]
        if kind == "raw-m":
            return [str(BZ4_READER), "bench-reader", str(frame), str(report), "--block", str(PAGE),
                    "--measure", str(measure), "--quiet-gate", "WORDZIP-READER-QUIET"]
        if kind == "native-control":
            return [str(NATIVE_READER), candidate["codec"], str(frame), str(raw), str(report),
                    "--mode", "query", "--measure", str(measure),
                    "--quiet-gate", "FRONTIER2026-ACCESS-QUIET"]
    if operation == "full":
        if kind == "wordfrontier":
            return [sys.executable, str(WORD_FRONTIER), "decode", str(frame), str(output),
                    "--backend-dir", str(DEFAULT_BACKEND), "--measure", str(measure),
                    "--quiet-gate", "WORDZIP-READER-QUIET"]
        if kind == "wsb2":
            command = [str(token) for token in candidate["registry"]["decode"]]
            values = {"input": str(frame), "output": str(output), "block_bytes": str(PAGE)}
            return [resolve_token(token, values) for token in command]
        if kind == "raw-m":
            return [str(BZ4_CLI), "decode", str(frame), str(output)]
        if kind == "native-control":
            return [str(NATIVE_CONTROLS), "decode", candidate["codec"], str(frame), str(output)]
    raise CaptureError(f"unsupported timing operation {operation} for {kind}")


def numeric_metric(event: dict[str, Any], names: tuple[str, ...]) -> int | None:
    for name in names:
        values = recursive_values(event, name)
        for value in values:
            try:
                if value is not None:
                    return int(value)
            except (ValueError, TypeError):
                continue
    return None


def nested_true(event: dict[str, Any], names: tuple[str, ...]) -> bool:
    return any(value is True for name in names for value in recursive_values(event, name))


def validate_query_event(candidate: dict[str, Any], event: dict[str, Any], expected: int) -> dict[str, Any]:
    count = numeric_metric(event, ("access_count", "query_count"))
    if count != 256:
        raise CaptureError(f"prepared reader returned {count} queries, expected 256")
    checksums = recursive_values(event, "query_checksum") + recursive_values(event, "checksum")
    parsed = []
    for value in checksums:
        try:
            parsed.append(int(value))
        except (TypeError, ValueError):
            pass
    if expected not in parsed:
        raise CaptureError(f"query checksum mismatch for {candidate['name']}: {parsed}")
    return {"query_count": count, "query_checksum": expected,
            "prepare_ns": numeric_metric(event, ("prepare_ns", "preparation_ns")),
            "query_native_ns": numeric_metric(event, ("query_256_ns", "decode_256_ns")),
            "frame_bytes": numeric_metric(event, ("frame_bytes",))}


def perform_timing(candidate: dict[str, Any], lane: dict[str, Any], frame: Path,
                   raw: Path, out: Path, op: str, measure: int, env: dict[str, str],
                   log: Path) -> dict[str, Any]:
    report = out.with_suffix(out.suffix + ".json")
    command = timing_command(candidate, frame, raw, report, out, op, measure)
    result, wall_ns = run_process(command, env, log, stage=f"timing-{op}-measure-{measure}")
    event = parse_stdout(result, f"timed {op}")
    raw_bytes = raw.read_bytes()
    normalized: dict[str, Any] = {"event": event, "process_wall_ns": wall_ns,
                                  "argv": command, "operation": op, "measure": measure}
    if op == "full":
        if not out.is_file() or out.read_bytes() != raw_bytes:
            raise CaptureError(f"full-decode timing sample failed byte oracle: {candidate['name']}")
        normalized["full_output_sha256"] = file_sha(out)
        normalized["native_full_decode_ns"] = numeric_metric(event, ("codec_ns", "decode_ns", "full_decode_ns"))
        normalized["output_bytes"] = out.stat().st_size
    else:
        expected = expected_query_checksum(raw_bytes)
        normalized.update(validate_query_event(candidate, event, expected))
    return normalized


def load_completed_size_rows(out: Path) -> dict[tuple[str, str], dict[str, Any]]:
    result_path = out / "results.jsonl"
    rows = {}
    if not result_path.is_file():
        return rows
    for line in result_path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("phase") == "size" and row.get("status") == "complete":
            rows[(row["corpus"]["name"], row["candidate"])] = row
    return rows


def run_timing(args) -> None:
    verify_declared_manifests()
    if args.quiet_token != "FRONTIER2026-ACCESS-QUIET" or os.environ.get("FRONTIER2026_ACCESS_QUIET") != args.quiet_token:
        raise CaptureError("timed capture requires root quiet release and matching FRONTIER2026_ACCESS_QUIET token")
    out = args.out.resolve()
    rows = load_completed_size_rows(out)
    registry = json.loads(CAPTURE_REGISTRY.read_text())
    lane_map = {name: row for name, row in rows.items()}
    corpora = {row["name"]: row for row in load_corpora(args.manifest.resolve())}
    cand_by_name = {row["name"]: row for row in candidates()}
    timing_lanes = registry["timing_lanes"]
    if len(timing_lanes) != 17:
        raise CaptureError("capture registry core timing lane count changed")
    names = registry["size_candidates"]
    total = len(timing_lanes) * len(names) * 2 * (1 + registry["paired_fresh_process_samples"])
    paths = source_list([row.get("registry", row) for row in cand_by_name.values()])
    paths.add(args.manifest.resolve())
    libs = ["libbz2.so.1.0", "libzstd.so.1", "liblzma.so.5", "/workspace/scratch/libbzip3.so"]
    fingerprint = resolved_fingerprint(paths, libs)
    fingerprint_sha256 = sha_bytes(json.dumps(fingerprint, sort_keys=True).encode())
    if fingerprint["git_head"] != PINNED_HEAD:
        raise CaptureError("canonical core source commit mismatch at timing start")
    for lane_name in timing_lanes:
        if lane_name not in corpora:
            raise CaptureError(f"core corpus lane missing: {lane_name}")
        for candidate_name in names:
            row = lane_map.get((lane_name, candidate_name))
            if row is None:
                raise CaptureError(f"missing complete size frame {lane_name}/{candidate_name}")
            frame = Path(row["frame_path"])
            if not frame.is_file() or frame.stat().st_size != row["frame_bytes"] or file_sha(frame) != row["frame_sha256"]:
                raise CaptureError(f"frame artifact changed: {lane_name}/{candidate_name}")
            if row.get("frozen_fingerprint_sha256") != fingerprint_sha256:
                raise CaptureError(f"size/timing frozen dependency fingerprints differ: {lane_name}/{candidate_name}")
    atomic_json(out / "timing-environment-start.json", fingerprint)
    env = os.environ.copy()
    env["WPG6_BIN_DIR"] = str(DEFAULT_BACKEND)
    timing_path = out / "timing-results.jsonl"
    completed: set[tuple[str, str, str, int]] = set()
    if timing_path.is_file():
        for line in timing_path.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                if row.get("status") == "complete":
                    if row.get("frozen_fingerprint_sha256") != fingerprint_sha256:
                        raise CaptureError("existing timing checkpoint belongs to another frozen runtime")
                    size_row = lane_map.get((row.get("corpus"), row.get("candidate")))
                    if not size_row or row.get("frame_sha256") != size_row.get("frame_sha256"):
                        raise CaptureError("existing timing checkpoint frame identity mismatch")
                    completed.add((row["corpus"], row["candidate"], row["operation"], row["sample_index"]))
    status_path = out / "timing-status.json"
    finished = len(completed)
    operations = ("full", "query")
    for lane_name in timing_lanes:
        lane = corpora[lane_name]
        raw = Path(lane["path"])
        for operation in operations:
            candidate_order = list(names)
            warmup_index = -1
            schedule = [(warmup_index, candidate_name) for candidate_name in candidate_order]
            for sample in range(registry["paired_fresh_process_samples"]):
                order = candidate_order if sample % 2 == 0 else list(reversed(candidate_order))
                schedule.extend((sample, candidate_name) for candidate_name in order)
            for sample_index, candidate_name in schedule:
                key = (lane_name, candidate_name, operation, sample_index)
                if key in completed:
                    continue
                size_row = lane_map[(lane_name, candidate_name)]
                candidate = cand_by_name[candidate_name]
                frame = Path(size_row["frame_path"])
                cell_dir = Path(size_row["frame_path"]).parent
                suffix = "warmup" if sample_index == warmup_index else f"paired-{sample_index + 1:02d}"
                output = cell_dir / f"timing-{operation}-{suffix}.bin"
                report = output.with_suffix(".json")
                log = cell_dir / "timing-calls.jsonl"
                atomic_json(status_path, {"phase": "timing", "active": list(key),
                                          "completed_operations": finished, "total_operations": total,
                                          "updated_unix_ns": time.time_ns()})
                try:
                    measurement = perform_timing(candidate, lane, frame, raw, output,
                                                 operation, int(sample_index >= 0), env, log)
                    if output.exists():
                        output.unlink()
                    if report.exists():
                        report.unlink()
                    current = resolved_fingerprint(paths, libs)
                    if current != fingerprint:
                        raise CaptureError("frozen source/binary/dependency guard changed during timing")
                    if file_sha(raw) != lane["sha256"] or file_sha(frame) != size_row["frame_sha256"]:
                        raise CaptureError("raw source or encoded frame changed during timing")
                    event = {"schema": 1, "status": "complete", "phase": "timing",
                             "corpus": lane_name, "candidate": candidate_name,
                             "operation": operation, "sample_index": sample_index,
                             "sample_kind": "warmup" if sample_index < 0 else "paired",
                             "order": "forward" if sample_index < 0 or sample_index % 2 == 0 else "reverse",
                             "source_sha256": lane["sha256"], "frame_sha256": size_row["frame_sha256"],
                             "frozen_fingerprint_sha256": fingerprint_sha256,
                             "measurement": measurement,
                             "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                    append_jsonl(timing_path, event)
                    completed.add(key)
                    finished += 1
                    atomic_json(status_path, {"phase": "timing", "active": None,
                                              "completed_operations": finished, "total_operations": total,
                                              "updated_unix_ns": time.time_ns()})
                except Exception as error:
                    append_jsonl(timing_path, {"schema": 1, "status": "failed", "phase": "timing",
                                               "corpus": lane_name, "candidate": candidate_name,
                                               "operation": operation, "sample_index": sample_index,
                                               "error": str(error)})
                    atomic_json(status_path, {"phase": "timing", "active": list(key),
                                              "completed_operations": finished, "total_operations": total,
                                              "error": str(error), "updated_unix_ns": time.time_ns()})
                    raise
    final = resolved_fingerprint(paths, libs)
    if final != fingerprint:
        raise CaptureError("end-of-timing source/binary/dependency guard failed")
    atomic_json(out / "timing-environment-end.json", final)
    atomic_json(status_path, {"phase": "timing", "active": None,
                              "completed_operations": finished, "total_operations": total,
                              "complete": finished == total, "updated_unix_ns": time.time_ns()})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    size = sub.add_parser("size", help="encode, size, and source-verify final artifacts")
    size.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    size.add_argument("--out", type=Path, required=True)
    size.add_argument("--whole-controls", action="store_true")
    size.add_argument("--smoke-development", help="run one hashed development lane through all candidates")
    timing = sub.add_parser("timing", help="serial gated five-pair full-decode/query capture")
    timing.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    timing.add_argument("--out", type=Path, required=True)
    timing.add_argument("--quiet-token", default="")
    args = parser.parse_args()
    if args.command == "size":
        run_size(args)
    elif args.command == "timing":
        run_timing(args)


if __name__ == "__main__":
    try:
        main()
    except (CaptureError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"access_capture: {error}", file=sys.stderr)
        sys.exit(1)
