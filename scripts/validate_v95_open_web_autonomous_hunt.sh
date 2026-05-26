#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V95_LOG:-/tmp/genesis_validate_v95_open_web_autonomous_hunt.log}"

echo "========================================================================"
echo "Genesis v9.5 Open-Web Autonomous Hunt Validation"
echo "========================================================================"

./scripts/run_v95_open_web_autonomous_hunt.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
hunter_summary = None
plans = []
scrolls = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "open_web_hunter_step_plan":
            plans.append(payload)
        elif event == "os_driver_scroll":
            scrolls.append(payload)
        elif event == "v94_open_web_hunter_controller_summary":
            hunter_summary = payload
        elif event == "v95_open_web_autonomous_hunt_summary":
            summary = payload

if summary is None:
    raise SystemExit("[v9.5] missing autonomous hunt summary")
if hunter_summary is None:
    raise SystemExit("[v9.5] missing delegated hunter summary")
if not plans:
    raise SystemExit("[v9.5] dry-run should emit at least one hunter plan")
if not scrolls:
    raise SystemExit("[v9.5] dry-run should emit one unarmed scroll receipt")

if summary.get("armed") is not False:
    raise SystemExit(f"[v9.5] validation must remain dry-run: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v9.5] validation leaked physical posting: {summary}")
if summary.get("url_changed") is not False or summary.get("assert_match") is not True:
    raise SystemExit(f"[v9.5] dry-run assertion failed: {summary}")
if summary.get("hunter_stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v9.5] dry-run did not stop at projection boundary: {summary}")
if hunter_summary.get("scroll_posted") is not False or hunter_summary.get("click_posted") is not False:
    raise SystemExit(f"[v9.5] delegated hunter leaked posting: {hunter_summary}")

print(json.dumps({
    "event": "v95_open_web_autonomous_hunt_assertions",
    "hunter_stop_reason": summary.get("hunter_stop_reason"),
    "target_id": summary.get("target_id"),
    "scroll_posted": summary.get("scroll_posted"),
    "click_posted": summary.get("click_posted"),
    "url_changed": summary.get("url_changed"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.5 open-web autonomous hunt validation passed"
echo "========================================================================"
