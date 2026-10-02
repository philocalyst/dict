#!/usr/bin/env python3
"""SED1 source-only clause edit diagnostic; see PROTOCOL.md.

The optimistic stream has free donor/position metadata and cannot decode.
The paid route and literal streams are independently byte-exact. This script
does not perform entropy coding or claim a new archive format.
"""

from __future__ import annotations

import binascii
import collections
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

PAGE = 65536
CLAUSE = 1024
WINDOW = 4096
POSTINGS = 64
CANDIDATES = 8
MIN_KEEP = 8
ENDS = (b"\xe3\x80\x82", b"\xef\xbc\x81", b"\xef\xbc\x9f")
PUNCT = frozenset(b" \t\n\r.,!?;:()[]{}\"'")
LIMIT = 16 * 1024 * 1024


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def uleb(value: int) -> bytes:
    assert value >= 0
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def read_uleb(buf: bytes, off: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if off >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[off]
        off += 1
        value |= (byte & 127) << shift
        if byte < 128:
            if value > LIMIT:
                raise ValueError("varint limit")
            return value, off
    raise ValueError("varint width")


def clauses(page: bytes) -> list[bytes]:
    out: list[bytes] = []
    start = pos = 0
    while pos < len(page):
        advance = 1
        cut = page[pos] in b".!?\n"
        if not cut:
            for marker in ENDS:
                if page.startswith(marker, pos):
                    advance = len(marker)
                    cut = True
                    break
        pos += advance
        if cut or pos - start >= CLAUSE:
            out.append(page[start:pos])
            start = pos
    if start < len(page):
        out.append(page[start:])
    assert b"".join(out) == page
    assert all(0 < len(c) <= CLAUSE + 2 for c in out)
    return out


def shingle_keys(clause: bytes) -> set[bytes]:
    keys = {b"b" + clause[i : i + 12] for i in range(0, len(clause) - 11, 4)}
    function = bytes(b for b in clause if b in PUNCT)
    keys.update(b"f" + function[i : i + 4] for i in range(len(function) - 3))
    return keys


@dataclass
class Donor:
    data: bytes
    masks: dict[int, int]


def make_donor(data: bytes) -> Donor:
    masks: dict[int, int] = {}
    for pos, byte in enumerate(data):
        masks[byte] = masks.get(byte, 0) | (1 << pos)
    return Donor(data, masks)


def lcs(target: bytes, donor: Donor, prefix_masks: list[int]) -> list[tuple[int, int]]:
    """Exact LCS positions via bitset DP, then fixed-tie backtracking."""
    state = 0
    rows = [0]
    for byte in target:
        x = donor.masks.get(byte, 0) | state
        state = x & ~(x - ((state << 1) | 1))
        rows.append(state)
    out: list[tuple[int, int]] = []
    i, j = len(target), len(donor.data)

    def score(ii: int, jj: int) -> int:
        return (rows[ii] & prefix_masks[jj]).bit_count()

    while i and j:
        here = score(i, j)
        if target[i - 1] == donor.data[j - 1] and here == score(i - 1, j - 1) + 1:
            out.append((i - 1, j - 1))
            i -= 1
            j -= 1
        elif score(i - 1, j) >= score(i, j - 1):
            i -= 1
        else:
            j -= 1
    out.reverse()
    assert len(out) == rows[-1].bit_count()
    assert all(target[t] == donor.data[d] for t, d in out)
    return out


def runs(pairs: list[tuple[int, int]]) -> list[tuple[int, int, int]]:
    out: list[tuple[int, int, int]] = []
    for t, d in pairs:
        if out and t == out[-1][0] + out[-1][2] and d == out[-1][1] + out[-1][2]:
            a, b, n = out[-1]
            out[-1] = (a, b, n + 1)
        else:
            out.append((t, d, 1))
    return out


def candidate_route(target: bytes, distance: int, matched: list[tuple[int, int]]):
    keep = [r for r in runs(matched) if r[2] >= MIN_KEEP]
    if not keep:
        return None
    route = bytearray(uleb((len(target) << 1) | 1))
    route.extend(uleb(distance))
    route.extend(uleb(len(keep)))
    literal = bytearray()
    prev_end = 0
    for t, d, length in keep:
        gap = target[prev_end:t]
        route.extend(uleb(len(gap)))
        route.extend(uleb(d))
        route.extend(uleb(length))
        literal.extend(gap)
        prev_end = t + length
    tail = target[prev_end:]
    route.extend(uleb(len(tail)))
    literal.extend(tail)
    return bytes(route), bytes(literal), sum(r[2] for r in keep), len(keep)


def decode(route: bytes, literal: bytes) -> tuple[bytes, list[bytes]]:
    if not route.startswith(b"SED1R\0"):
        raise ValueError("route magic")
    pos = 6
    raw_len, pos = read_uleb(route, pos)
    page_count, pos = read_uleb(route, pos)
    result = bytearray()
    pages = []
    lit_pos = 0
    for _ in range(page_count):
        page_len, pos = read_uleb(route, pos)
        count, pos = read_uleb(route, pos)
        history = []
        page = bytearray()
        if page_len > PAGE or count > PAGE:
            raise ValueError("page bounds")
        for _ in range(count):
            if len(history) == WINDOW:
                history.clear()
            code, pos = read_uleb(route, pos)
            size = code >> 1
            if size > CLAUSE + 2:
                raise ValueError("clause bound")
            if not code & 1:
                if lit_pos + size > len(literal):
                    raise ValueError("literal bound")
                target = literal[lit_pos : lit_pos + size]
                lit_pos += size
            else:
                distance, pos = read_uleb(route, pos)
                nseg, pos = read_uleb(route, pos)
                if distance < 1 or distance > len(history) or nseg > size // MIN_KEEP:
                    raise ValueError("donor/segment bound")
                donor = history[-distance]
                target_buf = bytearray()
                donor_end = 0
                for _ in range(nseg):
                    gap, pos = read_uleb(route, pos)
                    offset, pos = read_uleb(route, pos)
                    length, pos = read_uleb(route, pos)
                    if lit_pos + gap > len(literal) or offset < donor_end or offset + length > len(donor) or length < MIN_KEEP:
                        raise ValueError("segment bound")
                    target_buf.extend(literal[lit_pos : lit_pos + gap])
                    target_buf.extend(donor[offset : offset + length])
                    lit_pos += gap
                    donor_end = offset + length
                tail, pos = read_uleb(route, pos)
                if lit_pos + tail > len(literal):
                    raise ValueError("tail bound")
                target_buf.extend(literal[lit_pos : lit_pos + tail])
                lit_pos += tail
                target = bytes(target_buf)
            if len(target) != size or len(page) + size > page_len:
                raise ValueError("clause length")
            history.append(target)
            page.extend(target)
        if len(page) != page_len:
            raise ValueError("page length")
        pages.append(bytes(page))
        result.extend(page)
    if not route.startswith(b"IDX1", pos):
        raise ValueError("index magic")
    pos += 4
    indexed, pos = read_uleb(route, pos)
    if indexed != len(pages):
        raise ValueError("index count")
    for idx, page in enumerate(pages):
        rawoff, pos = read_uleb(route, pos)
        _, pos = read_uleb(route, pos)
        _, pos = read_uleb(route, pos)
        if rawoff != idx * PAGE or pos + 4 > len(route):
            raise ValueError("page index")
        crc = int.from_bytes(route[pos : pos + 4], "little")
        pos += 4
        if crc != binascii.crc32(page):
            raise ValueError("page crc")
    if pos != len(route) or lit_pos != len(literal) or len(result) != raw_len:
        raise ValueError("trailing bytes/total")
    return bytes(result), pages


def screen(raw: bytes):
    if len(raw) > LIMIT:
        raise ValueError("input limit")
    route = bytearray(b"SED1R\0" + uleb(len(raw)) + uleb((len(raw) + PAGE - 1) // PAGE))
    literal = bytearray()
    optimistic = bytearray()
    ledger = collections.Counter()
    index_entries = []
    source_pages = [raw[i : i + PAGE] for i in range(0, len(raw), PAGE)]
    prefix_masks = [(1 << j) - 1 for j in range(CLAUSE + 4)]
    for page_idx, page in enumerate(source_pages):
        split = clauses(page)
        index_entries.append((page_idx * PAGE, len(route), len(literal), binascii.crc32(page)))
        route.extend(uleb(len(page)))
        route.extend(uleb(len(split)))
        ledger["clauses"] += len(split)
        history: list[Donor] = []
        postings: dict[bytes, collections.deque[int]] = {}
        for target in split:
            if len(history) == WINDOW:
                history.clear()
                postings.clear()
                ledger["in_page_ring_resets"] += 1
            rank = collections.Counter()
            keys = shingle_keys(target)
            for key in keys:
                for donor_id in postings.get(key, ()):
                    rank[donor_id] += 1
            chosen = [idx for idx, _ in sorted(rank.items(), key=lambda item: (-item[1], -item[0]))[:CANDIDATES]]
            for donor_id in range(len(history) - 1, max(-1, len(history) - CANDIDATES - 1), -1):
                if len(chosen) == CANDIDATES:
                    break
                if donor_id not in chosen:
                    chosen.append(donor_id)
            literal_route = uleb(len(target) << 1)
            best_paid = (literal_route, target, 0, 0)
            best_cover = 0
            best_match: list[tuple[int, int]] = []
            for donor_id in chosen:
                matched = lcs(target, history[donor_id], prefix_masks)
                ledger["candidate_pairs"] += 1
                ledger["candidate_work_cells"] += len(target) * len(history[donor_id].data)
                if len(matched) > best_cover:
                    best_cover, best_match = len(matched), matched
                proposal = candidate_route(target, len(history) - donor_id, matched)
                if proposal and len(proposal[0]) + len(proposal[1]) < len(best_paid[0]) + len(best_paid[1]):
                    best_paid = proposal
            cover_positions = {t for t, _ in best_match}
            optimistic.extend(byte for t, byte in enumerate(target) if t not in cover_positions)
            ledger["optimistic_covered_bytes"] += best_cover
            ledger["optimistic_lcs_runs"] += len(runs(best_match))
            route.extend(best_paid[0])
            literal.extend(best_paid[1])
            ledger["paid_covered_bytes"] += best_paid[2]
            ledger["paid_keep_segments"] += best_paid[3]
            ledger["donor_clauses" if best_paid[3] else "literal_clauses"] += 1
            donor = make_donor(target)
            history.append(donor)
            donor_id = len(history) - 1
            for key in keys:
                postings.setdefault(key, collections.deque(maxlen=POSTINGS)).append(donor_id)
    route.extend(b"IDX1" + uleb(len(index_entries)))
    for rawoff, routeoff, litoff, crc in index_entries:
        route.extend(uleb(rawoff) + uleb(routeoff) + uleb(litoff) + crc.to_bytes(4, "little"))
    recovered, pages = decode(bytes(route), bytes(literal))
    if recovered != raw or pages != source_pages:
        raise AssertionError("transform inverse")
    assert ledger["optimistic_covered_bytes"] + len(optimistic) == len(raw)
    assert ledger["paid_covered_bytes"] + len(literal) == len(raw)
    return bytes(optimistic), bytes(route), bytes(literal), dict(ledger)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: sed_screen.py SOURCE OUTPUT_DIR")
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    raw = src.read_bytes()
    optimistic, route, literal, ledger = screen(raw)
    for name, data in (("optimistic-literal.bin", optimistic), ("route.bin", route), ("paid-literal.bin", literal)):
        (out / name).write_bytes(data)
    report = {
        "status": "source_only_no_entropy_frame",
        "source_path": str(src.resolve()),
        "source_bytes": len(raw),
        "source_sha256": sha(raw),
        "optimistic_literal_bytes": len(optimistic),
        "optimistic_literal_sha256": sha(optimistic),
        "route_bytes": len(route),
        "route_sha256": sha(route),
        "paid_literal_bytes": len(literal),
        "paid_literal_sha256": sha(literal),
        "pages_exact": (len(raw) + PAGE - 1) // PAGE,
        "full_inverse_exact": True,
        "ledger": ledger,
    }
    (out / "transform.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
