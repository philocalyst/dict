#!/usr/bin/env python3
"""Machine-check the measured comparison ledger in ``EVIDENCE.md``.

The corpus numbers are captured JSON outputs from the bounded commands.  This
small checker deliberately recomputes every reported delta and emits a summary
of the mixed signs, preventing prose from silently turning a first-use win
into an all-loss claim (or vice versa).
"""

from __future__ import annotations

import json


RAW = {
    ("OMW", "first"): {"cut": 61163, "program": 61366},
    ("OMW", "lex"): {"cut": 60132, "program": 60646},
    ("FreeDict", "first"): {"cut": 80785, "program": 81170},
    ("FreeDict", "lex"): {"cut": 87311, "program": 88106},
    ("GCIDE", "first"): {"cut": 90513, "program": 90647},
    ("GCIDE", "lex"): {"cut": 95614, "program": 96830},
    ("words", "first"): {"cut": 86616, "program": 105981},
    ("words", "lex"): {"cut": 86590, "program": 107295},
}

COMMON = {
    ("OMW", "first"): {"cut": (7326, 6448), "program": (7261, 6353)},
    ("OMW", "lex"): {"cut": (6997, 6246), "program": (7107, 6350)},
    ("FreeDict", "first"): {"cut": (10970, 9188), "program": (10899, 9127)},
    ("FreeDict", "lex"): {"cut": (10607, 8739), "program": (10793, 9103)},
    ("GCIDE", "first"): {"cut": (25056, 20120), "program": (24886, 20053)},
    ("GCIDE", "lex"): {"cut": (24129, 18907), "program": (24752, 19990)},
}

PGS = {
    ("OMW", "first"): {"independent": 61769, "cut": 61163, "pgs": 61892},
    ("OMW", "lex"): {"independent": 61063, "cut": 60132, "pgs": 60395},
    ("FreeDict", "first"): {"independent": 81459, "cut": 80785, "pgs": 82180},
    ("FreeDict", "lex"): {"independent": 88447, "cut": 87311, "pgs": 87269},
    ("GCIDE", "first"): {"independent": 91197, "cut": 90513, "pgs": 91402},
    ("GCIDE", "lex"): {"independent": 97479, "cut": 95614, "pgs": 93805},
}

V4 = {"OMW": 8457, "FreeDict": 10872, "GCIDE": 21835}


def validate() -> dict[str, object]:
    raw_delta = {
        f"{dataset}/{order}": row["program"] - row["cut"]
        for (dataset, order), row in RAW.items()
    }
    common_delta = {
        f"{dataset}/{order}": tuple(
            COMMON[(dataset, order)]["program"][i] - COMMON[(dataset, order)]["cut"][i]
            for i in (0, 1)
        )
        for dataset, order in COMMON
    }
    pgs_vs_independent = {
        f"{dataset}/{order}": row["pgs"] - row["independent"]
        for (dataset, order), row in PGS.items()
    }
    pgs_vs_cut = {
        f"{dataset}/{order}": row["pgs"] - row["cut"]
        for (dataset, order), row in PGS.items()
    }

    assert all(value > 0 for value in raw_delta.values())
    assert all(value[0] < 0 and value[1] < 0 for key, value in common_delta.items() if key.endswith("/first"))
    assert all(value[0] > 0 and value[1] > 0 for key, value in common_delta.items() if key.endswith("/lex"))
    assert pgs_vs_independent == {
        "OMW/first": 123,
        "OMW/lex": -668,
        "FreeDict/first": 721,
        "FreeDict/lex": -1178,
        "GCIDE/first": 205,
        "GCIDE/lex": -3674,
    }
    assert pgs_vs_cut == {
        "OMW/first": 729,
        "OMW/lex": 263,
        "FreeDict/first": 1395,
        "FreeDict/lex": -42,
        "GCIDE/first": 889,
        "GCIDE/lex": -1809,
    }
    # Do not assert a blanket v4 comparison: the measured signs intentionally
    # differ by corpus, order, and generic backend.
    return {
        "raw_program_minus_cut": raw_delta,
        "common_program_minus_cut_zlib_bz2": common_delta,
        "pgs_minus_independent": pgs_vs_independent,
        "pgs_minus_cut": pgs_vs_cut,
        "v4_totals": V4,
        "assertions": [
            "raw PPL1 program loses CUT on every dictionary and word-list row",
            "generic program wins first-use CUT on all three dictionaries",
            "generic program loses lex CUT on all three dictionaries",
            "PGS lex beats independent on all three dictionaries",
            "PGS beats raw CUT only on FreeDict/lex and GCIDE/lex",
            "v4 comparison is intentionally mixed-sign and not blanket-asserted",
        ],
    }


def main() -> int:
    print(json.dumps(validate(), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
