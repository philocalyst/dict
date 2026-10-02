#!/usr/bin/env python3
"""One fixed SED2 segmentation-only DEV diagnostic on six books."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import sed2_screen

PREFIX = 1048576
HEADER = 64


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verified_json(path: Path, expected: str):
    content = path.read_bytes()
    if digest(content) != expected:
        raise ValueError(f"manifest/control identity changed: {path}")
    return json.loads(content)


def command(argv: list[str]) -> bytes:
    proc = subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.stdout


def compress(bz3: Path, source: Path, frame: Path) -> bytes:
    data = command([str(bz3), "-c", "-b", "32", str(source)])
    frame.write_bytes(data)
    if command([str(bz3), "-d", "-c", str(frame)]) != source.read_bytes():
        raise ValueError("fresh bzip3 decode mismatch")
    return data


def make_header(raw: bytes, route_len: int, literal_len: int) -> bytes:
    header = bytearray(b"SED1" + bytes([1, 0, 0, 0]))
    for number in (len(raw), route_len, literal_len):
        header.extend(number.to_bytes(8, "little"))
    header.extend(hashlib.sha256(raw).digest())
    assert len(header) == HEADER
    return bytes(header)


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit("usage: run_six.py MANIFEST CONTROLS BZ3 OUTPUT_DIR EVIDENCE_JSON")
    manifest_path, controls_path, bz3, out, evidence_path = map(Path, sys.argv[1:])
    manifest = verified_json(manifest_path, "ee6cf531c46f704d6b5af36ca1fafd5ee16b44cc71d76c17d09ed566c623ef9d")
    controls = verified_json(controls_path, "640c4ed24bc1f2753f0a4f2fe8abf6ac3f7dee7ce2612aab294a732bbba2256f")
    if len(manifest["books"]) != 6:
        raise ValueError("expected fixed six books")
    by_book = {(row["book"], row["codec"]): row for row in controls["rows"]}
    if not bz3.is_file():
        raise ValueError("missing pinned bzip3 binary")
    out.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "development_diagnostic_bzip3_backend_not_new_native_codec",
        "source_script_sha256": digest(Path(sed2_screen.__file__).read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "manifest_sha256": digest(manifest_path.read_bytes()),
        "controls_sha256": digest(controls_path.read_bytes()),
        "backend_path": str(bz3.resolve()),
        "backend_sha256": digest(bz3.read_bytes()),
        "header_bytes": HEADER,
        "cases": [],
    }
    for book in manifest["books"]:
        name = book["id"]
        prefix = next((p for p in book["prefixes"] if p["byte_limit"] == PREFIX), None)
        if prefix is None:
            raise ValueError(f"missing fixed prefix {name}")
        source = Path(prefix["path"])
        raw = source.read_bytes()
        if len(raw) != prefix["bytes"] or digest(raw) != prefix["sha256"]:
            raise ValueError(f"source mismatch {name}")
        control = by_book[name, "bzip3"]
        if control["source_sha256"] != prefix["sha256"] or not control["exact_source_verified"]:
            raise ValueError(f"control mismatch {name}")
        case_dir = out / name
        command([sys.executable, str(Path(sed2_screen.__file__)), str(source), str(case_dir)])
        transform = json.loads((case_dir / "transform.json").read_text())
        if transform["source_sha256"] != prefix["sha256"] or not transform["full_inverse_exact"]:
            raise ValueError(f"transform mismatch {name}")
        optimistic = compress(bz3, case_dir / "optimistic-literal.bin", case_dir / "optimistic-literal.bz3")
        route_frame = compress(bz3, case_dir / "route.bin", case_dir / "route.bz3")
        literal_frame = compress(bz3, case_dir / "paid-literal.bin", case_dir / "paid-literal.bz3")
        route = command([str(bz3), "-d", "-c", str(case_dir / "route.bz3")])
        literal = command([str(bz3), "-d", "-c", str(case_dir / "paid-literal.bz3")])
        reconstructed, pages = sed2_screen.decode(route, literal)
        if reconstructed != raw or any(page != raw[i * sed2_screen.PAGE : (i + 1) * sed2_screen.PAGE] for i, page in enumerate(pages)):
            raise ValueError(f"full/page decode mismatch {name}")
        header = make_header(raw, len(route_frame), len(literal_frame))
        paid_frame = header + route_frame + literal_frame
        (case_dir / "paid.sed2").write_bytes(paid_frame)
        bzip3_bytes = control["complete_frame_bytes"]
        case = {
            "book_id": name,
            "language": book["language"],
            "source_path": str(source),
            "source_bytes": len(raw),
            "source_sha256": digest(raw),
            "bzip3_control_bytes": bzip3_bytes,
            "bzip3_control_sha256": control["frame_sha256"],
            "optimistic_free_donor_position_residual_frame_bytes": len(optimistic),
            "optimistic_free_donor_position_residual_frame_sha256": digest(optimistic),
            "route_frame_bytes": len(route_frame),
            "route_frame_sha256": digest(route_frame),
            "literal_frame_bytes": len(literal_frame),
            "literal_frame_sha256": digest(literal_frame),
            "paid_envelope_bytes": HEADER,
            "paid_two_backend_frame_diagnostic_bytes": len(paid_frame),
            "paid_two_backend_frame_sha256": digest(paid_frame),
            "paid_to_bzip3_ratio": len(paid_frame) / bzip3_bytes,
            "optimistic_to_bzip3_ratio": len(optimistic) / bzip3_bytes,
            "all_source_pages_exact": len(pages),
            "transform": transform,
        }
        report["cases"].append(case)
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"book": name, "bzip3": bzip3_bytes,
                          "optimistic": len(optimistic), "paid": len(paid_frame),
                          "covered_opt": transform["ledger"]["optimistic_covered_bytes"],
                          "covered_paid": transform["ledger"]["paid_covered_bytes"]}), flush=True)
    report["complete"] = True
    evidence_path.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
