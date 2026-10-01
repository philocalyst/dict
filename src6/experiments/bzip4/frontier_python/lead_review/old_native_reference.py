"""Replicate the frozen native round-two codec without rewriting old evidence.

This is a size/correctness run only. Timings from other active research jobs
must not be mistaken for a quiet-lane native performance comparison.
"""

import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from common import corpus_spec, load_corpus
from protocol.capture import run_and_save

BINARY = Path("/tmp/bzip4-install/bin/bzip4-experiment")
EXPECTED = "a0ff2f567e9eed41f00f0365c7d2a5538f020bd020fd994e420ba0c45436cf8f"


def main():
    digest = hashlib.sha256(BINARY.read_bytes()).hexdigest()
    if digest != EXPECTED:
        raise RuntimeError("Frozen native binary hash mismatch")
    for corpus in ("freedict-eng-spa", "gcide-054", "omw-ja-20"):
        load_corpus(corpus)  # independently enforce the pinned complete source
        spec = corpus_spec(corpus)
        for boundary in (16384, 65536):
            capture = run_and_save(
                [BINARY, "--input", spec.projection_path, "--input-format", "projection_content",
                 "--candidate", "bwt", "--training-bytes", "1048576",
                 "--max-eval-bytes", "8388608", "--block-bytes", str(boundary)],
                cwd=ROOT.parents[3], raw_root=ROOT / "lead_review/evidence/old-native-size-1",
                stem=f"{corpus}-{boundary}", timeout=180,
            )
            if capture.returncode != 0:
                raise RuntimeError(f"Native reference failed: {corpus}/{boundary}")
            pairs = [line.split("\t", 1) for line in capture.stdout.decode().splitlines()]
            record = dict(pairs)
            if len(record) != len(pairs) or record.get("roundtrip") != "ok":
                raise RuntimeError("Malformed or failed native reference record")
            print(json.dumps({"corpus": corpus, "block_bytes": boundary,
                              "binary_sha256": digest, "timing": "not-measured",
                              "metrics": record}), flush=True)


if __name__ == "__main__":
    main()
