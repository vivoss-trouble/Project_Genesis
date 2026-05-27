#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V135_LOG:-/tmp/genesis_validate_v135_obstacle_isr_controller.log}"

echo "========================================================================"
echo "Genesis v13.5 Obstacle ISR Controller Validation"
echo "========================================================================"

./scripts/run_v135_obstacle_isr_controller.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

interrupt = next((event for event in events if event.get("event") == "v135_isr_interrupt"), None)
freeze = next((event for event in events if event.get("event") == "v135_state_freeze"), None)
child = next((event for event in events if event.get("event") == "v135_child_clearance_summary"), None)
summary = next((event for event in events if event.get("event") == "v135_isr_summary"), None)

if interrupt is None:
    raise SystemExit("[v13.5] missing ISR interrupt event")
if freeze is None:
    raise SystemExit("[v13.5] missing state freeze event")
if child is None:
    raise SystemExit("[v13.5] missing child clearance summary")
if summary is None:
    raise SystemExit("[v13.5] missing ISR summary")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v13.5] dry-run validation must not post: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v13.5] dry-run validation leaked physical input: {payload}")

if interrupt.get("interrupt_requested") != "obstacle_clearance":
    raise SystemExit(f"[v13.5] did not request obstacle clearance ISR: {interrupt}")
if interrupt.get("main_loop_frozen") is not True:
    raise SystemExit(f"[v13.5] main loop was not frozen: {interrupt}")
if freeze.get("target_point") in (None, {}):
    raise SystemExit(f"[v13.5] frozen state has no target point: {freeze}")
if freeze.get("occluder_frame") in (None, {}):
    raise SystemExit(f"[v13.5] frozen state has no occluder frame: {freeze}")
if child.get("child_click_posted") is not False:
    raise SystemExit(f"[v13.5] dry-run child posted click: {child}")
if child.get("child_target_clear_after") is not False:
    raise SystemExit(f"[v13.5] dry-run child should not clear target: {child}")
if summary.get("stop_reason") != "dry_run_isr_projection_stop":
    raise SystemExit(f"[v13.5] dry-run stop reason mismatch: {summary}")
if summary.get("resume_allowed") is not False:
    raise SystemExit(f"[v13.5] dry-run must not resume main loop: {summary}")

print(json.dumps({
    "event": "v135_obstacle_isr_assertions",
    "interrupt_requested": "obstacle_clearance",
    "main_loop_frozen": True,
    "state_frozen": True,
    "child_click_posted": False,
    "resume_allowed": False,
    "stop_reason": "dry_run_isr_projection_stop",
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v13.5 obstacle ISR controller validation passed"
echo "========================================================================"
