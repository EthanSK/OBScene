#!/usr/bin/env bash
# package-release.sh — build, sign, notarise, and package OBScene for release.
#
# Produces (in build/):
#   OBScene.app                          — signed + notarised + stapled (if creds set)
#   OBScene-<version>-mac-universal.zip  — zipped app for auto-update style downloads
#   OBScene-<version>-mac-universal.dmg  — drag-to-Applications installer
#   *.sha256                             — shasum files for each artifact
#
# Required env for signed + notarised builds:
#   APPLE_DEVELOPER_ID  Full identity string, e.g.
#                       "Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)"
#   APPLE_ID            Apple ID email
#   APPLE_TEAM_ID       10-char Developer Team ID
#   APPLE_APP_PASSWORD  App-specific password
#
# If signing credentials are missing the script still builds, zips, and dmgs
# the .app ad-hoc-signed, but skips notarisation (with a warning). This keeps
# the workflow validatable end-to-end before secrets are configured.
#
# Usage:
#   ./scripts/package-release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_NAME="OBScene"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

APPLE_DEVELOPER_ID="${APPLE_DEVELOPER_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

signed_build=0
can_notarise=0

if [ -n "$APPLE_DEVELOPER_ID" ]; then
  signed_build=1
fi

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_TEAM_ID" ] && [ -n "$APPLE_APP_PASSWORD" ] && [ "$signed_build" = "1" ]; then
  can_notarise=1
fi

echo "==> Build"
if [ "$signed_build" = "1" ]; then
  SIGN_IDENTITY="$APPLE_DEVELOPER_ID" "$ROOT/scripts/build-app.sh"
else
  echo "    (no APPLE_DEVELOPER_ID set — ad-hoc signed build)"
  "$ROOT/scripts/build-app.sh"
fi

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
echo "==> Version: $version"

ZIP_BASENAME="${APP_NAME}-${version}-mac-universal"
ZIP_PATH="$BUILD_DIR/${ZIP_BASENAME}.zip"
DMG_PATH="$BUILD_DIR/${ZIP_BASENAME}.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"

echo "==> Creating zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [ "$can_notarise" = "1" ]; then
  echo "==> Submitting to Apple notary service (this takes a few minutes)"
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  echo "==> Stapling ticket to .app"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"

  echo "==> Re-zipping stapled app"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
else
  if [ "$signed_build" = "1" ]; then
    echo "==> Skipping notarisation (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD not set)"
  else
    echo "==> Skipping notarisation (ad-hoc signed — not eligible)"
  fi
fi

echo "==> Creating DMG"
# Simple hdiutil-based DMG with a nice volume name and the app at root.
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
# Use ditto (not `cp -R`) so Sparkle.framework's symlinked Versions/B
# layout is preserved — otherwise notarisation rejects the DMG.
ditto "$APP_BUNDLE" "$DMG_STAGING/$(basename "$APP_BUNDLE")"
# Symlink to /Applications for drag-to-install UX.
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "OBScene" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

if [ "$can_notarise" = "1" ]; then
  echo "==> Notarising DMG"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "==> Generating checksums"
(
  cd "$BUILD_DIR"
  shasum -a 256 "${ZIP_BASENAME}.zip" > "${ZIP_BASENAME}.zip.sha256"
  shasum -a 256 "${ZIP_BASENAME}.dmg" > "${ZIP_BASENAME}.dmg.sha256"
)

echo
echo "==> Artifacts:"
ls -lh "$BUILD_DIR"/${APP_NAME}-*.zip "$BUILD_DIR"/${APP_NAME}-*.dmg 2>/dev/null || true

if [ "$can_notarise" != "1" ]; then
  echo
  echo "WARNING: Release was NOT notarised. Users will see Gatekeeper warnings."
  echo "Set APPLE_DEVELOPER_ID, APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD"
  echo "(or the equivalent GitHub secrets) to produce notarised releases."
fi
