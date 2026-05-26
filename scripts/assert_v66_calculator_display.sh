#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${GENESIS_V66_HASH_BIN:-/tmp/genesis_v66_calculator_display_hash}"
BASELINE_JSON="${GENESIS_V66_BASELINE_JSON:-}"
ASSERT_CROP="${GENESIS_V66_ASSERT_CROP_PNG:-/tmp/genesis_v66_display_assert.png}"
DEBUG_PNG="${GENESIS_V66_ASSERT_DEBUG_PNG:-/tmp/genesis_v66_display_assert_debug.png}"

echo "========================================================================"
echo "Genesis v6.6 Calculator Display Assertion"
echo "========================================================================"

if [[ -z "$BASELINE_JSON" ]]; then
    echo "[v6.6] GENESIS_V66_BASELINE_JSON is required" >&2
    exit 1
fi
if [[ ! -f "$BASELINE_JSON" ]]; then
    echo "[v6.6] baseline JSON not found: $BASELINE_JSON" >&2
    exit 1
fi

open -a Calculator || true
sleep "${GENESIS_V66_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/calculator_display_hash.swift -o "$BIN_PATH"
GENESIS_V66_DISPLAY_CROP_PNG="$ASSERT_CROP" \
GENESIS_V66_DEBUG_PNG="$DEBUG_PNG" \
GENESIS_V66_BASELINE_JSON="$BASELINE_JSON" \
    "$BIN_PATH"
