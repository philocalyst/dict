#!/bin/sh
set -eu
ZIG=${ZIG:-zig}
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${OUT:-/tmp/frontier2026-bz4-reader}
"$ZIG" build-exe --dep bz4 -O ReleaseFast \
  -Mroot="$TASK_ROOT/src6/bench/native_controls/bz4_reader.zig" \
  -O ReleaseFast \
  -Mbz4="$TASK_ROOT/src6/experiments/bzip4/bz4/v3/src/root.zig" \
  -femit-bin="$OUT"
printf '%s\n' "$OUT"
