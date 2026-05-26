#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${GENESIS_V66_HASH_BIN:-/tmp/genesis_v66_calculator_display_hash}"
BASELINE_DIR="${GENESIS_V66_BASELINE_DIR:-/tmp/genesis_v66_baselines}"
BASELINE_NAME="${GENESIS_V66_BASELINE_NAME:-display_current}"
BASELINE_JSON="$BASELINE_DIR/${BASELINE_NAME}.json"
BASELINE_CROP="$BASELINE_DIR/${BASELINE_NAME}.png"
DEBUG_PNG="$BASELINE_DIR/${BASELINE_NAME}_debug.png"

echo "========================================================================"
echo "Genesis v6.6 Calculator Display Baseline Capture"
echo "========================================================================"

mkdir -p "$BASELINE_DIR"
open -a Calculator || true
sleep "${GENESIS_V66_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/calculator_display_hash.swift -o "$BIN_PATH"
GENESIS_V66_DISPLAY_CROP_PNG="$BASELINE_CROP" \
GENESIS_V66_DEBUG_PNG="$DEBUG_PNG" \
    "$BIN_PATH" | tee "$BASELINE_JSON"

python3 - "$BASELINE_JSON" "$BASELINE_CROP" "$DEBUG_PNG" <<'PY'
import json
import os
import sys

baseline_json, crop_png, debug_png = sys.argv[1:4]
event = None
with open(baseline_json, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "calculator_display_hash":
                event = payload

if event is None:
    raise SystemExit("[v6.6] missing calculator_display_hash event")
if event.get("status") == "error":
    raise SystemExit(f"[v6.6] baseline capture returned error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v6.6] display baseline capture must be read-only: {event}")
for path in [crop_png, debug_png]:
    if not os.path.exists(path) or os.path.getsize(path) <= 0:
        raise SystemExit(f"[v6.6] expected non-empty artifact: {path}")
if event.get("target_id") != "calculator-display-screen":
    raise SystemExit(f"[v6.6] display target drift: {event}")
if event.get("crop_width", 0) <= 0 or event.get("crop_height", 0) <= 0:
    raise SystemExit(f"[v6.6] invalid display crop dimensions: {event}")

print(json.dumps({
    "event": "v66_display_baseline_captured",
    "baseline_json": baseline_json,
    "crop_png": crop_png,
    "debug_overlay": debug_png,
    "exact_hash": event.get("exact_hash"),
    "average_hash": event.get("average_hash"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.6 Calculator display baseline captured"
echo "Baseline JSON: $BASELINE_JSON"
echo "Baseline crop: $BASELINE_CROP"
echo "========================================================================"
