#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../../.." && pwd)
zig_bin=${ZIG:-/home/agent/.local/bin/zig}

cd -- "$here"
"$zig_bin" build-exe -O ReleaseFast --dep bz4 \
  -Mroot=native_v3/main.zig -Mbz4=native_v3/root.zig \
  -femit-bin="$here/gen_native"

cd -- "$repo/src6/experiments/wordgrammar/wgp6"
"$zig_bin" build-exe -O ReleaseFast --dep lex --dep gram --dep bz4 \
  -Mroot=../../structural_wordcodec/m_reference_gen.zig \
  -Mlex=../../bzip4/bz4/m_lexicon.zig \
  -Mgram=../../bzip4/bz4/grammar2.zig \
  -Mbz4=../../structural_wordcodec/native_v3/root.zig \
  -femit-bin="$here/gen_m_reference"
"$zig_bin" build-exe -O ReleaseFast --dep bz4 \
  -Mroot=../../structural_wordcodec/forward_gen.zig \
  -Mbz4=../../structural_wordcodec/native_v3/root.zig \
  -femit-bin="$here/gen_native_forward"
"$zig_bin" build-exe -O ReleaseFast --dep bz4 \
  -Mroot=native.zig \
  -Mbz4=../../structural_wordcodec/native_v3/root.zig \
  -femit-bin="$here/gen_native_reader"

sha256sum "$here"/gen_native "$here"/gen_m_reference \
  "$here"/gen_native_forward "$here"/gen_native_reader
