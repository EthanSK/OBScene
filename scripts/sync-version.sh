#!/usr/bin/env bash
# sync-version.sh — copy the version from OBScene/Info.plist into site/version.json
#
# The Info.plist CFBundleShortVersionString is the single source of truth for
# the app's semantic version. This script keeps site/version.json in sync so
# the GitHub Pages landing page displays the right version and points the
# download button at the right release asset.
#
# Usage:
#   ./scripts/sync-version.sh
#
# Exit codes:
#   0 — site/version.json is up to date (written or already matching)
#   1 — Info.plist version is invalid or missing

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/OBScene/Info.plist"
SITE_VERSION_JSON="$ROOT/site/version.json"

if [ ! -f "$PLIST" ]; then
  echo "[version:sync] error: OBScene/Info.plist not found at $PLIST" >&2
  exit 1
fi

# Read CFBundleShortVersionString. PlistBuddy is macOS-only; on Linux
# (CI runners for version compute / pages deploy) fall back to Python's
# plistlib which is always available.
read_plist_key() {
  local key="$1"
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true
  elif command -v plutil >/dev/null 2>&1; then
    plutil -extract "$key" raw "$PLIST" 2>/dev/null || true
  else
    python3 - "$PLIST" "$key" <<'PY' 2>/dev/null || true
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    data = plistlib.load(f)
print(data.get(sys.argv[2], ''))
PY
  fi
}

version="$(read_plist_key CFBundleShortVersionString)"

if [ -z "$version" ]; then
  echo "[version:sync] error: CFBundleShortVersionString is empty or missing in Info.plist" >&2
  exit 1
fi

# Validate semver-ish x.y.z (with optional prerelease/build)
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "[version:sync] error: Info.plist CFBundleShortVersionString '$version' is not a supported semantic version" >&2
  exit 1
fi

display_version="v$version"

repo_owner="EthanSK"
repo_name="OBScene"
asset_name="OBScene-latest-mac-universal.zip"
latest_download_url="https://github.com/${repo_owner}/${repo_name}/releases/latest/download/${asset_name}"
releases_url="https://github.com/${repo_owner}/${repo_name}/releases/latest"

next_content=$(cat <<EOF
{
  "version": "$version",
  "displayVersion": "$display_version",
  "source": "OBScene/Info.plist",
  "downloadUrl": "$latest_download_url",
  "releasesUrl": "$releases_url",
  "minimumSystemVersion": "13.0"
}
EOF
)

mkdir -p "$(dirname "$SITE_VERSION_JSON")"

if [ -f "$SITE_VERSION_JSON" ] && [ "$(cat "$SITE_VERSION_JSON")" = "$next_content" ]; then
  echo "[version:sync] site/version.json already matches Info.plist ($version)."
  exit 0
fi

printf '%s\n' "$next_content" > "$SITE_VERSION_JSON"
echo "[version:sync] Updated site/version.json -> $display_version ($version)."
