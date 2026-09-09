#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
app_path="$project_root/.build/p7-ui/WeVault.app"
fixture_path="$project_root/.build/p7-ui-fixture"
mkdir -p "$fixture_path/synthetic-input"
WEVAULT_SIGN_IDENTITY=- WEVAULT_APP_OUTPUT="$app_path" Scripts/build-app.sh debug
python3 - "$app_path/Contents/Info.plist" "$fixture_path" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
values = plistlib.loads(path.read_bytes())
values["CFBundleIdentifier"] = "online.wevault.p7-smoke"
values["CFBundleName"] = "WeVault P7 Smoke"
values["WeVaultDevelopmentFixtureDirectory"] = sys.argv[2]
values.pop("CFBundleURLTypes", None)
path.write_bytes(plistlib.dumps(values))
PY
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
