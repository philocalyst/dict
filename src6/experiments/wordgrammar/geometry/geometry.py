#!/usr/bin/env python3
"""Exact whitespace geometry proposal; native v4 remains the payload backend."""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

SCALE = 4096
LOW = 1 << 23
HEADER = struct.Struct("<4sIIQIIIHHIII")
LIMIT = 64 * 1024 * 1024
TOKENS = re.compile(rb"[^ \n]+|[ \n]+")


def parts(raw):
    return [m.group() for m in TOKENS.finditer(raw)]


def advance(column, text):
    last = text.rfind(b"\n")
    return len(text) - last - 1 if last >= 0 else column + len(text)


def propose(raw, width):
    words = parts(raw)
    normalized, events, column = [], [], 0
    for index, word in enumerate(words):
        if word in (b" ", b"\n") and index + 1 < len(words):
            prediction = int(column + 1 + len(words[index + 1]) > width)
            events.append((prediction, prediction ^ int(word == b"\n")))
            normalized.append(b" ")
        else:
            normalized.append(word)
        column = advance(column, word)
    return b"".join(normalized), events


def frequencies(events):
    counts = [[0, 0], [0, 0]]
    for context, symbol in events:
        counts[context][symbol] += 1
    rows = []
    for zeros, ones in counts:
        if not zeros:
            rows.append(0 if ones else SCALE // 2)
        elif not ones:
            rows.append(SCALE)
        else:
            rows.append(max(1, min(SCALE - 1, round(SCALE * zeros / (zeros + ones)))))
    return rows


def pack(events, rows):
    state, emitted = LOW, bytearray()
    for context, symbol in reversed(events):
        zero = rows[context]
        start, frequency = (0, zero) if symbol == 0 else (zero, SCALE - zero)
        if not frequency:
            raise ValueError("zero-probability geometry event")
        maximum = ((LOW >> 12) << 8) * frequency
        while state >= maximum:
            emitted.append(state & 255)
            state >>= 8
        state = (state // frequency) * SCALE + state % frequency + start
    return struct.pack("<I", state) + bytes(reversed(emitted))


def realize(normalized, flags, rows, count, width):
    if len(rows) != 2 or any(not 0 <= row <= SCALE for row in rows):
        raise ValueError("invalid geometry probabilities")
    if not 1 <= width <= 4096 or not 0 <= count <= len(normalized):
        raise ValueError("invalid geometry geometry")
    if len(flags) < 4:
        raise ValueError("truncated geometry state")
    state, = struct.unpack_from("<I", flags)
    if not LOW <= state < LOW * 256:
        raise ValueError("invalid geometry state")
    position, seen, column = 4, 0, 0
    words, output = parts(normalized), []
    for index, word in enumerate(words):
        if word in (b" ", b"\n") and index + 1 < len(words):
            if word != b" " or seen >= count:
                raise ValueError("geometry slot mismatch")
            context = int(column + 1 + len(words[index + 1]) > width)
            zero = rows[context]
            residue = state & (SCALE - 1)
            symbol = int(residue >= zero)
            start, frequency = (0, zero) if symbol == 0 else (zero, SCALE - zero)
            if not frequency:
                raise ValueError("invalid geometry probability")
            state = frequency * (state >> 12) + residue - start
            while state < LOW:
                if position >= len(flags):
                    raise ValueError("truncated geometry bytes")
                state = (state << 8) | flags[position]
                position += 1
            word = b"\n" if (context ^ symbol) else b" "
            seen += 1
        output.append(word)
        column = advance(column, word)
    if seen != count or position != len(flags) or state != LOW:
        raise ValueError("noncanonical geometry tail")
    return b"".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["encode", "decode"])
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--native", default="/tmp/frontier2026-bzip4-v3")
    parser.add_argument("--reference", type=Path, help="optional faithful LaneA+M native reference encoder")
    parser.add_argument("--width", type=int, default=72)
    args = parser.parse_args()
    if not 1 <= args.width <= 4096 or args.source.stat().st_size > 512 * 1024 * 1024:
        raise ValueError("geometry resource limit")
    source = args.source.read_bytes()
    source_identity = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    decoder_identity = hashlib.sha256(Path(args.native).read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        a, b = directory / "source", directory / "native"
        if args.operation == "encode":
            if len(source) > LIMIT:
                raise ValueError("geometry input limit")
            normalized, events = propose(source, args.width)
            rows = frequencies(events)
            flags = pack(events, rows)
            if realize(normalized, flags, rows, len(events), args.width) != source:
                raise ValueError("geometry proposal does not reconstruct source")
            a.write_bytes(normalized)
            encode_command = ([str(args.reference), str(a), str(b), str(directory / "parse"),
                               "65536", "20", "a-best", "1"] if args.reference else
                              [args.native, "encode", str(a), str(b), "--block", "65536"])
            encoder_identity = hashlib.sha256(Path(encode_command[0]).read_bytes()).hexdigest()
            native = subprocess.run(encode_command,
                                    check=True, capture_output=True, text=True)
            if (hashlib.sha256(Path(encode_command[0]).read_bytes()).hexdigest() != encoder_identity or
                    hashlib.sha256(Path(args.native).read_bytes()).hexdigest() != decoder_identity or
                    hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != source_identity):
                raise ValueError("geometry source or native executable changed during experiment")
            coded = b.read_bytes()
            fields = [b"GWP1", 1, args.width, len(source), len(events), len(coded), len(flags),
                      *rows, zlib.crc32(source), zlib.crc32(normalized), 0]
            header = HEADER.pack(*fields)
            fields[-1] = zlib.crc32(header)
            frame = HEADER.pack(*fields) + coded + flags
            args.output.write_bytes(frame)
            print(json.dumps({"frame_bytes": len(frame), "native_payload_bytes": len(coded),
                "flags_bytes": len(flags), "header_bytes": HEADER.size,
                "eligible_separators": len(events), "rows": rows, "width": args.width,
                "source_sha256": hashlib.sha256(source).hexdigest(),
                "normalized_sha256": hashlib.sha256(normalized).hexdigest(),
                "frame_sha256": hashlib.sha256(frame).hexdigest(),
                "native_events": [json.loads(line) for line in native.stdout.splitlines()],
                "native_encoder_sha256": encoder_identity,
                "native_decoder_sha256": decoder_identity,
                "source_identity": source_identity,
                "scope": "whole-frame experimental transducer; interleaved native deltas; no independent restart claim; Python clocks not native throughput"}))
        else:
            if len(source) < HEADER.size:
                raise ValueError("truncated geometry header")
            fields = list(HEADER.unpack_from(source))
            magic, version, width, raw, count, native_len, flag_len, zero0, zero1, crc, normalized_crc, header_crc = fields
            fields[-1] = 0
            if (magic != b"GWP1" or version != 1 or not 1 <= width <= 4096 or raw > LIMIT
                    or count > raw or zero0 > SCALE or zero1 > SCALE
                    or native_len + flag_len != len(source) - HEADER.size
                    or zlib.crc32(HEADER.pack(*fields)) != header_crc):
                raise ValueError("invalid geometry header")
            a.write_bytes(source[HEADER.size:HEADER.size + native_len])
            subprocess.run([args.native, "decode", str(a), str(b)], check=True, capture_output=True)
            normalized = b.read_bytes()
            if len(normalized) != raw or zlib.crc32(normalized) != normalized_crc:
                raise ValueError("invalid normalized bytes")
            output = realize(normalized, source[HEADER.size + native_len:], [zero0, zero1], count, width)
            if len(output) != raw or zlib.crc32(output) != crc:
                raise ValueError("geometry output checksum")
            args.output.write_bytes(output)


if __name__ == "__main__":
    main()
