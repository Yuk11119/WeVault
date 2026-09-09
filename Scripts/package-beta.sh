#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mode="${1:-prepare}"
case "$mode" in prepare|preflight|notarize) ;; *) echo "Usage: $0 prepare|preflight|notarize" >&2; exit 2 ;; esac
# Invalidate any previous output before this attempt can fail, including preflight.
# Keep prior artifacts for diagnosis, but never leave them apparently approved.
if [[ "$mode" != preflight ]]; then
    output="$project_root/.build/beta/$mode"
    mkdir -p "$output"
    printf '%s\n' "NOT FOR DISTRIBUTION: release validation has not completed for this attempt." > "$output/NOT-FOR-DISTRIBUTION.txt"
fi
if [[ "$mode" != prepare ]]; then
    python3 Scripts/configure-bundle.py --preflight
    : "${WEVAULT_SIGN_IDENTITY:?Set a Developer ID Application identity}"
    : "${WEVAULT_NOTARY_PROFILE:?Set an existing notarytool Keychain profile name}"
    [[ "$WEVAULT_SIGN_IDENTITY" == "Developer ID Application: "* ]] || { echo "Developer ID Application identity required" >&2; exit 2; }
    security find-identity -v -p codesigning | grep -F -- "\"$WEVAULT_SIGN_IDENTITY\"" >/dev/null || { echo "Signing identity unavailable" >&2; exit 2; }
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    if [[ "$mode" == preflight ]]; then
        echo "Local release configuration passed; notary profile access is validated on submission."
        exit 0
    fi
fi
app_path="$project_root/.build/beta-build/WeVault.app"
WEVAULT_SIGN_IDENTITY=- WEVAULT_ARCHS=universal WEVAULT_APP_OUTPUT="$app_path" Scripts/build-app.sh release
lipo "$app_path/Contents/MacOS/WeVault" -verify_arch arm64 x86_64
archive="$output/WeVault.zip"
if [[ "$mode" == prepare ]]; then
    ditto -c -k --keepParent "$app_path" "$archive"
    printf '%s\n' "ENGINEERING PREVIEW ONLY: ad-hoc signed; not notarized or ready for distribution." > "$output/NOT-FOR-DISTRIBUTION.txt"
else
    codesign --force --options runtime --timestamp --sign "$WEVAULT_SIGN_IDENTITY" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    ditto -c -k --keepParent "$app_path" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$WEVAULT_NOTARY_PROFILE" --wait --output-format json > "$output/notarization.json"
    python3 - "$output/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "Accepted":
    sys.exit("Notarization not accepted; do not distribute this archive")
PY
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    codesign --verify --deep --strict "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
    # Repack the stapled application; the original submission zip has no ticket.
    ditto -c -k --keepParent "$app_path" "$archive"
fi
(cd "$output" && LC_ALL=C LANG=C LC_CTYPE=C shasum -a 256 WeVault.zip > WeVault.zip.sha256)
if [[ "$mode" == notarize ]]; then
    rm "$output/NOT-FOR-DISTRIBUTION.txt"
fi
printf '%s\n' "$archive"
