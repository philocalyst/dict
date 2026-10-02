#!/usr/bin/env python3
"""Exact, complete-frame compression evaluation on registered whole sources.

One command evaluates every case in a split against a pinned baseline. The
ledger records failed and cached trials as well as successes. Timing here is
diagnostic command wall time; quiet paired performance capture is separate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


STAGES = ("screen", "development", "validation", "final")
BACKENDS = ("self_contained", "control", "transform", "external_model")
PLACEHOLDERS = ("input", "frame", "output", "work")
HARNESS = Path(__file__).resolve()


class Invalid(ValueError):
    pass


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".report-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def append_ledger(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def require_file(spec, label, *, length=False, allow_symlink=False):
    if not isinstance(spec, dict):
        raise Invalid(f"{label} must be an object")
    path = Path(spec.get("path", ""))
    if not path.is_absolute() or not path.is_file() or (path.is_symlink() and not allow_symlink):
        raise Invalid(f"{label} must name an existing absolute regular file")
    expected = spec.get("sha256")
    if not isinstance(expected, str) or len(expected) != 64 or digest(path) != expected:
        raise Invalid(f"{label} SHA-256 mismatch: {path}")
    if length and (not isinstance(spec.get("bytes"), int) or spec["bytes"] < 0
                   or path.stat().st_size != spec["bytes"]):
        raise Invalid(f"{label} byte length mismatch: {path}")
    return path


def check_deps(spec):
    result = {}
    deps = spec["dependencies"]
    if not isinstance(deps, dict) or not deps:
        raise Invalid("dependencies must be a nonempty absolute-path SHA-256 map")
    for name, expected in deps.items():
        path = require_file({"path": name, "sha256": expected}, "dependency", allow_symlink=True)
        result[str(path)] = {"sha256": expected, "bytes": path.stat().st_size,
                             "resolved": str(path.resolve())}
    for name in ("encode_argv", "decode_argv"):
        executable = spec[name][0]
        if executable not in result:
            raise Invalid(f"{name}[0] must be a declared executable dependency")
        for argument in spec[name][1:]:
            value = argument.split("=", 1)[1] if argument.startswith("-") and "=" in argument else argument
            if value.startswith("/") and "{" not in value:
                if value in result:
                    continue
                directory = Path(value)
                if not directory.is_dir() or directory.is_symlink():
                    raise Invalid(f"unhashed absolute argv file/directory: {value}")
                files = []
                for path in directory.rglob("*"):
                    if len(files) >= 4096:
                        raise Invalid(f"directory dependency has too many entries: {value}")
                    files.append(path)
                files.sort()
                listed = {}
                total = 0
                for path in files:
                    if path.is_symlink():
                        raise Invalid(f"directory dependency contains a non-regular file: {path}")
                    if path.is_dir():
                        continue
                    if not path.is_file():
                        raise Invalid(f"directory dependency contains a non-regular file: {path}")
                    total += path.stat().st_size
                    if total > (1 << 30):
                        raise Invalid(f"directory dependency exceeds 1 GiB: {value}")
                    listed[str(path.relative_to(directory))] = {"sha256": digest(path),
                                                                "bytes": path.stat().st_size}
                result["directory:" + value] = listed
    env = spec.get("environment", {})
    if not isinstance(env, dict) or set(env) - {"LEX_BZIP3_LIBRARY"}:
        raise Invalid("only explicit LEX_BZIP3_LIBRARY environment is supported")
    library = env.get("LEX_BZIP3_LIBRARY")
    if library is not None and library not in result:
        raise Invalid("LEX_BZIP3_LIBRARY must be a hashed dependency")
    side = spec.get("side_information", [])
    if not isinstance(side, list):
        raise Invalid("side_information must be a list")
    for item in side:
        path = require_file(item, "side_information")
        if str(path) not in result:
            raise Invalid("side_information must also be a hashed dependency")
    return result


def validate_spec(spec, label):
    if not isinstance(spec, dict):
        raise Invalid(f"{label} must be an object")
    for name in ("id", "parent", "mechanism", "hypothesis", "decisive_test"):
        if not isinstance(spec.get(name), str) or not spec[name].strip():
            raise Invalid(f"{label}.{name} must be nonempty text")
    if spec.get("backend_class") not in BACKENDS:
        raise Invalid(f"{label}.backend_class must be one of {BACKENDS}")
    for name in ("encode_argv", "decode_argv"):
        argv = spec.get(name)
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise Invalid(f"{label}.{name} must be a nonempty argv string vector")
        for part in argv:
            for token in part.split("{")[1:]:
                key = token.split("}", 1)[0]
                if key not in PLACEHOLDERS or "}" not in token:
                    raise Invalid(f"{label}.{name}: unknown or malformed placeholder")
            if name == "decode_argv" and "{input}" in part:
                raise Invalid("decoder must not receive {input}")
        if not Path(argv[0]).is_absolute():
            raise Invalid(f"{label}.{name}[0] must be absolute")
        if "{" in argv[0] or "}" in argv[0]:
            raise Invalid(f"{label}.{name}[0] must be fixed")
    limits = spec.get("limits")
    if not isinstance(limits, dict):
        raise Invalid(f"{label}.limits required")
    timeout = limits.get("timeout_seconds")
    if (not isinstance(timeout, (int, float)) or isinstance(timeout, bool)
            or not math.isfinite(timeout) or not 0 < timeout <= 86400):
        raise Invalid(f"{label}.limits.timeout_seconds must be finite and positive")
    for key in ("max_raw_bytes", "max_frame_bytes"):
        value = limits.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or not 0 < value <= (1 << 40):
            raise Invalid(f"{label}.limits.{key} must be a positive bounded integer")
    if spec["backend_class"] == "control" and spec.get("side_information"):
        raise Invalid("control backend cannot have side information")
    checked_dependencies = check_deps(spec)
    accounting = spec.get("model_accounting")
    if not isinstance(accounting, dict) or accounting.get("kind") not in (
            "universal_code", "frame_learned_only", "external_learned"):
        raise Invalid(f"{label}.model_accounting.kind declaration required")
    embedded = accounting.get("embedded_learned_bytes")
    if not isinstance(embedded, int) or isinstance(embedded, bool) or not 0 <= embedded <= (1 << 40):
        raise Invalid(f"{label}.model_accounting.embedded_learned_bytes invalid")
    data_files = accounting.get("data_dependencies")
    if not isinstance(data_files, list) or any(not isinstance(x, str) for x in data_files):
        raise Invalid(f"{label}.model_accounting.data_dependencies must be a list")
    side_paths = {item.get("path") for item in spec.get("side_information", [])}
    if any(path not in side_paths or path not in spec["dependencies"] for path in data_files):
        raise Invalid("learned data dependencies must be hashed and charged side_information")
    return checked_dependencies


def validate_registry(registry):
    cases = registry.get("cases") if isinstance(registry, dict) else None
    if not isinstance(cases, list) or not cases:
        raise Invalid("registry requires nonempty cases list")
    seen = set()
    split_identities = {}
    for case in cases:
        if not isinstance(case, dict):
            raise Invalid("case must be an object")
        for name in ("id", "kind", "language", "work_id"):
            if not isinstance(case.get(name), str) or not case[name].strip():
                raise Invalid(f"case.{name} must be nonempty text")
        if case["id"] in seen:
            raise Invalid(f"duplicate case id: {case['id']}")
        seen.add(case["id"])
        if case.get("split") not in ("development", "validation", "final"):
            raise Invalid(f"invalid split: {case['id']}")
        source = case.get("source")
        if not isinstance(source, dict) or not Path(source.get("path", "")).is_absolute():
            raise Invalid(f"case {case['id']} requires absolute source path")
        if not isinstance(source.get("bytes"), int) or source["bytes"] < 0:
            raise Invalid(f"case {case['id']} has invalid length")
        if not isinstance(source.get("sha256"), str) or len(source["sha256"]) != 64:
            raise Invalid(f"case {case['id']} has invalid SHA-256")
        if "prefix" in case:
            prefix = case["prefix"]
            if not isinstance(prefix, dict) or not Path(prefix.get("path", "")).is_absolute():
                raise Invalid(f"case {case['id']} has invalid prefix")
            if (not isinstance(prefix.get("bytes"), int) or isinstance(prefix["bytes"], bool)
                    or prefix["bytes"] < 0 or prefix["bytes"] > source["bytes"]
                    or not isinstance(prefix.get("sha256"), str) or len(prefix["sha256"]) != 64):
                raise Invalid(f"case {case['id']} has invalid prefix length/hash")
        identities = [("work_id", case["work_id"]), ("source_sha256", source["sha256"])]
        for name in ("author", "lineage_id", "translation_lineage"):
            if name in case:
                if not isinstance(case[name], str) or not case[name].strip():
                    raise Invalid(f"case.{name} must be nonempty text when supplied")
                identities.append((name, case[name]))
        for identity in identities:
            old_split = split_identities.setdefault(identity, case["split"])
            if old_split != case["split"]:
                raise Invalid(f"source/work/lineage crosses splits: {identity[0]}={identity[1]}")
    return cases


def source_for(case, stage):
    if stage == "screen":
        if "prefix" not in case:
            raise Invalid(f"screen prefix missing for {case['id']}")
        full = require_file(case["source"], "registered full source", length=True)
        prefix = require_file(case["prefix"], "registered prefix", length=True)
        with full.open("rb") as original, prefix.open("rb") as first:
            if original.read(case["prefix"]["bytes"]) != first.read():
                raise Invalid(f"screen prefix differs from registered source: {case['id']}")
        return case["prefix"]
    return case["source"]


def select_cases(cases, stage):
    split = "development" if stage == "screen" else stage
    selected = [case for case in cases if case["split"] == split]
    if not selected:
        raise Invalid(f"no registered cases for {stage}")
    return selected


def expand(argv, locations):
    try:
        result = [part.format_map(locations) for part in argv]
    except (KeyError, ValueError) as error:
        raise Invalid(f"bad argv placeholder: {error}") from error
    if locations["input"] in result[0]:
        raise Invalid("executable path must not depend on the source")
    return result


def run_process(argv, cwd, timeout, file_limit, log_prefix, env):
    def bound_file():
        resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))

    start = time.monotonic_ns()
    with (log_prefix.with_suffix(".stdout")).open("wb") as stdout, \
         (log_prefix.with_suffix(".stderr")).open("wb") as stderr:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
                                   start_new_session=True, preexec_fn=bound_file)
        try:
            code = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            code = process.wait()
            timed_out = True
        # A successful launcher must not leave unmeasured workers alive to
        # mutate the frame or continue encoder search after its clock stops.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return {"argv": argv, "exit_code": code, "timed_out": timed_out,
            "wall_ns_diagnostic": time.monotonic_ns() - start,
            "stdout": str(log_prefix.with_suffix(".stdout")),
            "stderr": str(log_prefix.with_suffix(".stderr"))}


def child_environment(spec, directory):
    # No inherited PYTHONPATH, LD_LIBRARY_PATH, locale, user config, or hidden
    # LEX_BZIP3_LIBRARY. Commands are absolute and every required file is pinned.
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC",
           "PYTHONHASHSEED": "0", "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
           "MKL_NUM_THREADS": "1", "BLIS_NUM_THREADS": "1", "NUMEXPR_NUM_THREADS": "1",
           "TMPDIR": str(directory)}
    env.update(spec.get("environment", {}))
    return env


def costed_side_bytes(spec):
    return (sum(Path(item["path"]).stat().st_size for item in spec.get("side_information", []))
            + spec["model_accounting"]["embedded_learned_bytes"])


def safe_artifact(path, directory, limit):
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(directory.resolve()):
        raise Invalid(f"missing or escaping artifact: {path}")
    size = path.stat().st_size
    if size > limit:
        raise Invalid(f"artifact exceeds declared limit: {path} ({size}>{limit})")
    return size, digest(path)


def fingerprint(spec, case, source, dependencies, harness_hash):
    return sha(canonical({"spec": spec, "case": case, "source": source,
                          "dependencies": dependencies, "harness_sha256": harness_hash}))


def trial(spec, case, source, stage, role, work, ledger, harness_hash):
    trial_id = uuid.uuid4().hex
    started = {"event": "trial", "trial_id": trial_id, "role": role,
               "candidate": spec["id"], "case": case["id"], "stage": stage,
               "utc_ns": time.time_ns()}
    directory = work / "trials" / trial_id
    directory.mkdir(parents=True)
    encode_dir = directory / "encode_job"
    decode_dir = directory / "decode_job"
    encode_dir.mkdir()
    try:
        raw_path = require_file(source, "source", length=True)
        if source["bytes"] > spec["limits"]["max_raw_bytes"]:
            raise Invalid("source exceeds declared raw limit")
        dependencies = check_deps(spec)
        key = fingerprint(spec, case, source, dependencies, harness_hash)
        cached = work / "cache" / key
        if cached.is_symlink():
            raise Invalid("cache directory is a symlink")
        if cached.is_dir():
            meta = load_json(cached / "meta.json")
            cache_frame = cached / "frame.bin"
            cache_output = cached / "decoded.bin"
            frame_size, frame_hash = safe_artifact(cache_frame, cached, spec["limits"]["max_frame_bytes"])
            raw_size, raw_hash = safe_artifact(cache_output, cached, spec["limits"]["max_raw_bytes"])
            actual_side = costed_side_bytes(spec)
            if (meta.get("key") != key or meta.get("frame_sha256") != frame_hash
                    or meta.get("frame_bytes") != frame_size
                    or meta.get("side_information_bytes") != actual_side
                    or raw_size != source["bytes"] or raw_hash != source["sha256"]):
                raise Invalid("cached artifact verification failed")
            decode_dir.mkdir()
            copied_frame = decode_dir / "frame.bin"
            fresh_output = decode_dir / "output.bin"
            shutil.copyfile(cache_frame, copied_frame)
            if safe_artifact(copied_frame, decode_dir, spec["limits"]["max_frame_bytes"]) != (frame_size, frame_hash):
                raise Invalid("cached frame changed during copy")
            locations = {"input": str(encode_dir / "unavailable-input.bin"),
                         "frame": str(copied_frame), "output": str(fresh_output),
                         "work": str(decode_dir)}
            decode_argv = expand(spec["decode_argv"], locations)
            if any(str(raw_path) in part or locations["input"] in part for part in decode_argv):
                raise Invalid("decoder argv exposes original source path")
            limit = int(max(spec["limits"]["max_raw_bytes"], spec["limits"]["max_frame_bytes"], 1024 * 1024))
            decode = run_process(decode_argv, decode_dir,
                                 spec["limits"]["timeout_seconds"], limit,
                                 decode_dir / "decode", child_environment(spec, decode_dir))
            if decode["timed_out"] or decode["exit_code"] != 0:
                raise TrialFailed("cached frame decode failed", decode=decode)
            fresh_size, fresh_hash = safe_artifact(fresh_output, decode_dir, spec["limits"]["max_raw_bytes"])
            if fresh_size != source["bytes"] or fresh_hash != source["sha256"]:
                raise TrialFailed("cached frame is lossy", decode=decode)
            if safe_artifact(copied_frame, decode_dir, spec["limits"]["max_frame_bytes"]) != (frame_size, frame_hash):
                raise TrialFailed("cached frame mutated during decode", decode=decode)
            require_file(source, "source", length=True)
            if check_deps(spec) != dependencies:
                raise Invalid("dependency directory changed during cached decode")
            row = {**started, "status": "cached_verified", "cache_key": key,
                   "frame_bytes": frame_size, "frame_sha256": frame_hash,
                   "decoded_bytes": raw_size, "decoded_sha256": raw_hash,
                   "side_information_bytes": actual_side,
                   "complete_bytes": frame_size + actual_side,
                   "artifact_dir": str(directory), "cached_frame_dir": str(cached),
                   "fresh_encode": False, "fresh_decode": True, "decode": decode}
            append_ledger(ledger, row)
            return row
        input_copy = encode_dir / "input.bin"
        frame = encode_dir / "frame.bin"
        shutil.copyfile(raw_path, input_copy)
        if safe_artifact(input_copy, encode_dir, spec["limits"]["max_raw_bytes"]) != (source["bytes"], source["sha256"]):
            raise Invalid("anonymous encoder input copy differs from source")
        places = {"input": str(input_copy), "frame": str(frame),
                  "output": str(encode_dir / "unused-output.bin"), "work": str(encode_dir)}
        limit = int(max(spec["limits"]["max_raw_bytes"], spec["limits"]["max_frame_bytes"], 1024 * 1024))
        encode = run_process(expand(spec["encode_argv"], places), encode_dir,
                             spec["limits"]["timeout_seconds"], limit,
                             encode_dir / "encode", child_environment(spec, encode_dir))
        if encode["timed_out"] or encode["exit_code"] != 0:
            raise TrialFailed("encode failed", encode=encode)
        frame_size, frame_hash = safe_artifact(frame, directory, spec["limits"]["max_frame_bytes"])
        if safe_artifact(input_copy, encode_dir, spec["limits"]["max_raw_bytes"]) != (source["bytes"], source["sha256"]):
            raise TrialFailed("encoder mutated its anonymous input", encode=encode)
        require_file(source, "source", length=True)
        if check_deps(spec) != dependencies:
            raise Invalid("dependency directory changed during encode")
        decode_dir.mkdir()
        decode_frame = decode_dir / "frame.bin"
        output = decode_dir / "output.bin"
        shutil.copyfile(frame, decode_frame)
        if safe_artifact(decode_frame, decode_dir, spec["limits"]["max_frame_bytes"]) != (frame_size, frame_hash):
            raise TrialFailed("copied decoder frame differs", encode=encode)
        # Hold logs in unlinked parent-owned files, then remove every encoder
        # path before starting the decoder. Its cwd has only the copied frame.
        held_logs = []
        for suffix in ("stdout", "stderr"):
            held = tempfile.TemporaryFile()
            with Path(encode[suffix]).open("rb") as source_log:
                shutil.copyfileobj(source_log, held)
            held.seek(0)
            held_logs.append((suffix, held))
        shutil.rmtree(encode_dir)
        decode_places = {"input": str(input_copy), "frame": str(decode_frame),
                         "output": str(output), "work": str(decode_dir)}
        decode_argv = expand(spec["decode_argv"], decode_places)
        if any(str(raw_path) in part or str(input_copy) in part for part in decode_argv):
            raise TrialFailed("decoder argv exposes original source path", encode=encode)
        decode = run_process(decode_argv, decode_dir,
                             spec["limits"]["timeout_seconds"], limit,
                             decode_dir / "decode", child_environment(spec, decode_dir))
        if decode["timed_out"] or decode["exit_code"] != 0:
            raise TrialFailed("decode failed", encode=encode, decode=decode)
        raw_size, raw_hash = safe_artifact(output, directory, spec["limits"]["max_raw_bytes"])
        if raw_size != source["bytes"] or raw_hash != source["sha256"]:
            raise TrialFailed("lossy output", encode=encode, decode=decode)
        if safe_artifact(decode_frame, decode_dir, spec["limits"]["max_frame_bytes"]) != (frame_size, frame_hash):
            raise TrialFailed("frame mutated during decode", encode=encode, decode=decode)
        require_file(source, "source", length=True)
        if check_deps(spec) != dependencies:
            raise Invalid("dependency directory changed during decode")
        side_bytes = costed_side_bytes(spec)
        cache_parent = work / "cache"
        cache_parent.mkdir(exist_ok=True)
        if cache_parent.is_symlink():
            raise Invalid("cache root is a symlink")
        temp = cache_parent / (".pending-" + trial_id)
        temp.mkdir()
        shutil.copyfile(decode_frame, temp / "frame.bin")
        shutil.copyfile(output, temp / "decoded.bin")
        atomic_json(temp / "meta.json", {"key": key, "frame_bytes": frame_size,
                   "frame_sha256": frame_hash, "decoded_sha256": raw_hash,
                   "decoded_bytes": raw_size, "side_information_bytes": side_bytes})
        if cached.exists():
            shutil.rmtree(temp)
        else:
            temp.rename(cached)
        row = {**started, "status": "pass", "cache_key": key,
               "frame_bytes": frame_size, "frame_sha256": frame_hash,
               "decoded_bytes": raw_size, "decoded_sha256": raw_hash,
               "side_information_bytes": side_bytes,
               "complete_bytes": frame_size + side_bytes,
               "artifact_dir": str(directory), "fresh_encode": True, "fresh_decode": True,
               "encode": encode, "decode": decode}
    except Exception as error:
        row = {**started, "status": "fail", "error": str(error),
               "error_type": type(error).__name__, "artifact_dir": str(directory)}
        if "encode" in locals():
            row["encode"] = encode
        if "decode" in locals():
            row["decode"] = decode
        if isinstance(error, TrialFailed):
            row.update(error.evidence)
    finally:
        if "held_logs" in locals():
            encode_dir.mkdir(exist_ok=True)
            for suffix, held in held_logs:
                with Path(encode[suffix]).open("wb") as restored:
                    shutil.copyfileobj(held, restored)
                held.close()
    append_ledger(ledger, row)
    return row


class TrialFailed(Exception):
    def __init__(self, message, **evidence):
        super().__init__(message)
        self.evidence = evidence


def geo(values):
    return math.exp(sum(math.log(x) for x in values) / len(values))


def score(cases, rows):
    paired = []
    missing = []
    for case in cases:
        trials = rows[case["id"]]
        if any(trials[role]["status"] not in ("pass", "cached_verified") for role in ("baseline", "candidate")):
            missing.append(case["id"])
            continue
        base = trials["baseline"]["complete_bytes"]
        cand = trials["candidate"]["complete_bytes"]
        if base <= 0:
            missing.append(case["id"])
            continue
        paired.append({"id": case["id"], "kind": case["kind"],
                       "language": case["language"], "work_id": case["work_id"],
                       "baseline_bytes": base, "candidate_bytes": cand,
                       "ratio": cand / base})
    kinds = {}
    for kind in sorted({case["kind"] for case in cases}):
        expected = [case for case in cases if case["kind"] == kind]
        actual = [entry for entry in paired if entry["kind"] == kind]
        absent = [case["id"] for case in expected if case["id"] in missing]
        if absent:
            kinds[kind] = {"eligible": False, "expected": len(expected),
                           "scored": len(actual), "missing_or_failed": absent}
            continue
        works = {}
        for entry in actual:
            key = (entry["language"], entry["work_id"])
            works.setdefault(key, []).append(entry["ratio"])
        by_language = {}
        for (language, work_id), ratios in works.items():
            by_language.setdefault(language, {})[work_id] = geo(ratios)
        language_geo = {language: geo(list(work_ratios.values()))
                        for language, work_ratios in by_language.items()}
        values = [entry["ratio"] for entry in actual]
        kinds[kind] = {"eligible": True, "expected": len(expected),
                       "scored": len(actual), "language_balanced_work_geo": geo(list(language_geo.values())),
                       "work_geo_by_language": by_language, "language_geo": language_geo,
                       "median_case_ratio": statistics.median(values), "worst_case_ratio": max(values),
                       "case_win_fraction": sum(x < 1 for x in values) / len(values),
                       "cases": actual}
    return {"kinds": kinds, "missing_or_failed": missing, "all_cases_passed": not missing}


def book_goal(scores):
    # Books and other prose may be separate registry kinds, but both are the
    # primary scorecard; dictionary/page cases can never offset their losses.
    primary = [entry for kind, entry in scores["kinds"].items() if kind in ("book", "prose")]
    if not primary or any(not entry["eligible"] for entry in primary):
        return {"eligible": False, "reason": "book/prose cases missing or failed"}
    cases = [case for entry in primary for case in entry["cases"]]
    works = {}
    for case in cases:
        works.setdefault((case["language"], case["work_id"]), []).append(case["ratio"])
    languages = {}
    for (language, work_id), ratios in works.items():
        languages.setdefault(language, {})[work_id] = geo(ratios)
    per_language = {lang: geo(list(work.values())) for lang, work in languages.items()}
    ratio = geo(list(per_language.values()))
    return {"eligible": True, "language_balanced_work_geo": ratio,
            "language_geo": per_language, "worst_case_ratio": max(x["ratio"] for x in cases),
            "target_35_percent": ratio <= .65 and all(x <= .8 for x in per_language.values())
                                 and all(x["ratio"] <= 1 for x in cases)}


def verify_prior_report(path, expected_stage, registry, current_pins, *, same_candidate,
                        same_registry=False, prior_registry_path=None, proof_root=None):
    """Reprice a prior report from its pinned specs and retained current files."""
    previous = load_json(path)
    selected = select_cases(validate_registry(registry), expected_stage)
    prior_cases = previous.get("case_snapshot")
    if prior_cases is None:
        if prior_registry_path is None:
            raise Invalid("prior report lacks case snapshot; provide --qualification-cases")
        old_registry = load_json(Path(prior_registry_path))
        if sha(canonical(old_registry)) != previous.get("pins", {}).get("registry_sha256"):
            raise Invalid("qualification registry does not match prior report")
        prior_cases = select_cases(validate_registry(old_registry), expected_stage)
    elif sha(canonical(prior_cases)) != previous.get("case_snapshot_sha256"):
        raise Invalid("prior case snapshot hash differs")
    if canonical(prior_cases) != canonical(selected):
        raise Invalid("prior stage cases changed in current registry")
    if previous.get("stage") != expected_stage or previous.get("expected_case_ids") != [c["id"] for c in selected]:
        raise Invalid("prior report does not cover the exact required stage and cases")
    pins = previous.get("pins", {})
    for name in ("baseline_spec_sha256", "harness_sha256"):
        if pins.get(name) != current_pins[name]:
            raise Invalid(f"prior report {name} differs")
    if same_registry and pins.get("registry_sha256") != current_pins["registry_sha256"]:
        raise Invalid("prior report registry differs")
    if same_candidate and pins.get("candidate_spec_sha256") != current_pins["candidate_spec_sha256"]:
        raise Invalid("prior report candidate spec differs")
    specs = previous.get("specs", {})
    if not isinstance(specs, dict) or set(specs) != {"candidate", "baseline"}:
        raise Invalid("prior report lacks embedded pinned specs")
    for role in ("candidate", "baseline"):
        loaded = specs[role]
        if sha(canonical(loaded)) != pins[f"{role}_spec_sha256"]:
            raise Invalid(f"prior {role} spec hash mismatch")
        if validate_spec(loaded, role) != pins[f"{role}_dependencies"]:
            raise Invalid(f"prior {role} dependency set changed")
    verified_rows = {}
    proof_root = Path(proof_root or Path(path).parent / "prior-proofs")
    proof_root.mkdir(parents=True, exist_ok=True)
    old_rows = previous.get("trials", {})
    if set(old_rows) != {c["id"] for c in selected}:
        raise Invalid("prior report has missing or extra cases")
    for case in selected:
        source = source_for(case, expected_stage)
        require_file(source, "prior source", length=True)
        verified_rows[case["id"]] = {}
        for role in ("candidate", "baseline"):
            row = old_rows[case["id"]][role]
            if row.get("status") not in ("pass", "cached_verified") or not row.get("fresh_decode"):
                raise Invalid("prior case lacks successful fresh decode")
            spec = specs[role]
            artifact = Path(row["artifact_dir"])
            frame = (Path(row["cached_frame_dir"]) / "frame.bin" if row["status"] == "cached_verified"
                     else artifact / "decode_job" / "frame.bin")
            frame_bytes, frame_hash = safe_artifact(frame, frame.parent, spec["limits"]["max_frame_bytes"])
            decoded = artifact / "decode_job" / "output.bin"
            decoded_bytes, decoded_hash = safe_artifact(decoded, decoded.parent, spec["limits"]["max_raw_bytes"])
            side_bytes = costed_side_bytes(spec)
            if (frame_bytes != row.get("frame_bytes") or frame_hash != row.get("frame_sha256")
                    or decoded_bytes != source["bytes"] or decoded_hash != source["sha256"]
                    or decoded_bytes != row.get("decoded_bytes") or decoded_hash != row.get("decoded_sha256")
                    or side_bytes != row.get("side_information_bytes")
                    or frame_bytes + side_bytes != row.get("complete_bytes")):
                raise Invalid(f"prior report artifact mismatch: {case['id']} {role}")
            proof_dir = proof_root / uuid.uuid4().hex
            proof_dir.mkdir()
            proof_frame = proof_dir / "frame.bin"
            proof_output = proof_dir / "output.bin"
            shutil.copyfile(frame, proof_frame)
            if safe_artifact(proof_frame, proof_dir, spec["limits"]["max_frame_bytes"]) != (frame_bytes, frame_hash):
                raise Invalid("prior frame changed during proof copy")
            locations = {"input": str(proof_dir / "unavailable-input.bin"),
                         "frame": str(proof_frame), "output": str(proof_output),
                         "work": str(proof_dir)}
            decoder_argv = expand(spec["decode_argv"], locations)
            if any(source["path"] in part or locations["input"] in part for part in decoder_argv):
                raise Invalid("prior decoder argv exposes original source")
            limit = int(max(spec["limits"]["max_raw_bytes"], spec["limits"]["max_frame_bytes"], 1024 * 1024))
            proof = run_process(decoder_argv, proof_dir, spec["limits"]["timeout_seconds"], limit,
                                proof_dir / "decode", child_environment(spec, proof_dir))
            proof_row = {"event": "prior_decode_proof", "report": str(path), "stage": expected_stage,
                         "case": case["id"], "role": role, "process": proof,
                         "artifact_dir": str(proof_dir)}
            if proof["timed_out"] or proof["exit_code"] != 0:
                proof_row["status"] = "fail"
                append_ledger(proof_root / "proofs.jsonl", proof_row)
                raise Invalid(f"prior frame fresh decode failed: {case['id']} {role}")
            proof_bytes, proof_hash = safe_artifact(proof_output, proof_dir, spec["limits"]["max_raw_bytes"])
            proof_row["status"] = "pass" if (proof_bytes, proof_hash) == (source["bytes"], source["sha256"]) else "fail"
            append_ledger(proof_root / "proofs.jsonl", proof_row)
            if proof_row["status"] != "pass":
                raise Invalid(f"prior frame fresh decode is lossy: {case['id']} {role}")
            if safe_artifact(proof_frame, proof_dir, spec["limits"]["max_frame_bytes"]) != (frame_bytes, frame_hash):
                raise Invalid("prior frame mutated during fresh decode")
            if check_deps(spec) != pins[f"{role}_dependencies"]:
                raise Invalid("prior decoder dependencies changed during proof")
            verified_rows[case["id"]][role] = {"status": "pass", "complete_bytes": frame_bytes + side_bytes}
    scores = score(selected, verified_rows)
    primary = book_goal(scores)
    if not scores["all_cases_passed"] or not primary.get("eligible"):
        raise Invalid("prior report fails complete book/prose gate")
    stored = previous.get("primary", {}).get("language_balanced_work_geo")
    if not isinstance(stored, (int, float)) or not math.isclose(stored, primary["language_balanced_work_geo"], rel_tol=1e-12):
        raise Invalid("prior reported primary score differs from recomputed rows")
    return previous, scores, primary, digest(path)


def freeze_payload(spec, baseline, registry, candidate_deps, baseline_deps):
    return {"candidate_spec_sha256": sha(canonical(spec)),
            "baseline_spec_sha256": sha(canonical(baseline)),
            "registry_sha256": sha(canonical(registry)),
            "candidate_dependencies": candidate_deps,
            "baseline_dependencies": baseline_deps,
            "harness_sha256": digest(HARNESS)}


def verify_freeze(path, token, payload, stage, qualification_hash):
    frozen = load_json(path)
    if frozen.get("pins") != payload:
        raise Invalid("freeze pins do not match spec, cases, dependencies, or harness")
    if frozen.get("stage") != stage or frozen.get("qualification_report_sha256") != qualification_hash:
        raise Invalid("freeze stage or qualification report differs")
    if not token or frozen.get("token_sha256") != sha(token.encode()):
        raise Invalid("coordinator token mismatch")
    return sha(canonical(frozen))


def cohort_claim_paths(freeze_path, registry_path, stage, cases):
    claims = registry_path.resolve().parent / ".frontier-cohort-claims"
    paths = {freeze_path.resolve().with_name(freeze_path.name + f".{stage}.claimed")}
    for case in cases:
        identities = [("source", case["source"]["sha256"]), ("work", case["work_id"])]
        identities += [(name, case[name]) for name in ("author", "lineage_id", "translation_lineage")
                       if name in case]
        for kind, value in identities:
            paths.add(claims / f"{stage}-{kind}-{sha(value.encode())}.claimed")
    return sorted(paths)


def consume_cohort(freeze_path, registry_path, stage, registry_hash, freeze_hash, cases):
    """Claim both shared manifest and freeze siblings before any sealed trial.

    These files coordinate trusted operators; they are not a security boundary
    against someone copying the whole registry under a different path.
    """
    paths = cohort_claim_paths(freeze_path, registry_path, stage, cases)
    for path in paths:
        if path.exists() or path.is_symlink():
            raise Invalid(f"{stage} cohort already consumed: {path}")
    claim_root = registry_path.resolve().parent / ".frontier-cohort-claims"
    claim_root.mkdir(exist_ok=True)
    if claim_root.is_symlink():
        raise Invalid("cohort claim directory is a symlink")
    claimed = []
    for path in paths:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as error:
            raise Invalid(f"{stage} cohort already consumed: {path}") from error
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"stage": stage, "registry_sha256": registry_hash,
                       "freeze_sha256": freeze_hash, "utc_ns": time.time_ns()}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        claimed.append(str(path))
    return claimed


def command_freeze(args):
    spec, baseline, registry = (load_json(Path(x)) for x in (args.spec, args.baseline, args.cases))
    cand_deps = validate_spec(spec, "candidate")
    base_deps = validate_spec(baseline, "baseline")
    select_cases(validate_registry(registry), args.stage)
    if not args.token:
        raise Invalid("coordinator token required")
    payload = freeze_payload(spec, baseline, registry, cand_deps, base_deps)
    prior_stage = "development" if args.stage == "validation" else "validation"
    prior, _, previous_primary, qualification_hash = verify_prior_report(
        Path(args.qualification_report), prior_stage, registry, payload, same_candidate=True,
        prior_registry_path=args.qualification_cases, proof_root=Path(args.out).parent / "prior-proofs")
    if not previous_primary["target_35_percent"] or prior["backend_class"] != "self_contained":
        raise Invalid("qualification report does not meet the frozen book goal")
    claims = cohort_claim_paths(Path(args.out), Path(args.cases), args.stage,
                                select_cases(registry["cases"], args.stage))
    if any(path.exists() or path.is_symlink() for path in claims):
        raise Invalid(f"{args.stage} cohort already consumed")
    frozen = {"stage": args.stage, "pins": payload,
              "qualification_report_sha256": qualification_hash,
              "token_sha256": sha(args.token.encode())}
    atomic_json(Path(args.out), frozen)
    print(json.dumps({"freeze": str(args.out), "freeze_sha256": digest(Path(args.out))}))


def command_run(args):
    spec, baseline, registry = (load_json(Path(x)) for x in (args.spec, args.baseline, args.cases))
    cand_deps = validate_spec(spec, "candidate")
    base_deps = validate_spec(baseline, "baseline")
    cases = select_cases(validate_registry(registry), args.stage)
    if baseline["backend_class"] != "control":
        raise Invalid("baseline backend_class must be control")
    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    report = Path(args.report).resolve()
    ledger = work / "ledger.jsonl"
    payload = freeze_payload(spec, baseline, registry, cand_deps, base_deps)
    incumbent_evidence = None
    if args.incumbent_report:
        if args.stage != "development":
            raise Invalid("incumbent comparison is development-only")
        if Path(args.incumbent_report).resolve() == report:
            raise Invalid("incumbent report and current report must have distinct paths")
        incumbent_evidence = verify_prior_report(
            Path(args.incumbent_report), "development", registry, payload,
            same_candidate=False, same_registry=True, proof_root=work / "prior-proofs")
    freeze_hash = None
    cohort_seal = None
    qualification_hash = None
    if args.stage in ("validation", "final"):
        if not args.freeze or not args.qualification_report:
            raise Invalid("validation/final require freeze and prior-stage qualification report")
        prior_stage = "development" if args.stage == "validation" else "validation"
        qualification, _, qualified_primary, qualification_hash = verify_prior_report(
            Path(args.qualification_report), prior_stage, registry, payload, same_candidate=True,
            prior_registry_path=args.qualification_cases, proof_root=work / "prior-proofs")
        if not qualified_primary["target_35_percent"] or qualification["backend_class"] != "self_contained":
            raise Invalid("prior stage does not qualify for sealed cohort")
        freeze_hash = verify_freeze(Path(args.freeze), args.token, payload, args.stage, qualification_hash)
        cohort_seal = consume_cohort(Path(args.freeze), Path(args.cases), args.stage,
                                     payload["registry_sha256"], freeze_hash, cases)
    elif args.freeze:
        raise Invalid("freeze is reserved for validation/final stages")
    run_id = uuid.uuid4().hex
    prior = []
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            if line:
                event = json.loads(line)
                if (event.get("event") == "round" and event.get("stage") == "development"
                        and event.get("parent") == spec["parent"]):
                    prior.append(event)
    append_ledger(ledger, {"event": "round_start", "run_id": run_id, "stage": args.stage,
                           "candidate": spec["id"], "parent": spec["parent"],
                           "expected_cases": [case["id"] for case in cases],
                           "pins": payload, "freeze_sha256": freeze_hash,
                           "qualification_report_sha256": qualification_hash,
                           "cohort_seal": cohort_seal, "utc_ns": time.time_ns()})
    rows = {}
    for case in cases:
        source = source_for(case, args.stage)
        rows[case["id"]] = {
            "baseline": trial(baseline, case, source, args.stage, "baseline", work, ledger, payload["harness_sha256"]),
            "candidate": trial(spec, case, source, args.stage, "candidate", work, ledger, payload["harness_sha256"]),
        }
    scores = score(cases, rows)
    primary = book_goal(scores)
    strong_goal = (args.stage != "screen" and scores["all_cases_passed"]
                   and spec["backend_class"] == "self_contained"
                   and spec["model_accounting"]["kind"] != "external_learned"
                   and primary.get("target_35_percent", False))
    incumbent = 1.0
    incumbent_source = "whole_bzip3_baseline"
    incumbent_case_ratios = {c["id"]: 1.0 for c in cases if c["kind"] in ("book", "prose")}
    incumbent_language_ratios = {c["language"]: 1.0 for c in cases if c["kind"] in ("book", "prose")}
    improves = False
    if incumbent_evidence:
        previous, old_scores, old_primary, incumbent_hash = incumbent_evidence
        incumbent = old_primary["language_balanced_work_geo"]
        incumbent_source = {"report": str(args.incumbent_report), "sha256": incumbent_hash}
        incumbent_case_ratios = {row["id"]: row["ratio"]
                                 for entry in old_scores["kinds"].values() if entry["eligible"]
                                 for row in entry["cases"] if row["kind"] in ("book", "prose")}
        incumbent_language_ratios = old_primary["language_geo"]
    current_book_cases = [row for entry in scores["kinds"].values() if entry["eligible"]
                          for row in entry["cases"] if row["kind"] in ("book", "prose")]
    no_book_regression = (primary.get("eligible", False)
                          and all(ratio <= 1 and ratio <= incumbent_language_ratios.get(lang, 0) * (1 + 1e-12)
                                  for lang, ratio in primary["language_geo"].items())
                          and all(row["ratio"] <= 1 and row["ratio"] <= incumbent_case_ratios.get(row["id"], 0) * (1 + 1e-12)
                                  for row in current_book_cases))
    if primary.get("eligible"):
        improves = primary["language_balanced_work_geo"] <= incumbent * .995
    hillclimb_promoted = bool(args.stage == "development" and scores["all_cases_passed"]
                              and spec["backend_class"] == "self_contained"
                              and spec["model_accounting"]["kind"] != "external_learned"
                              and improves and no_book_regression)
    accepted = strong_goal if args.stage in ("validation", "final") else hillclimb_promoted
    preceding_failures = 0
    for entry in reversed(prior):
        if entry.get("goal_met") or entry.get("hillclimb_promoted"):
            break
        preceding_failures += 1
    next_action = ("reflection_required" if args.stage == "development" and not accepted
                   and preceding_failures >= 1 else "new_attributable_round")
    if strong_goal and args.stage == "development":
        next_action = "freeze_and_validate"
    elif accepted:
        next_action = "continue_attributable_iteration" if args.stage == "development" else "preserve_frozen_result"
    result = {"run_id": run_id, "stage": args.stage, "candidate": spec["id"],
              "baseline": baseline["id"], "parent": spec["parent"],
              "mechanism": spec["mechanism"], "hypothesis": spec["hypothesis"],
              "decisive_test": spec["decisive_test"], "backend_class": spec["backend_class"],
              "specs": {"candidate": spec, "baseline": baseline},
              "pins": payload, "freeze_sha256": freeze_hash, "cohort_seal": cohort_seal,
              "qualification_report_sha256": qualification_hash,
              "expected_case_ids": [case["id"] for case in cases],
              "case_snapshot": cases, "case_snapshot_sha256": sha(canonical(cases)),
              "trials": rows, "scores": scores, "primary": primary,
              "target_35_percent": bool(strong_goal), "goal_met": bool(strong_goal),
              "hillclimb_promoted": hillclimb_promoted,
              "no_book_regression": bool(no_book_regression), "incumbent_ratio": incumbent,
              "incumbent_source": incumbent_source,
              "improves_incumbent_by_0_5_percent": improves,
              "accepted": accepted, "next_action": next_action,
              "timing_scope": "diagnostic child-process command wall only; not quiet or paired",
              "performance_final_ready": False,
              "size_proof": "fresh exact decode of every current frame",
              "candidate_encoding_scope": ("fresh" if all(x["candidate"].get("fresh_encode") for x in rows.values())
                                           else "includes cached frames, each freshly decoded")}
    archived_report = work / "reports" / f"{run_id}.json"
    if archived_report.exists():
        raise Invalid("report run-id collision")
    atomic_json(archived_report, result)
    archived_report.chmod(0o444)
    if report != archived_report:
        atomic_json(report, result)
    append_ledger(ledger, {"event": "round", "run_id": run_id, "stage": args.stage,
                           "candidate": spec["id"], "parent": spec["parent"],
                           "accepted": accepted, "goal_met": bool(strong_goal),
                           "hillclimb_promoted": hillclimb_promoted,
                           "all_cases_passed": scores["all_cases_passed"],
                           "primary": primary, "next_action": next_action,
                           "report": str(report), "report_sha256": digest(report),
                           "archived_report": str(archived_report),
                           "archived_report_sha256": digest(archived_report),
                           "utc_ns": time.time_ns()})
    print(json.dumps({"report": str(report), "accepted": accepted,
                      "all_cases_passed": scores["all_cases_passed"],
                      "primary": primary, "next_action": next_action}, sort_keys=True))
    return 0 if scores["all_cases_passed"] else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="execute every registered case in a stage")
    run.add_argument("--spec", required=True)
    run.add_argument("--baseline", required=True)
    run.add_argument("--cases", required=True)
    run.add_argument("--stage", choices=STAGES, required=True)
    run.add_argument("--work", required=True)
    run.add_argument("--report", required=True)
    run.add_argument("--freeze")
    run.add_argument("--token")
    run.add_argument("--incumbent-report")
    run.add_argument("--qualification-report")
    run.add_argument("--qualification-cases", help="pinned older registry for a prior report without an embedded case snapshot")
    freeze = sub.add_parser("freeze", help="pin candidate, baseline, registry, dependencies and harness")
    freeze.add_argument("--spec", required=True)
    freeze.add_argument("--baseline", required=True)
    freeze.add_argument("--cases", required=True)
    freeze.add_argument("--stage", choices=("validation", "final"), required=True)
    freeze.add_argument("--qualification-report", required=True)
    freeze.add_argument("--qualification-cases", help="pinned older registry for a prior report without an embedded case snapshot")
    freeze.add_argument("--token", required=True)
    freeze.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        return command_freeze(args) if args.command == "freeze" else command_run(args)
    except (Invalid, OSError, json.JSONDecodeError) as error:
        if args.command == "run":
            failure = {"event": "fatal", "status": "fail", "stage": args.stage,
                       "error_type": type(error).__name__, "error": str(error),
                       "utc_ns": time.time_ns()}
            try:
                append_ledger(Path(args.work) / "ledger.jsonl", failure)
                atomic_json(Path(args.report), failure)
            except OSError:
                pass
        print(f"frontier-loop: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
