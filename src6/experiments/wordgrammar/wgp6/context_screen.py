#!/usr/bin/env python3
"""Price a spelling DAG with actual native automaton rows, then reparse.

Only retained old development inputs. Every intermediate native model-fit
and spelling parse is included in aggregate encoder codec time.
"""
import argparse
import json
from pathlib import Path
from screen import HERE, SAMPLES, run, sha


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output", type=Path)
    ap.add_argument("--size", type=int, default=1 << 20)
    ap.add_argument("--corpora", default="freedict,gcide,omw")
    ap.add_argument("--classes", type=int, default=0)
    ap.add_argument("--floor", type=float, default=0)
    ap.add_argument("--steps", type=int, default=3)
    ap.add_argument("--once", type=int, default=1)
    ap.add_argument("--activation", type=float, default=0)
    ap.add_argument("--prepare", type=Path, default=HERE / "prepare")
    ap.add_argument("--max-fragment", type=int, default=0)
    ap.add_argument("--preinline", type=int, default=0)
    ap.add_argument("--compiler", type=Path, default=HERE / "compile")
    ap.add_argument("--combined", action="store_true")
    args = ap.parse_args()
    args.prepare = args.prepare.resolve()
    args.compiler = args.compiler.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    fingerprint = {name: sha(HERE / name) for name in ("prepare.cpp", "compile.zig", "prepare", "compile")}
    fingerprint["effective_prepare"] = sha(args.prepare)
    fingerprint["effective_prepare_source"] = sha(args.prepare.with_suffix(".cpp"))
    fingerprint["effective_compiler"] = sha(args.compiler)
    fingerprint["effective_compiler_source"] = sha(args.compiler.with_suffix(".zig"))
    fingerprint["native_backend"] = {p.name: sha(p) for p in sorted((HERE.parents[1] / "bzip4/bz4/v3/src").glob("*.zig"))}
    if args.compiler.name in ("native_role", "native_role_root"):
        backend = "role_backend" if args.compiler.name == "native_role" else "role_root_backend"
        fingerprint["isolated_role_backend"] = {p.name: sha(p) for p in sorted((HERE / backend).glob("*.zig"))}
    for name in args.corpora.split(","):
        raw = args.output / f"{name}.raw"
        data = (SAMPLES / f"{name}-eval8-saved/external-decoded.bin").read_bytes()[:args.size]
        raw.write_bytes(data)
        previous = None
        encoder_ns = 0
        for step in range(args.steps + 1):
            parse = args.output / f"{name}-{step}.parse"
            frame = args.output / f"{name}-{step}.frame"
            decoded = args.output / f"{name}-{step}.decoded"
            command = [args.prepare, raw, parse, "--seed", "all", "--floor", args.floor,
                       "--rounds", 2, "--share", 0, "--once", args.once]
            if args.activation != 0:
                command.extend(["--activation", args.activation])
            if args.max_fragment != 0:
                command.extend(["--max-fragment", args.max_fragment])
            if args.preinline != 0:
                command.extend(["--preinline", args.preinline])
            if previous and not args.combined:
                prices = args.output / f"{name}-{step}.prices"
                priced = run([args.compiler, "prices", previous, prices, args.classes])
                encoder_ns += priced["codec_ns"]
                command.extend(["--prices", prices, "--price-map", str(previous) + ".seeds"])
            elif previous:
                prices = args.output / f"{name}-{step-1}.prices"
                command.extend(["--prices", prices, "--price-map", str(previous) + ".seeds"])
                priced = {"generated_by_previous_combined_compile": True}
            else:
                priced = None
            prep = run(command)
            compile_command = [args.compiler, "compile", parse, frame, args.classes]
            if args.combined and step < args.steps:
                compile_command.append(args.output / f"{name}-{step}.prices")
            compiled = run(compile_command)
            decoded_metrics = run([args.compiler, "decode", frame, decoded])
            if decoded.read_bytes() != data:
                raise RuntimeError("native contextual spelling roundtrip")
            encoder_ns += prep["codec_ns"] + compiled["codec_ns"]
            row = dict(corpus=name, step=step, input_sha256=sha(raw), input_bytes=len(data),
                       fingerprint=fingerprint, policy={"floor": args.floor, "classes": args.classes, "once": args.once,
                                                        "activation": args.activation, "max_fragment": args.max_fragment,
                                                        "preinline": args.preinline, "combined": args.combined},
                       prepare_command=list(map(str, command)), compile_command=list(map(str, compile_command)),
                       prepare=prep, priced=priced, compiled=compiled, decoded=decoded_metrics,
                       all_search_encoder_codec_ns=encoder_ns, frame_sha256=sha(frame))
            if Path(str(parse) + ".roles").exists():
                row["role_training_sidecar_sha256"] = sha(Path(str(parse) + ".roles"))
            with (args.output / "rows.jsonl").open("a") as f:
                f.write(json.dumps(row, sort_keys=True) + "\n")
            print(json.dumps({"corpus": name, "step": step, "frame": compiled["frame_bytes"],
                              "classes": compiled.get("classes"), "entries": prep["entries"]}), flush=True)
            decoded.unlink()
            previous = parse


if __name__ == "__main__":
    main()
