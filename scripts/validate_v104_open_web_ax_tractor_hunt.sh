#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V104_LOG:-/tmp/genesis_validate_v104_open_web_ax_tractor_hunt.log}"

echo "========================================================================"
echo "Genesis v10.4 Open-Web AX Tractor Hunt Validation"
echo "========================================================================"

./scripts/run_v104_open_web_ax_tractor_hunt.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
ax_probe = None
target = None
summary = None
maps = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v103_ax_scroll_to_visible_probe":
            ax_probe = payload
        elif event == "v104_ax_tractor_fire_target":
            target = payload
        elif event == "v104_open_web_ax_tractor_hunt_summary":
            summary = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if ax_probe is None:
    raise SystemExit("[v10.4] missing AX probe event")
if target is None:
    raise SystemExit("[v10.4] missing tractor target event")
if summary is None:
    raise SystemExit("[v10.4] missing summary event")
if len(maps) != 3:
    raise SystemExit(f"[v10.4] expected pre/post-tractor/post-click maps: {len(maps)}")

for payload in [ax_probe, target, summary, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v10.4] validation must not post: {payload}")

for payload in [ax_probe, *maps]:
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v10.4] validation must keep os-driver inactive: {payload}")

if ax_probe.get("web_area_found") is not True:
    raise SystemExit(f"[v10.4] AXWebArea not found: {ax_probe}")
if ax_probe.get("target_found") is not True:
    raise SystemExit(f"[v10.4] AX target not found: {ax_probe}")
if ax_probe.get("scroll_to_visible_available") is not True:
    raise SystemExit(f"[v10.4] target has no AXScrollToVisible: {ax_probe}")
if ax_probe.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.4] dry-run attempted AX mutation: {ax_probe}")
if target.get("target_found") is not True:
    raise SystemExit(f"[v10.4] target event did not preserve target: {target}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v10.4] validation must remain unarmed: {summary}")
if summary.get("move_posted") is not False or summary.get("click_posted") is not False:
    raise SystemExit(f"[v10.4] dry-run posted physical input: {summary}")
if summary.get("url_changed_after_ax") is not False or summary.get("url_changed_after_click") is not False:
    raise SystemExit(f"[v10.4] dry-run changed URL: {summary}")
if summary.get("assert_match") is not True:
    raise SystemExit(f"[v10.4] dry-run assertion failed: {summary}")

print(json.dumps({
    "event": "v104_open_web_ax_tractor_hunt_assertions",
    "web_area_found": True,
    "target_found": True,
    "scroll_to_visible_available": True,
    "ax_mutation_attempted": False,
    "move_posted": False,
    "click_posted": False,
    "url_changed_after_click": False,
    "assert_match": True,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v10.4 open-web AX tractor hunt validation passed"
echo "========================================================================"
