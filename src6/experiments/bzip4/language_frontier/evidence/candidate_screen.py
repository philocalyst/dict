#!/usr/bin/env python3
"""Storage-only screen for the weighted-emission candidate.

The screen consumes the exact 64 KiB prefixes and bzip3 controls materialized
by ``candidate_preflight.py``.  It then captures current v4 raw frames and
builds one self-contained WAM frame in each of MAP and marginal mode.  Every
WAM frame is persisted and decoded by ``wam_decode_subprocess.py`` in a fresh
process that receives only that frame.  No timings are read or reported.

This is deliberately an evidence harness rather than a tuning driver:
``max_piece``, ``min_occ``, ``max_vocab``, and EM rounds are fixed for all
seven workloads, and a model is fit only from the input bytes being charged.
The complete fitted model is serialized in the WAM header.  The confirmation
20% TRAIN resources are not mentioned or read here.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
BZ4 = HERE.parents[1] / "bz4"
V4_BIN = BZ4 / "v3" / "zig-out" / "bin" / "bz4"
BZ3_BIN = BZ4 / "bin" / "bz3base"
CAPTURE = HERE / "bin" / "capture_frame"
CAPTURE_SOURCE = HERE / "capture_frame.zig"
V4_SOURCE = BZ4 / "v3" / "src"
BZ3_SOURCE = BZ4 / "bz3base.zig"
WAM_SOURCE = HERE.parent / "segmentation" / "weighted_emission_coder.py"
WAM_DECODER = HERE / "wam_decode_subprocess.py"
PREFIX_BYTES = 65536
DEFAULT_PREFLIGHT = HERE / "runs" / "wam-screen-preflight-20260926"

POLICY: dict[str, Any] = {
    "max_piece": 8,
    "min_occ": 2,
    "max_vocab": 256,
    "em_rounds": 2,
    "modes": ["map", "marginal"],
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, Any]:
    path = path.resolve()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256(path)}


def tree_record(root: Path) -> dict[str, Any]:
    """Hash a small source tree deterministically, including relative names."""
    root = root.resolve()
    digest = hashlib.sha256()
    files = 0
    total_bytes = 0
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        data = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
        files += 1
        total_bytes += len(data)
    return {
        "path": str(root),
        "files": files,
        "bytes": total_bytes,
        "sha256": digest.hexdigest(),
    }


def load_codec():
    spec = importlib.util.spec_from_file_location("weighted_emission_coder_screen", WAM_SOURCE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import weighted-emission codec: {WAM_SOURCE}")
    module = importlib.util.module_from_spec(spec)
    if str(WAM_SOURCE.parent) not in sys.path:
        sys.path.insert(0, str(WAM_SOURCE.parent))
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run_command(argv: list[str], *, stdout_path: Path, stderr_path: Path) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    stdout_path.write_bytes(result.stdout)
    stderr_path.write_bytes(result.stderr)
    return result


def parse_ok_fields(raw: bytes) -> dict[str, str]:
    text = raw.decode("utf-8", "strict")
    lines = [line for line in text.splitlines() if line.startswith("ok\t")]
    if len(lines) != 1:
        raise ValueError(f"expected exactly one ok line, got {len(lines)}")
    fields: dict[str, str] = {}
    for field in lines[0].split("\t")[1:]:
        key, separator, value = field.partition("=")
        if not separator or key in fields:
            raise ValueError(f"malformed or duplicate capture field: {field!r}")
        fields[key] = value
    return fields


def parse_int_fields(fields: dict[str, str], names: set[str]) -> dict[str, int]:
    result: dict[str, int] = {}
    for name in names:
        if name in fields:
            result[name] = int(fields[name])
    return result


def check_external_v4_decode(
    sample_dir: Path,
    frame: Path,
    expected: Path,
    sample_id: str,
) -> dict[str, Any]:
    decoded = sample_dir / "external-decoded.bin"
    stdout = sample_dir / f"{sample_id}.decode.stdout"
    stderr = sample_dir / f"{sample_id}.decode.stderr"
    command = [str(V4_BIN), "d", str(frame), str(decoded), "1"]
    result = run_command(command, stdout_path=stdout, stderr_path=stderr)
    item: dict[str, Any] = {
        "command": command,
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
    }
    exact = False
    if decoded.is_file():
        item["output"] = file_record(decoded)
        exact = result.returncode == 0 and decoded.stat().st_size == expected.stat().st_size
        exact = exact and sha256(decoded) == sha256(expected)
    item["exact_hash"] = exact
    return item


def capture_v4(run_dir: Path, name: str, prefix: Path) -> dict[str, Any]:
    sample_dir = run_dir / "v4" / name
    sample_dir.mkdir(parents=True)
    frame = sample_dir / "frame.b4"
    stdout = sample_dir / "encode.stdout"
    stderr = sample_dir / "encode.stderr"
    command = [str(CAPTURE), "raw", str(prefix), str(frame), str(PREFIX_BYTES)]
    result = run_command(command, stdout_path=stdout, stderr_path=stderr)
    sample: dict[str, Any] = {
        "id": f"{name}-v4",
        "codec": "bzip4-v4",
        "kind": "current_v4_raw_prefix65536",
        "block_bytes": PREFIX_BYTES,
        "input": file_record(prefix),
        "binary": file_record(CAPTURE),
        "codec_source": file_record(CAPTURE_SOURCE),
        "command": command,
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
    }
    ok = result.returncode == 0 and frame.is_file()
    if frame.is_file():
        sample["frame"] = file_record(frame)
    if ok:
        try:
            fields = parse_ok_fields(result.stderr)
            storage = parse_int_fields(
                fields,
                {"classes", "block_bytes", "total", "header", "delta", "payload", "framing", "blocks", "raw_len"},
            )
            if storage.get("total") != frame.stat().st_size:
                raise ValueError("capture total does not match frame length")
            if storage.get("raw_len") != PREFIX_BYTES:
                raise ValueError("capture raw length does not match 64 KiB prefix")
            sample["storage"] = storage
        except (ValueError, UnicodeDecodeError, KeyError) as exc:
            sample["parse_error"] = str(exc)
            ok = False
    if frame.is_file():
        sample["external_decode"] = check_external_v4_decode(sample_dir, frame, prefix, name)
        ok = ok and bool(sample["external_decode"]["exact_hash"])
    sample["ok"] = ok
    return sample


def read_varint(frame: bytes, codec, at: int) -> tuple[int, int]:
    value, after = codec.read_varint(frame, at)
    if after <= at or after > len(frame):
        raise ValueError("invalid varint boundary")
    return value, after


def wam_breakdown(frame: bytes, codec) -> dict[str, int]:
    """Return comparable header/framing/payload byte counts for one WAM frame.

    WAM has no separate v4-style delta section: serialized token strings and
    frequencies are in its header.  ``header`` below includes the magic,
    mode/precision, raw length, full model, and MAP path count when present.
    ``framing`` is the payload-length varint, and ``payload`` includes the
    arithmetic finish/padding.  The labels are explicit so this is not
    mistaken for a v4 model-delta decomposition.
    """
    if len(frame) < 6 or frame[:4] != b"WAM1":
        raise ValueError("bad WAM frame")
    mode = frame[4]
    at = 6
    raw_len, at = read_varint(frame, codec, at)
    token_count, at = read_varint(frame, codec, at)
    for _ in range(token_count):
        token_len, at = read_varint(frame, codec, at)
        at += token_len
        if at > len(frame):
            raise ValueError("truncated WAM token")
        _, at = read_varint(frame, codec, at)
    path_count = -1
    if mode == 0:
        path_count, at = read_varint(frame, codec, at)
    payload_length_at = at
    payload_len, payload_at = read_varint(frame, codec, at)
    if payload_len != len(frame) - payload_at:
        raise ValueError("WAM payload length mismatch")
    return {
        "total": len(frame),
        "header": payload_length_at,
        "delta": 0,
        "framing": payload_at - payload_length_at,
        "payload": payload_len,
        "blocks": 1,
        "raw_len": raw_len,
        "tokens": token_count,
        "path_count": path_count,
    }


def check_wam_decode(
    sample_dir: Path,
    frame: Path,
    expected: Path,
    name: str,
    mode: str,
) -> dict[str, Any]:
    decoded = sample_dir / "fresh-decoded.bin"
    stdout = sample_dir / "decode.stdout"
    stderr = sample_dir / "decode.stderr"
    command = [sys.executable, str(WAM_DECODER), str(frame), str(decoded)]
    result = run_command(command, stdout_path=stdout, stderr_path=stderr)
    item: dict[str, Any] = {
        "command": command,
        "returncode": result.returncode,
        "stdout": file_record(stdout),
        "stderr": file_record(stderr),
        "decoder": file_record(WAM_DECODER),
    }
    exact = False
    if decoded.is_file():
        item["output"] = file_record(decoded)
        exact = result.returncode == 0 and decoded.stat().st_size == expected.stat().st_size
        exact = exact and sha256(decoded) == sha256(expected)
    item["exact_hash"] = exact
    return item


def capture_wam(run_dir: Path, name: str, mode: str, prefix: Path, codec) -> dict[str, Any]:
    sample_dir = run_dir / "wam" / name / mode
    sample_dir.mkdir(parents=True)
    frame_path = sample_dir / "frame.wam"
    data = prefix.read_bytes()
    model_tokens, model_freqs = codec.make_tokens(
        data,
        max_piece=int(POLICY["max_piece"]),
        min_occ=int(POLICY["min_occ"]),
        max_vocab=int(POLICY["max_vocab"]),
    )
    fitted_freqs = codec.em_fit_freqs(data, model_tokens, model_freqs, int(POLICY["em_rounds"]))
    model = codec.Model(model_tokens, fitted_freqs)
    exact_bits: float | None = None
    payload_bits: int | None = None
    if mode == "map":
        frame, api_round_trip = codec.encode_map(data, model)
    elif mode == "marginal":
        frame, api_round_trip, exact_bits, payload_bits = codec.encode_marginal_with_stats(data, model)
    else:
        raise ValueError(f"unsupported WAM mode: {mode}")
    frame_path.write_bytes(frame)
    breakdown = wam_breakdown(frame, codec)
    fresh_decode = check_wam_decode(sample_dir, frame_path, prefix, name, mode)
    row: dict[str, Any] = {
        "id": f"{name}-wam-{mode}",
        "codec": "weighted-emission-wam1",
        "kind": "candidate_input_self_fit",
        "mode": mode,
        "block_bytes": PREFIX_BYTES,
        "input": file_record(prefix),
        "candidate_source": file_record(WAM_SOURCE),
        "encoder_api": "make_tokens -> em_fit_freqs -> Model -> encode_map/encode_marginal_with_stats",
        "frame": file_record(frame_path),
        "storage": breakdown,
        "model": {
            "tokens": len(model.tokens),
            "piece_tokens": len(model.tokens) - 256,
            "max_piece": int(POLICY["max_piece"]),
            "min_occ": int(POLICY["min_occ"]),
            "max_vocab": int(POLICY["max_vocab"]),
            "em_rounds": int(POLICY["em_rounds"]),
            "fitted_frequency_sum": sum(model.freqs),
        },
        "fit_policy": "input bytes only; all fitted model tokens/frequencies are serialized in the frame header",
        "header_semantics": "WAM header includes token strings and fitted frequencies; no separate delta section",
        "encoder_api_round_trip": bool(api_round_trip),
        "fresh_decode": fresh_decode,
        "exact_bits": exact_bits,
        "payload_bits": payload_bits,
        "ok": bool(api_round_trip and fresh_decode["exact_hash"]),
    }
    return row


def load_preflight(preflight: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    manifest_path = preflight / "manifest.json"
    samples_path = preflight / "samples.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    samples = json.loads(samples_path.read_text(encoding="utf-8"))
    expected_names = [
        "web2",
        "freedict-eval8",
        "gcide-eval8",
        "omw-eval8",
        "ud-fi-test-form",
        "ud-tr-test-form",
        "ud-ar-test-form",
    ]
    by_name = {row.get("name"): row for row in samples}
    if list(by_name) != expected_names:
        raise ValueError(f"preflight workload order/names differ: {list(by_name)}")
    if manifest.get("candidate_policy_frozen") != POLICY:
        raise ValueError("preflight policy does not match frozen candidate policy")
    for name in expected_names:
        row = by_name[name]
        if not row.get("ok") or row.get("bzip3", {}).get("block_bytes") != PREFIX_BYTES:
            raise ValueError(f"preflight control failed for {name}")
        prefix = Path(row["prefix"]["path"])
        actual = file_record(prefix)
        if actual != row["prefix"]:
            raise ValueError(f"preflight prefix changed for {name}")
        if actual["bytes"] != PREFIX_BYTES:
            raise ValueError(f"preflight prefix is not exactly 64 KiB for {name}")
    return manifest, [by_name[name] for name in expected_names]


def bzip3_reference(row: dict[str, Any], preflight: Path) -> dict[str, Any]:
    return {
        "id": f"{row['name']}-bzip3",
        "codec": "bzip3-control",
        "kind": "matched_block_control_reused_exact_prefix_hash",
        "block_bytes": PREFIX_BYTES,
        "input": row["prefix"],
        "binary": row["bzip3_binary"],
        "reference_run": str(preflight.resolve()),
        "stdout": row["stdout"],
        "stderr": row["stderr"],
        "storage": row["bzip3"],
        "timing_policy": "raw control timing fields are retained in referenced stdout but ignored",
        "ok": bool(row["ok"]),
    }


def summarize(samples: list[dict[str, Any]], names: list[str]) -> tuple[list[dict[str, Any]], dict[str, int]]:
    summary: list[dict[str, Any]] = []
    negative = {"wam_map_vs_bzip3": 0, "wam_marginal_vs_bzip3": 0, "wam_map_vs_v4": 0, "wam_marginal_vs_v4": 0}
    for name in names:
        key_for = {
            "bzip4-v4": "v4",
            "bzip3-control": "bzip3",
            "weighted-emission-wam1": "wam_{mode}",
        }
        rows: dict[str, dict[str, Any]] = {}
        for row in samples:
            if not row["id"].startswith(name + "-"):
                continue
            key = key_for[row["codec"]]
            rows[key.format(mode=row.get("mode"))] = row
        sizes = {key: value.get("storage", {}).get("total") for key, value in rows.items()}
        if sizes.get("wam_map") is not None and sizes.get("bzip3") is not None and sizes["wam_map"] >= sizes["bzip3"]:
            negative["wam_map_vs_bzip3"] += 1
        if sizes.get("wam_marginal") is not None and sizes.get("bzip3") is not None and sizes["wam_marginal"] >= sizes["bzip3"]:
            negative["wam_marginal_vs_bzip3"] += 1
        if sizes.get("wam_map") is not None and sizes.get("v4") is not None and sizes["wam_map"] >= sizes["v4"]:
            negative["wam_map_vs_v4"] += 1
        if sizes.get("wam_marginal") is not None and sizes.get("v4") is not None and sizes["wam_marginal"] >= sizes["v4"]:
            negative["wam_marginal_vs_v4"] += 1
        summary.append({"name": name, "ok": all(bool(row.get("ok")) for row in rows.values()), "bytes": sizes, "rows": rows})
    return summary, negative


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True, help="new run directory name; never overwritten")
    parser.add_argument("--preflight-run", type=Path, default=DEFAULT_PREFLIGHT)
    parser.add_argument("--output-root", type=Path, default=HERE / "runs")
    args = parser.parse_args()
    required = [V4_BIN, BZ3_BIN, CAPTURE, CAPTURE_SOURCE, WAM_SOURCE, WAM_DECODER, BZ3_SOURCE]
    if not all(path.is_file() for path in required) or not V4_SOURCE.is_dir():
        missing = [str(path) for path in required if not path.is_file()]
        if not V4_SOURCE.is_dir():
            missing.append(str(V4_SOURCE))
        raise SystemExit("missing candidate/baseline artifact: " + ", ".join(missing))
    run_dir = args.output_root / args.run_id
    if run_dir.exists():
        raise SystemExit(f"refusing to overwrite existing run: {run_dir}")
    run_dir.mkdir(parents=True)

    preflight_manifest, preflight_rows = load_preflight(args.preflight_run)
    source_start = file_record(WAM_SOURCE)
    codec = load_codec()
    names = [row["name"] for row in preflight_rows]
    samples: list[dict[str, Any]] = []
    for preflight_row in preflight_rows:
        name = preflight_row["name"]
        prefix = Path(preflight_row["prefix"]["path"])
        v4_row = capture_v4(run_dir, name, prefix)
        samples.append(v4_row)
        print(f"{name}: v4 ok={v4_row['ok']}", flush=True)
        control = bzip3_reference(preflight_row, args.preflight_run)
        samples.append(control)
        print(f"{name}: bzip3 reused ok={control['ok']}", flush=True)
        for mode in POLICY["modes"]:
            wam_row = capture_wam(run_dir, name, mode, prefix, codec)
            samples.append(wam_row)
            print(f"{name}: wam {mode} ok={wam_row['ok']} total={wam_row['storage']['total']}", flush=True)

    source_end = file_record(WAM_SOURCE)
    source_stable = source_start == source_end
    summary, negative = summarize(samples, names)
    manifest = {
        "schema": 1,
        "purpose": "Storage-only independent WAM MAP/marginal screen against current v4 and matched bzip3 on exact 64 KiB development prefixes.",
        "run_id": args.run_id,
        "prefix_bytes": PREFIX_BYTES,
        "input_policy": "seven exact first-65536-byte prefixes; identical bytes feed current v4, bzip3 reference, WAM MAP, and WAM marginal",
        "candidate_policy_frozen": POLICY,
        "fit_policy": "model fit uses only each charged input itself; no external model/training bytes; complete fitted model is charged in WAM header",
        "decode_policy": "each WAM frame is persisted then decoded by fresh wam_decode_subprocess.py receiving only the frame",
        "baseline_setup": {
            "v4": "current capture_frame raw mode with block_bytes=65536, internal serial round-trip plus external bz4 d exact hash",
            "bzip3": "reused preflight control only when the exact prefix hash matches; no control rerun",
        },
        "timing_policy": "no harness clocks; bzip3 and decoder raw timing text is retained only as provenance and ignored",
        "confirmation_policy": "TRAIN confirmation-20 resources are not listed, read, or benchmarked",
        "preflight": {
            "manifest": file_record(args.preflight_run / "manifest.json"),
            "samples": file_record(args.preflight_run / "samples.json"),
            "run": str(args.preflight_run.resolve()),
            "manifest_schema": preflight_manifest.get("schema"),
        },
        "codec_artifacts": {
            "evidence_harness": file_record(HERE / "candidate_screen.py"),
            "weighted_emission_source_start": source_start,
            "weighted_emission_source_end": source_end,
            "weighted_emission_source_stable": source_stable,
            "wam_decoder_helper": file_record(WAM_DECODER),
            "v4_capture_binary": file_record(CAPTURE),
            "v4_capture_source": file_record(CAPTURE_SOURCE),
            "v4_binary": file_record(V4_BIN),
            "v4_source_tree": tree_record(V4_SOURCE),
            "bzip3_binary": file_record(BZ3_BIN),
            "bzip3_source": file_record(BZ3_SOURCE),
            "python": file_record(Path(sys.executable)),
        },
        "sample_count": len(samples),
        "successful_samples": sum(bool(row.get("ok")) for row in samples),
        "negative_result_counts": negative,
    }
    (run_dir / "samples.json").write_text(json.dumps(samples, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if not source_stable:
        raise SystemExit("candidate source changed during run; discard this run and repeat after source freeze")
    if not all(bool(row.get("ok")) for row in samples):
        raise SystemExit("one or more storage captures or independent decodes failed; inspect samples.json")
    print(run_dir)


if __name__ == "__main__":
    main()
