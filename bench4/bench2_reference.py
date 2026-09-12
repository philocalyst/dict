#!/usr/bin/env python3
"""Read-only, explicitly historical projections of bench2 results.

The LEX4 harness must not mix bench2's direct native child timings with the
current JSONL protocol timings.  This module therefore retains a compact
provenance-bound snapshot and marks profiles comparable only when the source
metadata proves semantic identity.  No missing or unavailable profile is
invented here.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


class Bench2ReferenceError(RuntimeError):
    pass


def _digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def _meta(rows: list[dict[str, Any]], fixture: str | None, name: str) -> Any:
    for row in rows:
        if row.get("kind") != "meta" or row.get("name") != name:
            continue
        if fixture is None or row.get("scope") in {fixture, "global"}:
            return row.get("value")
    return None


def load(path: Path, *, current_seed: str | None = None, current_records: int | None = None) -> dict[str, Any]:
    """Load bench2 summary rows without treating them as current measurements."""

    path = path.expanduser().resolve(strict=False)
    if not path.is_file():
        return {
            "status": "unavailable",
            "source": {"path": str(path), "missing": True},
            "reason": "bench2 benchmark.json is unavailable",
            "profiles": [],
        }
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        rows = value.get("rows")
        if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
            raise ValueError("rows is not a list of objects")
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError) as exc:
        raise Bench2ReferenceError(f"cannot read bench2 reference {path}: {exc}") from exc

    source = {"path": str(path), "size": path.stat().st_size, "sha256": _digest(path)}
    global_seed = _meta(rows, None, "seed")
    global_records = _meta(rows, None, "records")
    profiles: list[dict[str, Any]] = []
    grouped: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in rows:
        if row.get("kind") != "result":
            continue
        fixture = row.get("fixture")
        format_name = row.get("format")
        variant = row.get("variant")
        metric = row.get("metric")
        if not all(isinstance(item, str) and item for item in (fixture, format_name, variant, metric)):
            continue
        profile = grouped.setdefault((fixture, format_name, variant), {"fixture": fixture, "format": format_name, "variant": variant, "metrics": {}})
        profile["metrics"][metric] = row.get("value")
    for key in sorted(grouped):
        profile = grouped[key]
        fixture = str(profile["fixture"])
        fixture_seed = _meta(rows, fixture, "seed")
        fixture_records = _meta(rows, fixture, "records")
        # bench2's current integer digests are not the LEX4 SHA-256 semantic
        # digest, so equal-looking metric names never imply identity.
        comparable = (
            current_seed is not None
            and current_records is not None
            and str(fixture_seed or global_seed) == str(current_seed)
            and int(fixture_records or global_records or -1) == int(current_records)
        )
        profile.update(
            {
                "source_kind": "bench2_authoritative_native",
                "timing_model": "bench2 direct native child timing; no current JSONL transport",
                "seed": fixture_seed or global_seed,
                "records": fixture_records or global_records,
                "comparable_to_current": comparable,
                "comparability_reason": "semantic seed/record identity is not proven" if not comparable else "seed and record count match; verify semantic/query digest before ratio use",
            }
        )
        profiles.append(profile)
    return {
        "status": "available",
        "source": source,
        "authority": "bench2/results/benchmark.json",
        "timing_model": "bench2 direct native child timing; not the current LEX4 JSONL transport boundary",
        "global_seed": global_seed,
        "global_records": global_records,
        "profiles": profiles,
    }


def verify(snapshot: dict[str, Any]) -> tuple[bool, str | None]:
    """Detect mutation of the historical source after capture."""

    source = snapshot.get("source") if isinstance(snapshot, dict) else None
    if not isinstance(source, dict):
        return False, "bench2 reference source metadata missing"
    path = Path(str(source.get("path", "")))
    if source.get("missing"):
        return (not path.exists(), None if not path.exists() else "bench2 reference appeared after capture")
    if not path.is_file():
        return False, "bench2 reference disappeared"
    current = {"size": path.stat().st_size, "sha256": _digest(path)}
    expected = {"size": source.get("size"), "sha256": source.get("sha256")}
    return (current == expected, None if current == expected else "bench2 reference changed during run")


__all__ = ["Bench2ReferenceError", "load", "verify"]
