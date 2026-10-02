#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'usage: build_native_decode.sh PREPARED_JOBS_STATIC_LIBRARY OUTPUT_BINARY' >&2
  exit 2
fi
jobs_library=$(realpath -- "$1")
output_binary=$(realpath -m -- "$2")
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p -- "$(dirname -- "$output_binary")"
# A renamed main loses C++'s implicit return-zero rule. Generate reader CLI
# adapters with an explicit equivalent return; the frozen sources stay intact.
adapter_directory=$(mktemp -d -- "$(dirname -- "$output_binary")/adapters.XXXXXX")
trap 'rm -rf -- "$adapter_directory"' EXIT
python3 - "$source_directory" "$adapter_directory" <<'PY'
import pathlib, sys
source, out = map(pathlib.Path, sys.argv[1:])
for relative, name in [('../word_constructions/prepared_wpg.cpp', 'wpg_cli.inc'),
                       ('../wordgrammar/geometry/prepared_geometry.cpp', 'gwt_cli.inc')]:
    text = (source / relative).read_text()
    if text.count('int main(') != 1 or not text.rstrip().endswith('}'):
        raise SystemExit('unexpected reader CLI source shape')
    before, close = text.rstrip().rsplit('\n}', 1)
    (out / name).write_text(before + '\n    return 0;\n}' + close + '\n')
PY
"${CXX:-g++}" -std=c++17 -O3 -DNDEBUG -Wall -Wextra -no-pie \
  -I"$adapter_directory" -I"$source_directory/../word_constructions" \
  -I"$source_directory/../wordgrammar/geometry" \
  "$source_directory/native_decode.cpp" "$jobs_library" -pthread -lm \
  -o "$output_binary"
