#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
# This file contains only a certificate fingerprint, never a private key.
# An explicit environment value (including '-') overrides local configuration.
sign_identity="${WEVAULT_SIGN_IDENTITY-}"
if [[ -z "$sign_identity" && -f "$HOME/.config/wevault/signing-identity" ]]; then
    sign_identity="$(cat "$HOME/.config/wevault/signing-identity")"
    [[ "$sign_identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo "Invalid local WeVault signing fingerprint" >&2; exit 2; }
fi
sign_identity="${sign_identity:--}"
build_args=(-c "$configuration")
case "${WEVAULT_ARCHS:-native}" in
  native) ;;
  universal) build_args+=(--arch arm64 --arch x86_64) ;;
  *) echo "WEVAULT_ARCHS must be native or universal" >&2; exit 2 ;;
esac
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_path="${WEVAULT_APP_OUTPUT:-$project_root/.build/app/WeVault.app}"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_dir/WeVault" "$app_path/Contents/MacOS/WeVault"
cp Packaging/Info.plist "$app_path/Contents/Info.plist"
python3 Scripts/configure-bundle.py "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"
# Reuse a certificate across local rebuilds so Keychain can recognize the app.
# package-beta.sh still owns distribution signing and notarization.
if [[ "$sign_identity" == - ]]; then
    echo "Warning: ad-hoc signing changes Keychain identity on rebuild. Set WEVAULT_SIGN_IDENTITY to a persistent signing certificate to retain Always Allow grants." >&2
fi
codesign --force --sign "$sign_identity" "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
