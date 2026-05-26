#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V62_LOG:-/tmp/genesis_validate_v62_calculator_single_shot.log}"
TARGET_ID="${GENESIS_V62_TARGET_ID:-calculator-cell-r4-c2}"

echo "========================================================================"
echo "Genesis v6.2 Calculator Single-Shot Dry-Run Validation"
echo "========================================================================"

GENESIS_V62_TARGET_ID="$TARGET_ID" \
    ./scripts/run_v62_calculator_single_shot.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$TARGET_ID" <<'PY'
import json
import sys

log_path, expected_target_id = sys.argv[1:3]
selected = None
move = None
click = None
receipts = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "calculator_single_shot_target":
            selected = payload
        elif event == "os_driver_move":
            move = payload.get("move")
        elif event == "os_driver_click":
            click = payload.get("click")
        elif event == "v62_single_shot_receipts":
            receipts = payload

if selected is None:
    raise SystemExit("[v6.2] missing selected Calculator target")
if selected.get("target_id") != expected_target_id:
    raise SystemExit(f"[v6.2] selected wrong target: {selected}")
if selected.get("posted") is not False:
    raise SystemExit(f"[v6.2] pre-fire selection must be read-only: {selected}")

point = selected.get("selected", {}).get("global_coregraphics_point") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v6.2] selected target missing global point: {selected}")

for label, payload in [("move", move), ("click", click)]:
    if payload is None:
        raise SystemExit(f"[v6.2] missing os-driver {label} event")
    if payload.get("status") != "ok":
        raise SystemExit(f"[v6.2] os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not False:
        raise SystemExit(f"[v6.2] dry-run {label} must not post: {payload}")
    if expected_target_id not in (payload.get("action_id") or ""):
        raise SystemExit(f"[v6.2] action_id must bind target id: {payload}")

if receipts is None:
    raise SystemExit("[v6.2] missing receipt summary")
if receipts.get("armed") is not False or receipts.get("move_posted") is not False or receipts.get("click_posted") is not False:
    raise SystemExit(f"[v6.2] dry-run receipt summary is unsafe: {receipts}")

print(json.dumps({
    "event": "v62_calculator_single_shot_assertions",
    "target_id": expected_target_id,
    "point": point,
    "move_posted": False,
    "click_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.2 Calculator single-shot dry-run validation passed"
echo "========================================================================"
