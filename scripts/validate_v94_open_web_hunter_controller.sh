#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V94_LOG:-/tmp/genesis_validate_v94_open_web_hunter_controller.log}"

echo "========================================================================"
echo "Genesis v9.4 Open-Web Hunter Controller Validation"
echo "========================================================================"

./scripts/run_v94_open_web_hunter_controller.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
maps = []
plans = []
scrolls = []
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
        elif event == "open_web_hunter_step_plan":
            plans.append(payload)
        elif event == "os_driver_scroll":
            scrolls.append(payload)
        elif event == "v94_open_web_hunter_controller_summary":
            summary = payload

if len(maps) != 1:
    raise SystemExit(f"[v9.4] dry-run hunter should take exactly one map, got {len(maps)}")
if len(plans) != 1:
    raise SystemExit(f"[v9.4] dry-run hunter should emit exactly one plan, got {len(plans)}")
if len(scrolls) != 1:
    raise SystemExit(f"[v9.4] dry-run hunter should emit exactly one scroll receipt, got {len(scrolls)}")
if summary is None:
    raise SystemExit("[v9.4] missing hunter summary")

for event in maps:
    if event.get("posted") is not False or event.get("os_driver_active") is not False:
        raise SystemExit(f"[v9.4] maps must remain read-only: {event}")

plan = plans[0]
if plan.get("planner_contract") != "bounded_hunter_controller_remap_required":
    raise SystemExit(f"[v9.4] bad planner contract: {plan}")
if plan.get("posted") is not False:
    raise SystemExit(f"[v9.4] plan leaked posting: {plan}")
if plan.get("target_kind") != "link-like":
    raise SystemExit(f"[v9.4] validation target must remain link-like: {plan}")
if plan.get("ready_to_fire") is not False:
    raise SystemExit(f"[v9.4] default bottommost target should require scroll before fire: {plan}")
if plan.get("occlusion_clear") is not True:
    raise SystemExit(f"[v9.4] default hunter target should not be occluded: {plan}")

distance = abs(float(plan.get("distance_to_safe_center_px", 0.0)))
dy = float((plan.get("planned_scroll_delta") or {}).get("dy", 0.0))
if dy == 0.0 or abs(dy) >= distance:
    raise SystemExit(f"[v9.4] hunter scroll must be a nonzero undershoot: distance={distance} dy={dy}")

scroll = scrolls[0].get("scroll") or {}
receipt = scroll.get("receipt") or {}
if receipt.get("posted") is not False:
    raise SystemExit(f"[v9.4] dry-run leaked scroll posting: {scroll}")
actual_dy = float((receipt.get("scroll_delta") or {}).get("dy", 1e9))
if abs(actual_dy - dy) > 0.001:
    raise SystemExit(f"[v9.4] scroll receipt drifted from plan: plan={plan} scroll={scroll}")

if summary.get("armed") is not False or summary.get("fired") is not False:
    raise SystemExit(f"[v9.4] validation must not arm or fire: {summary}")
if summary.get("stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v9.4] dry-run must stop after projection: {summary}")
if summary.get("posted") is not False or summary.get("scroll_posted") is not False:
    raise SystemExit(f"[v9.4] summary leaked posting: {summary}")
if summary.get("url_changed") is not False:
    raise SystemExit(f"[v9.4] dry-run changed URL: {summary}")

print(json.dumps({
    "event": "v94_open_web_hunter_controller_assertions",
    "target_id": plan.get("target_id"),
    "damping_band": plan.get("damping_band"),
    "damping_factor": plan.get("damping_factor"),
    "planned_scroll_delta": plan.get("planned_scroll_delta"),
    "stop_reason": summary.get("stop_reason"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.4 open-web hunter controller validation passed"
echo "========================================================================"
