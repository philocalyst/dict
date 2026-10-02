#!/usr/bin/env python3
"""Byte-only full-frame zstd19 screen; each page remains independent.

Also tests reversible shape-hole transposition. Template identity and hole
position define each column, so every literal's exact context/order is restored
without a second lexical schema. Both complete original metadata and transform
markers are charged. This is a compressor cost oracle, not a direct-view format.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import platform
import struct
import zstandard


def u32(data: bytes, at: int) -> int:
    return struct.unpack_from("<I", data, at)[0]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bundle(path: pathlib.Path):
    data = path.read_bytes()
    assert len(data) >= 64 and data[:5] == b"LPB1\x02"
    assert hashlib.sha256(data[:32] + data[64:]).digest() == data[32:64]
    pages, roots = u32(data, 8), u32(data, 12)
    assert u32(data, 16) == 24
    cursor, next_root, frames, groups = 64 + pages * 24, 0, [], []
    for i in range(pages):
        at = 64 + i * 24
        start, count, raw, stored, offset = struct.unpack_from("<5I", data, at)
        assert start == next_root and offset == cursor and data[at + 20] == 0
        assert raw == stored and stored <= len(data) - cursor
        frame = data[cursor:cursor + stored]
        assert frame[:4] in (b"LPD1", b"LPS1")
        assert hashlib.sha256(frame[:32] + frame[64:]).digest() == frame[32:64]
        frames.append(frame)
        groups.append((start, count))
        cursor += stored
        next_root += count
    assert cursor == len(data) and next_root == roots
    return data, frames, groups


def varint(data: bytes, at: int):
    value = 0
    for i in range(10):
        byte = data[at]
        at += 1
        assert i != 9 or byte <= 1
        value |= (byte & 127) << (i * 7)
        if byte < 128:
            assert i == 0 or byte != 0
            return value, at
    raise AssertionError("overlong varint")


def shape_literals(frame: bytes):
    assert frame[:4] == b"LPS1"
    root_count, nodes, _, lane_size = struct.unpack_from("<4I", frame, 8)
    roots_at = 64 + (nodes + 1) * 4
    lane_at = len(frame) - lane_size
    rows, shapes, counts = [], [], []
    for i in range(root_count):
        template, offset, size, _, leaves = struct.unpack_from("<5I", frame, roots_at + i * 20)
        at, end, tokens = lane_at + offset, lane_at + offset + size, []
        for _ in range(leaves):
            start = at
            length, at = varint(frame, at)
            assert length <= end - at
            at += length
            tokens.append(frame[start:at])
        assert at == end
        rows.append(tokens)
        shapes.append(template)
        counts.append(leaves)
    return lane_at, rows, shapes, counts


def transpose(frame: bytes, columns: bool) -> bytes:
    lane_at, rows, shapes, counts = shape_literals(frame)
    lane = []
    for template in sorted(set(shapes)):
        indices = [i for i, kind in enumerate(shapes) if kind == template]
        assert len({counts[i] for i in indices}) == 1
        if columns:
            lane.extend(rows[i][hole] for hole in range(counts[indices[0]]) for i in indices)
        else:
            lane.extend(token for i in indices for token in rows[i])
    result = b"LPT1" + bytes((1 if columns else 0, 0, 0, 0)) + frame[:lane_at] + b"".join(lane)
    assert len(result) == len(frame) + 8
    assert restore(result) == frame
    return result


def restore(transformed: bytes) -> bytes:
    assert transformed[:4] == b"LPT1" and transformed[4] in (0, 1)
    frame = transformed[8:]
    root_count, nodes, _, lane_size = struct.unpack_from("<4I", frame, 8)
    roots_at, lane_at = 64 + (nodes + 1) * 4, len(frame) - lane_size
    shapes, counts = [], []
    for i in range(root_count):
        template, _, _, _, leaves = struct.unpack_from("<5I", frame, roots_at + i * 20)
        shapes.append(template)
        counts.append(leaves)
    rows = [[b""] * n for n in counts]
    at = lane_at
    for template in sorted(set(shapes)):
        indices = [i for i, kind in enumerate(shapes) if kind == template]
        coordinates = ((i, h) for h in range(counts[indices[0]]) for i in indices) if transformed[4] else ((i, h) for i in indices for h in range(counts[i]))
        for i, h in coordinates:
            start = at
            length, at = varint(frame, at)
            assert length <= len(frame) - at
            at += length
            rows[i][h] = frame[start:at]
    assert at == len(frame)
    result = frame[:lane_at] + b"".join(token for row in rows for token in row)
    assert hashlib.sha256(result[:32] + result[64:]).digest() == result[32:64]
    return result


def compressed_bundle(variant: int, groups, frames, blocks) -> bytes:
    """Actual independently decodable LPZ1 envelope, including its digest."""
    output = bytearray(64 + 24 * len(groups))
    output[:4] = b"LPZ1"
    output[4:6] = bytes((1, variant))
    struct.pack_into("<3I", output, 8, len(groups), sum(count for _, count in groups), 24)
    struct.pack_into("<Q", output, 24, sum(map(len, frames)))
    for i, ((start, count), frame, block) in enumerate(zip(groups, frames, blocks)):
        struct.pack_into("<5I", output, 64 + i * 24, start, count, len(frame), len(block), len(output))
        output[64 + i * 24 + 20] = 2  # experimental zstd codec marker
        output.extend(block)
    output[32:64] = hashlib.sha256(output[:32] + output[64:]).digest()
    result = bytes(output)
    assert len(result) == 64 + 24 * len(groups) + sum(map(len, blocks))
    assert hashlib.sha256(result[:32] + result[64:]).digest() == result[32:64]
    decoder = zstandard.ZstdDecompressor()
    for i, frame in enumerate(frames):
        raw, size, at = struct.unpack_from("<3I", result, 64 + i * 24 + 8)
        assert result[64 + i * 24 + 20] == 2 and raw == len(frame)
        assert decoder.decompress(result[at:at + size], max_output_size=raw) == frame
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("prefix", type=pathlib.Path)
    parser.add_argument("--retain-directory", type=pathlib.Path)
    args = parser.parse_args()
    fixed, source_hashes, groups = {}, {}, None
    for name in ("flat", "shared", "shape"):
        path = pathlib.Path(f"{args.prefix}.{name}.raw.lpb")
        raw, frames, selected = read_bundle(path)
        assert groups is None or groups == selected
        groups = selected
        fixed[name] = frames
        source_hashes[str(path)] = sha(raw)
    fixed["shape_template_rows"] = [transpose(frame, False) for frame in fixed["shape"]]
    fixed["shape_template_columns"] = [transpose(frame, True) for frame in fixed["shape"]]
    compressor = zstandard.ZstdCompressor(level=19)
    decompressor = zstandard.ZstdDecompressor()
    compressed, artifacts = {}, {}
    overhead = 64 + 24 * len(groups)
    for name, frames in fixed.items():
        blocks = [compressor.compress(frame) for frame in frames]
        for original, block in zip(frames, blocks):
            restored = decompressor.decompress(block, max_output_size=len(original))
            assert restored == original
            if name.startswith("shape_template_"):
                assert restore(restored) in fixed["shape"]
        compressed[name] = blocks
        artifacts[name] = compressed_bundle(len(artifacts), groups, frames, blocks)
        record = {
            "representation": name, "backend": "zstd19", "pages": len(groups),
            "roots": sum(count for _, count in groups), "complete_bytes": len(artifacts[name]),
            "artifact_sha256": sha(artifacts[name]),
            "raw_complete_bytes": overhead + sum(map(len, frames)),
            "outer_header_directory_bytes": overhead, "max_decoded_frame_bytes": max(map(len, frames), default=0),
            "transform_header_bytes_per_page": 8 if name.startswith("shape_template_") else 0,
            "gate": "every independent compressed frame exact; transposition restores original fully admitted frame digest",
        }
        print(json.dumps(record, sort_keys=True))
    names = tuple(compressed)
    choices = [min(names, key=lambda name: (len(compressed[name][i]), names.index(name))) for i in range(len(groups))]
    artifacts["compressed_minimum"] = compressed_bundle(len(names), groups, [fixed[name][i] for i, name in enumerate(choices)], [compressed[name][i] for i, name in enumerate(choices)])
    print(json.dumps({"representation": "compressed_minimum", "backend": "zstd19", "complete_bytes": len(artifacts["compressed_minimum"]), "artifact_sha256": sha(artifacts["compressed_minimum"]), "choices": {name: choices.count(name) for name in names}, "encoding_trials_paid": len(names) * len(groups)}, sort_keys=True))
    print(json.dumps({"provenance": {"python": platform.python_version(), "zstandard_python": zstandard.__version__, "zstandard_library": zstandard.ZSTD_VERSION, "script_sha256": sha(pathlib.Path(__file__).read_bytes()), "input_bundles": source_hashes, "timing": False, "scope": "same common root groups; outer ordinal envelope costs charged; no lexical/identity indexes; normal pages originally <=64KiB; transform adds8B; exceptional single-large-root pages explicit in source report"}}, sort_keys=True))
    if args.retain_directory:
        args.retain_directory.mkdir(parents=True, exist_ok=True)
        for name, blocks in compressed.items():
            for i, block in enumerate(blocks):
                (args.retain_directory / f"{name}.{i:05d}.zst").write_bytes(block)
        for name, artifact in artifacts.items():
            (args.retain_directory / f"{name}.lpz").write_bytes(artifact)


if __name__ == "__main__":
    main()
