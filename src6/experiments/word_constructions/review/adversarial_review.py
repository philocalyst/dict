#!/usr/bin/env python3
"""Independent WPG2 envelope and constructor probes on a retained archive.

Run with `python3 review/adversarial_review.py`. This deliberately uses the
public binaries and reseals outer CRCs when mutating headers or native bytes.
It does not call the research encoder or depend on a compressor search.
"""
import hashlib
import json
import random
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import compose_page
from compose_best import inverse
from template_split import getvar, varint

ARCHIVE = Path("/workspace/scratch/wpg2-audit/omw-8m-strong-hoist-cb19cecf.wpg2")
SOURCE = ROOT / "src6/experiments/bzip4/language_frontier/evidence/runs/storage-screen-auto-20260926-strict/samples/omw-eval8-saved/external-decoded.bin"
READER = HERE / "prepared_wpg"
REGISTERS = HERE / "register_decode"
NATIVE = ROOT / "src6/experiments/wordgrammar/wgp6/native"
PAGE = 65536


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parts(blob):
    if blob[:4] != b"WPG2":
        raise ValueError("fixture magic")
    at = 5
    raw, at = getvar(blob, at)
    page, at = getvar(blob, at)
    count, at = getvar(blob, at)
    entries = []
    for _ in range(count):
        n, at = getvar(blob, at)
        entries.append((n, struct.unpack_from("<I", blob, at)[0]))
        at += 4
    at += 4  # header CRC
    frame_size, at = getvar(blob, at)
    return blob[4], raw, page, entries, blob[at:at+frame_size], blob[at+frame_size:]


def seal(mode, raw, page, entries, frame, tail):
    header = (b"WPG2" + bytes((mode,)) + varint(raw) + varint(page) +
              varint(len(entries)) + b"".join(varint(n)+struct.pack("<I", crc)
                                               for n, crc in entries))
    return header + struct.pack("<I", zlib.crc32(header)) + varint(len(frame)) + frame + tail


def native_spans(frame):
    at = 4
    header, at = getvar(frame, at)
    at += header
    spans = []
    while at < len(frame):
        kind = frame[at]
        at += 1
        if kind == 0:
            break
        delta = payload = 0
        delta_bytes_at = None
        if kind & 1:
            _, at = getvar(frame, at)  # definitions
            delta_bytes_at = at
            _, at = getvar(frame, at)
            delta, at = getvar(frame, at)
        if kind & 2:
            _, at = getvar(frame, at)  # raw length
            _, at = getvar(frame, at)  # tokens
            payload, at = getvar(frame, at)
        spans.append((delta_bytes_at, at, delta, at+delta, payload))
        at += delta + payload
    return spans


def execute(op, blob, index=None):
    with tempfile.TemporaryDirectory(prefix="wpg2-review-") as directory:
        archive = Path(directory) / "archive"
        output = Path(directory) / "output"
        archive.write_bytes(blob)
        args = [str(READER), op, str(archive), str(output)]
        if index is not None:
            args += ["--index", str(index)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        return result.returncode, result.stderr.strip(), output.read_bytes() if output.exists() else b""


def check_constructor_boundaries():
    rng = random.Random(827191)
    ancestor = b'<parent id="abcdefghijklmno0123456789tail">'
    child = b'<child copy="abcdefghijklmno0123456789tail" />'
    local = b'<item id="stem-XYZ-tail" members="stem-A-tail stem-B-tail" />'
    cases = [
        b"\x00\x01\x00\x02\x00\x03\xff\xfe" + ancestor + child + local + b"</parent>",
        b"x"*(PAGE-4) + b"<par" + b'ent id="crosspage">' + child,
        ancestor + b"x"*(PAGE-len(ancestor)) + child + local,
        b'<x id="' + b"a"*4086 + b'">' + local,  # 4095-byte tag
        b'<x id="' + b"a"*4087 + b'">' + local,  # 4096-byte tag
        b'<x id="' + b"a"*4088 + b'">' + local,  # 4097-byte tag
        b'<x id="' + b"a"*256 + b'">' + child + b'<x id="' + b"a"*257 + b'">',
        b"<root id=\"a\">"*33 + child + b"</root>"*33,
        b'<x '+b" ".join(b'f%d="abcdefghijk"'%i for i in range(33))+b' />'+local,
    ]
    for empty_fields in (255, 256, 257):
        cases.append(b'<x ' + b' '.join([b'a=""']*empty_fields +
                     [b'a="prefix-aaaa-suffix"',
                      b'b="prefix-X-suffix prefix-Y-suffix prefix-Z-suffix"']) + b' />')
    scoped_parent = b'<parent id="abcdefghij12345tail">'
    scoped_child = b'<child copy="abcdefghij12345tail" />'
    field_31 = b'<parent '+b' '.join([b'a=""']*31+[b'a="abcdefghij12345tail"'])+b'>'
    field_32 = b'<parent '+b' '.join([b'a=""']*32+[b'a="abcdefghij12345tail"'])+b'>'
    cases += [field_31+scoped_child+b'</parent>', field_32+scoped_child+b'</parent>',
              scoped_parent+b'<n>'*31+scoped_child+b'</n>'*31+b'</parent>',
              b'<root>'+b'<n>'*32+scoped_parent+scoped_child+b'</parent>'+b'</n>'*32+b'</root>']
    assert compose_page.scope_register.forward(cases[-4])[1]["slices"] > 0
    assert compose_page.scope_register.forward(cases[-3])[1]["slices"] == 0
    assert compose_page.scope_register.forward(cases[-2])[1]["slices"] > 0
    assert compose_page.scope_register.forward(cases[-1])[1]["slices"] == 0
    for _ in range(100):
        noise = rng.randbytes(rng.randrange(1, 350))
        at = rng.randrange(len(noise)+1)
        cases.append(noise[:at]+local+noise[at:])

    page_groups = [[case[i:i+PAGE] for i in range(0, len(case), PAGE)] or [b""] for case in cases]
    checked = 0
    for mode in (0, 1, 2, 3):
        for pages in page_groups:
            transformed = [compose_page.transform_page(page, mode)[0] for page in pages]
            for original, encoded in zip(pages, transformed):
                if inverse(encoded, mode) != original:
                    raise AssertionError("Python constructor mismatch")
            with tempfile.TemporaryDirectory(prefix="wpg2-construct-") as directory:
                src = Path(directory) / "source"
                idx = Path(directory) / "lengths"
                dst = Path(directory) / "restored"
                src.write_bytes(b"".join(transformed))
                idx.write_text("".join(f"{len(p)}\n" for p in transformed))
                run = subprocess.run([str(REGISTERS), str(mode), str(src), str(dst), "--pages", str(idx)],
                                     capture_output=True, text=True, timeout=5)
                if run.returncode or dst.read_bytes() != b"".join(pages):
                    raise AssertionError((mode, run.stderr, len(b"".join(pages))))
            checked += 1
    return checked


def check_all_modes():
    raw = (b'\x00\xff<parent id="abcdefghij12345tail">'
           b'<child copy="abcdefghij12345tail" /></parent>'
           b'<item id="prefix-AAAA-suffix" members="prefix-BBBB-suffix prefix-CCCC-suffix" />\xfe')
    for mode in range(4):
        transformed, _ = compose_page.transform_page(raw, mode)
        with tempfile.TemporaryDirectory(prefix="wpg2-mode-") as directory:
            source = Path(directory) / "source"
            frame = Path(directory) / "frame"
            source.write_bytes(transformed)
            run = subprocess.run([str(NATIVE), "original", str(source), str(frame), "65536"],
                                 capture_output=True, text=True, timeout=15)
            assert run.returncode == 0, (mode, run.stderr)
            archive = seal(mode, len(raw), PAGE, [(len(transformed), zlib.crc32(raw))],
                           frame.read_bytes(), struct.pack("<I", zlib.crc32(raw)))
            for operation in ("decode", "query"):
                code, error, output = execute(operation, archive, 0 if operation == "query" else None)
                assert code == 0 and output == raw, (mode, operation, error)
    return 4


def check_envelope(blob, raw):
    mode, size, page, entries, frame, tail = parts(blob)
    assert len(raw) == size and sha(raw) == "d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261"
    assert mode == 3 and page == PAGE and len(entries) == 128
    good = 0
    for index in (0, 63, 127):
        code, error, output = execute("query", blob, index)
        assert code == 0, error
        assert output == raw[index*PAGE:(index+1)*PAGE]
        good += 1

    altered = list(entries)
    altered[0] = (entries[0][0], entries[0][1] ^ 1)
    cases = {
        "bad_magic": b"X" + blob[1:],
        "bad_mode_resealed": seal(4, size, page, entries, frame, tail),
        "bad_page_geometry_resealed": seal(mode, size, PAGE//2, entries, frame, tail),
        "bad_raw_bound_resealed": seal(mode, 32*1024*1024+1, page, entries, frame, tail),
        "bad_page_length_resealed": seal(mode, size, page, [(2*PAGE+1, entries[0][1])]+entries[1:], frame, tail),
        "bad_page_crc_resealed": seal(mode, size, page, altered, frame, tail),
        "bad_transformed_offsets_resealed": seal(mode, size, page,
                                                  [(entries[0][0]+1, entries[0][1])] + entries[1:-1] +
                                                  [(entries[-1][0]-1, entries[-1][1])], frame, tail),
        "frame_tail": blob + b"x",
    }
    for label, candidate in cases.items():
        code, error, _ = execute("query", candidate, 0)
        assert code != 0, (label, error)
        assert code > 0, (label, "process signal", code)

    bad_global = seal(mode, size, page, entries, frame, struct.pack("<I", struct.unpack("<I", tail)[0] ^ 1))
    assert execute("query", bad_global, 0)[0] == 0  # page CRC is independent
    code, error, output = execute("decode", bad_global)
    assert code != 0 and "global CRC" in error and output == b""  # no partial output
    with tempfile.TemporaryDirectory(prefix="wpg2-atomic-") as directory:
        archive = Path(directory) / "archive"
        output = Path(directory) / "output"
        archive.write_bytes(bad_global)
        output.write_bytes(b"existing verified output")
        run = subprocess.run([str(READER), "decode", str(archive), str(output)],
                             capture_output=True, text=True, timeout=15)
        assert run.returncode != 0 and output.read_bytes() == b"existing verified output"
        assert not list(Path(directory).glob("output.tmp.*"))

    spans = native_spans(frame)
    # A damaged final entropy payload must leave the first page query alone.
    last = next(span for span in reversed(spans) if span[4])
    damaged = bytearray(frame)
    damaged[last[3]+last[4]//2] ^= 0x5a
    selected_payload = seal(mode, size, page, entries, bytes(damaged), tail)
    assert execute("query", selected_payload, 0)[2] == raw[:PAGE]
    assert execute("query", selected_payload, len(entries)-1)[0] != 0
    assert execute("decode", selected_payload)[0] != 0

    # Legacy native v4 would reserve the declared output for a delta before
    # validating its size. WPG2's private preflight must reject this reseal.
    first = next(span for span in spans if span[0] is not None)
    declaration_at = first[0]
    _, declaration_end = getvar(frame, declaration_at)
    inflated = frame[:declaration_at] + varint(64*1024*1024+1) + frame[declaration_end:]
    unbounded_delta = seal(mode, size, page, entries, inflated, tail)
    code, error, _ = execute("query", unbounded_delta, 0)
    assert code > 0 and "model preparation failed" in error

    # Rewriting a payload token count above its raw byte count must fail in
    # preflight, even when the requested page does not touch that payload.
    at = 4
    header, at = getvar(frame, at)
    at += header
    excessive_items = None
    while at < len(frame):
        kind = frame[at]
        at += 1
        if kind == 0:
            break
        delta = payload = 0
        if kind & 1:
            _, at = getvar(frame, at)
            _, at = getvar(frame, at)
            delta, at = getvar(frame, at)
        if kind & 2:
            raw_len, at = getvar(frame, at)
            item_at = at
            _, at = getvar(frame, at)
            item_end = at
            payload, at = getvar(frame, at)
            if raw_len < 65536:
                excessive_items = frame[:item_at]+varint(raw_len+1)+frame[item_end:]
                break
        at += delta+payload
    assert excessive_items is not None
    inflated_items = seal(mode, size, page, entries, excessive_items, tail)
    code, error, _ = execute("query", inflated_items, 0)
    assert code > 0 and "model preparation failed" in error
    return good, len(cases)+8


def main():
    blob = ARCHIVE.read_bytes()
    raw = SOURCE.read_bytes()
    constructor_cases = check_constructor_boundaries()
    modes = check_all_modes()
    pages, mutations = check_envelope(blob, raw)
    print(json.dumps({"archive_sha256": sha(blob), "reader_sha256": sha(READER.read_bytes()),
                      "constructor_cases": constructor_cases, "small_native_modes": modes,
                      "selected_pages": pages,
                      "resealed_or_malformed_cases": mutations, "status": "pass"}))


if __name__ == "__main__":
    main()
