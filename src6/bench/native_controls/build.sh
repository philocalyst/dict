#!/bin/sh
set -eu
cd "$(dirname "$0")"
${CC:-cc} -O3 -std=c99 -Wall -Wextra codec.c -ldl -o native-controls
${CC:-cc} -O3 -std=c99 -Wall -Wextra reader.c -ldl -o native-controls-reader
