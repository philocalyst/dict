#!/usr/bin/env python3
"""Private exact-byte GEN/PAST prototype for retained development inputs.

This is a costed format probe, not a WGP6 or v4 codec. It has no word list,
normalizer, pretrained model, or omitted spelling side channel. Its single
static byte rANS model is trained from and serialized with the event stream.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import struct
import zlib

MAGIC = b"GTG1"
RANS_L = 1 << 23
SCALE_BITS = 12
SCALE = 1 << SCALE_BITS
REACH = 1023  # bz4 v3's default ring=10, not its 4096-position storage size.
HISTORY_SIZE = REACH + 1
MAX_BLOCK = 1 << 16
OP_PAST, OP_LITERAL, OP_EDIT = 0xF0, 0xF1, 0xF2


def uleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative ULEB")
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def take_uleb(data: bytes, at: int) -> tuple[int, int]:
    value = shift = 0
    for i in range(10):
        if at >= len(data):
            raise ValueError("truncated ULEB")
        byte = data[at]
        at += 1
        if i == 9 and byte >= 2:
            raise ValueError("ULEB overflow")
        value |= (byte & 127) << shift
        if byte < 128:
            if i and byte == 0:
                raise ValueError("noncanonical ULEB")
            return value, at
        shift += 7
    raise ValueError("ULEB overflow")


def atom_kind(byte: int) -> int:
    return 0 if byte >= 128 or 65 <= byte <= 90 or 97 <= byte <= 122 else 1 if 48 <= byte <= 57 else 2


def atoms(raw: bytes) -> list[bytes]:
    """Match v4 byte atomization exactly: high-byte/letter runs, digit runs, other bytes."""
    out: list[bytes] = []
    pos = 0
    while pos < len(raw):
        kind = atom_kind(raw[pos])
        end = pos + 1
        if kind != 2:
            while end < len(raw) and atom_kind(raw[end]) == kind:
                end += 1
        out.append(raw[pos:end])
        pos = end
    return out


def restart_blocks(raw: bytes) -> list[list[bytes]]:
    result: list[list[bytes]] = []
    current: list[bytes] = []
    size = 0
    for token in atoms(raw):
        current.append(token)
        size += len(token)
        if size >= MAX_BLOCK:
            result.append(current)
            current, size = [], 0
    if current:
        result.append(current)
    return result


def scalar_boundaries(word: bytes) -> set[int] | None:
    try:
        decoded = word.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    result = {0}
    at = 0
    for scalar in decoded:
        at += len(scalar.encode("utf-8"))
        result.add(at)
    return result


def longest_common_span(a: bytes, b: bytes, scalar: bool) -> tuple[int, int, int] | None:
    """Return (a_start, length, b_start), respecting scalar edges when requested."""
    if not a or not b or len(a) < 3 or len(b) < 3:
        return None
    a_bounds = scalar_boundaries(a) if scalar else None
    b_bounds = scalar_boundaries(b) if scalar else None
    if scalar and (a_bounds is None or b_bounds is None):
        return None
    best = None
    previous = [0] * (len(b) + 1)
    for ai, byte in enumerate(a):
        current = [0] * (len(b) + 1)
        for bj, other in enumerate(b):
            if byte != other:
                continue
            current[bj + 1] = previous[bj] + 1
            size = current[bj + 1]
            aend, bend = ai + 1, bj + 1
            if scalar and (aend not in a_bounds or bend not in b_bounds):
                continue
            while size >= 3:
                astart, bstart = aend - size, bend - size
                if not scalar or (astart in a_bounds and bstart in b_bounds):
                    candidate = (astart, size, bstart)
                    if best is None or (size, -astart, -bstart) > (best[1], -best[0], -best[2]):
                        best = candidate
                    break
                size -= 1
        previous = current
    return best


def event_stream(block: list[bytes], scalar: bool) -> tuple[bytes, bytes, dict]:
    events = bytearray()
    output = bytearray()
    history: list[bytes | None] = [None] * HISTORY_SIZE
    last_exact: dict[bytes, int] = {}
    gram_positions: dict[bytes, list[tuple[int, bytes]]] = defaultdict(list)
    counts = {"past": 0, "literal": 0, "edit": 0, "copied_core_bytes": 0,
              "literal_edge_bytes": 0, "word_tokens": 0}

    def push(token: bytes, index: int) -> None:
        history[index % HISTORY_SIZE] = token
        last_exact[token] = index
        if len(token) >= 3:
            for i in range(len(token) - 2):
                gram_positions[token[i:i + 3]].append((index, token))

    for index, token in enumerate(block):
        counts["word_tokens"] += bool(token and atom_kind(token[0]) == 0)
        previous = last_exact.get(token)
        if previous is not None and index - previous <= REACH:
            distance = index - previous
            events.extend((OP_PAST,))
            events.extend(uleb(distance))
            counts["past"] += 1
        else:
            literal = bytes((OP_LITERAL,)) + uleb(len(token)) + token
            best = None
            if token and atom_kind(token[0]) == 0:
                seen: set[int] = set()
                candidate_rows = []
                if len(token) >= 3:
                    for pos in range(len(token) - 2):
                        rows = gram_positions.get(token[pos:pos + 3], ())
                        got = 0
                        for source_index, source in reversed(rows):
                            if index - source_index > REACH:
                                break
                            if source_index not in seen:
                                seen.add(source_index)
                                candidate_rows.append((source_index, source))
                                got += 1
                                if got == 8:
                                    break
                candidate_rows.sort(reverse=True, key=lambda row: row[0])
                for source_index, source in candidate_rows[:64]:
                    if not source or atom_kind(source[0]) != 0:
                        continue
                    match = longest_common_span(source, token, scalar)
                    if match is None:
                        continue
                    source_start, core_len, target_start = match
                    prefix, suffix = token[:target_start], token[target_start + core_len:]
                    distance = index - source_index
                    encoded = (bytes((OP_EDIT,)) + uleb(distance) + uleb(source_start) +
                               uleb(core_len) + uleb(len(prefix)) + prefix +
                               uleb(len(suffix)) + suffix)
                    if len(encoded) < len(literal) and (best is None or len(encoded) < len(best[0])):
                        best = (encoded, core_len, len(prefix) + len(suffix))
            if best is None:
                events.extend(literal)
                counts["literal"] += 1
            else:
                events.extend(best[0])
                counts["edit"] += 1
                counts["copied_core_bytes"] += best[1]
                counts["literal_edge_bytes"] += best[2]
        output.extend(token)
        push(token, index)
        if index >= REACH:
            expired_index = index - REACH
            expired = block[expired_index]
            # Keep only live exact/gram index entries; stale gram rows are popped on the next query.
            if last_exact.get(expired) == expired_index:
                del last_exact[expired]
    return bytes(events), bytes(output), counts


def train_freq(data: bytes) -> list[int]:
    counts = [0] * 256
    for value in data:
        counts[value] += 1
    live = [i for i, count in enumerate(counts) if count]
    if not live:
        return [SCALE] + [0] * 255
    if len(live) > SCALE:
        raise ValueError("rANS alphabet exceeds scale")
    remaining = SCALE - len(live)
    total = len(data)
    frequencies = [0] * 256
    remainders = []
    assigned = 0
    for symbol in live:
        share, remainder = divmod(remaining * counts[symbol], total)
        frequencies[symbol] = 1 + share
        assigned += share
        remainders.append((remainder, symbol))
    for _, symbol in sorted(remainders, reverse=True)[:remaining - assigned]:
        frequencies[symbol] += 1
    assert sum(frequencies) == SCALE
    return frequencies


def rans_encode(data: bytes, frequencies: list[int]) -> bytes:
    cumulatives = [0] * 256
    for i in range(1, 256):
        cumulatives[i] = cumulatives[i - 1] + frequencies[i - 1]
    state = RANS_L
    tail = bytearray()
    for symbol in reversed(data):
        frequency = frequencies[symbol]
        if not frequency:
            raise ValueError("uncoded rANS symbol")
        threshold = (RANS_L >> SCALE_BITS) * 256 * frequency
        while state >= threshold:
            tail.append(state & 255)
            state >>= 8
        state = (state // frequency) * SCALE + state % frequency + cumulatives[symbol]
    return struct.pack("<I", state) + bytes(reversed(tail))


def rans_decode(coded: bytes, count: int, frequencies: list[int]) -> bytes:
    if len(coded) < 4:
        raise ValueError("short rANS block")
    state, = struct.unpack_from("<I", coded)
    if not RANS_L <= state < RANS_L * 256:
        raise ValueError("bad rANS state")
    lookup = [0] * SCALE
    cumulatives = [0] * 256
    cumulative = 0
    for symbol, frequency in enumerate(frequencies):
        cumulatives[symbol] = cumulative
        cumulative += frequency
        if frequency:
            lookup[cumulatives[symbol]:cumulatives[symbol] + frequency] = [symbol] * frequency
    out = bytearray()
    at = 4
    for _ in range(count):
        low = state & (SCALE - 1)
        symbol = lookup[low]
        out.append(symbol)
        state = frequencies[symbol] * (state >> SCALE_BITS) + low - cumulatives[symbol]
        while state < RANS_L:
            if at >= len(coded):
                raise ValueError("rANS underflow")
            state = (state << 8) | coded[at]
            at += 1
    if state != RANS_L or at != len(coded):
        raise ValueError("rANS tail mismatch")
    return bytes(out)


def encode(raw: bytes, scalar: bool = False) -> tuple[bytes, dict]:
    blocks = restart_blocks(raw)
    events = []
    reconstructed = []
    counters = {"past": 0, "literal": 0, "edit": 0, "copied_core_bytes": 0,
                "literal_edge_bytes": 0, "word_tokens": 0}
    for block in blocks:
        stream, decoded, counts = event_stream(block, scalar)
        events.append((block, stream, decoded))
        reconstructed.append(decoded)
        for key, value in counts.items():
            counters[key] += value
    all_events = b"".join(stream for _, stream, _ in events)
    frequencies = train_freq(all_events)
    frame = bytearray(MAGIC)
    frame.extend(struct.pack("<IQI", 1, len(raw), len(blocks)))
    frame.extend(struct.pack("<256H", *frequencies))
    block_metrics = []
    for block, stream, decoded in events:
        coded = rans_encode(stream, frequencies)
        checksum = zlib.crc32(decoded) & 0xFFFFFFFF
        frame.extend(struct.pack("<IIIII", len(decoded), len(block), len(stream), len(coded), checksum))
        frame.extend(coded)
        block_metrics.append({"raw_bytes": len(decoded), "tokens": len(block),
                              "event_bytes_before_rans": len(stream), "rans_bytes": len(coded),
                              "crc32": checksum})
    report = {"wire": "GTG1", "edit_mode": "scalar-boundary" if scalar else "arbitrary-byte",
              "input_bytes": len(raw), "frame_bytes": len(frame), "fixed_header_bytes": 20,
              "model_bytes": 512,
              "block_directory_bytes": 20 * len(blocks), "blocks": block_metrics,
              "events": counters, "event_stream_bytes": len(all_events),
              "payload_bytes": len(frame) - 20 - 512 - 20 * len(blocks),
              "input_sha256": hashlib.sha256(raw).hexdigest(),
              "frame_sha256": hashlib.sha256(frame).hexdigest()}
    if b"".join(reconstructed) != raw:
        raise AssertionError("encoder source tokenization lost bytes")
    return bytes(frame), report


def decode(frame: bytes, selected: int | None = None) -> bytes:
    if len(frame) < 532 or frame[:4] != MAGIC:
        raise ValueError("bad GTG1 frame")
    version, raw_total, block_count = struct.unpack_from("<IQI", frame, 4)
    if version != 1 or block_count > 1_000_000:
        raise ValueError("bad GTG1 header")
    frequencies = list(struct.unpack_from("<256H", frame, 20))
    if sum(frequencies) != SCALE:
        raise ValueError("bad rANS model")
    at = 532
    outputs = []
    total_raw = 0
    for block_index in range(block_count):
        if len(frame) - at < 20:
            raise ValueError("truncated block directory")
        raw_len, token_count, event_count, coded_len, checksum = struct.unpack_from("<IIIII", frame, at)
        at += 20
        if coded_len > len(frame) - at:
            raise ValueError("truncated block payload")
        coded = frame[at:at + coded_len]
        at += coded_len
        total_raw += raw_len
        if selected is not None and block_index != selected:
            continue
        stream = rans_decode(coded, event_count, frequencies)
        cursor = 0
        history: list[bytes | None] = [None] * HISTORY_SIZE
        output = bytearray()
        for token_index in range(token_count):
            if cursor >= len(stream):
                raise ValueError("truncated token operation")
            opcode = stream[cursor]
            cursor += 1
            if opcode == OP_PAST:
                distance, cursor = take_uleb(stream, cursor)
                if not 0 < distance <= min(REACH, token_index):
                    raise ValueError("past distance out of range")
                token = history[(token_index - distance) % HISTORY_SIZE]
                if token is None:
                    raise ValueError("missing past token")
            elif opcode == OP_LITERAL:
                length, cursor = take_uleb(stream, cursor)
                if length > len(stream) - cursor:
                    raise ValueError("truncated literal")
                token = stream[cursor:cursor + length]
                cursor += length
            elif opcode == OP_EDIT:
                distance, cursor = take_uleb(stream, cursor)
                start, cursor = take_uleb(stream, cursor)
                core_len, cursor = take_uleb(stream, cursor)
                pre_len, cursor = take_uleb(stream, cursor)
                if pre_len > len(stream) - cursor:
                    raise ValueError("truncated edit prefix")
                prefix = stream[cursor:cursor + pre_len]
                cursor += pre_len
                suffix_len, cursor = take_uleb(stream, cursor)
                if suffix_len > len(stream) - cursor:
                    raise ValueError("truncated edit suffix")
                suffix = stream[cursor:cursor + suffix_len]
                cursor += suffix_len
                if not 0 < distance <= min(REACH, token_index):
                    raise ValueError("edit source distance out of range")
                source = history[(token_index - distance) % HISTORY_SIZE]
                if source is None:
                    raise ValueError("missing edit source")
                if core_len < 3 or start > len(source) or core_len > len(source) - start:
                    raise ValueError("edit source span out of range")
                token = prefix + source[start:start + core_len] + suffix
            else:
                raise ValueError("unknown token operation")
            history[token_index % HISTORY_SIZE] = token
            output.extend(token)
        if cursor != len(stream) or len(output) != raw_len:
            raise ValueError("block expansion mismatch")
        if zlib.crc32(output) & 0xFFFFFFFF != checksum:
            raise ValueError("block CRC mismatch")
        if selected is None or block_index == selected:
            outputs.append(bytes(output))
    if at != len(frame) or total_raw != raw_total:
        raise ValueError("frame length mismatch")
    if selected is not None and selected >= block_count:
        raise ValueError("selected block out of range")
    return b"".join(outputs)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    enc = sub.add_parser("encode")
    enc.add_argument("input", type=Path)
    enc.add_argument("frame", type=Path)
    enc.add_argument("--scalar-boundaries", action="store_true")
    dec = sub.add_parser("decode")
    dec.add_argument("frame", type=Path)
    dec.add_argument("output", type=Path)
    dec.add_argument("--block", type=int)
    args = parser.parse_args()
    if args.operation == "encode":
        raw = args.input.read_bytes()
        frame, report = encode(raw, args.scalar_boundaries)
        args.frame.write_bytes(frame)
        print(json.dumps(report, sort_keys=True))
    else:
        frame = args.frame.read_bytes()
        output = decode(frame, args.block)
        args.output.write_bytes(output)
        print(json.dumps({"decoded_bytes": len(output), "block": args.block,
                          "sha256": hashlib.sha256(output).hexdigest()}))


if __name__ == "__main__":
    main()
