#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V73_LOG:-/tmp/genesis_validate_v73_browser_fixture_scroll_projection.log}"

echo "========================================================================"
echo "Genesis v7.3 Browser Fixture Scroll Projection Validation"
echo "========================================================================"

./scripts/run_v73_browser_fixture_scroll_projection.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
map_event = None
target_event = None
receipt_event = None
driver_event = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "browser_fixture_readonly_map":
            map_event = payload
        elif event == "browser_fixture_scroll_projection_target":
            target_event = payload
        elif event == "os_driver_scroll":
            driver_event = payload
        elif event == "v73_browser_fixture_scroll_projection_receipts":
            receipt_event = payload

if map_event is None:
    raise SystemExit("[v7.3] missing readonly browser map event")
if target_event is None:
    raise SystemExit("[v7.3] missing scroll target event")
if driver_event is None:
    raise SystemExit("[v7.3] missing os-driver scroll event")
if receipt_event is None:
    raise SystemExit("[v7.3] missing scroll projection receipt event")
if map_event.get("posted") is not False:
    raise SystemExit(f"[v7.3] map must remain read-only: {map_event}")
if target_event.get("selected", {}).get("control_kind") != "scroll-container":
    raise SystemExit(f"[v7.3] target must be scroll-container: {target_event}")
if receipt_event.get("posted") is not False or receipt_event.get("scroll_posted") is not False:
    raise SystemExit(f"[v7.3] projection must never post: {receipt_event}")

scroll = driver_event.get("scroll") or {}
receipt = scroll.get("receipt") or {}
if scroll.get("armed") is not False or receipt.get("posted") is not False:
    raise SystemExit(f"[v7.3] os-driver violated projection-only mode: {driver_event}")
if receipt.get("scroll_delta") is None:
    raise SystemExit(f"[v7.3] os-driver receipt missing scroll_delta: {driver_event}")

print(json.dumps({
    "event": "v73_browser_fixture_scroll_projection_assertions",
    "target_id": receipt_event.get("target_id"),
    "scroll_delta": receipt_event.get("scroll_delta"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.3 Browser fixture scroll projection validation passed"
echo "========================================================================"
