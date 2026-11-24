#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

cache_dir=${ZIG_LOCAL_CACHE_DIR:-.zig-cache}
mkdir -p "$cache_dir/tmp" "$cache_dir/f"
# Zig can fail to create its log when the fuzzer starts from a cold cache.
touch "$cache_dir/tmp/libfuzzer.log"
run_dir=$(mktemp -d "$cache_dir/tmp/uidiff-fuzz.XXXXXX")
trap 'rm -f -- "$run_dir/fuzz-target-count.txt" "$run_dir/report.log"; rmdir -- "$run_dir"' EXIT
zig build fuzz-target-count --prefix "$run_dir"
expected=$(cat "$run_dir/fuzz-target-count.txt")
# Fuzz workers lock a numbered input file. Precreate their cold-cache slots.
for ((worker=0; worker<expected; worker++)); do
    printf -v input 'in%x' "$worker"
    touch "$cache_dir/f/$input"
done
log="$run_dir/report.log"

zig build test --fuzz=10K -j1 2>&1 | tee "$log"
if grep -q 'terminated with signal' "$log"; then
    exit 1
fi
if grep -Eq '^Runs:[[:space:]]+0 -> 0([[:space:]]|$)' "$log"; then
    printf 'A fuzz target reported zero runs.\n' >&2
    exit 1
fi
reports=$(grep -c '^Fuzz test:' "$log" || :)
if (( reports < expected )); then
    printf 'Expected %s fuzz reports, saw %s.\n' "$expected" "$reports" >&2
    exit 1
fi
