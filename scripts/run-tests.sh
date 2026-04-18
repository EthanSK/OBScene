#!/usr/bin/env bash
# run-tests.sh — compile + run OBScene unit tests.
#
# Runs TWO unit-test binaries sequentially:
#   1. VerifiedSetEngine retry/verify state machine (2026-04-18 bug fix).
#   2. SafeModeDialogDismisser decision logic (2026-04-18 Safe Mode auto-
#      dismissal feature — v1.26).
#
# Each binary is produced with `swiftc -parse-as-library` and has its own
# `@main` entrypoint, so they must be compiled separately.
#
# Usage:
#   ./scripts/run-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

mkdir -p "$BUILD_DIR"

# --- 1. VerifiedSetEngine ------------------------------------------------
VERIFIED_BIN="$BUILD_DIR/obscene-unit-tests"
echo "[test] compiling VerifiedSetEngine tests -> $VERIFIED_BIN"
xcrun swiftc \
  -parse-as-library \
  -o "$VERIFIED_BIN" \
  "$ROOT/OBScene/VerifiedSetEngine.swift" \
  "$ROOT/scripts/test-retry-verify.swift"
echo "[test] running VerifiedSetEngine tests"
"$VERIFIED_BIN"

# --- 2. SafeModeDialogDismisser ------------------------------------------
#
# The dismisser source references ActivityLog + UserNotifier from
# ConfigStore.swift, so we compile that alongside. The test only exercises
# the pure decision logic (SafeModeDismissalLogic / SafeModeDismisserEngine /
# DialogProbe), never the real AX watcher, so it runs headlessly in CI.
SAFEMODE_BIN="$BUILD_DIR/obscene-safemode-tests"
echo "[test] compiling SafeModeDialogDismisser tests -> $SAFEMODE_BIN"
xcrun swiftc \
  -parse-as-library \
  -o "$SAFEMODE_BIN" \
  "$ROOT/OBScene/ConfigStore.swift" \
  "$ROOT/OBScene/SafeModeDialogDismisser.swift" \
  "$ROOT/scripts/test-safe-mode-dismisser.swift"
echo "[test] running SafeModeDialogDismisser tests"
"$SAFEMODE_BIN"
