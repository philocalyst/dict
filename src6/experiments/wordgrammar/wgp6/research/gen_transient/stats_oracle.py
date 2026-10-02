#!/usr/bin/env python3
"""Price real fitted WGP6 token placements with unchanged v3 Stats.

Private research bridge: regenerates the best complete WGP6 candidate while
retaining its P6P1 parse, translates that parse losslessly to the old lab's
B4SD interchange, and extracts its native fitted per-byte Stats ledger.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
WGP6 = HERE.parents[1]


def run(command: list[object]) -> dict:
    p = subprocess.run(list(map(str, command)), check=True, capture_output=True, text=True)
    return json.loads(p.stdout)


def arrays(raw: bytes) -> tuple[list[int], list[int], list[int], list[int]]:
    if not raw.startswith(b"P6P1"):
        raise ValueError("not P6P1")
    at = 4
    result = []
    for _ in range(4):
        n, = struct.unpack_from("<I", raw, at); at += 4
        vals = list(struct.unpack_from(f"<{n}I", raw, at)); at += 4 * n
        result.append(vals)
    if at != len(raw):
        raise ValueError("trailing P6P1 bytes")
    return tuple(result)  # type: ignore[return-value]


def to_b4sd(parse: Path, output: Path) -> None:
    body_off, kids, block_off, toks = arrays(parse.read_bytes())
    words = [0x44533442, 2, len(body_off) - 1, len(block_off) - 1, 0, 0]
    for e in range(len(body_off) - 1):
        body = kids[body_off[e]:body_off[e + 1]]
        words.append(len(body)); words.extend(body)
    for b in range(len(block_off) - 1):
        block = toks[block_off[b]:block_off[b + 1]]
        words.append(len(block)); words.extend(block)
    output.write_bytes(struct.pack(f"<{len(words)}I", *words))


def best_parse(source: Path, work: Path) -> tuple[Path, dict]:
    prep = WGP6 / "prepare_maximal"
    native = WGP6 / "native"
    block = 65536
    old_path = work / "old.frame"
    old = run([native, "original", source, old_path, block])
    best_size, best_parse_path, selected = old["frame_bytes"], None, "native_old"
    previous = None
    rows = []
    for step in range(5):
        parse = work / f"{step}.parse"
        frame = work / f"{step}.frame"
        prices = work / f"{step}.prices"
        command: list[object] = [prep, source, parse, "--block", block, "--seed", "all",
                                 "--capacity", 200000, "--max-fragment", 128, "--floor", 0,
                                 "--rounds", 2, "--share", 0, "--once", 1]
        if previous is not None:
            command += ["--prices", work / f"{step - 1}.prices", "--price-map", str(previous) + ".seeds"]
        prepared = run(command)
        compile_command: list[object] = [native, "compile", parse, frame, 0]
        if step < 4:
            compile_command.append(prices)
        compiled = run(compile_command)
        rows.append({"step": step, "bytes": compiled["frame_bytes"]})
        if compiled["frame_bytes"] < best_size:
            best_size, best_parse_path, selected = compiled["frame_bytes"], parse, f"maximal_round_{step}"
        previous = parse
    if best_parse_path is None:
        raise RuntimeError("native fallback was selected; no WGP6 parse to price")
    return best_parse_path, {"selected": selected, "frame_bytes": best_size, "candidates": rows}


def expanded(parse: Path) -> tuple[list[int], list[int], list[int], list[int], list[bytes]]:
    body_off, kids, block_off, toks = arrays(parse.read_bytes())
    memo: dict[int, bytes] = {}
    def entry(e: int) -> bytes:
        if e in memo:
            return memo[e]
        out = bytearray()
        preceding = 0
        for kid in kids[body_off[e]:body_off[e + 1]]:
            if kid >= 0xffffff00:
                retained = kid - 0xffffff00
                if retained > preceding:
                    raise ValueError("invalid cut")
                del out[len(out) - preceding + retained:]
                preceding = retained
                continue
            part = bytes([kid]) if kid < 256 else entry(kid - 256)
            out.extend(part)
            preceding = len(part)
        memo[e] = bytes(out)
        return memo[e]
    texts = [bytes([t]) if t < 256 else entry(t - 256) for t in toks]
    return body_off, kids, block_off, toks, texts


def atom_word(s: bytes) -> bool:
    if not s:
        return False
    def k(c: int) -> int:
        return 0 if c >= 128 or 65 <= c <= 90 or 97 <= c <= 122 else 1 if 48 <= c <= 57 else 2
    ks = {k(c) for c in s}
    return len(ks) == 1 and 2 not in ks


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("output", type=Path, help="JSON oracle result")
    ap.add_argument("--native", type=Path, default=Path("/tmp/wgp6-stats-native"))
    a = ap.parse_args()
    import hashlib
    with tempfile.TemporaryDirectory(prefix="wgp6-gen-oracle-") as d:
        work = Path(d)
        raw = work / "source.raw"
        data = a.source.read_bytes()[:1 << 20]
        raw.write_bytes(data)
        parse, candidate = best_parse(raw, work)
        prefix = work / "oracle"
        p = subprocess.run([str(a.native), str(raw), str(parse), str(prefix)], check=True, capture_output=True, text=True)
        metrics = json.loads((work / "oracle.stats.json").read_text())
        body_off, kids, block_off, toks, texts = expanded(parse)
        if sum(map(len, texts)) != len(data):
            raise ValueError("expanded parse root stream does not cover source byte-for-byte")
        token_bits = struct.unpack(f"<{len(toks)}d", (work / "oracle.token_bits.f64").read_bytes())
        name_bits = struct.unpack(f"<{len(toks)}d", (work / "oracle.name_bits.f64").read_bytes())
        def_bits = struct.unpack(f"<{len(toks)}d", (work / "oracle.def_bits.f64").read_bytes())
        if not (len(token_bits) == len(name_bits) == len(def_bits) == len(texts)):
            raise ValueError("Stats/token stream length mismatch")
        groups: dict[bytes, list[int]] = {}
        for i, text in enumerate(texts):
            if atom_word(text) and toks[i] >= 256:
                groups.setdefault(text, []).append(i)
        singleton = []
        all_word_activation = 0.0
        all_word_name = 0.0
        all_word_def = 0.0
        singleton_token_total = 0.0
        singleton_non_name_def_total = 0.0
        for text, ix in groups.items():
            # Repeated identical spellings are one candidate realization, so
            # credit can only be claimed once, at its first payload placement.
            first = ix[0]
            all_word_name += sum(name_bits[i] for i in ix)
            all_word_def += sum(def_bits[i] for i in ix)
            all_word_activation += name_bits[first] + def_bits[first]
            if len(ix) == 1:
                singleton.append({"utf8_bytes": len(text), "occurrences": 1,
                                  "token_bits": token_bits[first], "name_bits": name_bits[first],
                                  "def_bits": def_bits[first], "word_hex": text.hex()})
                singleton_token_total += token_bits[first]
                singleton_non_name_def_total += token_bits[first] - name_bits[first] - def_bits[first]
        singleton.sort(key=lambda x: x["name_bits"] + x["def_bits"], reverse=True)
        result = {"scope": "retained old DEV prefix only; actual WGP6 maximal complete-frame winner and unchanged v3 fit/encoder pricing",
                  "corpus": a.source.name, "input_bytes": len(data),
                  "input_sha256": hashlib.sha256(data).hexdigest(),
                  "wgp6": candidate, "native_stats": metrics,
                  "parse_sha256": hashlib.sha256(parse.read_bytes()).hexdigest(),
                  "parse_cut_symbols": sum(k >= 0xffffff00 for k in kids),
                  "expanded_root_bytes": sum(map(len, texts)),
                  "word_identity_groups": len(groups),
                  "word_root_occurrences": sum(len(x) for x in groups.values()),
                  "all_word_activation_name_plus_def_bits": all_word_activation,
                  "all_word_name_bits": all_word_name, "all_word_def_bits": all_word_def,
                  "singleton_word_types": len(singleton),
                  "singleton_activation_name_plus_def_bits": sum(x["name_bits"] + x["def_bits"] for x in singleton),
                  "singleton_full_token_bits": singleton_token_total,
                  "singleton_retained_bits_outside_name_def": singleton_non_name_def_total,
                  "singleton_details_top64": singleton[:64],
                  "interpretation": "Gross upper bound only: subtracts only exact NAME and DEF event prices for standalone word-root activations. It does not credit source child/ARITY costs, fitting/model-size changes, or charge any GEN command, operand, cache-control, or new event-row costs. Not a net win estimate."}
        a.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"corpus": a.source.name, "frame_bytes": candidate["frame_bytes"],
                          "word_groups": len(groups), "singleton": len(singleton),
                          "singleton_name_def_credit_bits": result["singleton_activation_name_plus_def_bits"],
                          "all_word_activation_bits": all_word_activation,
                          "retained_metrics": metrics}))


if __name__ == "__main__":
    main()
