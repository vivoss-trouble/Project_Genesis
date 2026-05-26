#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V85_LOG:-/tmp/genesis_validate_v85_scroll_region_topology.log}"

echo "========================================================================"
echo "Genesis v8.5 Scroll-Region Topology Validation"
echo "========================================================================"

./scripts/validate_v81_open_web_shadow_map.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
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
    raise SystemExit("[v8.5] missing shadow map event")

if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.5] scroll topology validation must stay read-only: {event}")

targets = event.get("targets") or []
targets_by_id = {target.get("target_id"): target for target in targets}
scroll_regions = event.get("scroll_regions") or []
active_regions = [
    region for region in scroll_regions
    if region.get("control_kind") == "scroll-region" and region.get("child_target_ids")
]

if not active_regions:
    raise SystemExit(f"[v8.5] expected at least one scroll-region with child targets: {event}")

for region in active_regions:
    region_id = region.get("target_id")
    for child_id in region.get("child_target_ids") or []:
        child = targets_by_id.get(child_id)
        if not child:
            raise SystemExit(f"[v8.5] missing child target {child_id}: {event}")
        if child.get("container_id") != region_id:
            raise SystemExit(
                f"[v8.5] child {child_id} has container_id={child.get('container_id')}, expected {region_id}"
            )

print(json.dumps({
    "event": "v85_scroll_region_topology_assertions",
    "active_scroll_region_count": len(active_regions),
    "child_target_count": sum(len(region.get("child_target_ids") or []) for region in active_regions),
    "posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.5 scroll-region topology validation passed"
echo "========================================================================"
