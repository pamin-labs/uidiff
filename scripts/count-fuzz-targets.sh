#!/usr/bin/env bash
set -euo pipefail
output=$1
shift
total=0
for runner; do
    report=$("$runner" 2>&1) || {
        printf '%s\n' "$report" >&2
        exit 1
    }
    count=$(awk '/^[1-9][0-9]* fuzz tests found\.$/ {print $1}' <<<"$report")
    if [[ -z "$count" ]]; then
        printf 'No fuzz tests ran in %s.\n' "${runner##*/}" >&2
        exit 1
    fi
    total=$((total + count))
done
printf '%d\n' "$total" > "$output"
