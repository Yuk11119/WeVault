#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
count="${1:-10000}"
[[ "$count" =~ ^[0-9]+$ ]] || { echo "Expected a numeric fixture count" >&2; exit 2; }
swift test list >/dev/null
mkdir -p .build/p7-resources
# Compare separate processes, excluding compilation. Fixtures never touch WeChat or the cloud.
for mode in legacy bounded; do
    WEVAULT_P7_RESOURCE_COUNT="$count" WEVAULT_P7_SCAN_MODE="$mode" \
        /usr/bin/time -l swift test --skip-build --filter P7ResourceTests \
        > ".build/p7-resources/$mode-$count.txt" 2>&1
done
printf 'Measurements: %s/.build/p7-resources/*-%s.txt\n' "$PWD" "$count"
