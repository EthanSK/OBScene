#!/usr/bin/env bash
# bump-version.sh — bump CFBundleShortVersionString in OBScene/Info.plist
#
# Usage:
#   ./scripts/bump-version.sh              # patch bump (default: 1.0.0 -> 1.0.1)
#   ./scripts/bump-version.sh patch        # patch bump
#   ./scripts/bump-version.sh minor        # minor bump (1.0.1 -> 1.1.0)
#   ./scripts/bump-version.sh major        # major bump (1.1.0 -> 2.0.0)
#   ./scripts/bump-version.sh set 1.2.3    # set an explicit version
#
# Also updates CFBundleVersion (build number) to a monotonically increasing
# integer (strips dots from the new version, e.g. 1.2.3 -> 123).
#
# After bumping, runs scripts/sync-version.sh so site/version.json tracks.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/OBScene/Info.plist"

mode="${1:-patch}"

if [ ! -f "$PLIST" ]; then
  echo "[version:bump] error: OBScene/Info.plist not found at $PLIST" >&2
  exit 1
fi

current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if ! [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "[version:bump] error: current version '$current' is not in x.y.z format" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$mode" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  set)
    explicit="${2:-}"
    if [ -z "$explicit" ]; then
      echo "[version:bump] error: 'set' requires an explicit version argument (e.g. 1.2.3)" >&2
      exit 1
    fi
    if ! [[ "$explicit" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      echo "[version:bump] error: '$explicit' is not in x.y.z format" >&2
      exit 1
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    ;;
  *)
    echo "[version:bump] error: unknown mode '$mode' (expected patch|minor|major|set)" >&2
    exit 1
    ;;
esac

next="$major.$minor.$patch"
build_number="$((major * 10000 + minor * 100 + patch))"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$PLIST"

echo "[version:bump] $current -> $next (build $build_number)"

"$ROOT/scripts/sync-version.sh"
