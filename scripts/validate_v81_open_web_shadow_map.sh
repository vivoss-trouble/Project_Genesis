#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V81_LOG:-/tmp/genesis_validate_v81_open_web_shadow_map.log}"

echo "========================================================================"
echo "Genesis v8.1 Open-Web Shadow Mapping Validation"
echo "========================================================================"

./scripts/run_v81_open_web_shadow_map.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import os
import sys

log_path = sys.argv[1]
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit("[v8.1] missing open_web_shadow_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v8.1] mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v8.1] shadow mapping must remain read-only: {event}")
if event.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.1] os-driver must remain disconnected: {event}")

required = {"heading", "link-like", "button-like", "code-block", "scroll-region"}
kinds = set(event.get("control_kinds") or [])
missing = sorted(required - kinds)
if missing:
    raise SystemExit(f"[v8.1] missing taxonomy classes {missing}; got {sorted(kinds)}")
if event.get("target_count", 0) < len(required):
    raise SystemExit(f"[v8.1] target_count too small: {event.get('target_count')}")

debug_overlay = event.get("debug_overlay")
if not debug_overlay or not os.path.exists(debug_overlay):
    raise SystemExit(f"[v8.1] debug overlay missing: {debug_overlay}")

print(json.dumps({
    "event": "v81_open_web_shadow_map_assertions",
    "control_kinds": sorted(kinds),
    "target_count": event.get("target_count"),
    "posted": False,
    "os_driver_active": False,
    "debug_overlay": debug_overlay,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.1 open-web shadow mapping validation passed"
echo "========================================================================"
