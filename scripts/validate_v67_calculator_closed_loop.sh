#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${GENESIS_VALIDATE_V67_WORK_DIR:-/tmp/genesis_v67_closed_loop_validation}"
LOG_PATH="$WORK_DIR/closed_loop.log"
SEQUENCE="${GENESIS_V67_TARGET_SEQUENCE:-calculator-cell-r3-c0}"

echo "========================================================================"
echo "Genesis v6.7 Calculator Closed Loop Dry-Run Validation"
echo "========================================================================"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

GENESIS_V67_WORK_DIR="$WORK_DIR/run" \
GENESIS_V67_TARGET_SEQUENCE="$SEQUENCE" \
GENESIS_V67_SETTLE_MODE=hybrid \
    ./scripts/run_v67_calculator_closed_loop.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$SEQUENCE" <<'PY'
import json
import os
import sys

log_path, sequence_raw = sys.argv[1:3]
expected_targets = [item.strip() for item in sequence_raw.split(",") if item.strip()]
summary = None
clicks = []
settles = []
assert_event = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v67_closed_loop_summary":
            summary = payload
        elif event == "os_driver_click":
            clicks.append(payload)
        elif event == "v65_sequence_settle":
            settles.append(payload)
        elif event == "calculator_display_hash":
            assert_event = payload

if summary is None:
    raise SystemExit("[v6.7] missing closed loop summary")
if assert_event is None:
    raise SystemExit("[v6.7] missing final assertion event")
if len(clicks) != len(expected_targets):
    raise SystemExit(f"[v6.7] expected {len(expected_targets)} click events, got {len(clicks)}")
if len(settles) != len(expected_targets):
    raise SystemExit(f"[v6.7] expected {len(expected_targets)} settle events, got {len(settles)}")
if summary.get("sequence_complete") is not True:
    raise SystemExit(f"[v6.7] sequence did not complete: {summary}")
if summary.get("assert_match") is not True:
    raise SystemExit(f"[v6.7] visual assertion failed: {summary}")
if summary.get("armed") is not False or summary.get("posted") is not False:
    raise SystemExit(f"[v6.7] dry-run summary must not post: {summary}")
if summary.get("sequence") != expected_targets:
    raise SystemExit(f"[v6.7] summary sequence drift: {summary}")
if assert_event.get("posted") is not False:
    raise SystemExit(f"[v6.7] assertion must be read-only: {assert_event}")

for click in clicks:
    receipt = (click.get("click") or {}).get("receipt") or {}
    if receipt.get("posted") is not False:
        raise SystemExit(f"[v6.7] dry-run click must not post: {click}")
for settle in settles:
    if settle.get("posted") is not False:
        raise SystemExit(f"[v6.7] settle must remain read-only: {settle}")

for key in ["assert_crop_png", "assert_debug_overlay", "baseline_json"]:
    path = summary.get(key)
    if not path or not os.path.exists(path) or os.path.getsize(path) <= 0:
        raise SystemExit(f"[v6.7] summary artifact missing {key}: {path}")

print(json.dumps({
    "event": "v67_closed_loop_assertions",
    "sequence": expected_targets,
    "assert_match": summary.get("assert_match"),
    "sequence_complete": summary.get("sequence_complete"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.7 Calculator closed loop dry-run validation passed"
echo "Artifacts: $WORK_DIR"
echo "========================================================================"
