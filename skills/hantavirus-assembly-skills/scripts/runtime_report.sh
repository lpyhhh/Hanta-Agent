#!/usr/bin/env bash
set -euo pipefail

runtime_log="${1:-}"
if [[ -z "${runtime_log}" || ! -f "${runtime_log}" ]]; then
    echo "ERROR: runtime log not found: ${runtime_log}" >&2
    exit 1
fi

total_seconds=$(awk -F'\t' '$1 == "total_seconds" { value=$2 } END { print value }' "${runtime_log}")
if [[ -z "${total_seconds}" ]]; then
    echo "ERROR: total_seconds not found in ${runtime_log}" >&2
    exit 1
fi

hours=$((total_seconds / 3600))
minutes=$(((total_seconds % 3600) / 60))
seconds=$((total_seconds % 60))
printf "total_runtime\t%02d:%02d:%02d\n" "${hours}" "${minutes}" "${seconds}"
