#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo 'Requires macOS and Xcode.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
mkdir -p dist
xcodebuild -project Live.xcodeproj -scheme Live -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build

APP_PATH='build/release/Build/Products/Release-iphoneos/Live.app'
test -d "$APP_PATH"
python3 - "$APP_PATH" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert info['CFBundleIdentifier'] == 'app.personal.zb.live'
assert info['MinimumOSVersion'] == '17.0', info['MinimumOSVersion']
assert (app / info['CFBundleExecutable']).is_file()
assert not (app / 'embedded.mobileprovision').exists()
print('Minimum iOS:', info['MinimumOSVersion'])
PY

# Ad-hoc signing requires no Apple account; TrollStore applies its installation signature.
while IFS= read -r -d '' FRAMEWORK_PATH; do
  codesign --force --sign - --timestamp=none "$FRAMEWORK_PATH"
done < <(find "$APP_PATH/Frameworks" -type d -name '*.framework' -print0 2>/dev/null || true)
codesign --force --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

PACKAGE_STAGE="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
mkdir -p "$PACKAGE_STAGE/Payload"
ditto "$APP_PATH" "$PACKAGE_STAGE/Payload/Live.app"
ditto -c -k --keepParent "$PACKAGE_STAGE/Payload" dist/Live-iOS17-TrollStore.ipa
python3 scripts/validate_ipa.py dist/Live-iOS17-TrollStore.ipa
shasum -a 256 dist/Live-iOS17-TrollStore.ipa > dist/SHA256SUMS.txt
