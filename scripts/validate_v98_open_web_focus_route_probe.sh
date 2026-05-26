#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V98_LOG:-/tmp/genesis_validate_v98_open_web_focus_route_probe.log}"

echo "========================================================================"
echo "Genesis v9.8 Open-Web Focus Route Probe Validation"
echo "========================================================================"

./scripts/run_v98_open_web_focus_route_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
focus = None
result = None
summary = None
maps = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v98_ax_focus_probe":
            focus = payload
        elif event == "v98_focus_route_probe_result":
            result = payload
        elif event == "v98_open_web_focus_route_probe_summary":
            summary = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if focus is None:
    raise SystemExit("[v9.8] missing AX focus event")
if result is None:
    raise SystemExit("[v9.8] missing focus route result")
if summary is None:
    raise SystemExit("[v9.8] missing focus route summary")
if len(maps) != 2:
    raise SystemExit(f"[v9.8] expected pre/post shadow maps: {len(maps)}")

for payload in [focus, result, summary, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v9.8] probe must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v9.8] os-driver must remain inactive: {payload}")

if focus.get("status") != "ok":
    raise SystemExit(f"[v9.8] AX focus failed: {focus}")
if result.get("url_changed") is not False:
    raise SystemExit(f"[v9.8] focus route changed URL: {result}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v9.8] focus route did not keep the same window id: {result}")
if summary.get("url_changed") is not False:
    raise SystemExit(f"[v9.8] summary changed URL: {summary}")

print(json.dumps({
    "event": "v98_open_web_focus_route_probe_assertions",
    "ax_success": result.get("ax_success"),
    "window_id_stable": result.get("window_id_stable"),
    "url_changed": False,
    "posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.8 open-web focus route probe validation passed"
echo "========================================================================"
