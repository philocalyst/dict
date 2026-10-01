#!/usr/bin/env python3
"""Small causal/normalization checks for the diagnostic circuit."""

from __future__ import annotations

import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from circuit_probe import ALPHABET, ROWS, logp, tables


def main() -> int:
    # Include an empty type to exercise the start(END) branch even though the
    # v4 atom scanner normally yields non-empty atoms.
    types = [b"", b"a", b"ab", b"ba"]
    counts, prior = tables(types, [0, 0, 1, 1], 2)
    assert len(counts) == 2 and all(len(rows) == ROWS for rows in counts)
    assert all(len(row) == ALPHABET for row in counts[0])
    assert prior == [3, 3]

    # Every component is a proper variable-length generator: start chooses
    # END or its first byte; interior repeatedly chooses END or another byte.
    # The finite-prefix mass approaches one geometrically, with no oracle
    # final-position row or supplied length.
    for component in range(2):
        start, interior = counts[component]
        start_total = sum(start)
        interior_total = sum(interior)
        p_empty = start[256] / start_total
        p_first_nonempty = sum(start[:256]) / start_total
        p_end = interior[256] / interior_total
        assert math.isclose(p_empty + p_first_nonempty, 1.0)
        assert 0.0 < p_end < 1.0
        finite_mass = p_empty + p_first_nonempty * (1.0 - (1.0 - p_end) ** 2048)
        assert finite_mass < 1.0 and finite_mass > 0.99

        # The same interior row prices END after a one-byte and a two-byte
        # word; the score does not inspect a caller-provided final length.
        assert math.isfinite(logp(b"a", component, counts))
        assert math.isfinite(logp(b"ab", component, counts))
        assert logp(b"a", component, counts) != logp(b"ab", component, counts)

    print("tests=causal_rows,variable_length_normalization,empty_word")
    print("status=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
