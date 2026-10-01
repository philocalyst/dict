"""Quantify unreachable-rank probability mass, not a serialized codec result.

The alphabet mask already stored in every BWT block implies that only RUNA,
RUNB, ranks 1..k-1 and EOB can occur: event IDs 0..k+1. This diagnostic gives
the ideal coding reduction from conditioning a shared table on that known set.
It deliberately does not pretend decoder-table preparation is free.
"""

import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bwt_context import codec
from common import corpus_partition


def main():
    for corpus in ("freedict-eng-spa", "gcide-054", "omw-ja-20"):
        training, screen = corpus_partition(corpus, "screen")
        for boundary in (16384, 65536):
            model = codec.train(training, "A", boundary)
            table = model.tables[0]
            rows = []
            ideal_saved_bits = 0.0
            for offset in range(0, len(screen), boundary):
                last, _ = codec._bwt_transform(screen[offset:offset + boundary])
                tokens, mask = codec._mtf_tokens(last)
                alphabet = sum(byte.bit_count() for byte in mask)
                reachable_mass = sum(table[:alphabet + 2])
                saved = len(tokens) * math.log2(4096 / reachable_mass)
                ideal_saved_bits += saved
                rows.append({"alphabet": alphabet, "events": len(tokens),
                             "unreachable_mass": 4096 - reachable_mass,
                             "ideal_saved_bits": saved})
            print(json.dumps({"corpus": corpus, "block_bytes": boundary,
                              "kind": "analytical-bound-not-coded-size",
                              "training_bytes": len(training),
                              "screen_bytes": len(screen),
                              "frequency_one_symbols": table.count(1),
                              "ideal_saved_bytes": ideal_saved_bits / 8,
                              "blocks": rows}), flush=True)


if __name__ == "__main__":
    main()
