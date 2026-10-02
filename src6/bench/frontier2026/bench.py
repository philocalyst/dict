#!/usr/bin/env python3
"""Reproducible block-matched screen and serial timing harness for codec CLIs."""
from __future__ import annotations

import argparse
import ctypes.util
import hashlib
import json
import os
import platform
import re
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Any

MAGIC = b"LUNAB26\0"
VERSION = 1
HEADER = struct.Struct("<8sIIQ I 32s")  # magic, version, block bytes, raw bytes, count, raw SHA-256
RECORD = struct.Struct("<II")           # raw chunk bytes, compressed member bytes
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


class BenchError(RuntimeError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def bz4_max_atom_bytes(raw: bytes) -> int:
    """Bound BZ4 v3's word-aligned block overshoot by its learner's atoms."""
    longest = 0
    at = 0
    while at < len(raw):
        byte = raw[at]
        if byte >= 0x80 or 65 <= byte <= 90 or 97 <= byte <= 122:
            kind = 1  # letter; high bytes are letters in learn.zig
        elif 48 <= byte <= 57:
            kind = 2  # digit
        else:
            kind = 0  # punctuation and whitespace are single-byte atoms
        end = at + 1
        if kind:
            while end < len(raw):
                next_byte = raw[end]
                next_kind = (1 if next_byte >= 0x80 or 65 <= next_byte <= 90 or 97 <= next_byte <= 122
                             else 2 if 48 <= next_byte <= 57 else 0)
                if next_kind != kind:
                    break
                end += 1
        longest = max(longest, end - at)
        at = end
    return longest


def file_sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def load_candidates(path: Path) -> dict[str, dict[str, Any]]:
    doc = json.loads(path.read_text())
    for row in doc["candidates"]:
        for key in ("encode", "decode"):
            row[key] = [str((REPO / token).resolve()) if not Path(token).is_absolute()
                        and not token.startswith("{") and (REPO / token).exists() else token
                        for token in row[key]]
        row["source_files"] = [str((REPO / source).resolve()) if not Path(source).is_absolute()
                               else source for source in row.get("source_files", [])]
    return {row["name"]: row for row in doc["candidates"]}


def executable_identity(command: list[str]) -> dict[str, Any]:
    exe = shutil.which(command[0])
    if not exe:
        raise BenchError(f"missing executable: {command[0]}")
    p = Path(exe).resolve()
    referenced = []
    for item in command[1:]:
        candidate = Path(item).expanduser()
        if candidate.is_file():
            candidate = candidate.resolve()
            referenced.append({"path": str(candidate), "bytes": candidate.stat().st_size,
                               "sha256": file_sha(candidate)})
    dependencies = []
    try:
        linked = subprocess.run(["ldd", str(p)], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, check=False)
        for line in linked.stdout.splitlines():
            target = line.split("=>", 1)[1].strip().split()[0] if "=>" in line else line.strip().split()[0]
            dep = Path(target)
            if dep.is_file():
                dep = dep.resolve()
                dependencies.append({"path": str(dep), "bytes": dep.stat().st_size,
                                     "sha256": file_sha(dep)})
    except (OSError, IndexError):
        pass
    return {"command": command, "executable": str(p), "bytes": p.stat().st_size,
            "sha256": file_sha(p), "referenced_files": referenced,
            "dynamic_dependencies": dependencies}


def runtime_library_identity(name: str) -> dict[str, Any]:
    direct = Path(name)
    path: Path | None = direct.resolve() if direct.is_file() else None
    if path is None:
        soname = ctypes.util.find_library(name) or name
        try:
            p = subprocess.run(["ldconfig", "-p"], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, check=False)
            for line in p.stdout.splitlines():
                if line.strip().startswith(soname + " ") and "=>" in line:
                    path = Path(line.split("=>", 1)[1].strip()).resolve()
                    break
        except OSError:
            pass
    if path is None or not path.is_file():
        raise BenchError(f"cannot resolve runtime codec library {name}")
    return {"requested": name, "path": str(path), "bytes": path.stat().st_size,
            "sha256": file_sha(path)}


def run_bytes(command: list[str], data: bytes, block_bytes: int, extra: dict[str, Any] | None = None,
              events: list[dict[str, Any]] | None = None) -> bytes:
    use_files = any("{input}" in part or "{output}" in part for part in command)
    substitutions = {"block_bytes": str(block_bytes), **{k: str(v) for k, v in (extra or {}).items()}}
    if not use_files:
        command = [part.format_map(substitutions) for part in command]
        try:
            p = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except OSError as e:
            raise BenchError(f"cannot run {command[0]}: {e}") from e
        if events is not None:
            events.append({"command": command, "returncode": p.returncode,
                           "stdout_bytes": len(p.stdout), "stdout": p.stdout.decode("utf-8", "replace"),
                           "stderr_bytes": len(p.stderr), "stderr": p.stderr.decode("utf-8", "replace")})
        if p.returncode:
            raise BenchError(f"command failed ({p.returncode}): {command!r}\n{p.stderr[-2000:].decode(errors='replace')}")
        return p.stdout
    with tempfile.TemporaryDirectory(prefix="luna-codec-") as temp_name:
        temp = Path(temp_name)
        input_path, output_path = temp / "input.bin", temp / "output.bin"
        input_path.write_bytes(data)
        substitutions.update({"input": str(input_path), "output": str(output_path)})
        command = [part.format_map(substitutions) for part in command]
        try:
            p = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, check=False)
        except OSError as e:
            raise BenchError(f"cannot run {command[0]}: {e}") from e
        if events is not None:
            events.append({"command": command, "returncode": p.returncode,
                           "stdout_bytes": len(p.stdout), "stdout": p.stdout.decode("utf-8", "replace"),
                           "stderr_bytes": len(p.stderr), "stderr": p.stderr.decode("utf-8", "replace")})
        if p.returncode:
            raise BenchError(f"command failed ({p.returncode}): {command!r}\n{p.stderr[-2000:].decode(errors='replace')}")
        if not output_path.is_file():
            raise BenchError(f"file-mode command did not create output: {command!r}")
        return output_path.read_bytes()


def event_operation(event: dict[str, Any]) -> str | None:
    command = event.get("command", [])
    if not isinstance(command, list):
        return None
    for token in command:
        if token in {"encode", "decode", "decode-block", "extract"}:
            return token
    return None


def command_metrics(events: list[dict[str, Any]] | None,
                    operation: str | None = None) -> dict[str, Any]:
    if not events:
        return {}
    for event in events:
        if operation is not None and event_operation(event) != operation:
            continue
        try:
            record = json.loads(event["stdout"])
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(record, dict):
            return record
    return {}


def encode_frame(raw: bytes, block_bytes: int, codec: dict[str, Any], *, measure: bool = False,
                 events: list[dict[str, Any]] | None = None) -> tuple[bytes, dict[str, Any]]:
    if block_bytes <= 0:
        raise BenchError("block size must be positive")
    started = time.perf_counter_ns() if measure else None
    if codec.get("mode", "members") == "whole-frame":
        if not codec.get("extract"):
            raise BenchError(f"whole-frame candidate {codec['name']} must provide a fresh-process block extractor")
        frame = run_bytes(codec["encode"], raw, block_bytes, events=events)
        elapsed = time.perf_counter_ns() - started if started is not None else None
        metrics = command_metrics(events)
        header_bytes = int(metrics.get("header_bytes", codec.get("header_bytes", 0)))
        directory_bytes = int(metrics.get("restart_directory_bytes", -1))
        if directory_bytes < 0 and "directory_bytes" in metrics:
            directory_bytes = int(metrics["directory_bytes"])
        if directory_bytes < 0:
            directory_bytes = int(codec.get("restart_record_bytes", 0)) * max(1, (len(raw) + block_bytes - 1) // block_bytes)
        if header_bytes + directory_bytes > len(frame):
            raise BenchError("declared whole-frame metadata exceeds the complete frame")
        model_bytes = int(metrics.get("model_dictionary_bytes", metrics.get(
            "dictionary_bytes", metrics.get("model_bytes", codec.get("model_dictionary_bytes", 0)))))
        if model_bytes < 0 or model_bytes > len(frame):
            raise BenchError("declared model/dictionary bytes exceed the complete frame")
        payload_bytes = int(metrics.get("payload_bytes", len(frame) - header_bytes - directory_bytes))
        reported_frame_bytes = metrics.get("frame_bytes", metrics.get("output_bytes"))
        if reported_frame_bytes is not None and int(reported_frame_bytes) != len(frame):
            raise BenchError("candidate-reported complete frame size disagrees with output bytes")
        if payload_bytes + header_bytes + directory_bytes + model_bytes != len(frame):
            raise BenchError("candidate metadata and payload accounting do not sum to complete frame")
        raw_lengths = [int(value) for value in metrics.get("block_raw_lengths", [])]
        if not raw_lengths:
            raw_lengths = [min(block_bytes, len(raw) - offset) for offset in range(0, len(raw), block_bytes)]
        max_slack = (bz4_max_atom_bytes(raw) if codec.get("restart_slack_policy") == "bz4-max-atom"
                     else int(codec.get("max_restart_overhead_bytes", 0)))
        if sum(raw_lengths) != len(raw) or any(n <= 0 or n > block_bytes + max_slack for n in raw_lengths):
            raise BenchError(f"candidate {codec['name']} restart raw lengths do not cover input within "
                             f"declared boundary (input={len(raw)}, block={block_bytes}, "
                             f"sum={sum(raw_lengths)}, min={min(raw_lengths, default=0)}, "
                             f"max={max(raw_lengths, default=0)}, maximum_atom_slack={max_slack})")
        if int(metrics.get("blocks", len(raw_lengths))) != len(raw_lengths):
            raise BenchError("candidate reported block count disagrees with restart raw lengths")
        return frame, {
            "encode_ns": elapsed,
            "model_dictionary_bytes": model_bytes,
            "member_payload_bytes": payload_bytes,
            "frame_header_bytes": header_bytes,
            "restart_directory_bytes": directory_bytes,
            "frame_bytes": len(frame),
            "blocks": len(raw_lengths),
            "block_raw_lengths": raw_lengths,
            "intrinsic_encode_ns": intrinsic_ns(events or [], "encode"),
            "encode_maxrss_kib": metrics.get("maxrss_kib", metrics.get("peakrss_kib")),
        }
    encoded: list[bytes] = []
    raw_lengths: list[int] = []
    for off in range(0, len(raw), block_bytes):
        chunk = raw[off:off + block_bytes]
        member = run_bytes(codec["encode"], chunk, block_bytes, events=events)
        encoded.append(member)
        raw_lengths.append(len(chunk))
    elapsed = time.perf_counter_ns() - started if started is not None else None
    if not raw and codec.get("allow_empty", True):
        encoded = [run_bytes(codec["encode"], b"", block_bytes, events=events)]
        raw_lengths = [0]
    count = len(encoded)
    header = HEADER.pack(MAGIC, VERSION, block_bytes, len(raw), count, hashlib.sha256(raw).digest())
    directory = b"".join(RECORD.pack(n, len(member)) for n, member in zip(raw_lengths, encoded))
    frame = header + directory + b"".join(encoded)
    meta = {
        "encode_ns": elapsed,
        "model_dictionary_bytes": int(codec.get("model_dictionary_bytes", 0)),
        "member_payload_bytes": sum(map(len, encoded)),
        "frame_header_bytes": len(header),
        "restart_directory_bytes": len(directory),
        "frame_bytes": len(frame),
        "block_raw_lengths": raw_lengths,
        "blocks": count,
    }
    return frame, meta


def decode_frame(frame: bytes, raw_expected: bytes, codec: dict[str, Any], block_bytes: int, *,
                 raw_lengths: list[int] | None = None, measure: bool = False,
                 events: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    start = time.perf_counter_ns() if measure else None
    if codec.get("mode", "members") == "whole-frame":
        decoded = run_bytes(codec["decode"], frame, block_bytes, events=events)
        elapsed = time.perf_counter_ns() - start if start is not None else None
        actual_sha = hashlib.sha256(decoded).digest()
        if len(decoded) != len(raw_expected) or actual_sha != hashlib.sha256(raw_expected).digest() or decoded != raw_expected:
            raise BenchError("fresh-process complete-frame verification failed")
        extraction = verify_extraction(frame, raw_expected, codec, block_bytes,
                                       raw_lengths=raw_lengths, measure=measure, events=events)
        return {"decode_ns": elapsed, "decoded_bytes": len(decoded),
                "decoded_sha256": actual_sha.hex(), "verified": True,
                **extraction,
                "intrinsic_decode_ns": intrinsic_ns(events or [], "decode"),
                "decode_maxrss_kib": command_metrics(events, "decode").get("maxrss_kib",
                                              command_metrics(events, "decode").get("peakrss_kib"))}
    if len(frame) < HEADER.size:
        raise BenchError("truncated frame header")
    magic, version, block_bytes, raw_len, count, expected_sha = HEADER.unpack_from(frame)
    if magic != MAGIC or version != VERSION:
        raise BenchError("unsupported benchmark frame")
    directory_end = HEADER.size + count * RECORD.size
    if directory_end > len(frame):
        raise BenchError("truncated restart directory")
    payload = bytearray()
    lens: list[int] = []
    raw_lens: list[int] = []
    rawn = 0
    for i in range(count):
        raw_n, member_n = RECORD.unpack_from(frame, HEADER.size + i * RECORD.size)
        rawn += raw_n
        lens.append(member_n)
        raw_lens.append(raw_n)
    if rawn != raw_len or directory_end + sum(lens) != len(frame):
        raise BenchError("frame lengths do not agree")
    pos = directory_end
    for n in lens:
        payload.extend(frame[pos:pos + n])
        pos += n
    decoded = run_bytes(codec["decode"], bytes(payload), block_bytes, events=events)
    elapsed = time.perf_counter_ns() - start if start is not None else None
    actual_sha = hashlib.sha256(decoded).digest()
    if len(decoded) != raw_len or actual_sha != expected_sha or decoded != raw_expected:
        raise BenchError("fresh-process complete-frame verification failed")
    verify_start = time.perf_counter_ns() if measure else None
    at = directory_end
    raw_at = 0
    cold_samples: list[dict[str, Any]] = []
    sample_indices = {0, count // 2, count - 1} if count else set()
    for i, (member_n, raw_n) in enumerate(zip(lens, raw_lens)):
        member = frame[at:at + member_n]
        raw_block = raw_expected[raw_at:raw_at + raw_n]
        started_call = time.perf_counter_ns() if measure and i in sample_indices else None
        event_start = len(events) if events is not None else 0
        block = run_bytes(codec["decode"], member, block_bytes, events=events)
        if started_call is not None:
            last_event = events[-1] if events and len(events) > event_start else {}
            cold_samples.append({"block_index": i, "raw_bytes": raw_n,
                                 "wall_ns": time.perf_counter_ns() - started_call,
                                 "codec_ns": event_codec_ns(last_event)})
        if block != raw_block:
            raise BenchError(f"independent member {i} failed extraction verification")
        at += member_n
        raw_at += raw_n
    extraction_ns = time.perf_counter_ns() - verify_start if verify_start is not None else None
    return {"decode_ns": elapsed, "decoded_bytes": len(decoded), "decoded_sha256": actual_sha.hex(),
            "verified": True, "extraction_verify_ns": extraction_ns,
            "extraction_verified_blocks": count,
            "extraction_verified_block_indices": list(range(count)),
            "extraction_verified_raw_bytes": sum(raw_lens),
            "extraction_policy": "all independent members",
            "extraction_cold_samples": cold_samples}


def verify_extraction(frame: bytes, raw: bytes, codec: dict[str, Any], block_bytes: int, *,
                      raw_lengths: list[int] | None = None, measure: bool = False,
                      events: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    extractor = codec.get("extract")
    if not extractor:
        return {"extraction_verify_ns": None, "extraction_verified_blocks": 0,
                "extraction_verified_block_indices": [], "extraction_verified_raw_bytes": 0,
                "extraction_policy": "not available"}
    lengths = raw_lengths or [min(block_bytes, len(raw) - offset) for offset in range(0, len(raw), block_bytes)]
    count = len(lengths)
    policy = codec.get("extraction_policy", "all-restarts")
    if policy == "legacy_sampled_replay16":
        sample_count = min(count, int(codec.get("extraction_samples", 16)))
        if sample_count <= 1:
            indices = [0] if count else []
        else:
            indices = sorted({(i * (count - 1)) // (sample_count - 1) for i in range(sample_count)})
    else:
        indices = list(range(count))
    started = time.perf_counter_ns() if measure else None
    cold_samples: list[dict[str, Any]] = []
    sample_indices = {0, count // 2, count - 1} if count else set()
    offsets = [0]
    for length in lengths:
        offsets.append(offsets[-1] + length)
    for index in indices:
        expected = raw[offsets[index]:offsets[index + 1]]
        started_call = time.perf_counter_ns() if measure and index in sample_indices else None
        event_start = len(events) if events is not None else 0
        actual = run_bytes(extractor, frame, block_bytes, {"block_index": index}, events=events)
        if started_call is not None:
            last_event = events[-1] if events and len(events) > event_start else {}
            cold_samples.append({"block_index": index, "raw_bytes": lengths[index],
                                 "wall_ns": time.perf_counter_ns() - started_call,
                                 "codec_ns": event_codec_ns(last_event)})
        if actual != expected:
            raise BenchError(f"whole-frame block {index} extraction verification failed")
    return {"extraction_verify_ns": time.perf_counter_ns() - started if started is not None else None,
            "extraction_verified_blocks": len(indices), "extraction_verified_block_indices": indices,
            "extraction_verified_raw_bytes": sum(lengths[index] for index in indices),
            "extraction_policy": policy, "extraction_cold_samples": cold_samples}


def candidate_fingerprint(codec: dict[str, Any]) -> dict[str, Any]:
    sources = []
    for source in codec.get("source_files", []):
        path = Path(source).resolve()
        sources.append({"path": str(path), "bytes": path.stat().st_size, "sha256": file_sha(path)})
    return {"name": codec["name"], "encode": executable_identity(codec["encode"]),
            "decode": executable_identity(codec["decode"]),
            "extract": executable_identity(codec["extract"]) if codec.get("extract") else None,
            "source_files": sources,
            "runtime_libraries": [runtime_library_identity(name) for name in codec.get("runtime_libraries", [])],
            "model_dictionary_bytes": int(codec.get("model_dictionary_bytes", 0)),
            "mode": codec.get("mode", "members"),
            "header_bytes": int(codec.get("header_bytes", 0)),
            "restart_directory_bytes": int(codec.get("restart_directory_bytes", 0)),
            "restart_record_bytes": int(codec.get("restart_record_bytes", 0)),
            "max_restart_overhead_bytes": int(codec.get("max_restart_overhead_bytes", 0)),
            "restart_slack_policy": codec.get("restart_slack_policy"),
            "extraction_policy": codec.get("extraction_policy", "all-restarts"),
            "extraction_samples": int(codec.get("extraction_samples", 0)),
            "restart_policy": codec.get("restart_policy", "independent members at harness block boundary")}


def intrinsic_ns(events: list[dict[str, Any]], direction: str) -> int | None:
    for event in events:
        if event_operation(event) != direction:
            continue
        try:
            record = json.loads(event["stdout"])
        except (json.JSONDecodeError, TypeError):
            continue
        for key in (f"{direction}_codec_ns", "codec_ns"):
            if key in record:
                return int(record[key])
        if "codec_us" in record:
            return int(float(record["codec_us"]) * 1000)
    return None


def event_codec_ns(event: dict[str, Any]) -> int | None:
    try:
        record = json.loads(event["stdout"])
    except (KeyError, json.JSONDecodeError, TypeError):
        return None
    for key in ("codec_ns", "encode_codec_ns", "decode_codec_ns"):
        if key in record:
            return int(record[key])
    if "codec_us" in record:
        return int(float(record["codec_us"]) * 1000)
    return None


def host_identity() -> dict[str, Any]:
    cpu_model = None
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.is_file():
        for line in cpuinfo.read_text(errors="replace").splitlines():
            if line.lower().startswith(("model name", "hardware")) and ":" in line:
                cpu_model = line.split(":", 1)[1].strip()
                break
    mem_total_kib = None
    meminfo = Path("/proc/meminfo")
    if meminfo.is_file():
        for line in meminfo.read_text(errors="replace").splitlines():
            if line.startswith("MemTotal:"):
                try:
                    mem_total_kib = int(line.split()[1])
                except (IndexError, ValueError):
                    pass
                break
    return {"captured_at_utc": datetime.now(timezone.utc).isoformat(),
            "platform": platform.platform(), "uname": list(platform.uname()),
            "machine": platform.machine(), "processor": platform.processor(),
            "cpu_model": cpu_model, "logical_cpu_count": os.cpu_count(),
            "memory_total_kib": mem_total_kib}


def persist_events(out: Path, candidate: str, corpus: str, block: int, rep: str,
                   events: list[dict[str, Any]]) -> list[str]:
    def slug(value: str) -> str:
        return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)[:100]
    base = out / "raw_logs" / slug(candidate) / slug(corpus) / str(block) / slug(rep)
    base.mkdir(parents=True, exist_ok=True)
    path = base / "calls.jsonl"
    with path.open("w") as stream:
        for event in events:
            stream.write(json.dumps(event, separators=(",", ":")) + "\n")
    return [str(path)]


def result_row(name: str, corpus_name: str, raw: bytes, source_meta: dict[str, Any],
               block_mode: str, block_bytes: int, trials: list[dict[str, Any]], *,
               cache_hit: bool = False) -> dict[str, Any]:
    def median(field: str) -> int | None:
        vals = [t[field] for t in trials if t.get(field) is not None]
        return sorted(vals)[len(vals) // 2] if vals else None

    def extraction_sample_median(label: str, field: str) -> int | None:
        block_count = int(trials[0].get("blocks", 0))
        index = {"first": 0, "middle": block_count // 2,
                 "last": max(0, block_count - 1)}[label]
        vals = [sample[field] for trial in trials
                for sample in trial.get("extraction_cold_samples", [])
                if sample.get("block_index") == index and sample.get(field) is not None]
        return sorted(vals)[len(vals) // 2] if vals else None

    first = trials[0]
    raw_lengths = first["block_raw_lengths"]
    return {"candidate": name, "corpus": corpus_name, "input": source_meta,
            "block_bytes": block_bytes, "block_mode": block_mode, "trials": trials,
            "frame_bytes": first["frame_bytes"], "blocks": first["blocks"],
            "block_raw_min_bytes": min(raw_lengths, default=0),
            "block_raw_max_bytes": max(raw_lengths, default=0),
            "block_raw_lengths": raw_lengths,
            "model_dictionary_bytes": first["model_dictionary_bytes"],
            "payload_bytes": first["member_payload_bytes"],
            "metadata_bytes": first["frame_header_bytes"] + first["restart_directory_bytes"] + first["model_dictionary_bytes"],
            "encode_ns_median": median("encode_ns"), "decode_ns_median": median("decode_ns"),
            "intrinsic_encode_ns_median": median("intrinsic_encode_ns"),
            "intrinsic_decode_ns_median": median("intrinsic_decode_ns"),
            "encode_maxrss_kib_median": median("encode_maxrss_kib"),
            "decode_maxrss_kib_median": median("decode_maxrss_kib"),
            "extract_first_wall_ns_median": extraction_sample_median("first", "wall_ns"),
            "extract_middle_wall_ns_median": extraction_sample_median("middle", "wall_ns"),
            "extract_last_wall_ns_median": extraction_sample_median("last", "wall_ns"),
            "extract_first_codec_ns_median": extraction_sample_median("first", "codec_ns"),
            "extract_middle_codec_ns_median": extraction_sample_median("middle", "codec_ns"),
            "extract_last_codec_ns_median": extraction_sample_median("last", "codec_ns"),
            "extraction_policy": first.get("extraction_policy"),
            "extraction_verified_blocks": first.get("extraction_verified_blocks", 0),
            "extraction_verified_raw_bytes": first.get("extraction_verified_raw_bytes", 0),
            "raw_bytes": len(raw), "ratio": first["frame_bytes"] / max(1, len(raw)),
            "cache_hit": cache_hit}


def inputs(args: argparse.Namespace) -> list[tuple[str, bytes, dict[str, Any]]]:
    out = []
    if args.manifest:
        manifest_path = args.manifest.resolve()
        manifest = json.loads(manifest_path.read_text())
        known_names = {row["name"] for row in manifest["corpora"]}
        missing_names = set(args.corpus) - known_names
        if missing_names:
            raise BenchError(f"unknown corpus name(s) in manifest: {', '.join(sorted(missing_names))}")
        for row in manifest["corpora"]:
            if args.corpus and row["name"] not in args.corpus:
                continue
            if row.get("split") not in (args.split or ["development"]):
                continue
            path = Path(row["path"])
            if not path.is_absolute():
                path = (manifest_path.parent / path).resolve()
            source = path.read_bytes()
            actual_source_sha = sha(source)
            if row.get("sha256") and row["sha256"] != actual_source_sha:
                raise BenchError(f"manifest SHA-256 mismatch for {row['name']}")
            raw = source if args.max_input_bytes is None else source[:args.max_input_bytes]
            out.append((row["name"], raw, {**row, "path": str(path), "source_bytes": len(source),
                         "source_sha256": actual_source_sha, "bytes": len(raw), "sha256": sha(raw),
                         "screen_prefix_bytes": len(raw) if len(raw) < len(source) else None}))
    for spec in args.input:
        if "=" not in spec:
            raise BenchError("--input format is NAME=PATH")
        name, raw_path = spec.split("=", 1)
        path = Path(raw_path).resolve()
        raw = path.read_bytes()
        out.append((name, raw, {"path": str(path), "bytes": len(raw), "sha256": sha(raw)}))
    if not out:
        raise BenchError("provide at least one --input NAME=PATH")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", choices=("screen", "measure"), default="screen")
    ap.add_argument("--input", action="append", default=[], metavar="NAME=PATH")
    ap.add_argument("--manifest", type=Path, help="corpus manifest with corpus name, path and source metadata")
    ap.add_argument("--corpus", action="append", default=[], help="select manifest corpus by exact name; repeatable")
    ap.add_argument("--split", action="append", default=[], help="manifest split; defaults to development")
    ap.add_argument("--max-input-bytes", type=int, help="cap each loaded corpus to this prefix size")
    ap.add_argument("--candidate", action="append", default=[], help="candidate name; default all configured")
    ap.add_argument("--candidates", type=Path, default=HERE / "candidates.json")
    ap.add_argument("--block-bytes", action="append", default=None,
                    help="raw restart target in bytes, or 'whole' for one whole-input frame")
    ap.add_argument("--repetitions", type=int, default=3)
    ap.add_argument("--warmups", type=int, default=1)
    ap.add_argument("--out", type=Path, default=Path("/tmp/frontier2026-run"))
    ap.add_argument("--use-cache", action="store_true", help="reuse matching verified screen rows")
    args = ap.parse_args()
    status_path: Path | None = None
    try:
        codecs = load_candidates(args.candidates)
        selected = args.candidate or list(codecs)
        datasets = inputs(args)
        block_modes = args.block_bytes or ["16384", "65536"]
        if args.repetitions < 1 or args.warmups < 0 or any(x != "whole" and int(x) <= 0 for x in block_modes) or (args.max_input_bytes is not None and args.max_input_bytes <= 0):
            raise BenchError("repetitions and block sizes must be positive; warmups cannot be negative")
        if any(x != "whole" and int(x) > 64 * 1024 * 1024 for x in block_modes):
            raise BenchError("block sizes above 64 MiB are not supported")
        args.out.mkdir(parents=True, exist_ok=True)
        status_path = args.out / "status.json"
        cache_path = args.out / "size-cache.json"
        cache = json.loads(cache_path.read_text()) if args.use_cache and cache_path.exists() else {}
        rows: list[dict[str, Any]] = []
        fingerprints = {name: candidate_fingerprint(codecs[name]) for name in selected}
        manifest_identity = None
        if args.manifest:
            manifest_identity = {"path": str(args.manifest.resolve()),
                                 "bytes": args.manifest.stat().st_size,
                                 "sha256": file_sha(args.manifest.resolve())}
        candidate_config_identity = {"path": str(args.candidates.resolve()),
                                     "bytes": args.candidates.stat().st_size,
                                     "sha256": file_sha(args.candidates.resolve())}
        expected_cells = len(datasets) * len(block_modes) * len(selected)
        atomic_json(status_path, {"state": "in-progress", "completed_cells": 0,
                                  "expected_cells": expected_cells,
                                  "candidate_config_sha256": candidate_config_identity["sha256"]})
        atomic_json(args.out / "environment.json", {"python": sys.version,
          "python_executable": executable_identity([sys.executable]), "host": host_identity(),
          "corpus_manifest": manifest_identity,
          "candidate_config": candidate_config_identity,
          "corpora": [{"name": name, "path": metadata.get("path"), "bytes": len(raw),
                       "sha256": metadata.get("sha256"), "split": metadata.get("split"),
                       "source_manifest": metadata.get("source_manifest")}
                      for name, raw, metadata in datasets],
          "candidates": fingerprints, "mode": args.mode, "block_bytes": block_modes,
          "repetitions": args.repetitions, "warmups": args.warmups,
          "order_policy": "paired by corpus and block; candidate start rotates each repetition"})
        for corpus_name, raw, source_meta in datasets:
            for block_mode in block_modes:
                block_bytes = max(1, len(raw)) if block_mode == "whole" else int(block_mode)
                cohort_trials: dict[str, list[dict[str, Any]]] = {name: [] for name in selected}
                cached_names: set[str] = set()
                if args.mode == "screen":
                    for name in selected:
                        key_obj = {"corpus_sha256": source_meta["sha256"], "candidate": fingerprints[name],
                                   "block_bytes": block_bytes}
                        key = sha(json.dumps(key_obj, sort_keys=True).encode())
                        cached = cache.get(key) if args.use_cache else None
                        if cached:
                            rows.append({**cached, "cache_hit": True})
                            cached_names.add(name)
                            atomic_json(args.out / "results.partial.json", rows)
                            atomic_json(status_path, {"state": "in-progress", "completed_cells": len(rows),
                                      "expected_cells": expected_cells, "last_cell": [corpus_name, block_mode, name],
                                      "candidate_config_sha256": candidate_config_identity["sha256"]})
                completed_screen_names: set[str] = set()
                phases = [("warmup", i) for i in range(args.warmups)] if args.mode == "measure" else []
                phases += [("measure" if args.mode == "measure" else "screen", i)
                           for i in range(args.repetitions if args.mode == "measure" else 1)]
                for phase, index in phases:
                    if phase == "screen":
                        order = [name for name in selected if name not in cached_names]
                    else:
                        offset = index % len(selected)
                        order = selected[offset:] + selected[:offset]
                    for name in order:
                        codec = codecs[name]
                        events: list[dict[str, Any]] = []
                        frame, encoded = encode_frame(raw, block_bytes, codec,
                                                      measure=phase == "measure", events=events)
                        checked = decode_frame(frame, raw, codec, block_bytes,
                                               raw_lengths=encoded["block_raw_lengths"],
                                               measure=phase == "measure", events=events)
                        trial = {**encoded, **checked, "frame_sha256": sha(frame)}
                        if phase == "measure":
                            trial["intrinsic_encode_ns"] = intrinsic_ns(events, "encode")
                            trial["intrinsic_decode_ns"] = intrinsic_ns(events, "decode")
                            trial["log_paths"] = persist_events(args.out, name, corpus_name, block_bytes,
                                                                 f"trial-{index + 1}", events)
                            trial["trial"] = index + 1
                            cohort_trials[name].append(trial)
                        elif phase == "screen":
                            trial["trial"] = 1
                            trial["log_paths"] = persist_events(args.out, name, corpus_name,
                                                                 block_bytes, "screen-1", events)
                            cohort_trials[name].append(trial)
                            row = result_row(name, corpus_name, raw, source_meta, block_mode,
                                             block_bytes, cohort_trials[name])
                            rows.append(row)
                            completed_screen_names.add(name)
                            key_obj = {"corpus_sha256": source_meta["sha256"],
                                       "candidate": fingerprints[name], "block_bytes": block_bytes}
                            cache[sha(json.dumps(key_obj, sort_keys=True).encode())] = row
                            if file_sha(args.candidates.resolve()) != candidate_config_identity["sha256"]:
                                raise BenchError("candidate configuration changed during run")
                            atomic_json(args.out / "results.partial.json", rows)
                            atomic_json(cache_path, cache)
                            atomic_json(status_path, {"state": "in-progress", "completed_cells": len(rows),
                                      "expected_cells": expected_cells, "last_cell": [corpus_name, block_mode, name],
                                      "candidate_config_sha256": candidate_config_identity["sha256"]})
                for name in selected:
                    if name in cached_names or (args.mode == "screen" and name in completed_screen_names):
                        continue
                    trials = cohort_trials[name]
                    if not trials:
                        continue
                    row = result_row(name, corpus_name, raw, source_meta, block_mode,
                                     block_bytes, trials)
                    rows.append(row)
                    if args.mode == "screen":
                        key_obj = {"corpus_sha256": source_meta["sha256"], "candidate": fingerprints[name],
                                   "block_bytes": block_bytes}
                        cache[sha(json.dumps(key_obj, sort_keys=True).encode())] = row
                (args.out / "results.partial.json").write_text(json.dumps(rows, indent=2) + "\n")
        for name in selected:
            if candidate_fingerprint(codecs[name]) != fingerprints[name]:
                raise BenchError(f"candidate fingerprint changed by end of run: {name}")
        if file_sha(args.candidates.resolve()) != candidate_config_identity["sha256"]:
            raise BenchError("candidate configuration changed during run")
        atomic_json(args.out / "results.json", rows)
        (args.out / "results.partial.json").unlink(missing_ok=True)
        atomic_json(cache_path, cache)
        atomic_json(status_path, {"state": "complete", "completed_cells": len(rows),
                                  "expected_cells": expected_cells,
                                  "candidate_config_sha256": candidate_config_identity["sha256"]})
        print(json.dumps(rows, separators=(",", ":")))
        return 0
    except (BenchError, OSError, ValueError, KeyError) as e:
        if status_path is not None:
            status = {}
            if status_path.is_file():
                try:
                    status = json.loads(status_path.read_text())
                except json.JSONDecodeError:
                    pass
            status.update({"state": "failed", "error": str(e)})
            atomic_json(status_path, status)
        print(f"frontier2026: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
