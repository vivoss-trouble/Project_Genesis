#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V72_LOG:-/tmp/genesis_validate_v72_browser_fixture_fire_projection.log}"
TARGET_ID="${GENESIS_V72_TARGET_ID:-browser-button-like-0}"

echo "========================================================================"
echo "Genesis v7.2 Browser Fixture Fire Projection Validation"
echo "========================================================================"

GENESIS_V72_TARGET_ID="$TARGET_ID" \
    ./scripts/run_v72_browser_fixture_fire_projection.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$TARGET_ID" <<'PY'
import json
import sys

log_path, target_id = sys.argv[1:3]
map_event = None
target_event = None
receipt_event = None
driver_events = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "browser_fixture_readonly_map":
            map_event = payload
        elif event == "browser_fixture_fire_projection_target":
            target_event = payload
        elif event == "v72_browser_fixture_fire_projection_receipts":
            receipt_event = payload
        elif event in {"os_driver_move", "os_driver_click"}:
            driver_events.append(payload)

if map_event is None:
    raise SystemExit("[v7.2] missing readonly browser map event")
if target_event is None:
    raise SystemExit("[v7.2] missing projection target event")
if receipt_event is None:
    raise SystemExit("[v7.2] missing projection receipt event")
if map_event.get("posted") is not False:
    raise SystemExit(f"[v7.2] map must remain read-only: {map_event}")
if target_event.get("target_id") != target_id:
    raise SystemExit(f"[v7.2] selected unexpected target: {target_event}")
if receipt_event.get("posted") is not False:
    raise SystemExit(f"[v7.2] projection must never post: {receipt_event}")
if receipt_event.get("move_posted") is not False or receipt_event.get("click_posted") is not False:
    raise SystemExit(f"[v7.2] driver receipts unexpectedly posted: {receipt_event}")

for payload in driver_events:
    envelope = payload.get("move") or payload.get("click") or {}
    receipt = envelope.get("receipt") or {}
    if envelope.get("armed") is not False or receipt.get("posted") is not False:
        raise SystemExit(f"[v7.2] os-driver event violated projection-only mode: {payload}")

print(json.dumps({
    "event": "v72_browser_fixture_fire_projection_assertions",
    "target_id": target_id,
    "control_kind": receipt_event.get("control_kind"),
    "target_count": map_event.get("target_count"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.2 Browser fixture fire projection validation passed"
echo "========================================================================"
