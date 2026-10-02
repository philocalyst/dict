#!/usr/bin/env python3
"""Development-only, complete-frame spelling search for the native v4 codec.

This deliberately preserves the old archive and decoder. It is not WGP5 and
does not provide WGP5's adversarial-input/resource-bound guarantees.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
MAX_INPUT = 64 << 20
POLICY = {
    "id": "wgp6-maximal-native-search-1",
    "seed": "all",
    "capacity": 200000,
    "max_fragment": 128,
    "minimum_support": 3,
    "floor": 0,
    "initial_refits": 2,
    "native_reparse_rounds": 4,
    "recent_cut_donors": 0,
    "once_in_place": True,
    "classes": "old_native_automatic",
    "old_native_fallback": True,
    "selection": "smallest_complete_frame_first_tie",
}


def invoke(command):
    result = subprocess.run(list(map(str, command)), check=True,
                            capture_output=True, text=True)
    return json.loads(result.stdout)


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def encode(source, output, block):
    if source.stat().st_size > MAX_INPUT:
        raise ValueError("encoder input exceeds 64 MiB research limit")
    if not 0 < block <= 65536:
        raise ValueError("requested restart target must be in 1..65536")
    prepare, native = HERE / "prepare_maximal", HERE / "native"
    started = time.monotonic_ns()
    trials = []
    with tempfile.TemporaryDirectory(prefix="wgp6-") as directory:
        work = Path(directory)
        old_frame = work / "old.frame"
        old = invoke([native, "original", source, old_frame, block])
        trials.append({"candidate": "native_old", "codec_ns": old["codec_ns"],
                       "frame_bytes": old["frame_bytes"]})
        best_path, best_size, best_name = old_frame, old["frame_bytes"], "native_old"
        codec_ns = old["codec_ns"]
        previous = None
        for step in range(POLICY["native_reparse_rounds"] + 1):
            parse = work / f"{step}.parse"
            frame = work / f"{step}.frame"
            prices = work / f"{step}.prices"
            command = [prepare, source, parse, "--block", block, "--seed", "all",
                       "--capacity", POLICY["capacity"], "--max-fragment", 128,
                       "--floor", 0, "--rounds", 2, "--share", 0, "--once", 1]
            if previous is not None:
                command += ["--prices", work / f"{step - 1}.prices",
                            "--price-map", str(previous) + ".seeds"]
            prepared = invoke(command)
            command = [native, "compile", parse, frame, 0]
            if step < POLICY["native_reparse_rounds"]:
                command.append(prices)
            compiled = invoke(command)
            trial_ns = prepared["codec_ns"] + compiled["codec_ns"]
            codec_ns += trial_ns
            trials.append({"candidate": f"maximal_round_{step}",
                           "codec_ns": trial_ns, "frame_bytes": compiled["frame_bytes"],
                           "prepare": prepared, "compiled": compiled})
            if compiled["frame_bytes"] < best_size:
                best_path, best_size = frame, compiled["frame_bytes"]
                best_name = f"maximal_round_{step}"
            previous = parse
        # No candidate-choice symbol is omitted: the chosen old-format graph
        # and every definition/row it requires are already inside this frame.
        inspected = invoke([native, "inspect", best_path, work / "ledger.json"])
        shutil.copyfile(best_path, output)
    wall_ns = time.monotonic_ns() - started
    return {"policy": {**POLICY, "requested_restart_target": block},
            "selected_candidate": best_name, "frame_bytes": best_size,
            "all_search_encoder_codec_ns": codec_ns,
            "driver_wall_ns_including_io_and_process_startup": wall_ns,
            "codec_time_scope": "sum_of_all_native_learning_and_fit_stages_including_auxiliary_price_reads",
            "trials": trials, "ledger": inspected,
            "input_sha256": sha(source), "frame_sha256": sha(output),
            "fingerprint": {name: sha(HERE / name) for name in
                            ("prepare_maximal.cpp", "prepare_maximal", "native.zig", "native", "encode.py")},
            "native_backend_fingerprint": {
                path.name: sha(path) for path in
                sorted((HERE.parents[1] / "bzip4/bz4/v3/src").glob("*.zig"))}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    for operation in ("encode", "decode", "extract", "inspect"):
        command = sub.add_parser(operation)
        command.add_argument("input", type=Path)
        command.add_argument("output", type=Path)
        if operation == "encode":
            command.add_argument("--block", type=int, default=65536)
        if operation == "extract":
            command.add_argument("--index", type=int, required=True)
    args = parser.parse_args()
    source, output = args.input.resolve(), args.output.resolve()
    if source == output:
        parser.error("input and output paths must differ")
    if args.operation == "encode":
        result = encode(source, output, args.block)
    else:
        command = [HERE / "native", args.operation, source, output]
        if args.operation == "extract":
            if args.index < 0:
                parser.error("block index must be nonnegative")
            command.append(args.index)
        result = invoke(command)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
