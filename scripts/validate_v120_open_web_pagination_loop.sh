#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V120_LOG:-/tmp/genesis_validate_v120_open_web_pagination_loop.log}"

echo "========================================================================"
echo "Genesis v12.0 Open-Web Pagination Loop Validation"
echo "========================================================================"

./scripts/run_v120_open_web_pagination_loop.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
events = []
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

if not events:
    raise SystemExit("[v12.0] no JSON events captured")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v12.0] validation must not post: {payload}")
    if payload.get("event") in {"open_web_shadow_map", "v103_ax_scroll_to_visible_probe"}:
        if payload.get("os_driver_active") is not False:
            raise SystemExit(f"[v12.0] validation must keep os-driver inactive: {payload}")

ax_events = [event for event in events if event.get("event") == "v103_ax_scroll_to_visible_probe"]
target_events = [event for event in events if event.get("event") == "v120_pagination_step_target"]
step_summaries = [event for event in events if event.get("event") == "v120_pagination_step_summary"]
summary = next((event for event in events if event.get("event") == "v120_open_web_pagination_loop_summary"), None)

if len(ax_events) != 1:
    raise SystemExit(f"[v12.0] dry-run should project exactly one pagination step: {len(ax_events)}")
if len(target_events) != 1:
    raise SystemExit(f"[v12.0] missing projected target event: {len(target_events)}")
if len(step_summaries) != 1:
    raise SystemExit(f"[v12.0] missing dry-run step summary: {len(step_summaries)}")
if summary is None:
    raise SystemExit("[v12.0] missing pagination summary")

ax = ax_events[0]
target = target_events[0]
step = step_summaries[0]

if ax.get("web_area_found") is not True:
    raise SystemExit(f"[v12.0] AXWebArea not found: {ax}")
if ax.get("target_found") is not True:
    raise SystemExit(f"[v12.0] projected pagination target not found: {ax}")
if ax.get("scroll_to_visible_available") is not True:
    raise SystemExit(f"[v12.0] target has no AXScrollToVisible: {ax}")
if ax.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v12.0] dry-run attempted AX mutation: {ax}")
if target.get("target_found") is not True:
    raise SystemExit(f"[v12.0] target event lost projected target: {target}")
if step.get("stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v12.0] dry-run did not stop at projection boundary: {step}")
if step.get("move_posted") is not False or step.get("click_posted") is not False:
    raise SystemExit(f"[v12.0] dry-run posted physical input: {step}")
if summary.get("pagination_complete") is not False:
    raise SystemExit(f"[v12.0] dry-run pagination should not complete: {summary}")
if summary.get("stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v12.0] dry-run summary stop reason mismatch: {summary}")

print(json.dumps({
    "event": "v120_open_web_pagination_loop_assertions",
    "projected_step_id": ax.get("step_id"),
    "target_found": True,
    "scroll_to_visible_available": True,
    "ax_mutation_attempted": False,
    "move_posted": False,
    "click_posted": False,
    "stop_reason": "dry_run_projection_stop",
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v12.0 open-web pagination loop validation passed"
echo "========================================================================"
