#!/usr/bin/env python3
"""Exact, page-reset references to previously spelled byte lexemes.

This is an experimental construction layer, not a learned vocabulary. The
4096-entry ring is rebuilt from decoded bytes within each page. Lexemes are
maximal runs between fixed ASCII separators. A reference costs four bytes;
literal zero bytes are doubled so both arbitrary binary and previous record
opcodes remain unambiguous. No Unicode decoding or normalization is used.
"""

RING = 4096
SEPARATORS = frozenset(b' -<>="\t\r\n')
MARK = b"\x00\x04"
DELTA_MARK = b"\x00\x05"


def eligible(word):
    return 6 <= len(word) <= 128 and b"\x00" not in word


def _split(data):
    start = 0
    for at, byte in enumerate(data):
        if byte in SEPARATORS:
            if start < at:
                yield data[start:at], False
            yield data[at:at + 1], True
            start = at + 1
    if start < len(data):
        yield data[start:], False


def forward(data, policy="all", delta=False):
    if policy not in ("all", "nonascii", "nonascii_long", "long"):
        raise ValueError("unknown reference policy")
    slots = [None] * RING
    latest = {}
    next_slot = 0
    out = bytearray()
    stats = {"refs": 0, "saved_raw_bytes": 0, "literal_zeroes": 0}
    for word, separator in _split(data):
        if separator:
            out += word.replace(b"\x00", b"\x00\x00")
            continue
        candidate = eligible(word)
        if policy in ("nonascii", "nonascii_long"):
            candidate = candidate and any(c >= 128 for c in word)
        if policy in ("long", "nonascii_long"):
            candidate = candidate and len(word) >= 12
        index = latest.get(word) if candidate else None
        if index is not None:
            if delta:
                distance = (next_slot - index) % RING or RING
                if distance < 128:
                    out += DELTA_MARK + bytes((distance,))
                else:
                    out += DELTA_MARK + bytes(((distance & 127) | 128, distance >> 7))
            else:
                out += MARK + index.to_bytes(2, "little")
            stats["refs"] += 1
            stats["saved_raw_bytes"] += len(word) - 4
        else:
            out += word.replace(b"\x00", b"\x00\x00")
            stats["literal_zeroes"] += word.count(b"\x00")
        if eligible(word):
            old = slots[next_slot]
            if old is not None and latest.get(old) == next_slot:
                del latest[old]
            slots[next_slot] = word
            latest[word] = next_slot
            next_slot = (next_slot + 1) % RING
    return bytes(out), stats


def inverse(data):
    slots = [None] * RING
    next_slot = 0
    out = bytearray()
    word = bytearray()

    def flush():
        nonlocal next_slot
        if not word:
            return
        value = bytes(word)
        if eligible(value):
            slots[next_slot] = value
            next_slot = (next_slot + 1) % RING
        out.extend(word)
        word.clear()

    at = 0
    while at < len(data):
        c = data[at]
        if c in SEPARATORS:
            flush()
            out.append(c)
            at += 1
        elif c == 0:
            if at + 1 >= len(data):
                raise ValueError("truncated zero escape")
            op = data[at + 1]
            if op == 0:
                word.append(0)
                at += 2
            elif op in (4, 5):
                if at + 3 > len(data) or word:
                    raise ValueError("invalid prior-word reference")
                if op == 4:
                    if at + 4 > len(data):
                        raise ValueError("truncated prior-word index")
                    index = int.from_bytes(data[at + 2:at + 4], "little")
                    at += 4
                else:
                    lo = data[at + 2]
                    if lo & 128:
                        if at + 4 > len(data):
                            raise ValueError("truncated prior-word distance")
                        distance = (lo & 127) | (data[at + 3] << 7)
                        at += 4
                    else:
                        distance = lo
                        at += 3
                    if not 1 <= distance <= RING:
                        raise ValueError("bad prior-word distance")
                    index = (next_slot - distance) % RING
                if index >= RING or slots[index] is None:
                    raise ValueError("missing prior word")
                word.extend(slots[index])
            else:
                raise ValueError("invalid prior-word opcode")
        else:
            word.append(c)
            at += 1
    flush()
    return bytes(out)
