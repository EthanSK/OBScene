#!/usr/bin/env bash
set -euo pipefail

# OBScene notarization script.
#
# Required env vars:
#   APPLE_ID              Apple ID email
#   APPLE_TEAM_ID         10-char Developer Team ID
#   APPLE_APP_PASSWORD    App-specific password (appleid.apple.com > Sign-In and Security)
#
# Optional:
#   SIGN_IDENTITY         Defaults to "Developer ID Application"
#   SCHEME                Defaults to "OBScene"
#   CONFIG                Defaults to "Release"
#
# Usage:
#   ./scripts/notarize.sh
#
# Output:
#   build/export/OBScene.app      — notarized + stapled
#   build/OBScene.zip             — zipped app for distribution

: "${APPLE_ID:?APPLE_ID not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID not set}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD not set}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
SCHEME="${SCHEME:-OBScene}"
CONFIG="${CONFIG:-Release}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/$SCHEME.app"
ZIP_PATH="$BUILD_DIR/$SCHEME.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Archiving"
xcodebuild \
    -project "$ROOT/$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    clean archive

echo "==> Exporting .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" | grep -E "Authority|TeamIdentifier|Identifier|Runtime" || true

echo "==> Creating zip for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Re-zipping stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Done. Notarized bundle:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
