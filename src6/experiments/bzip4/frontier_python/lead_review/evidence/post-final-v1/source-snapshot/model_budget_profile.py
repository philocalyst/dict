"""Standard-codec diagnostic for the stored model's remaining entropy.

These are NOT new Bzip4 frames or candidate decoder measurements. The complete
bz2/zlib streams are measured only as empirical model-blob controls, with exact
roundtrip. Any future model wire must include its own tags/lengths/checksums,
portable decoder, scratch, and startup costs inside the reported model budget.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import json
from pathlib import Path
import zlib


def profile(summary: dict, streams: Path) -> list[dict]:
    streams.mkdir(parents=True, exist_ok=False)
    rows = [item["result"] for item in summary["records"]]
    controls = {(row["corpus"], row["lane"], row["block_bytes"]): row for row in rows if row["variant"] == "native"}
    results = []
    for row in rows:
        if row["variant"] != "symbol_bwt":
            continue
        frame = Path(row["frame_path"]).read_bytes()
        assert hashlib.sha256(frame).hexdigest() == row["frame_sha256"]
        header_bytes = row["metrics"]["header_bytes"]
        model_bytes = row["metrics"]["model_bytes"]
        model = frame[header_bytes : header_bytes + model_bytes]
        encoded_bz2 = bz2.compress(model, compresslevel=9)
        encoded_zlib = zlib.compress(model, level=9)
        assert bz2.decompress(encoded_bz2) == model
        assert zlib.decompress(encoded_zlib) == model
        stem = f"{row['corpus']}.{row['lane']}.b{row['block_bytes']}.model"
        saved = {}
        for kind, encoded in (("bz2", encoded_bz2), ("zlib", encoded_zlib)):
            path = streams / f"{stem}.{kind}"
            with path.open("xb") as handle:
                handle.write(encoded)
            saved[kind] = {"path": str(path), "bytes": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}
        control = controls[(row["corpus"], row["lane"], row["block_bytes"])]
        fixed_bytes = len(frame) - len(model)
        results.append({
            "corpus": row["corpus"],
            "lane": row["lane"],
            "block_bytes": row["block_bytes"],
            "frame_sha256": row["frame_sha256"],
            "model_sha256": hashlib.sha256(model).hexdigest(),
            "stored_model_bytes": len(model),
            "bz2_complete_model_stream_bytes": len(encoded_bz2),
            "zlib_complete_model_stream_bytes": len(encoded_zlib),
            "fixed_other_candidate_bytes": fixed_bytes,
            "native_complete_bytes": control["frame_bytes"],
            "model_and_any_new_framing_budget_to_tie_native": control["frame_bytes"] - fixed_bytes,
            "saved_standard_codec_streams": saved,
        })
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--streams-dir", type=Path, required=True)
    args = parser.parse_args()
    summary = json.loads((args.root / "results.json").read_text())
    assert summary["status"] == 0
    print(json.dumps({
        "status": "pass",
        "timing_disabled": True,
        "diagnostic_only": True,
        "not_a_candidate_frame_or_native_decoder_claim": True,
        "codecs": {"bz2": "Python standard-library libbz2 binding, level 9", "zlib": f"Python standard-library zlib binding {zlib.ZLIB_RUNTIME_VERSION}, level 9"},
        "records": profile(summary, args.streams_dir),
    }, sort_keys=True))
