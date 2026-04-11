#!/usr/bin/env bash
# build-app.sh — build OBScene.app as a universal binary from Swift sources.
#
# Produces build/OBScene.app with:
#   Contents/MacOS/OBScene        (arm64 + x86_64 universal Mach-O)
#   Contents/Resources/AppIcon.icns
#   Contents/Info.plist
#   Contents/_CodeSignature/      (only after codesign)
#
# Requires:
#   - Xcode command-line tools (swiftc, codesign, lipo, PlistBuddy)
#   - macOS 13 SDK (shipped with Xcode 14+)
#
# Optional environment variables:
#   SIGN_IDENTITY   Codesign identity. Defaults to "-" (ad-hoc) if not a
#                   Developer ID. Pass the full identity string or fingerprint:
#                     "Developer ID Application: Your Name (TEAMID)"
#   HARDENED_RUNTIME  If set to "1" (default when SIGN_IDENTITY is a real
#                     identity), enables the hardened runtime required for
#                     notarisation.
#   BUILD_DIR       Defaults to <repo>/build.
#
# Usage:
#   ./scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)" \
#     ./scripts/build-app.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_NAME="OBScene"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST_SRC="$ROOT/OBScene/Info.plist"
ENTITLEMENTS="$ROOT/OBScene/$APP_NAME.entitlements"
ICNS_SRC="$ROOT/Resources/AppIcon.icns"
SRC_DIR="$ROOT/OBScene"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# Default target: macOS 13 minimum.
DEPLOY_TARGET="13.0"

if [ ! -f "$INFO_PLIST_SRC" ]; then
  echo "[build] error: $INFO_PLIST_SRC not found" >&2
  exit 1
fi
if [ ! -f "$ICNS_SRC" ]; then
  echo "[build] error: $ICNS_SRC not found" >&2
  exit 1
fi

echo "[build] cleaning $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

SWIFT_SOURCES=("$SRC_DIR"/*.swift)

build_arch() {
  local arch="$1"
  local out="$2"
  echo "[build] compiling $arch"
  xcrun -sdk macosx swiftc \
    -O \
    -target "${arch}-apple-macos${DEPLOY_TARGET}" \
    -parse-as-library \
    -module-name "$APP_NAME" \
    -o "$out" \
    "${SWIFT_SOURCES[@]}"
}

ARM_BIN="$BUILD_DIR/${APP_NAME}-arm64"
X86_BIN="$BUILD_DIR/${APP_NAME}-x86_64"
UNIVERSAL_BIN="$MACOS_DIR/$APP_NAME"

build_arch "arm64" "$ARM_BIN"

# Check if x86_64 SDK stdlib is available (it is, on all current Xcode).
if build_arch "x86_64" "$X86_BIN" 2>/tmp/obscene_x86_err; then
  echo "[build] creating universal binary"
  lipo -create -output "$UNIVERSAL_BIN" "$ARM_BIN" "$X86_BIN"
  rm -f "$ARM_BIN" "$X86_BIN"
else
  echo "[build] warning: x86_64 build failed, falling back to arm64-only binary"
  cat /tmp/obscene_x86_err >&2 || true
  mv "$ARM_BIN" "$UNIVERSAL_BIN"
fi
chmod +x "$UNIVERSAL_BIN"

echo "[build] assembling bundle"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICNS_SRC" "$RES_DIR/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Codesign
if [ -z "$SIGN_IDENTITY" ]; then
  echo "[build] SIGN_IDENTITY unset — ad-hoc signing (unsigned distribution)"
  codesign --force --deep --sign - "$APP_BUNDLE"
else
  echo "[build] signing with identity: $SIGN_IDENTITY"
  codesign_args=(
    --force
    --deep
    --options runtime
    --timestamp
    --sign "$SIGN_IDENTITY"
  )
  if [ -f "$ENTITLEMENTS" ]; then
    codesign_args+=(--entitlements "$ENTITLEMENTS")
  fi
  codesign "${codesign_args[@]}" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
echo "[build] done: $APP_BUNDLE (v$version)"
