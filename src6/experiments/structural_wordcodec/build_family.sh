#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../../.." && pwd)
zig_bin=${ZIG:-/home/agent/.local/bin/zig}

cd -- "$repo/src6/experiments/wordgrammar/wgp6"
"$zig_bin" build-exe -O ReleaseFast --dep lex --dep gram --dep bz4 \
  -Mroot=../../structural_wordcodec/m_reference_family.zig \
  -Mlex=../../bzip4/bz4/m_lexicon.zig \
  -Mgram=../../bzip4/bz4/grammar2.zig \
  -Mbz4=../../structural_wordcodec/native_family/root.zig \
  -femit-bin="$here/family_m_reference"
"$zig_bin" build-exe -O ReleaseFast --dep bz4 \
  -Mroot=../../structural_wordcodec/forward_family.zig \
  -Mbz4=../../structural_wordcodec/native_family/root.zig \
  -femit-bin="$here/family_forward"
"$zig_bin" build-exe -O ReleaseFast --dep bz4 \
  -Mroot=native.zig \
  -Mbz4=../../structural_wordcodec/native_family/root.zig \
  -femit-bin="$here/family_reader"
sha256sum "$here"/family_m_reference "$here"/family_forward "$here"/family_reader
