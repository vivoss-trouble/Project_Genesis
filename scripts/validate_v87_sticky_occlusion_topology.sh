#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V87_LOG:-/tmp/genesis_validate_v87_sticky_occlusion_topology.log}"

echo "========================================================================"
echo "Genesis v8.7 Sticky/Floating Occlusion Topology Validation"
echo "========================================================================"

./scripts/run_v86_open_web_scroll_remap.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import math
import sys

log_path = sys.argv[1]
maps = []
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "open_web_shadow_map":
            maps.append(payload)
            if payload.get("posted") is not False or payload.get("os_driver_active") is not False:
                raise SystemExit(f"[v8.7] map must stay read-only: {payload}")
        elif event == "v86_open_web_scroll_remap_summary":
            summary = payload

if len(maps) < 2:
    raise SystemExit(f"[v8.7] expected pre and post maps, got {len(maps)}")
if summary is None:
    raise SystemExit("[v8.7] missing v8.6 scroll-remap summary")
if summary.get("posted") is not False or summary.get("scroll_posted") is not False:
    raise SystemExit(f"[v8.7] scroll projection leaked physical posting: {summary}")
if summary.get("child_window_y_delta", 0) > -20:
    raise SystemExit(f"[v8.7] scroll child did not remap materially: {summary}")

pre, post = maps[0], maps[-1]

def active_region(event):
    regions = [
        region for region in event.get("scroll_regions") or []
        if region.get("control_kind") == "scroll-region"
        and region.get("child_target_ids")
        and region.get("sticky_target_ids")
    ]
    if not regions:
        raise SystemExit(f"[v8.7] missing scroll-region with sticky occluder: {event}")
    return sorted(regions, key=lambda item: item["pixel_center"]["y"])[0]

def target_by_id(event, target_id):
    for target in event.get("targets") or []:
        if target.get("target_id") == target_id:
            return target
    return None

def sticky_target(event, region):
    ids = region.get("sticky_target_ids") or []
    if not ids:
        raise SystemExit(f"[v8.7] region missing sticky_target_ids: {region}")
    target = target_by_id(event, ids[0])
    if target is None:
        raise SystemExit(f"[v8.7] sticky target id not found: {ids[0]}")
    if target.get("control_kind") != "sticky-like":
        raise SystemExit(f"[v8.7] sticky target misclassified: {target}")
    if target.get("motion_role") != "sticky_occluder":
        raise SystemExit(f"[v8.7] sticky target missing motion_role: {target}")
    if target.get("container_id") != region.get("target_id"):
        raise SystemExit(f"[v8.7] sticky target has wrong container_id: {target}")
    return target

pre_region = active_region(pre)
post_region = active_region(post)
pre_sticky = sticky_target(pre, pre_region)
post_sticky = sticky_target(post, post_region)

sticky_delta = (
    post_sticky["window_coregraphics_point"]["y"]
    - pre_sticky["window_coregraphics_point"]["y"]
)
region_delta = (
    post_region["window_coregraphics_point"]["y"]
    - pre_region["window_coregraphics_point"]["y"]
)

if abs(sticky_delta) > 5.0:
    raise SystemExit(f"[v8.7] sticky occluder drifted with scroll content: {sticky_delta}")
if abs(region_delta) > 5.0:
    raise SystemExit(f"[v8.7] scroll-region shell drifted too far: {region_delta}")

print(json.dumps({
    "event": "v87_sticky_occlusion_topology_assertions",
    "pre_sticky_target_id": pre_sticky.get("target_id"),
    "post_sticky_target_id": post_sticky.get("target_id"),
    "sticky_window_y_delta": sticky_delta,
    "scroll_child_window_y_delta": summary.get("child_window_y_delta"),
    "scroll_region_window_y_delta": region_delta,
    "sticky_count": pre_region.get("sticky_count"),
    "motion_role": pre_sticky.get("motion_role"),
    "posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.7 sticky/floating occlusion topology validation passed"
echo "========================================================================"
