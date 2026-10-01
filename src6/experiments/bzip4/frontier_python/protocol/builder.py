"""Build/reuse the pinned bzip3 control library in the isolated protocol area.

This is intentionally separate from the production/build system.  The C
source is read from the repository's already-pinned vendor tree, its expected
hashes are checked before compilation, and the resulting shared object is
written below ``frontier_python/protocol/vendor`` only.  The build command and
all source/output hashes are retained in a manifest beside that object.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
from functools import wraps
from typing import Final

try:  # Unix hosts are the supported native-control build targets.
    import fcntl
except ImportError:  # pragma: no cover - Windows is rejected by the builder.
    fcntl = None  # type: ignore[assignment]

from .capture import run_and_save


REPO: Final[Path] = Path(__file__).resolve().parents[5]
PROTOCOL_ROOT: Final[Path] = Path(__file__).resolve().parent
ISOLATED_VENDOR_ROOT: Final[Path] = PROTOCOL_ROOT / "vendor"
MANIFEST_PATH: Final[Path] = ISOLATED_VENDOR_ROOT / "build-manifest.json"
LOCK_PATH: Final[Path] = ISOLATED_VENDOR_ROOT / ".build.lock"

VENDOR_ROOT: Final[Path] = REPO / "vendor" / "bzip3"
SOURCE_FILES: Final[tuple[tuple[str, str, int], ...]] = (
    ("src/libbz3.c", "7f3c79053898c25bc8dd2c67c9fdafa86f3b94bf8e3a3e3fc1dd7e8c7e8872ad", 36_230),
    ("include/libbz3.h", "ccb20f66402f4ca42656471ec401ceaaeac7c729d590dd976856d48967a734df", 9_525),
    ("include/common.h", "f87f5b286e4b733e79c32c0cd5ee521a41c843a4e73a85fec161c3f0e79011da", 4_968),
    ("include/libsais.h", "65d065a8bbf37fb01a2e02817cd571d5853ccfc068195da30d0586bdeb86487c", 214_460),
)


class BuildError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _source_records() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for relative, expected_hash, expected_bytes in SOURCE_FILES:
        path = VENDOR_ROOT / relative
        if not path.is_file():
            raise BuildError(f"missing pinned bzip3 source: {path}")
        actual_bytes = path.stat().st_size
        actual_hash = _sha256(path)
        if actual_bytes != expected_bytes or actual_hash != expected_hash:
            raise BuildError(
                f"pinned bzip3 source changed: {relative}: expected {expected_bytes}/{expected_hash}, "
                f"got {actual_bytes}/{actual_hash}"
            )
        records.append({"path": str(path), "relative": relative, "bytes": actual_bytes, "sha256": actual_hash})
    return records


def library_name() -> str:
    system = platform.system().lower()
    if system == "darwin":
        return "libbz3.dylib"
    if system == "windows":
        return "bz3.dll"
    return "libbz3.so"


def library_path() -> Path:
    return ISOLATED_VENDOR_ROOT / library_name()


def _compile_command(output: Path, compiler: str) -> list[str]:
    system = platform.system().lower()
    # VERSION is required by the pinned upstream source and is deliberately
    # explicit so two builders cannot silently select different library APIs.
    command = [compiler, "-O3", "-fPIC", '-DVERSION="1.5.1"', "-I", str(VENDOR_ROOT / "include")]
    if system == "darwin":
        command.extend(["-dynamiclib", "-Wl,-install_name,@rpath/" + output.name])
    elif system != "windows":
        command.extend(["-shared"])
    else:
        raise BuildError("Windows shared-library build is not supported by this protocol helper")
    command.extend([str(VENDOR_ROOT / "src" / "libbz3.c"), "-o", str(output)])
    return command


def _with_build_lock(function):
    """Serialize first-build/reuse checks across concurrently started workers."""

    @wraps(function)
    def locked(*args, **kwargs):
        ISOLATED_VENDOR_ROOT.mkdir(parents=True, exist_ok=True)
        if fcntl is None:
            return function(*args, **kwargs)
        with LOCK_PATH.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                return function(*args, **kwargs)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    return locked


@_with_build_lock
def build_shared_library(*, force: bool = False, compiler: str | None = None) -> Path:
    """Build or reuse the isolated control library after source verification."""

    source_records = _source_records()
    output = library_path()
    ISOLATED_VENDOR_ROOT.mkdir(parents=True, exist_ok=True)
    compiler = compiler or os.environ.get("CC") or shutil.which("cc") or shutil.which("clang")
    if compiler is None:
        raise BuildError("no C compiler found; set CC or install a compiler")
    command = _compile_command(output, compiler)

    if output.is_file():
        if force:
            raise BuildError(f"refusing to replace retained isolated control library: {output}")
        if not MANIFEST_PATH.is_file():
            raise BuildError(f"existing isolated library has no provenance manifest: {output}")
        try:
            manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise BuildError(f"cannot read isolated control manifest {MANIFEST_PATH}: {exc}") from exc
        expected_sources = manifest.get("source")
        if expected_sources != source_records:
            raise BuildError("isolated control source hashes no longer match its retained manifest")
        if manifest.get("command") != command:
            raise BuildError("isolated control compiler command differs from retained manifest")
        recorded = manifest.get("library", {})
        actual_hash = _sha256(output)
        if recorded.get("sha256") != actual_hash or recorded.get("bytes") != output.stat().st_size:
            raise BuildError("isolated control library hash differs from retained manifest")
        # Preserve the original build record.  A reuse operation is returned
        # to the caller but never rewrites provenance as a new build.
        return output

    # Compile in the final isolated directory; no production or root build
    # output is touched.  Capture the compiler's raw streams before writing the
    # manifest, just as measurement children are captured.
    capture = run_and_save(command, cwd=REPO, raw_root=ISOLATED_VENDOR_ROOT, stem="build", timeout=120)
    if capture.returncode != 0 or not output.is_file():
        raise BuildError(
            f"bzip3 shared-library build failed (status={capture.status}, returncode={capture.returncode}): "
            f"{capture.stderr.decode('utf-8', 'replace')[-2000:]}"
        )
    output_hash = _sha256(output)
    manifest = {
        "schema": 1,
        "status": "built",
        "library": {"path": str(output), "bytes": output.stat().st_size, "sha256": output_hash},
        "compiler": compiler,
        "command": command,
        "source": source_records,
        "platform": {"system": platform.system(), "machine": platform.machine()},
        "build_process": capture.record(),
        "raw_capture": {
            "stdout": str(ISOLATED_VENDOR_ROOT / "build.stdout.bin"),
            "stderr": str(ISOLATED_VENDOR_ROOT / "build.stderr.bin"),
            "status": str(ISOLATED_VENDOR_ROOT / "build.status.json"),
        },
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return output


__all__ = [
    "BuildError",
    "REPO",
    "PROTOCOL_ROOT",
    "ISOLATED_VENDOR_ROOT",
    "MANIFEST_PATH",
    "LOCK_PATH",
    "VENDOR_ROOT",
    "SOURCE_FILES",
    "library_name",
    "library_path",
    "build_shared_library",
]
