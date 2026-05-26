#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V86_LOG:-/tmp/genesis_validate_v86_open_web_scroll_remap.log}"

echo "========================================================================"
echo "Genesis v8.6 Open-Web Scroll Projection & Remap Validation"
echo "========================================================================"

./scripts/run_v86_open_web_scroll_remap.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
map_count = 0
pre_child = None
post_child = None
pre_outside = None
post_outside = None
scroll = None
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "open_web_shadow_map":
            map_count += 1
            if payload.get("posted") is not False or payload.get("os_driver_active") is not False:
                raise SystemExit(f"[v8.6] map must stay read-only: {payload}")
        elif event == "open_web_pre_scroll_child_target":
            pre_child = payload
        elif event == "open_web_post_scroll_child_target":
            post_child = payload
        elif event == "open_web_pre_scroll_outside_target":
            pre_outside = payload
        elif event == "open_web_post_scroll_outside_target":
            post_outside = payload
        elif event == "os_driver_scroll":
            scroll = payload.get("scroll")
        elif event == "v86_open_web_scroll_remap_summary":
            summary = payload

if map_count < 2:
    raise SystemExit(f"[v8.6] expected pre and post shadow maps, got {map_count}")
if pre_child is None or post_child is None:
    raise SystemExit("[v8.6] missing contained child remap evidence")
if pre_outside is None or post_outside is None:
    raise SystemExit("[v8.6] missing outside-target stability evidence")
if scroll is None:
    raise SystemExit("[v8.6] missing os-driver scroll receipt")
if summary is None:
    raise SystemExit("[v8.6] missing remap summary")

receipt = scroll.get("receipt") or {}
if scroll.get("armed") is not False or receipt.get("posted") is not False:
    raise SystemExit(f"[v8.6] scroll receipt must remain projection-only: {scroll}")
if summary.get("posted") is not False or summary.get("scroll_posted") is not False:
    raise SystemExit(f"[v8.6] summary violated projection-only mode: {summary}")
if summary.get("child_window_y_delta", 0) > -20:
    raise SystemExit(f"[v8.6] contained child did not remap upward enough: {summary}")
if abs(summary.get("outside_window_y_delta", 999)) > 5.0:
    raise SystemExit(f"[v8.6] outside target drifted unexpectedly: {summary}")
if abs(summary.get("scroll_region_window_y_delta", 999)) > 3.0:
    raise SystemExit(f"[v8.6] scroll-region shell drifted unexpectedly: {summary}")

print(json.dumps({
    "event": "v86_open_web_scroll_remap_assertions",
    "map_count": map_count,
    "child_window_y_delta": summary.get("child_window_y_delta"),
    "outside_window_y_delta": summary.get("outside_window_y_delta"),
    "scroll_region_window_y_delta": summary.get("scroll_region_window_y_delta"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.6 open-web scroll remap validation passed"
echo "========================================================================"
