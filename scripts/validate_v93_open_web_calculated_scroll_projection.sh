#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V93_LOG:-/tmp/genesis_validate_v93_open_web_calculated_scroll.log}"

echo "========================================================================"
echo "Genesis v9.3 Open-Web Calculated Scroll Projection Validation"
echo "========================================================================"

./scripts/run_v93_open_web_calculated_scroll_projection.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
maps = []
plan = None
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
            maps.append(payload)
        elif event == "open_web_calculated_scroll_plan":
            plan = payload
        elif event == "os_driver_scroll":
            scroll = payload.get("scroll")
        elif event == "v93_open_web_calculated_scroll_summary":
            summary = payload

if not maps:
    raise SystemExit("[v9.3] missing open-web map")
if plan is None:
    raise SystemExit("[v9.3] missing calculated scroll plan")
if scroll is None:
    raise SystemExit("[v9.3] missing OS-driver scroll receipt")
if summary is None:
    raise SystemExit("[v9.3] missing calculated scroll summary")

for event in maps:
    if event.get("posted") is not False or event.get("os_driver_active") is not False:
        raise SystemExit(f"[v9.3] maps must remain read-only: {event}")

if plan.get("posted") is not False or plan.get("planner_contract") != "piecewise_undershoot_remap_required":
    raise SystemExit(f"[v9.3] bad planner contract: {plan}")
if plan.get("target_kind") != "link-like":
    raise SystemExit(f"[v9.3] validation target must be link-like: {plan}")
if plan.get("target_strategy") != "bottommost":
    raise SystemExit(f"[v9.3] validation should use bottommost target: {plan}")

distance = abs(float(plan.get("distance_to_safe_center_px", 0.0)))
delta = plan.get("planned_scroll_delta") or {}
dy = float(delta.get("dy", 0.0))
factor = float(plan.get("damping_factor", -1.0))
if distance <= float(plan.get("safe_band_px", 0.0)):
    if dy != 0.0 or factor != 0.0:
        raise SystemExit(f"[v9.3] safe-band target should not scroll: {plan}")
else:
    if dy == 0.0:
        raise SystemExit(f"[v9.3] out-of-band target produced no scroll: {plan}")
    if abs(dy) >= distance:
        raise SystemExit(f"[v9.3] planner must undershoot, got distance={distance} dy={dy}: {plan}")
    if factor not in {0.25, 0.45, 0.60, 0.75}:
        raise SystemExit(f"[v9.3] unexpected damping factor: {plan}")

receipt = scroll.get("receipt") or {}
if receipt.get("posted") is not False:
    raise SystemExit(f"[v9.3] dry-run leaked physical scroll: {scroll}")
actual = receipt.get("scroll_delta") or {}
if abs(float(actual.get("dy", 1e9)) - dy) > 0.001:
    raise SystemExit(f"[v9.3] receipt did not match planned dy: plan={plan} scroll={scroll}")
if dy == -480.0:
    raise SystemExit(f"[v9.3] calculated scroll must not collapse to the v9.2 fixed step: {summary}")

if summary.get("posted") is not False or summary.get("scroll_posted") is not False:
    raise SystemExit(f"[v9.3] summary leaked posting: {summary}")
if summary.get("url_changed") is not False:
    raise SystemExit(f"[v9.3] projection changed URL: {summary}")

print(json.dumps({
    "event": "v93_open_web_calculated_scroll_assertions",
    "target_id": plan.get("target_id"),
    "damping_band": plan.get("damping_band"),
    "damping_factor": factor,
    "distance_to_safe_center_px": plan.get("distance_to_safe_center_px"),
    "planned_scroll_delta": delta,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.3 open-web calculated scroll projection validation passed"
echo "========================================================================"
