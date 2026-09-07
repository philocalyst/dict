#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [[ "${LEX2_NIX_DONE:-0}" != 1 ]]; then
  exec nix develop .# --command env LEX2_NIX_DONE=1 bash "$root_dir/bench2/run.sh" "$@"
fi

records=${LEX2_RECORDS:-2048}
repetitions=${LEX2_REPETITIONS:-1000}
warmup=${LEX2_WARMUP:-200}
# The external readers must use the same operation counts: their normalized
# query checksums are only comparable when the workload cardinality matches.
external_repetitions=${LEX2_EXTERNAL_REPETITIONS:-$repetitions}
external_warmup=${LEX2_EXTERNAL_WARMUP:-$warmup}
presets=${LEX2_PRESETS:-latency,balanced,compact}
if [[ "$external_repetitions" != "$repetitions" || "$external_warmup" != "$warmup" ]]; then
  echo "external repetitions/warmup must match Zig for checksum-equivalent runs" >&2
  exit 2
fi
out_dir="$root_dir/bench2/results"
run_stamp=$(date -u +%Y%m%dT%H%M%SZ)
run_id="${run_stamp}-$$"
run_root="$out_dir/runs/$run_id"
staging="$out_dir/runs/.staging-$run_id"

mkdir -p "$out_dir/runs"
if [[ -e "$staging" ]]; then
  echo "staging run already exists: $staging" >&2
  exit 1
fi
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
raw_dir="$staging/raw"
artifact_dir="$staging/artifacts"
mkdir -p "$raw_dir" "$artifact_dir"

tool_version() {
  local tool=$1
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" --version 2>&1 | head -1
  else
    printf '%s\n' unavailable
  fi
}

printf 'meta\tglobal\thost\t%s\n' "$(uname -a)" > "$raw_dir/machine.tsv"
printf 'meta\tglobal\tzig\t%s\n' "$(zig version)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tnix\t%s\n' "$(tool_version nix)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tpython\t%s\n' "$(python3 --version 2>&1)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tsqlite\t%s\n' "$(tool_version sqlite3)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tdictfmt\t%s\n' "$(tool_version dictfmt)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tdictd\t%s\n' "$(tool_version dictd)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tdictzip\t%s\n' "$(tool_version dictzip)" >> "$raw_dir/machine.tsv"
printf 'meta\tglobal\tzstd\t%s\n' "$(tool_version zstd)" >> "$raw_dir/machine.tsv"

if [[ "${LEX2_SKIP_BUILD:-0}" != 1 ]]; then
  zig build --build-file build2.zig install -Doptimize=ReleaseFast
fi

# Capture the exact source, flake lock, environment, CLI, and executable after
# the build and before any measured fixture starts.  The verify step below
# prevents promotion if the source or executable changes during the run.
python3 bench2/provenance.py capture \
  --repo "$root_dir" \
  --out "$staging/provenance.json" \
  --meta-tsv "$raw_dir/provenance.tsv" \
  --executable zig-out/bin/bench2 \
  --cli "$0" "$@"

for fixture in flat prose_heavy repeated rich pathological_prefix; do
  corpus="$raw_dir/corpus-${fixture}.tsv"
  zig_out="$raw_dir/zig-${fixture}.tsv"
  zig_stdout="$raw_dir/zig-${fixture}.stdout"
  zig_stderr="$raw_dir/zig-${fixture}.stderr"
  zig_stats="$raw_dir/zig-${fixture}.stats.json"
  mkdir -p "$artifact_dir/$fixture"
  python3 bench2/process_runner.py \
    --stdout "$zig_stdout" \
    --stderr "$zig_stderr" \
    --stats "$zig_stats" \
    --cwd "$root_dir" \
    -- ./zig-out/bin/bench2 \
    "--fixture=$fixture" \
    "--records=$records" \
    "--repetitions=$repetitions" \
    "--warmup=$warmup" \
    "--presets=$presets" \
    "--artifact-dir=$artifact_dir/$fixture" \
    "--emit-corpus=$corpus"
  cat "$zig_stdout" "$zig_stderr" > "$zig_out"
  python3 bench2/parse_time.py "$zig_stats" "$fixture" zig >> "$raw_dir/process.tsv"

  external_out="$raw_dir/external-${fixture}.tsv"
  external_stdout="$raw_dir/external-${fixture}.stdout"
  external_stderr="$raw_dir/external-${fixture}.stderr"
  external_stats="$raw_dir/external-${fixture}.stats.json"
  python3 bench2/process_runner.py \
    --stdout "$external_stdout" \
    --stderr "$external_stderr" \
    --stats "$external_stats" \
    --cwd "$root_dir" \
    -- python3 bench2/external_baselines.py \
    --corpus "$corpus" \
    --artifact-dir "$artifact_dir/$fixture" \
    --out "$external_out" \
    --repetitions "$external_repetitions" \
    --warmup "$external_warmup"
  cat "$external_stdout" "$external_stderr" > "$raw_dir/external-${fixture}.combined"
  python3 bench2/parse_time.py "$external_stats" "$fixture" external >> "$raw_dir/process.tsv"
done

python3 bench2/provenance.py verify \
  --repo "$root_dir" \
  --manifest "$staging/provenance.json" \
  --meta-tsv "$raw_dir/provenance.tsv"

python3 bench2/tsv_to_json.py \
  --out "$staging/benchmark.json" \
  "$raw_dir/machine.tsv" "$raw_dir/process.tsv" \
  "$raw_dir/provenance.tsv" \
  "$raw_dir/zig-flat.tsv" "$raw_dir/zig-prose_heavy.tsv" "$raw_dir/zig-repeated.tsv" "$raw_dir/zig-rich.tsv" "$raw_dir/zig-pathological_prefix.tsv" \
  "$raw_dir/external-flat.tsv" "$raw_dir/external-prose_heavy.tsv" "$raw_dir/external-repeated.tsv" "$raw_dir/external-rich.tsv" "$raw_dir/external-pathological_prefix.tsv"

python3 bench2/render_report.py \
  --json "$staging/benchmark.json" \
  --output "$staging/BENCHMARKS.md" \
  --records "$records" \
  --repetitions "$repetitions" \
  --warmup "$warmup" \
  --external-repetitions "$external_repetitions" \
  --external-warmup "$external_warmup" \
  --presets "$presets"

printf 'run_id\t%s\n' "$run_id" > "$staging/COMPLETE"
printf 'records\t%s\nrepetitions\t%s\nwarmup\t%s\nexternal_repetitions\t%s\nexternal_warmup\t%s\npresets\t%s\n' \
  "$records" "$repetitions" "$warmup" "$external_repetitions" "$external_warmup" "$presets" > "$staging/config.tsv"
python3 bench2/hash_artifacts.py --root "$staging" --out "$staging/hashes.tsv"

mv "$staging" "$run_root"
trap - EXIT HUP INT TERM
latest_link="$out_dir/.latest-$run_id"
ln -s "runs/$run_id" "$latest_link"
# `mv` follows an existing symlink-to-directory on Darwin, which can place the
# new link inside the previous run and leave `latest` stale.  os.replace
# replaces the directory entry itself and is atomic on the same filesystem.
python3 - "$latest_link" "$out_dir/latest" <<'PY'
import os
import sys

os.replace(sys.argv[1], sys.argv[2])
PY

printf 'benchmark artifacts: %s/latest\n' "$out_dir"
