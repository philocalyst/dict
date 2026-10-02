#!/usr/bin/env bash
set -euo pipefail

# Usage: ./build.sh OUTPUT_DIRECTORY [Debug|ReleaseSafe|ReleaseFast]
artifact_dir="${1:?output directory required}"
optimize="${2:-ReleaseFast}"
zig_bin="${ZIG_BIN:-zig}"
mkdir -p "$artifact_dir"
artifact_dir="$(cd "$artifact_dir" && pwd)"
cd "$(dirname "$0")"

"$zig_bin" build-exe --dep bz4 -O "$optimize" -Mroot=native_forward.zig \
  -O "$optimize" -Mbz4=native_v4/root.zig \
  -femit-bin="$artifact_dir/native_forward_trace"
"$zig_bin" build-exe --dep bz4 -O "$optimize" -Mroot=context_forward.zig \
  -O "$optimize" -Mbz4=native_context/root.zig \
  -femit-bin="$artifact_dir/context_forward"
"$zig_bin" build-exe --dep bz4 -O "$optimize" -Mroot=joint_forward.zig \
  -O "$optimize" -Mbz4=native_joint/root.zig \
  -femit-bin="$artifact_dir/joint_forward"
"$zig_bin" build-exe --dep lex --dep gram --dep bz4 -O "$optimize" \
  -Mroot=raw_codec.zig -O "$optimize" \
  -Mlex=../bzip4/bz4/m_lexicon.zig -O "$optimize" \
  -Mgram=../bzip4/bz4/grammar2.zig -O "$optimize" \
  -Mbz4=native_context/root.zig -femit-bin="$artifact_dir/raw_codec"
"$zig_bin" build-exe --dep lex --dep gram --dep bz4 -O "$optimize" \
  -Mroot=raw_codec_joint.zig -O "$optimize" \
  -Mlex=../bzip4/bz4/m_lexicon.zig -O "$optimize" \
  -Mgram=../bzip4/bz4/grammar2.zig -O "$optimize" \
  -Mbz4=native_joint/root.zig -femit-bin="$artifact_dir/raw_codec_joint"
