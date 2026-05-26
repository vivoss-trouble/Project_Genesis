#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${GENESIS_VALIDATE_V66_WORK_DIR:-/tmp/genesis_v66_display_assertion}"
BASELINE_DIR="$WORK_DIR/baselines"
BASELINE_NAME="${GENESIS_VALIDATE_V66_BASELINE_NAME:-display_current}"
BASELINE_JSON="$BASELINE_DIR/${BASELINE_NAME}.json"
ASSERT_LOG="$WORK_DIR/assert_positive.jsonl"
NEGATIVE_JSON="$BASELINE_DIR/${BASELINE_NAME}_wrong.json"
NEGATIVE_LOG="$WORK_DIR/assert_negative.jsonl"

echo "========================================================================"
echo "Genesis v6.6 Calculator Display Assertion Validation"
echo "========================================================================"

rm -rf "$WORK_DIR"
mkdir -p "$BASELINE_DIR"

GENESIS_V66_BASELINE_DIR="$BASELINE_DIR" \
GENESIS_V66_BASELINE_NAME="$BASELINE_NAME" \
    ./scripts/capture_v66_calculator_display_baseline.sh | tee "$WORK_DIR/capture.log"

GENESIS_V66_BASELINE_JSON="$BASELINE_JSON" \
GENESIS_V66_ASSERT_CROP_PNG="$WORK_DIR/assert_positive.png" \
GENESIS_V66_ASSERT_DEBUG_PNG="$WORK_DIR/assert_positive_debug.png" \
    ./scripts/assert_v66_calculator_display.sh | tee "$ASSERT_LOG"

python3 - "$BASELINE_JSON" "$NEGATIVE_JSON" <<'PY'
import json
import sys

baseline_json, negative_json = sys.argv[1:3]
event = None
with open(baseline_json, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "calculator_display_hash":
                event = payload
if event is None:
    raise SystemExit("[v6.6] missing baseline event while making negative control")
event["average_hash"] = "0000000000000000" if event.get("average_hash") != "0000000000000000" else "ffffffffffffffff"
with open(negative_json, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(event, sort_keys=True) + "\n")
PY

GENESIS_V66_BASELINE_JSON="$NEGATIVE_JSON" \
GENESIS_V66_ASSERT_CROP_PNG="$WORK_DIR/assert_negative.png" \
GENESIS_V66_ASSERT_DEBUG_PNG="$WORK_DIR/assert_negative_debug.png" \
    ./scripts/assert_v66_calculator_display.sh | tee "$NEGATIVE_LOG"

python3 - "$BASELINE_JSON" "$ASSERT_LOG" "$NEGATIVE_LOG" "$WORK_DIR" <<'PY'
import json
import os
import sys

baseline_json, assert_log, negative_log, work_dir = sys.argv[1:5]

def last_display_event(path):
    event = None
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if raw.startswith("{"):
                payload = json.loads(raw)
                if payload.get("event") == "calculator_display_hash":
                    event = payload
    if event is None:
        raise SystemExit(f"[v6.6] missing calculator_display_hash in {path}")
    if event.get("status") == "error":
        raise SystemExit(f"[v6.6] display hash returned error: {event}")
    return event

baseline = last_display_event(baseline_json)
positive = last_display_event(assert_log)
negative = last_display_event(negative_log)

for label, event in [("baseline", baseline), ("positive", positive), ("negative", negative)]:
    if event.get("posted") is not False:
        raise SystemExit(f"[v6.6] {label} must remain read-only: {event}")
    if event.get("target_id") != "calculator-display-screen":
        raise SystemExit(f"[v6.6] {label} target drift: {event}")
    for key in ["crop_png", "debug_overlay"]:
        path = event.get(key)
        if not path or not os.path.exists(path) or os.path.getsize(path) <= 0:
            raise SystemExit(f"[v6.6] {label} missing artifact {key}: {path}")

if positive.get("match") is not True:
    raise SystemExit(f"[v6.6] expected positive display assertion to match: {positive}")
if positive.get("changed_pixel_ratio") != 0:
    raise SystemExit(f"[v6.6] expected exact positive pixel match: {positive}")
if negative.get("match") is not False:
    raise SystemExit(f"[v6.6] expected negative display assertion to fail: {negative}")
if negative.get("hash_distance", 0) <= 0:
    raise SystemExit(f"[v6.6] negative hash distance did not move: {negative}")

print(json.dumps({
    "event": "v66_calculator_display_assertions",
    "baseline_json": baseline_json,
    "positive_match": positive.get("match"),
    "negative_match": negative.get("match"),
    "positive_changed_pixel_ratio": positive.get("changed_pixel_ratio"),
    "negative_hash_distance": negative.get("hash_distance"),
    "work_dir": work_dir,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.6 Calculator display assertion validation passed"
echo "Artifacts: $WORK_DIR"
echo "========================================================================"
