#!/usr/bin/env python3
"""Charged, static type-weighted spelling generator.

This is a bounded research prototype, not the v4 codec.  It deliberately
keeps the wire format self-contained so that a complete byte total can be
compared with v4:

  * the input is split with v4's byte-only atom rule;
  * a segment inventory is learned from distinct training types;
  * each first-use type is written as a segment sequence by four frozen
    canonical-Huffman rows (start/letter/digit/other);
  * the occurrence stream uses a frozen three-symbol event table, a checked
    fixed-width recent gap, or a checked ULEB old type id.

No Unicode normalization, dictionary, external tokenizer, adaptive
probability update, or compression library is used.  zlib is used only for
the frame CRC.  The decoder is intentionally strict about every count and
bitstream boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import math
import struct
import sys
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


MAGIC = b"LPRED001"
VERSION = 1
ROWS = 4  # start, letter/high-byte, digit, other
END_EXTRA = 1
EVENT_NEW = 0


def kind_byte(value: int) -> int:
    """Match v4's byte-only learner class without decoding UTF-8."""

    if (65 <= value <= 90) or (97 <= value <= 122) or value >= 0x80:
        return 1
    if 48 <= value <= 57:
        return 2
    return 3


def iter_atoms(data: bytes) -> Iterator[bytes]:
    """Yield maximal letter/high-byte and digit runs, else one byte."""

    at = 0
    n = len(data)
    while at < n:
        k = kind_byte(data[at])
        end = at + 1
        if k != 3:
            while end < n and kind_byte(data[end]) == k:
                end += 1
        yield data[at:end]
        at = end


def atom_list(data: bytes) -> list[bytes]:
    return list(iter_atoms(data))


class BitWriter:
    __slots__ = ("data", "value", "bits")

    def __init__(self) -> None:
        self.data = bytearray()
        self.value = 0
        self.bits = 0

    def write(self, value: int, count: int) -> None:
        if count < 0 or value < 0 or (count and value >= (1 << count)):
            raise ValueError("invalid bit write")
        for shift in range(count - 1, -1, -1):
            self.value = (self.value << 1) | ((value >> shift) & 1)
            self.bits += 1
            if self.bits == 8:
                self.data.append(self.value)
                self.value = 0
                self.bits = 0

    def finish(self) -> tuple[bytes, int]:
        count = len(self.data) * 8 + self.bits
        if self.bits:
            self.data.append(self.value << (8 - self.bits))
        return bytes(self.data), count


class BitReader:
    __slots__ = ("data", "limit", "pos")

    def __init__(self, data: bytes, bit_count: int) -> None:
        if bit_count < 0 or bit_count > len(data) * 8:
            raise ValueError("invalid bit count")
        self.data = data
        self.limit = bit_count
        self.pos = 0

    def read(self, count: int) -> int:
        if count < 0 or self.pos + count > self.limit:
            raise ValueError("truncated bitstream")
        value = 0
        for _ in range(count):
            byte = self.data[self.pos >> 3]
            value = (value << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return value

    def remaining(self) -> int:
        return self.limit - self.pos


def huffman_lengths(freq: Sequence[int]) -> list[int]:
    """Deterministic binary Huffman lengths; zero frequencies are avoided."""

    if not freq:
        raise ValueError("empty alphabet")
    if len(freq) == 1:
        return [1]
    heap: list[tuple[int, int, object]] = []
    serial = 0
    for symbol, count in enumerate(freq):
        # Smoothing is done by the caller; still make this total and safe.
        heapq.heappush(heap, (max(1, int(count)), serial, symbol))
        serial += 1
    while len(heap) > 1:
        a_count, _, a = heapq.heappop(heap)
        b_count, _, b = heapq.heappop(heap)
        heapq.heappush(heap, (a_count + b_count, serial, (a, b)))
        serial += 1
    lengths = [0] * len(freq)

    def visit(node: object, depth: int) -> None:
        if isinstance(node, int):
            lengths[node] = max(1, depth)
            return
        left, right = node
        visit(left, depth + 1)
        visit(right, depth + 1)

    visit(heap[0][2], 0)
    return lengths


@dataclass(frozen=True)
class Huffman:
    lengths: tuple[int, ...]
    codes: tuple[int, ...]
    decode: dict[tuple[int, int], int]

    @staticmethod
    def from_lengths(lengths: Sequence[int]) -> "Huffman":
        ordered = sorted((length, symbol) for symbol, length in enumerate(lengths) if length)
        if not ordered:
            raise ValueError("empty huffman table")
        codes = [0] * len(lengths)
        decode: dict[tuple[int, int], int] = {}
        code = 0
        previous = 0
        for length, symbol in ordered:
            code <<= length - previous
            if code >= (1 << length):
                raise ValueError("oversubscribed huffman table")
            codes[symbol] = code
            decode[(length, code)] = symbol
            code += 1
            previous = length
        return Huffman(tuple(lengths), tuple(codes), decode)

    @staticmethod
    def from_freq(freq: Sequence[int]) -> "Huffman":
        return Huffman.from_lengths(huffman_lengths(freq))

    def write(self, writer: BitWriter, symbol: int) -> None:
        length = self.lengths[symbol]
        if length == 0:
            raise ValueError("symbol absent from huffman table")
        writer.write(self.codes[symbol], length)

    def read(self, reader: BitReader) -> int:
        code = 0
        for length in range(1, 256):
            code = (code << 1) | reader.read(1)
            symbol = self.decode.get((length, code))
            if symbol is not None:
                return symbol
        raise ValueError("invalid huffman code")


def vleb(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative uleb")
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def take_vleb(data: bytes, at: int, limit: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 35, 7):
        if at >= limit:
            raise ValueError("truncated uleb")
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            if shift and byte == 0:
                # Canonicality is useful for an independently checked frame.
                raise ValueError("noncanonical uleb")
            return value, at
    raise ValueError("oversized uleb")


def symbol_class(text: bytes) -> int:
    return kind_byte(text[-1]) if text else 3


def build_candidates(types: Sequence[bytes], max_len: int, limit: int, min_occ: int) -> list[bytes]:
    """Select substrings by a type-weighted MDL-like gain, not pair merging."""

    occurrences: Counter[bytes] = Counter()
    for text in types:
        # A type contributes its occurrences, but a duplicate substring at the
        # same offsets is not allowed to inflate the type-weighted score.
        for length in range(2, min(max_len, len(text)) + 1):
            for at in range(0, len(text) - length + 1):
                occurrences[text[at : at + length]] += 1
    ranked: list[tuple[float, int, bytes]] = []
    for piece, count in occurrences.items():
        if count < min_occ:
            continue
        # Saving (length-1) byte symbols is the baseline gain.  The model pays
        # the piece itself and a fixed inventory/index charge.  This ranking is
        # only candidate generation; final segmentation is a shortest path.
        gain = float(count * (len(piece) - 1) - 2 * len(piece) - 8)
        if gain > 0:
            ranked.append((gain, count, piece))
    ranked.sort(key=lambda row: (-row[0], -row[1], -len(row[2]), row[2]))
    return [piece for _, _, piece in ranked[:limit]]


def best_segmentation(text: bytes, pieces: Sequence[bytes], costs: Sequence[float]) -> list[int]:
    """Viterbi segmentation with byte fallback and deterministic ties."""

    by_first: dict[int, list[tuple[int, bytes]]] = defaultdict(list)
    for index, piece in enumerate(pieces):
        by_first[piece[0]].append((index, piece))
    for values in by_first.values():
        values.sort(key=lambda row: (-len(row[1]), row[0]))
    n = len(text)
    best = [float("inf")] * (n + 1)
    prev: list[tuple[int, int] | None] = [None] * (n + 1)
    best[0] = 0.0
    for at in range(n):
        if not math.isfinite(best[at]):
            continue
        byte_symbol = text[at]
        candidate = best[at] + costs[byte_symbol]
        if candidate < best[at + 1] - 1e-12:
            best[at + 1] = candidate
            prev[at + 1] = (at, byte_symbol)
        for piece_index, piece in by_first.get(byte_symbol, ()):
            end = at + len(piece)
            if end > n or text[at:end] != piece:
                continue
            symbol = 256 + piece_index
            candidate = best[at] + costs[symbol]
            old = prev[end]
            # Prefer a longer piece, then lower symbol id on exact cost ties.
            if candidate < best[end] - 1e-12 or (
                abs(candidate - best[end]) <= 1e-12
                and (old is None or end - at > end - old[0] or symbol < old[1])
            ):
                best[end] = candidate
                prev[end] = (at, symbol)
    if prev[n] is None:
        raise ValueError("segmentation failed")
    out: list[int] = []
    at = n
    while at:
        old = prev[at]
        if old is None:
            raise ValueError("broken segmentation")
        at, symbol = old
        out.append(symbol)
    out.reverse()
    return out


@dataclass
class Model:
    pieces: tuple[bytes, ...]
    rows: tuple[Huffman, ...]
    event: Huffman
    recent_window: int
    scanner_version: int = 1

    @property
    def alphabet(self) -> int:
        return 257 + len(self.pieces)

    @property
    def event_old(self) -> int:
        return self.recent_window + 1


def train_model(train: bytes, *, max_piece_len: int = 6, piece_limit: int = 256, min_occ: int = 3, recent_window: int = 64) -> Model:
    train_atoms = atom_list(train)
    train_types = list(dict.fromkeys(train_atoms))
    pieces = build_candidates(train_types, max_piece_len, piece_limit, min_occ)
    # Start with type-weighted substring counts.  Re-segmentation after the
    # first static table is what makes this a unigram/shortest-path learner,
    # rather than a greedy pair merge.
    frequencies = [1] * (256 + len(pieces))
    for text in train_types:
        for byte in text:
            frequencies[byte] += 1
        for piece_index, piece in enumerate(pieces):
            occurrences = 0
            at = 0
            while True:
                found = text.find(piece, at)
                if found < 0:
                    break
                occurrences += 1
                at = found + 1
            frequencies[256 + piece_index] += occurrences
    total = float(sum(frequencies))
    costs = [-math.log2(freq / total) for freq in frequencies]
    paths = [best_segmentation(text, pieces, costs) for text in train_types]

    # A frozen finite-state generator: row 0 is start, other rows are the
    # previous emitted symbol's byte class.  End is always legal.
    counts = [[1] * (257 + len(pieces)) for _ in range(ROWS)]
    end_symbol = 256 + len(pieces)
    for path, text in zip(paths, train_types):
        state = 0
        for symbol in path:
            counts[state][symbol] += 1
            emitted = bytes((symbol,)) if symbol < 256 else pieces[symbol - 256]
            state = symbol_class(emitted)
        counts[state][end_symbol] += 1
    rows = tuple(Huffman.from_freq(row) for row in counts)
    # Re-price training paths with actual static code lengths once.  This
    # second shortest-path pass removes the diagnostic-only probability proxy.
    actual_costs = [float("inf")] * (256 + len(pieces))
    for symbol in range(256 + len(pieces)):
        actual_costs[symbol] = float(rows[0].lengths[symbol])
    paths = []
    counts = [[1] * (257 + len(pieces)) for _ in range(ROWS)]
    for text in train_types:
        path = best_segmentation(text, pieces, actual_costs)
        paths.append(path)
        state = 0
        for symbol in path:
            counts[state][symbol] += 1
            emitted = bytes((symbol,)) if symbol < 256 else pieces[symbol - 256]
            state = symbol_class(emitted)
        counts[state][end_symbol] += 1
    rows = tuple(Huffman.from_freq(row) for row in counts)

    # Event alphabet: NEW=0, recent gap g=1..R, OLD=R+1.  Coding the gap in
    # the static Huffman table avoids the fixed-width rank tax of the first
    # sketch while keeping the decoder entirely non-adaptive.
    event_counts = [1] * (recent_window + 2)
    seen: dict[bytes, int] = {}
    last: dict[int, int] = {}
    position = 0
    for text in train_atoms:
        identifier = seen.get(text)
        if identifier is None:
            identifier = len(seen)
            seen[text] = identifier
            event_counts[EVENT_NEW] += 1
        else:
            gap = position - last[identifier]
            event_counts[gap if gap <= recent_window else recent_window + 1] += 1
        last[identifier] = position
        position += 1
    event = Huffman.from_freq(event_counts)
    return Model(tuple(pieces), rows, event, recent_window)


def model_bytes(model: Model) -> bytes:
    """Serialize all learned rows and inventory; nothing is implicit."""

    out = bytearray()
    out += struct.pack("<BBHH", model.scanner_version, ROWS, len(model.pieces), model.recent_window)
    for piece in model.pieces:
        if not (1 <= len(piece) <= 0xFFFF):
            raise ValueError("piece too long")
        out += struct.pack("<H", len(piece))
        out += piece
    alphabet = model.alphabet
    out += struct.pack("<H", alphabet)
    for row in model.rows:
        if len(row.lengths) != alphabet:
            raise ValueError("row alphabet mismatch")
        out += bytes(row.lengths)
    if len(model.event.lengths) != model.recent_window + 2:
        raise ValueError("event alphabet mismatch")
    out += struct.pack("<H", len(model.event.lengths))
    out += bytes(model.event.lengths)
    return bytes(out)


def parse_model(data: bytes, *, max_model: int = 16 << 20) -> Model:
    if len(data) > max_model or len(data) < 6:
        raise ValueError("invalid model size")
    at = 0
    scanner, rows_count, piece_count, recent_window = struct.unpack_from("<BBHH", data, at)
    at += 6
    if scanner != 1 or rows_count != ROWS or piece_count > 4096 or not (1 <= recent_window <= 4096):
        raise ValueError("unsupported model metadata")
    pieces: list[bytes] = []
    for _ in range(piece_count):
        if at + 2 > len(data):
            raise ValueError("truncated piece length")
        length = struct.unpack_from("<H", data, at)[0]
        at += 2
        if length == 0 or at + length > len(data):
            raise ValueError("truncated piece")
        pieces.append(data[at : at + length])
        at += length
    if at + 2 > len(data):
        raise ValueError("truncated alphabet")
    alphabet = struct.unpack_from("<H", data, at)[0]
    at += 2
    if alphabet != 257 + piece_count:
        raise ValueError("wrong alphabet")
    rows: list[Huffman] = []
    for _ in range(ROWS):
        if at + alphabet > len(data):
            raise ValueError("truncated row")
        lengths = tuple(data[at : at + alphabet])
        at += alphabet
        rows.append(Huffman.from_lengths(lengths))
    if at + 2 > len(data):
        raise ValueError("model tail")
    event_alphabet = struct.unpack_from("<H", data, at)[0]
    at += 2
    if event_alphabet != recent_window + 2 or at + event_alphabet != len(data):
        raise ValueError("event alphabet")
    event = Huffman.from_lengths(tuple(data[at : at + event_alphabet]))
    return Model(tuple(pieces), tuple(rows), event, recent_window, scanner)


def encode_spelling(model: Model, text: bytes, writer: BitWriter) -> int:
    # Viterbi with the actual finite-state row costs.  The state is part of the
    # shortest-path key, so a segment can be chosen for its transition class.
    by_first: dict[int, list[tuple[int, bytes]]] = defaultdict(list)
    for index, piece in enumerate(model.pieces):
        by_first[piece[0]].append((index, piece))
    for values in by_first.values():
        values.sort(key=lambda row: (-len(row[1]), row[0]))
    n = len(text)
    # best[(position,state)] = bit cost; state 0 only at the beginning.
    best = [[float("inf")] * ROWS for _ in range(n + 1)]
    prev: list[list[tuple[int, int, int] | None]] = [[None] * ROWS for _ in range(n + 1)]
    best[0][0] = 0.0
    for at in range(n):
        for state in range(ROWS):
            if not math.isfinite(best[at][state]):
                continue
            candidates: list[tuple[int, int, bytes]] = [(at + 1, text[at], bytes((text[at],)))]
            candidates.extend((at + len(piece), 256 + index, piece) for index, piece in by_first.get(text[at], ()))
            for end, symbol, emitted in candidates:
                if end > n or text[at:end] != emitted:
                    continue
                next_state = symbol_class(emitted)
                value = best[at][state] + model.rows[state].lengths[symbol]
                old = prev[end][next_state]
                if value < best[end][next_state] - 1e-12 or (
                    abs(value - best[end][next_state]) <= 1e-12
                    and (old is None or end - at > end - old[0] or symbol < old[2])
                ):
                    best[end][next_state] = value
                    prev[end][next_state] = (at, state, symbol)
    end_symbol = 256 + len(model.pieces)
    final_state = min(range(ROWS), key=lambda state: (best[n][state] + model.rows[state].lengths[end_symbol], state))
    if prev[n][final_state] is None and n:
        raise ValueError("finite-state spelling path failed")
    path: list[tuple[int, int]] = []
    at = n
    state = final_state
    while at:
        item = prev[at][state]
        if item is None:
            raise ValueError("broken spelling path")
        old_at, old_state, symbol = item
        path.append((old_state, symbol))
        at, state = old_at, old_state
    for row, symbol in reversed(path):
        model.rows[row].write(writer, symbol)
    model.rows[final_state].write(writer, end_symbol)
    return len(path) + 1


def decode_spelling(model: Model, reader: BitReader, *, max_type: int = 1 << 20) -> bytes:
    out = bytearray()
    state = 0
    end_symbol = 256 + len(model.pieces)
    while True:
        symbol = model.rows[state].read(reader)
        if symbol == end_symbol:
            return bytes(out)
        if symbol < 256:
            emitted = bytes((symbol,))
        elif symbol < end_symbol:
            emitted = model.pieces[symbol - 256]
        else:
            raise ValueError("invalid spelling symbol")
        out += emitted
        if len(out) > max_type:
            raise ValueError("type exceeds decoder budget")
        state = symbol_class(emitted)


def encode_frame(model: Model, data: bytes) -> bytes:
    atoms = atom_list(data)
    spelling = BitWriter()
    event = BitWriter()
    known: dict[bytes, int] = {}
    last: dict[int, int] = {}
    history: list[int] = []
    spelling_types = 0
    spelling_symbols = 0
    recent_bits = 0  # retained as an explicit header field; no raw recent bits
    for position, text in enumerate(atoms):
        identifier = known.get(text)
        if identifier is None:
            identifier = len(known)
            known[text] = identifier
            model.event.write(event, EVENT_NEW)
            spelling_symbols += encode_spelling(model, text, spelling)
            spelling_types += 1
        else:
            gap = position - last[identifier]
            if gap <= model.recent_window:
                model.event.write(event, gap)
            else:
                model.event.write(event, model.event_old)
                raw = vleb(identifier)
                for byte in raw:
                    event.write(byte, 8)
        last[identifier] = position
        history.append(identifier)
    spelling_bytes, spelling_bits = spelling.finish()
    event_bytes, event_bits = event.finish()
    model_data = model_bytes(model)
    # Header length is fixed.  CRC covers everything after the header so a
    # decoder can reject a damaged model or stream before allocating output.
    header_size = 64
    header = bytearray(header_size)
    struct.pack_into(
        "<8sHHQQIIHHIIIIII",
        header,
        0,
        MAGIC,
        VERSION,
        header_size,
        len(data),
        len(atoms),
        spelling_types,
        len(model.pieces),
        model.recent_window,
        recent_bits,
        len(model_data),
        len(spelling_bytes),
        spelling_bits,
        len(event_bytes),
        event_bits,
        0,
    )
    body = model_data + spelling_bytes + event_bytes
    crc = zlib.crc32(body) & 0xFFFFFFFF
    struct.pack_into("<I", header, 60, crc)
    return bytes(header) + body


def decode_frame(frame: bytes, *, max_output: int = 1 << 30, max_model: int = 16 << 20) -> bytes:
    if len(frame) < 64:
        raise ValueError("short frame")
    fields = struct.unpack_from("<8sHHQQIIHHIIIIII", frame, 0)
    magic, version, header_size, raw_len, event_count, type_count, piece_count, recent_window, recent_bits, model_len, spelling_len, spelling_bits, event_len, event_bits, _ = fields
    if magic != MAGIC or version != VERSION or header_size != 64:
        raise ValueError("bad frame header")
    if raw_len > max_output or type_count > event_count or piece_count > 4096:
        raise ValueError("frame budget")
    if recent_window == 0 or recent_bits != 0:
        raise ValueError("recent metadata")
    end = 64 + model_len + spelling_len + event_len
    if end != len(frame):
        raise ValueError("frame section lengths")
    body = frame[64:]
    if (zlib.crc32(body) & 0xFFFFFFFF) != struct.unpack_from("<I", frame, 60)[0]:
        raise ValueError("frame crc")
    model_data = body[:model_len]
    spelling_data = body[model_len : model_len + spelling_len]
    event_data = body[model_len + spelling_len :]
    model = parse_model(model_data, max_model=max_model)
    if len(model.pieces) != piece_count or model.recent_window != recent_window:
        raise ValueError("model/header mismatch")
    spelling_reader = BitReader(spelling_data, spelling_bits)
    event_reader = BitReader(event_data, event_bits)
    known: dict[bytes, int] = {}
    values: list[bytes] = []
    history: list[int] = []
    last: dict[int, int] = {}
    out = bytearray()
    for position in range(event_count):
        symbol = model.event.read(event_reader)
        if symbol == EVENT_NEW:
            text = decode_spelling(model, spelling_reader)
            if text in known:
                raise ValueError("duplicate new type")
            identifier = len(known)
            if identifier >= type_count:
                raise ValueError("too many types")
            known[text] = identifier
            values.append(text)
        elif 1 <= symbol <= model.recent_window:
            gap = symbol
            if gap > model.recent_window or gap > len(history):
                raise ValueError("bad recent gap")
            identifier = history[position - gap]
            if identifier >= len(values):
                raise ValueError("unknown recent type")
            text = values[identifier]
        elif symbol == model.event_old:
            value = 0
            shift = 0
            while True:
                byte = event_reader.read(8)
                value |= (byte & 0x7F) << shift
                if byte < 0x80:
                    break
                shift += 7
                if shift > 28:
                    raise ValueError("old id overflow")
            identifier = value
            if identifier >= len(known):
                raise ValueError("unknown old type")
            if identifier >= len(values):
                raise ValueError("unknown old type")
            text = values[identifier]
        else:
            raise ValueError("invalid event symbol")
        out += text
        if len(out) > raw_len:
            raise ValueError("output overflow")
        history.append(identifier)
        last[identifier] = position
    if len(known) != type_count or len(out) != raw_len:
        raise ValueError("frame count mismatch")
    if spelling_reader.remaining() > 7 or event_reader.remaining() > 7:
        raise ValueError("noncanonical stream tail")
    # Padding bits are required to be zero.  This catches accidental trailing
    # data while allowing the final byte to be naturally aligned.
    for reader in (spelling_reader, event_reader):
        while reader.remaining():
            if reader.read(1):
                raise ValueError("nonzero stream padding")
    return bytes(out)


def breakdown(frame: bytes) -> dict[str, int]:
    if len(frame) < 64:
        raise ValueError("short frame")
    fields = struct.unpack_from("<8sHHQQIIHHIIIIII", frame, 0)
    _, _, _, _, _, _, _, _, _, model_len, spelling_len, _, event_len, _, _ = fields
    return {"header": 64, "model": model_len, "spelling": spelling_len, "events": event_len, "total": len(frame)}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_one(train_path: Path, input_path: Path, output_path: Path, args: argparse.Namespace) -> None:
    train = train_path.read_bytes()
    data = input_path.read_bytes()
    model = train_model(train, max_piece_len=args.max_piece_len, piece_limit=args.piece_limit, min_occ=args.min_occ, recent_window=args.recent_window)
    frame = encode_frame(model, data)
    decoded = decode_frame(frame)
    if decoded != data:
        raise RuntimeError("round trip mismatch")
    output_path.write_bytes(frame)
    info = breakdown(frame)
    print(
        f"input={input_path} train={train_path} input_bytes={len(data)} "
        f"input_sha256={sha256(data)} frame_sha256={sha256(frame)} "
        f"types={struct.unpack_from('<I', frame, 28)[0]} pieces={len(model.pieces)} "
        f"header={info['header']} model={info['model']} spelling={info['spelling']} "
        f"events={info['events']} total={info['total']} roundtrip=ok"
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("train", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--max-piece-len", type=int, default=6)
    parser.add_argument("--piece-limit", type=int, default=256)
    parser.add_argument("--min-occ", type=int, default=3)
    parser.add_argument("--recent-window", type=int, default=64)
    args = parser.parse_args(argv)
    run_one(args.train, args.input, args.output, args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
