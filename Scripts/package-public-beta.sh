#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
# Explicit, user-authorized alternative to the notarized release workflow.
# Never remove or republish the engineering preview's NOT-FOR-DISTRIBUTION marker.
python3 Scripts/configure-bundle.py --preflight
output="$project_root/.build/public-beta/${WEVAULT_VERSION}-${WEVAULT_BUILD}"
mkdir -p "$project_root/.build/public-beta"
mkdir "$output" # Versioned artifacts are immutable; refuse accidental replacement.
printf '%s\n' 'BUILD INCOMPLETE: do not publish this directory.' > "$output/BUILD-INCOMPLETE.txt"
app_path="$output/WeVault.app"
WEVAULT_SIGN_IDENTITY=- WEVAULT_ARCHS=universal WEVAULT_APP_OUTPUT="$app_path" Scripts/build-app.sh release
python3 - "$app_path/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
info = plistlib.loads(p.read_bytes())
info['WeVaultDistributionChannel'] = 'public-unnotarized-beta'
assert info['CFBundleIdentifier'] == 'online.wevault.mac'
assert 'WeVaultDevelopmentFixtureDirectory' not in info
p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
lipo "$app_path/Contents/MacOS/WeVault" -verify_arch arm64 x86_64
archive="WeVault-${WEVAULT_VERSION}-${WEVAULT_BUILD}-macos-universal.zip"
ditto -c -k --keepParent "$app_path" "$output/$archive"
(cd "$output" && LC_ALL=C LANG=C LC_CTYPE=C shasum -a 256 "$archive" > "$archive.sha256")
printf '%s\n' 'PUBLIC TEST BUILD — AD-HOC SIGNED, NOT APPLE NOTARIZED.' 'Gatekeeper may block first launch. See https://wevault.online/download/ before installing.' 'Cloud accounts currently require an invitation. Downloading does not create an account.' > "$output/UNNOTARIZED-BETA.txt"
rm "$output/BUILD-INCOMPLETE.txt"
printf '%s\n' "$output"
