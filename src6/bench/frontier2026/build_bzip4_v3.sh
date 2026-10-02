#!/bin/sh
set -eu
ZIG=${ZIG:-zig}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT=${OUT:-/tmp/frontier2026-bzip4-v3}
"$ZIG" build-exe --dep bz4 -O ReleaseFast \
  -Mroot="$ROOT/src6/bench/frontier2026/bzip4_v3_adapter.zig" \
  -O ReleaseFast \
  -Mbz4="$ROOT/src6/experiments/bzip4/bz4/v3/src/root.zig" \
  -femit-bin="$OUT"
printf '%s\n' "$OUT"
