#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$project_root/.build/app/WeVault.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_dir/WeVault" "$app_path/Contents/MacOS/WeVault"
cp Packaging/Info.plist "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"
# Development signature only; distribution signing/notarization belongs to P7.
codesign --force --sign - "$app_path"
printf '%s\n' "$app_path"
