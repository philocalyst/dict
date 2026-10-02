#!/usr/bin/env python3
"""SWC development only: paid ablations on pinned development prefixes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

NAMES = [
    "omw-ja-20-content-development", "omw-cmn-20-content-development",
    "gcide-debian-054-content-development", "freedict-spa-eng-content-development",
    "freedict-eng-fra-content-development", "ud-zh-prose-development",
    "ud-ja-prose-development", "ud-ru-prose-development", "ud-es-prose-development",
    "ud-en-prose-development", "ud-multilingual-prose-development",
]
PROFILES = {
    "no_grammar": {"SWC_RULE_CAP": "0", "SWC_COPY_MIN": "0"},
    "grammar_512": {"SWC_RULE_CAP": "512", "SWC_COPY_MIN": "0"},
    "grammar_2048": {"SWC_RULE_CAP": "2048", "SWC_COPY_MIN": "0"},
    "no_lexicon": {"SWC_RULE_CAP": "2048", "SWC_COPY_MIN": "0", "SWC_WORD_CAP": "0"},
    "byte_fallback": {"SWC_RULE_CAP": "2048", "SWC_COPY_MIN": "0", "SWC_SCALARS": "0"},
    "recent_copy": {"SWC_RULE_CAP": "2048", "SWC_COPY_MIN": "13"},
    "recent_copy_8": {"SWC_RULE_CAP": "2048", "SWC_COPY_MIN": "8"},
}

def run(cmd, **kwargs):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if p.returncode:
        raise RuntimeError(f"{cmd}: {p.stderr.decode(errors='replace')[-2000:]}")
    return p

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="/workspace/scratch/frontier-corpora/manifest.json")
    ap.add_argument("--bytes", type=int, default=262144)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    manifest = json.loads(Path(args.manifest).read_text())
    corpora = {c["name"]: c for c in manifest["corpora"]}
    binary = Path(__file__).with_name("swc")
    with tempfile.TemporaryDirectory(prefix="swc-development-") as tmp, open(args.output, "w") as ledger:
        tmp = Path(tmp)
        for name in NAMES:
            row = corpora[name]
            assert row["split"] == "development" and "development" in str(row["path"])
            source = Path(row["path"]).read_bytes()[:args.bytes]
            source_path = tmp / "source.bin"
            source_path.write_bytes(source)
            # Whole-file bzip3, not a same-restart baseline. Kept separate.
            bz = run(["/workspace/scratch/bzip3", "-c", str(source_path)]).stdout
            base = {"name": name, "raw": len(source), "sha256": hashlib.sha256(source).hexdigest(),
                    "whole_bzip3": len(bz), "scope": "development-prefix", "prefix_cap": args.bytes}
            for profile, settings in PROFILES.items():
                archive, restored = tmp / "frame.swc", tmp / "restored.bin"
                env = os.environ.copy()
                for key in ("SWC_RULE_CAP", "SWC_COPY_MIN", "SWC_WORD_CAP", "SWC_SCALARS"):
                    env.pop(key, None)
                env.update(settings)
                enc = run([str(binary), "encode", str(source_path), str(archive)], env=env)
                dec = run([str(binary), "decode", str(archive), str(restored)])
                if restored.read_bytes() != source:
                    raise RuntimeError(f"full parity failed: {name} {profile}")
                for i in range((len(source)+65535)//65536):
                    run([str(binary), "decode", str(archive), str(restored), str(i)])
                    if restored.read_bytes() != source[i*65536:(i+1)*65536]:
                        raise RuntimeError(f"restart parity failed: {name} {profile} block {i}")
                metadata = json.loads(enc.stderr.decode().splitlines()[0])
                ledger.write(json.dumps({**base, "profile": profile, "settings": settings,
                                         "encode_ms": int(enc.stderr.decode().split("encode_ms=")[1].splitlines()[0]),
                                         "decode_ms": int(dec.stderr.decode().split("decode_ms=")[1].splitlines()[0]),
                                         **metadata}, sort_keys=True) + "\n")
                ledger.flush()
                print(name, profile, metadata["frame"], "bzip3", len(bz), flush=True)

if __name__ == "__main__":
    main()
