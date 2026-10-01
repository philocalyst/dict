"""Lead's independent same-slice size controls. No timing claim is made."""

from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from common import CORPUS_SPECS, corpus_partition
from protocol import bzip3_decode, bzip3_decode_block, bzip3_encode_blocks


def main():
    for corpus in CORPUS_SPECS:
        training, data = corpus_partition(corpus, "screen")
        for boundary in (16384, 65536):
            frame = bzip3_encode_blocks(data, boundary)
            assert bzip3_decode(frame) == data
            independent = b"".join(
                bzip3_decode_block(frame, i)
                for i in range((len(data) + boundary - 1) // boundary)
            )
            assert independent == data
            print(json.dumps({
                "corpus": corpus,
                "lane": "screen",
                "raw_bytes": len(data),
                "training_bytes": len(training),
                "block_bytes": boundary,
                "complete_bytes": len(frame),
                "data_sha256": hashlib.sha256(data).hexdigest(),
                "frame_sha256": hashlib.sha256(frame).hexdigest(),
                "control": "native bzip3 with actual 32+16*N framing",
                "roundtrip": "all and every independent block",
                "timing": "not measured",
            }), flush=True)


if __name__ == "__main__":
    main()
