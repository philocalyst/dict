#!/usr/bin/env python3
"""Development-only fixed joint spelling/root reparse of the M inventory.

The same bounded byte-DP policy is used for every corpus. All learning,
refitting, pricing, and intermediate trials are charged in encoder time.
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
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--reference", type=Path, default=HERE / "m_reference")
    ap.add_argument("--compiler", type=Path, default=HERE / "native_forward")
    args = ap.parse_args()
    if args.size < 0 or args.size > 64 << 20 or args.rounds < 0 or args.rounds > 8:
        ap.error("development screen budget")
    args.reference = args.reference.resolve()
    args.compiler = args.compiler.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    fingerprint = {name: sha(HERE / name) for name in (
        "m_reference.zig", "learner_epochs.zig", "lifetime_fit.zig", "budget.zig",
        "reparse_context.cpp", "reparse_context", args.compiler.with_suffix(".zig").name)}
    fingerprint["effective_reference_binary"] = sha(args.reference)
    fingerprint["effective_compiler_binary"] = sha(args.compiler)
    fingerprint["original_learner"] = {name: sha(HERE / "../../bzip4/bz4" / name)
                                       for name in ("grammar2.zig", "m_lexicon.zig")}
    fingerprint["original_native_backend"] = {p.name: sha(p) for p in
        sorted((HERE / "../../bzip4/bz4/v3/src").glob("*.zig"))}
    for name in args.corpora.split(","):
        if name not in ("freedict", "gcide", "omw"):
            ap.error("only retained old development corpora are admitted")
        raw = args.output / f"{name}.raw"
        data = (SAMPLES / f"{name}-eval8-saved/external-decoded.bin").read_bytes()[:args.size]
        raw.write_bytes(data)
        frame = args.output / f"{name}-0.frame"
        graph = args.output / f"{name}-0.forward"
        baseline = run([args.reference, raw, frame, graph, 65536, 20, "a-best", 1, 0])
        encoder_ns = baseline["codec_ns"]
        best_bytes, best_step = baseline["frame_bytes"], 0
        previous = graph
        for step in range(args.rounds + 1):
            frame = args.output / f"{name}-{step}.frame"
            price = args.output / f"{name}-{step}.prices"
            if step == 0:
                preparation = baseline
            else:
                graph = args.output / f"{name}-{step}.forward"
                preparation = run([HERE / "reparse_context", raw, previous,
                                   args.output / f"{name}-{step-1}.prices", graph, "both", 0])
                encoder_ns += preparation["codec_ns"]
                previous = graph
            command = [args.compiler, "compile", previous, frame, 0]
            if step < args.rounds:
                command.append(price)
            old_bytes = frame.read_bytes() if step == 0 else None
            encoded = run(command)
            if old_bytes is not None and frame.read_bytes() != old_bytes:
                raise RuntimeError("reference and repricing compiler emitted different frames")
            encoder_ns += encoded["codec_ns"]
            decoded = args.output / f"{name}-{step}.decoded"
            decode_metrics = run([args.compiler, "decode", frame, decoded])
            if decoded.read_bytes() != data:
                raise RuntimeError("fresh full decode differs from raw development bytes")
            decoded.unlink()
            if encoded["frame_bytes"] < best_bytes:
                best_bytes, best_step = encoded["frame_bytes"], step
            row = dict(corpus=name, step=step, baseline=baseline, prepare=preparation,
                       encoded=encoded, decoded=decode_metrics, input_sha256=sha(raw),
                       frame_sha256=sha(frame), fingerprint=fingerprint,
                       policy={"seed": "a-best", "max_iters": 20, "triples": True,
                               "block_bytes": 65536, "mode": "both", "prune": False,
                               "rounds": args.rounds, "native_classes": "automatic"},
                       all_encoder_codec_ns=encoder_ns, best_frame_bytes=best_bytes,
                       best_step=best_step)
            with (args.output / "rows.jsonl").open("a") as out:
                out.write(json.dumps(row, sort_keys=True) + "\n")
            print(json.dumps({"corpus": name, "step": step, "frame": encoded["frame_bytes"],
                              "best": best_bytes, "classes": encoded["classes"]}), flush=True)


if __name__ == "__main__":
    main()
