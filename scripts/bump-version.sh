#!/usr/bin/env bash
# bump-version.sh — bump CFBundleShortVersionString in OBScene/Info.plist
#
# OBScene uses a TWO-PART display versioning scheme (mirrors producer-player):
#   - Display version: v<major>.<minor>        (e.g. v1.0, v1.1, v2.0)
#   - Internal semver: <major>.<minor>.0       (patch is ALWAYS 0)
#   - CFBundleVersion: monotonic integer build number (major*10000 + minor*100)
#
# The release workflow calls this script on every push to main so the app
# auto-increments with each build. Manual local use is supported too:
#
#   ./scripts/bump-version.sh             # minor bump (1.0.0 -> 1.1.0), default
#   ./scripts/bump-version.sh minor       # same as default
#   ./scripts/bump-version.sh major       # major bump (1.1.0 -> 2.0.0)
#   ./scripts/bump-version.sh set 2.5.0   # set an explicit x.y.0 version
#
# After bumping, runs scripts/sync-version.sh so site/version.json tracks.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/OBScene/Info.plist"

mode="${1:-minor}"

if [ ! -f "$PLIST" ]; then
  echo "[version:bump] error: OBScene/Info.plist not found at $PLIST" >&2
  exit 1
fi

# Read the current CFBundleShortVersionString via PlistBuddy (macOS) or plistlib
# fallback so this script also works in Linux CI runners.
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

write_plist_key() {
  local key="$1"
  local value="$2"
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST"
  elif command -v plutil >/dev/null 2>&1; then
    plutil -replace "$key" -string "$value" "$PLIST"
  else
    python3 - "$PLIST" "$key" "$value" <<'PY'
import plistlib, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'rb') as f:
    data = plistlib.load(f)
data[key] = value
with open(path, 'wb') as f:
    plistlib.dump(data, f)
PY
  fi
}

current="$(read_plist_key CFBundleShortVersionString)"

if ! [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "[version:bump] error: current version '$current' is not in x.y.z format" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

if [ "$patch" != "0" ]; then
  echo "[version:bump] error: current version '$current' has non-zero patch ($patch)." >&2
  echo "[version:bump] OBScene uses two-part versioning (x.y) where the internal patch is always 0." >&2
  echo "[version:bump] Fix OBScene/Info.plist CFBundleShortVersionString to x.y.0 before bumping." >&2
  exit 1
fi

case "$mode" in
  minor|"")
    minor=$((minor + 1))
    ;;
  major)
    major=$((major + 1))
    minor=0
    ;;
  set)
    explicit="${2:-}"
    if [ -z "$explicit" ]; then
      echo "[version:bump] error: 'set' requires an explicit version argument (e.g. 2.5.0)" >&2
      exit 1
    fi
    if ! [[ "$explicit" =~ ^([0-9]+)\.([0-9]+)\.0$ ]]; then
      echo "[version:bump] error: '$explicit' is not in x.y.0 format (patch must be 0)" >&2
      exit 1
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    ;;
  *)
    echo "[version:bump] error: unknown mode '$mode' (expected minor|major|set)" >&2
    exit 1
    ;;
esac

next="$major.$minor.0"
build_number="$((major * 10000 + minor * 100))"

write_plist_key CFBundleShortVersionString "$next"
write_plist_key CFBundleVersion "$build_number"

display="v$major.$minor"
echo "[version:bump] $current -> $next (display: $display, build $build_number)"

"$ROOT/scripts/sync-version.sh"
