#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${FLUIDVOICE_DERIVED_DATA:-/tmp/FluidVoiceDevDerived}"
dev_app="${FLUIDVOICE_DEV_APP:-$HOME/Applications/FluidVoice Dev.app}"
identity="${FLUIDVOICE_SIGNING_IDENTITY:-FluidVoice Local Development}"
built_app="$derived_data/Build/Products/Debug/FluidVoice Debug.app"

if ! security find-identity -v -p codesigning | grep -Fq '"'$identity'"'; then
    echo "Missing signing identity: $identity"
    echo "Run scripts/setup-dev-signing.sh once, then retry."
    exit 1
fi

cd "$repo_root"
xcodebuild \
    -project Fluid.xcodeproj \
    -scheme Fluid \
    -destination 'platform=macOS' \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

osascript -e 'tell application id "com.FluidApp.app.dev" to quit' 2>/dev/null || true
mkdir -p "$(dirname "$dev_app")"

if [[ "$dev_app" != *"FluidVoice Dev.app" ]]; then
    echo "Refusing to replace unexpected app path: $dev_app"
    exit 1
fi
rm -rf "$dev_app"
ditto "$built_app" "$dev_app"
if [[ -d /Applications/FluidVoice.app/Contents/Frameworks ]]; then
    rm -rf "$dev_app/Contents/Frameworks"
    ditto /Applications/FluidVoice.app/Contents/Frameworks "$dev_app/Contents/Frameworks"
fi

plist="$dev_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.FluidApp.app.dev' "$plist"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName FluidVoice Dev' "$plist"
else
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string FluidVoice Dev' "$plist"
fi
if /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName FluidVoice Dev' "$plist"
else
    /usr/libexec/PlistBuddy -c 'Add :CFBundleName string FluidVoice Dev' "$plist"
fi

codesign --force --deep --options runtime --entitlements "$repo_root/Fluid.entitlements" --sign "$identity" "$dev_app"
codesign --verify --deep --strict "$dev_app"
open "$dev_app"

echo "Running: $dev_app"
