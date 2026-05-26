#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V100_LOG:-/tmp/genesis_validate_v100_open_web_ax_webarea_key_probe.log}"

echo "========================================================================"
echo "Genesis v10.0 Open-Web AX WebArea Key Probe Validation"
echo "========================================================================"

GENESIS_V100_KEY="${GENESIS_V100_KEY:-page_down}" \
    ./scripts/run_v100_open_web_ax_webarea_key_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
focus = None
result = None
summary = None
key_event = None
maps = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v100_ax_web_area_focus_probe":
            focus = payload
        elif event == "v100_ax_webarea_key_probe_result":
            result = payload
        elif event == "v100_open_web_ax_webarea_key_probe_summary":
            summary = payload
        elif event == "os_driver_key":
            key_event = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if focus is None:
    raise SystemExit("[v10.0] missing AX WebArea focus event")
if result is None:
    raise SystemExit("[v10.0] missing AX WebArea key result")
if summary is None:
    raise SystemExit("[v10.0] missing AX WebArea key summary")
if key_event is None:
    raise SystemExit("[v10.0] missing key event")
if len(maps) != 3:
    raise SystemExit(f"[v10.0] expected pre-focus/pre-key/post-key maps: {len(maps)}")

for payload in [focus, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v10.0] setup must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v10.0] setup maps must keep os-driver inactive: {payload}")

if focus.get("status") != "ok":
    raise SystemExit(f"[v10.0] AX WebArea focus failed: {focus}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v10.0] target window changed during probe: {result}")
if result.get("url_changed_after_focus") is not False:
    raise SystemExit(f"[v10.0] AX WebArea focus changed URL: {result}")
if result.get("url_changed_after_key") is not False:
    raise SystemExit(f"[v10.0] dry-run key changed URL: {result}")
if result.get("key_posted") is not False:
    raise SystemExit(f"[v10.0] dry-run key leaked physical input: {result}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v10.0] validation must remain dry-run: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v10.0] dry-run summary leaked physical input: {summary}")

print(json.dumps({
    "event": "v100_open_web_ax_webarea_key_probe_assertions",
    "requested_key": result.get("requested_key"),
    "web_area_found": result.get("web_area_found"),
    "web_area_focus_success": result.get("web_area_focus_success"),
    "focused_role_after": result.get("focused_role_after"),
    "window_id_stable": True,
    "url_changed_after_key": False,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v10.0 open-web AX WebArea key probe validation passed"
echo "========================================================================"
