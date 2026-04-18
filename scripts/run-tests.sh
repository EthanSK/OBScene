#!/usr/bin/env bash
# run-tests.sh — compile + run OBScene unit tests.
#
# Currently covers the VerifiedSetEngine retry/verify state machine used
# for OBS profile + scene-collection switches (the fix for the
# "change scene collection but not profile" reliability bug from 2026-04-18).
#
# Usage:
#   ./scripts/run-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
BIN="$BUILD_DIR/obscene-unit-tests"

mkdir -p "$BUILD_DIR"

echo "[test] compiling unit-test binary -> $BIN"
xcrun swiftc \
  -parse-as-library \
  -o "$BIN" \
  "$ROOT/OBScene/VerifiedSetEngine.swift" \
  "$ROOT/scripts/test-retry-verify.swift"

echo "[test] running"
"$BIN"
