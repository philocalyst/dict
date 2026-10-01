#!/usr/bin/env python3
"""Condense complete paired dictionary evidence without dropping setup or losses."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def read(path):
    data = path.read_bytes()
    report = json.loads(data)
    if report.get("status") != "complete-verified":
        raise ValueError(f"incomplete evidence: {path}")
    return report, {"name": path.parent.name, "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    names = ["dictionary-final-20261001", "dictionary-rich-final-20261001",
             "dictionary-natural-final-20261001"]
    reports, provenance = [], []
    for name in names:
        report, fingerprint = read(args.scratch / name / "results.json")
        reports.append(report)
        provenance.append(fingerprint)
    real, rich, natural = reports
    result = {"schema": 1, "status": "summary-of-complete-verified-evidence",
              "baseline_commit": "eda533210ddfa8901a4fde66b558bd84e4e3b555",
              "reports": provenance, "binaries": {n: r["binaries"] for n, r in zip(names, reports)},
              "limitations": [
                  "Natural inputs are exact headword/definition projections, not complete original XML/RDF semantics.",
                  "Wire access requires full semantic verification of the immutable archive, charged separately.",
                  "Page cache is an application cache over memory-resident, previously touched archive bytes.",
                  "Rich fixture has repeated bodies; its storage result does not establish natural-corpus gains.",
                  "Rich allocation figures cover Zig allocator requests, excluding native bzip3 allocations.",
                  "Natural access consumes the complete headword and definition in every measured operation.",
                  "Optional identity index bytes are included in rich candidate access artifacts."
              ], "storage_and_native_operations": [], "rich": [], "natural": []}
    for corpus in real["corpora"]:
        for lane in corpus["lanes"]:
            sizes = []
            for target in sorted({x["target_page_bytes"] for x in lane["sizes"]}):
                artifacts = {x["lane"]: x["artifact"] for x in lane["sizes"]
                             if x["target_page_bytes"] == target}
                before, after = (artifacts[k]["bytes"] for k in ("before", "after"))
                sizes.append({"target_page_bytes": target, "artifacts": artifacts,
                              "after_change_percent": 100 * (after / before - 1)})
            result["storage_and_native_operations"].append({"name": corpus["name"],
                "codec": lane["codec"], "projection": corpus["projection"],
                "entries": corpus["records"], "sizes": sizes, "native_phases": lane["summary"],
                "legacy_v2_admission": lane["legacy_read"]})
    for lane in rich["lanes"]:
        result["rich"].append({"compression": lane["compression"], "entries": rich["entries"],
                               "pairs": rich["pairs"], "phases": lane["summary"]})
    for lane in natural["lanes"]:
        item = {k: lane[k] for k in ("name", "codec", "entries", "projection", "artifacts",
                                    "oracle_consumed_bytes", "independent_admission", "summary")}
        comparisons = {}
        for workload in ("samepage", "mixed"):
            native, wire = f"native_{workload}_access", f"wire_{workload}_access"
            pairs = zip(lane["samples"]["before"], lane["samples"]["after"])
            ratios = []
            for b, a in pairs:
                bp, ap = b["phases"][native], a["phases"][wire]
                if (bp["checksum"], bp["consumed_bytes"], bp["operations"]) != (
                        ap["checksum"], ap["consumed_bytes"], ap["operations"]):
                    raise ValueError("mismatched measured work")
                ratios.append(bp["ns"] / ap["ns"])
            phases = lane["summary"]
            b = phases["before"]["phases"][native]
            a = phases["after"]["phases"][wire]
            setup = phases["after"]["phases"]["full_semantic_verification"]["ns"]["median"]
            saving = (b["ns"]["median"] - a["ns"]["median"]) / b["operations"]
            comparisons[workload] = {"before_native_over_after_wire_paired_ratio": {
                "median": statistics.median(ratios), "min": min(ratios), "max": max(ratios)},
                "median_verification_amortization_operations": math.ceil(setup / saving) if saving > 0 else None,
                "amortization_definition": "candidate full verification divided by median per-operation saving; excludes open and reader init; estimates repeated equivalent workload"}
        item["comparisons"] = comparisons
        result["natural"].append(item)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
