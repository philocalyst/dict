#!/usr/bin/env python3
"""MDL-gated productive stem/tail source with exact-identity fallback.

This is a development type-inventory diagnostic, not a WGP6 frame.  It reuses
the scanner and cost helpers in lexical_factor_probe.py.  Proposed families
are fixed from repeated byte-exact stems, grouped by modal prefix/suffix
signature, and limited to four common signatures per class.  A family is
activated only when its separately charged class source saves more model bits
than its measured H(T|class(S)) - H(T|S) penalty.  Rejected or irregular forms
remain identity stems with the empty signature.

The delivered representation has a stem->class map and a per-class signature
support table.  It sends stem and tail symbols per occurrence; it never sends
an occupied pair list or a word-ID permutation.  Class support therefore
permits unseen stem/tail combinations.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import lexical_factor_probe as lp

EMPTY = (b"", b"")
MAX_ROOT = 12
MAX_TAILS = 4
MIN_STEMS_PER_TAIL = 2
MIN_FORMS_PER_STEM = 2
MIN_ACTIVE_STEMS = 2


class CountOnly:
    def __init__(self, n: int):
        self.n = n

    def __len__(self) -> int:
        return self.n


@dataclass
class SubInventory:
    names: list[bytes]
    counts: list[int]
    ids: dict[bytes, int]
    token_ids: CountOnly


def family_splits(inv: lp.Inventory) -> tuple[list[tuple[bytes, tuple[bytes, bytes]]], list[bool], dict[str, int]]:
    """Choose repeated codepoint-boundary cores, including a whole-word core.

    The whole-word option matters for a lemma that is also the stem of longer
    forms (for example walk / walked).  It is accepted only when that complete
    word also occurs as a proper substring in at least one other type.
    """
    decoded: list[tuple[str, ...] | None] = []
    subcount: collections.Counter[str] = collections.Counter()
    for word in inv.names:
        try:
            cps = tuple(word.decode("utf-8", "strict"))
        except UnicodeDecodeError:
            decoded.append(None)
            continue
        if len(cps) > 64:
            decoded.append(None)
            continue
        decoded.append(cps)
        seen: set[str] = set()
        for i in range(len(cps)):
            for j in range(i + 2, min(len(cps), i + MAX_ROOT) + 1):
                # Count full forms too; a repeated full form can be a stem
                # whose realization has an empty tail.
                seen.add("".join(cps[i:j]))
        subcount.update(seen)

    result: list[tuple[bytes, tuple[bytes, bytes]]] = []
    candidate: list[bool] = []
    for word, cps in zip(inv.names, decoded):
        if cps is None:
            result.append((word, EMPTY))
            candidate.append(False)
            continue
        best: tuple[float, int, int, bytes, bytes, bytes] | None = None
        chosen = (word, EMPTY)
        for i in range(len(cps)):
            for j in range(i + 2, min(len(cps), i + MAX_ROOT) + 1):
                core = "".join(cps[i:j])
                support = subcount[core]
                if support < 2:
                    continue
                core_b = core.encode("utf-8")
                pre_b = "".join(cps[:i]).encode("utf-8")
                suf_b = "".join(cps[j:]).encode("utf-8")
                score = len(core_b) * (support - 1) / support
                key = (score, support, len(core_b), bytes(255 - b for b in core_b), pre_b, suf_b)
                if best is None or key > best:
                    best = key
                    chosen = (core_b, (pre_b, suf_b))
        if best is None:
            result.append((word, EMPTY))
            candidate.append(False)
        else:
            result.append(chosen)
            candidate.append(True)
    return result, candidate, {"candidate_substrings": len(subcount)}


def subinventory(inv: lp.Inventory, ids: list[int]) -> SubInventory:
    names = [inv.names[i] for i in ids]
    counts = [inv.counts[i] for i in ids]
    return SubInventory(
        names=names,
        counts=counts,
        ids={w: i for i, w in enumerate(names)},
        token_ids=CountOnly(sum(counts)),
    )


def propose_classes(inv: lp.Inventory, splits, is_candidate) -> list[dict]:
    forms: dict[bytes, dict[tuple[bytes, bytes], list[int]]] = collections.defaultdict(lambda: collections.defaultdict(list))
    for wid, ((stem, tail), candidate) in enumerate(zip(splits, is_candidate)):
        if candidate:
            forms[stem][tail].append(wid)

    by_modal_tail: dict[tuple[bytes, bytes], list[bytes]] = collections.defaultdict(list)
    for stem, tails in forms.items():
        if len(tails) < MIN_FORMS_PER_STEM:
            continue
        mass = {tail: sum(inv.counts[w] for w in wids) for tail, wids in tails.items()}
        modal = min(mass, key=lambda t: (-mass[t], t))
        by_modal_tail[modal].append(stem)

    proposed: list[dict] = []
    structural_rejects: list[dict] = []
    for modal, stems in sorted(by_modal_tail.items()):
        if len(stems) < MIN_ACTIVE_STEMS:
            structural_rejects.append({
                "key": [modal[0].hex(), modal[1].hex()],
                "reason": "fewer_than_two_stems_in_modal_tail_group",
                "candidate_stems": len(stems),
                "candidate_types": sum(len(wids) for stem in stems for wids in forms[stem].values()),
            })
            continue
        support_stems: collections.Counter[tuple[bytes, bytes]] = collections.Counter()
        support_mass: collections.Counter[tuple[bytes, bytes]] = collections.Counter()
        for stem in stems:
            for tail, wids in forms[stem].items():
                support_stems[tail] += 1
                support_mass[tail] += sum(inv.counts[w] for w in wids)
        common = [t for t, n in support_stems.items() if n >= MIN_STEMS_PER_TAIL]
        if modal not in common:
            common.append(modal)
        common = sorted(common, key=lambda t: (-support_mass[t], t))
        selected = [modal] + [t for t in common if t != modal][: MAX_TAILS - 1]
        selected = list(dict.fromkeys(selected))
        if len(selected) < 2:
            structural_rejects.append({
                "key": [modal[0].hex(), modal[1].hex()],
                "reason": "fewer_than_two_common_tail_signatures",
                "candidate_stems": len(stems),
                "candidate_types": sum(len(wids) for stem in stems for wids in forms[stem].values()),
            })
            continue

        active_stems: list[bytes] = []
        active_types: list[int] = []
        for stem in stems:
            supported = [t for t in selected if t in forms[stem]]
            if len(supported) < MIN_FORMS_PER_STEM:
                continue
            active_stems.append(stem)
            for tail in supported:
                active_types.extend(forms[stem][tail])
        if len(active_stems) < MIN_ACTIVE_STEMS:
            structural_rejects.append({
                "key": [modal[0].hex(), modal[1].hex()],
                "reason": "fewer_than_two_stems_with_two_supported_forms",
                "candidate_stems": len(stems),
                "candidate_types": sum(len(wids) for stem in stems for wids in forms[stem].values()),
                "selected_tail_count": len(selected),
            })
            continue
        active_types = sorted(set(active_types))
        active_support = sorted({splits[i][1] for i in active_types})
        if len(active_support) < 2:
            structural_rejects.append({
                "key": [modal[0].hex(), modal[1].hex()],
                "reason": "active_family_has_fewer_than_two_tail_signatures",
                "candidate_stems": len(stems),
                "active_stems": len(active_stems),
                "candidate_types": sum(len(wids) for stem in stems for wids in forms[stem].values()),
            })
            continue

        local_inv = subinventory(inv, active_types)
        local_splits = [splits[i] for i in active_types]
        direct = lp.direct_source(local_inv)
        fact = lp.factor_source(local_inv, local_splits, "one", "frontcoded")
        model_saving = direct["model_bytes"] - fact["model_bytes"]
        penalty = fact["conditional_penalty_bits"]
        net = 8 * model_saving - penalty
        proposed.append({
            "key": [modal[0].hex(), modal[1].hex()],
            "stems": active_stems,
            "tails": active_support,
            "types": active_types,
            "gate": {
                "types": len(active_types),
                "occurrences": sum(inv.counts[i] for i in active_types),
                "stems": len(active_stems),
                "tails": len(active_support),
                "direct_model_bytes": direct["model_bytes"],
                "factor_model_bytes": fact["model_bytes"],
                "model_saving_bytes": model_saving,
                "conditional_penalty_bits": penalty,
                "net_mdl_bits": net,
                "direct_static_huffman_total": direct["total_bytes"],
                "factor_static_huffman_total": fact["total_bytes"],
                "static_huffman_delta_bytes": fact["total_bytes"] - direct["total_bytes"],
                "charged_activation_and_rows_bytes": fact["model_components"]["stem_to_class_map"] + fact["model_components"]["class_support_and_tail_code_lengths"],
            },
            "accepted": net > 0,
        })
    return proposed, structural_rejects


def hybrid_source(inv: lp.Inventory, splits, is_candidate, classes: list[dict]) -> dict:
    accepted = [c for c in classes if c["accepted"]]
    accepted.sort(key=lambda c: (tuple(bytes.fromhex(x) for x in c["key"])))
    active_map: dict[int, tuple[int, bytes, tuple[bytes, bytes]]] = {}
    class_support: dict[int, set[tuple[bytes, bytes]]] = {0: {EMPTY}}
    class_stems: dict[int, set[bytes]] = {0: set()}
    for ci, family in enumerate(accepted, start=1):
        for stem in family["stems"]:
            class_stems.setdefault(ci, set()).add(stem)
        for tail in family["tails"]:
            class_support.setdefault(ci, set()).add(tail)
        for wid in family["types"]:
            stem, tail = splits[wid]
            active_map[wid] = (ci, stem, tail)

    # Every unaccepted/irregular surface is its own identity stem in class 0.
    source_for_type: list[tuple[int, bytes, tuple[bytes, bytes]]] = []
    for wid, word in enumerate(inv.names):
        if wid in active_map:
            source_for_type.append(active_map[wid])
        else:
            source_for_type.append((0, word, EMPTY))
            class_stems[0].add(word)
    for ci in range(1, len(accepted) + 1):
        used = {tail for c, _, tail in source_for_type if c == ci}
        class_support[ci] = used

    # Inactive identity stems default to class 0. Only productive roots need
    # an explicit activation entry; retain duplicate byte strings when one
    # surface is both an identity form and a productive stem.
    stem_keys = sorted({(stem, ci > 0) for ci, stem, _ in source_for_type})
    stem_id = {key: i for i, key in enumerate(stem_keys)}
    all_tails = sorted({tail for tails in class_support.values() for tail in tails})
    tail_id = {tail: i for i, tail in enumerate(all_tails)}
    stem_freq = [0] * len(stem_keys)
    stem_class = [0] * len(stem_keys)
    tail_counts: list[collections.Counter[int]] = [collections.Counter() for _ in range(len(accepted) + 1)]
    tails_by_stem: list[collections.Counter[int]] = [collections.Counter() for _ in stem_keys]
    for wid, (ci, stem, tail) in enumerate(source_for_type):
        si = stem_id[(stem, ci > 0)]
        stem_class[si] = ci
        ti = tail_id[tail]
        count = inv.counts[wid]
        stem_freq[si] += count
        tail_counts[ci][ti] += count
        tails_by_stem[si][ti] += count

    base = lp.direct_source(inv)
    # Complete exact model ledger. Stem bytes are front-coded. Inactive
    # identity stems default to class 0; the sparse activation map lists only
    # productive stem IDs and their class IDs.
    frame = 4 + len(lp.uleb(len(inv.token_ids)))
    stem_records = [stem for stem, _ in stem_keys]
    stem_literals = lp.frontcoded_records(stem_records)
    sig_records = [lp.uleb(len(pre)) + pre + lp.uleb(len(suf)) + suf for pre, suf in all_tails]
    signature_literals = lp.frontcoded_records(sig_records)
    active_map_ids = [i for i, ci in enumerate(stem_class) if ci > 0]
    activation_map = len(lp.uleb(len(active_map_ids)))
    prev_active = -1
    for i in active_map_ids:
        activation_map += len(lp.uleb(i - prev_active)) + len(lp.uleb(stem_class[i]))
        prev_active = i
    support_bytes = len(lp.uleb(len(tail_counts)))
    tail_lengths: list[list[int]] = []
    payload_bits = 0
    entropy_tail_class = 0.0
    for ci, counter in enumerate(tail_counts):
        support = sorted(tail_id[t] for t in class_support[ci])
        support_bytes += len(lp.uleb(len(support)))
        for t in support:
            support_bytes += len(lp.uleb(t))
        counts = [counter[t] for t in support]
        # A singleton tail alphabet is an implicit deterministic emission:
        # its sole supported symbol is known from the active class, costs no
        # operand bits, and needs no code-length vector in the table.
        lengths = [0] if len(support) == 1 else lp.huffman_lengths(counts)
        tail_lengths.append(lengths)
        if len(support) > 1:
            support_bytes += len(lp.uleb(len(lengths))) + len(lengths)
        payload_bits += sum(c * l for c, l in zip(counts, lengths))
        entropy_tail_class += lp.shannon_bits(counts)
    stem_lengths = lp.huffman_lengths(stem_freq)
    stem_length_header = len(lp.uleb(len(stem_lengths))) + len(stem_lengths)
    stem_payload_bits = sum(c * l for c, l in zip(stem_freq, stem_lengths))
    payload_bits += stem_payload_bits
    model = frame + stem_literals + signature_literals + activation_map + support_bytes + stem_length_header
    payload = (payload_bits + 7) // 8
    entropy_stem = lp.shannon_bits(stem_freq)
    entropy_tail_stem = sum(lp.shannon_bits(row.values()) for row in tails_by_stem)
    penalty = entropy_tail_class - entropy_tail_stem
    model_saving = base["model_bytes"] - model
    observed_active = sum(len(c["types"]) for c in accepted)
    active_stem_signatures = sum(
        len(tails_by_stem[si]) for si in range(len(stem_keys)) if stem_class[si] > 0
    )
    possible = sum(len(class_stems[ci]) * len(class_support[ci]) for ci in range(1, len(accepted) + 1))
    observed_pairs = sum(
        len(tails_by_stem[si]) for si in range(len(stem_keys)) if stem_class[si] > 0
    )
    return {
        "direct": base,
        "hybrid": {
            "model_bytes": model,
            "payload_bytes": payload,
            "total_bytes": model + payload,
            "payload_huffman_bits": payload_bits,
            "stem_huffman_bits": stem_payload_bits,
            "model_components": {
                "frame_and_occurrence_count": frame,
                "stem_literals_frontcoded": stem_literals,
                "tail_signature_literals_frontcoded": signature_literals,
                "sparse_active_stem_to_class_map": activation_map,
                "class_support_and_tail_code_lengths": support_bytes,
                "stem_huffman_lengths": stem_length_header,
            },
            "inventory": {
                "accepted_classes": len(accepted),
                "stem_symbols_including_identity_fallbacks": len(stem_keys),
                "tail_signatures": len(all_tails),
                "factorized_types": observed_active,
                "identity_types": len(inv.names) - observed_active,
                "factorized_occurrences": sum(sum(inv.counts[i] for i in c["types"]) for c in accepted),
                "identity_occurrences": sum(inv.counts[i] for i in range(len(inv.names)) if i not in active_map),
                "productive_supported_pairs": possible,
                "observed_productive_pairs": observed_pairs,
                "unobserved_productive_pairs": possible - observed_pairs,
                "tail_symbol_distinct_per_factor_stem": active_stem_signatures,
            },
            "shannon_stem_bits": entropy_stem,
            "shannon_tail_given_class_bits": entropy_tail_class,
            "shannon_tail_given_stem_bits": entropy_tail_stem,
            "conditional_penalty_bits": penalty,
            "conditional_penalty_bits_per_occurrence": penalty / len(inv.token_ids) if inv.token_ids else 0.0,
            "model_saving_bytes": model_saving,
            "model_saving_minus_conditional_penalty_bits": 8 * model_saving - penalty,
            "huffman_delta_bytes": model + payload - base["total_bytes"],
        },
        "accepted_families": [{k: v for k, v in c.items() if k not in ("stems", "tails", "types")} for c in accepted],
        "rejected_families": [{k: v for k, v in c.items() if k not in ("stems", "tails", "types")} for c in classes if not c["accepted"]],
    }


def run_one(path: Path, limit: int) -> dict:
    data = path.read_bytes()[:limit]
    inv = lp.inventory(data, len(data))
    splits, candidates, split_stats = family_splits(inv)
    families, structural_rejects = propose_classes(inv, splits, candidates)
    outcome = hybrid_source(inv, splits, candidates, families)
    return {
        "input": str(path),
        "input_bytes": len(data),
        "input_sha256": hashlib.sha256(data).hexdigest(),
        "type_inventory": {
            "types": len(inv.names),
            "occurrences": len(inv.token_ids),
            "surface_bytes": sum(map(len, inv.names)),
            "invalid_utf8_types_kept_as_identity": inv.invalid_utf8_types,
            "over_64_codepoint_types_kept_as_identity": inv.long_types,
            "candidate_core_types": sum(candidates),
            **split_stats,
        },
        "fixed_policy": {
            "max_root_codepoints": MAX_ROOT,
            "max_tails_per_class": MAX_TAILS,
            "min_stems_per_tail": MIN_STEMS_PER_TAIL,
            "min_forms_per_stem": MIN_FORMS_PER_STEM,
            "min_active_stems": MIN_ACTIVE_STEMS,
            "gate": "accept iff 8*(direct family model bytes - factor family model bytes) - [H(T|class(S))-H(T|S)] > 0 bits",
        },
        "family_candidates": [
            {k: v for k, v in c.items() if k not in ("stems", "tails", "types")}
            for c in families
        ],
        "structural_rejects": structural_rejects,
        "summary": {
            "proposed_classes": len(families),
            "accepted_classes": sum(c["accepted"] for c in families),
            "rejected_classes": sum(not c["accepted"] for c in families),
            "structural_reject_classes": len(structural_rejects),
            "direct_total_bytes": outcome["direct"]["total_bytes"],
            "hybrid_total_bytes": outcome["hybrid"]["total_bytes"],
            "hybrid_delta_bytes": outcome["hybrid"]["huffman_delta_bytes"],
            "model_saving_minus_conditional_penalty_bits": outcome["hybrid"]["model_saving_minus_conditional_penalty_bits"],
        },
        "direct_front_coded_control": outcome["direct"],
        "hybrid_source": outcome["hybrid"],
        "scope_note": "Exact counted type-inventory diagnostic only. No non-letter atoms, complete WGP frame, native entropy backend, timing, or held-out corpus.",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--bytes", type=int, default=8 << 20)
    ap.add_argument("--json", type=Path, required=True)
    args = ap.parse_args()
    rows = [run_one(path, args.bytes) for path in args.inputs]
    result = {"schema": "wgp6-mdl-gated-hybrid-1", "limit_bytes": args.bytes, "rows": rows}
    args.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"rows": [r["summary"] for r in rows]}, indent=2))


if __name__ == "__main__":
    main()
