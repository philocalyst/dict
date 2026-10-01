"""Distinguish stored DAG fan-in from repeated execution of a definition.

This diagnostic is deliberately separate from the grammar worker. A rule used
by exactly one stored parent can be substituted into that parent even when
the parent expands thousands of times. Dynamic use count is the wrong measure
of whether that extra stored definition earns its place.
"""

from collections import Counter
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from common import corpus_partition
from grammar import grammar


def main():
    for corpus in ("freedict-eng-spa", "gcide-054", "omw-ja-20"):
        _, data = corpus_partition(corpus, "screen")
        rules, blocks, metrics = grammar._build_grammar(data, 16384)
        fan_in = Counter(ref for block in blocks for ref in block if ref >= 256)
        for rule in rules:
            fan_in.update(ref for ref in rule if ref >= 256)
        single = [index for index in range(len(rules)) if fan_in[index + 256] == 1]
        print(json.dumps({"corpus": corpus, "kind": "stored-fan-in-diagnostic",
                          "rules": len(rules), "stored_once_rules": len(single),
                          "root_events": sum(map(len, blocks)),
                          "rule_references": sum(map(len, rules)),
                          "existing_builder_metrics": metrics}), flush=True)


if __name__ == "__main__":
    main()
