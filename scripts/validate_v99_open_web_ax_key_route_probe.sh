#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V99_LOG:-/tmp/genesis_validate_v99_open_web_ax_key_route_probe.log}"

echo "========================================================================"
echo "Genesis v9.9 Open-Web AX Key Route Probe Validation"
echo "========================================================================"

GENESIS_V99_KEY="${GENESIS_V99_KEY:-page_down}" \
    ./scripts/run_v99_open_web_ax_key_route_probe.sh | tee "$LOG_PATH"

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
        if event == "v98_ax_focus_probe":
            focus = payload
        elif event == "v99_ax_key_route_probe_result":
            result = payload
        elif event == "v99_open_web_ax_key_route_probe_summary":
            summary = payload
        elif event == "os_driver_key":
            key_event = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if focus is None:
    raise SystemExit("[v9.9] missing AX focus event")
if result is None:
    raise SystemExit("[v9.9] missing AX key route result")
if summary is None:
    raise SystemExit("[v9.9] missing AX key route summary")
if key_event is None:
    raise SystemExit("[v9.9] missing key event")
if len(maps) != 3:
    raise SystemExit(f"[v9.9] expected pre-focus/pre-key/post-key maps: {len(maps)}")

for payload in [focus, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v9.9] setup must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v9.9] setup maps must keep os-driver inactive: {payload}")

if focus.get("status") != "ok":
    raise SystemExit(f"[v9.9] AX focus failed: {focus}")
if result.get("ax_success") is not True:
    raise SystemExit(f"[v9.9] AX focus was not successful in route result: {result}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v9.9] target window changed during probe: {result}")
if result.get("url_changed_after_focus") is not False:
    raise SystemExit(f"[v9.9] AX focus changed URL: {result}")
if result.get("url_changed_after_key") is not False:
    raise SystemExit(f"[v9.9] dry-run key changed URL: {result}")
if result.get("key_posted") is not False:
    raise SystemExit(f"[v9.9] dry-run key leaked physical input: {result}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v9.9] validation must remain dry-run: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v9.9] dry-run summary leaked physical input: {summary}")

print(json.dumps({
    "event": "v99_open_web_ax_key_route_probe_assertions",
    "requested_key": result.get("requested_key"),
    "ax_success": True,
    "window_id_stable": True,
    "url_changed_after_key": False,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.9 open-web AX key route probe validation passed"
echo "========================================================================"
