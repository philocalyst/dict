#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: runtime2_build.sh REPOSITORY_LOCAL_BACKEND_DIR' >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../../../.." && pwd)
output_dir=$(realpath -m -- "$1")
case "$output_dir" in
  "$repo_root"/*) ;;
  *) echo 'backend directory must be inside the repository' >&2; exit 2 ;;
esac
if [[ "$output_dir" == "$script_dir" ]]; then
  echo 'backend directory must not overwrite the original WGP6 binaries' >&2
  exit 2
fi
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
case "$output_dir" in
  "$repo_root"/*) ;;
  *) echo 'backend directory resolves outside the repository' >&2; exit 2 ;;
esac
if [[ "$output_dir" == "$script_dir" ]]; then
  echo 'backend directory resolves to the original WGP6 binary directory' >&2
  exit 2
fi

zig_bin=${ZIG:-zig}
cxx_bin=${CXX:-g++}
cd -- "$script_dir"

"$zig_bin" build-exe --dep lex --dep gram --dep bz4 -O ReleaseFast \
  -Mroot=m_reference_reclaim.zig -O ReleaseFast -Mlex=../../bzip4/bz4/m_lexicon.zig \
  -O ReleaseFast -Mgram=../../bzip4/bz4/grammar2.zig \
  -O ReleaseFast -Mbz4=../../bzip4/bz4/v3/src/root.zig \
  -femit-bin="$output_dir/m_reference"

for name in native native_forward native_forward_hoist; do
  "$zig_bin" build-exe --dep bz4 -O ReleaseFast -Mroot="$name.zig" \
    -O ReleaseFast -Mbz4=../../bzip4/bz4/v3/src/root.zig \
    -femit-bin="$output_dir/$name"
done
"$cxx_bin" -std=c++17 -O3 -DNDEBUG -Wall -Wextra reparse_context.cpp -o "$output_dir/reparse_context"

sha256sum "$output_dir"/{m_reference,native,native_forward,native_forward_hoist,reparse_context}
