#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V190_LOG:-/tmp/genesis_validate_v190_public_task_planner.log}"

echo "========================================================================"
echo "Genesis v19.0 Public Read-Only Task Planner Validation"
echo "========================================================================"

./scripts/run_v190_public_task_planner.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

plans = [event for event in events if event.get("event") == "v190_public_task_plan"]
plan = plans[-1] if plans else None
assert plan, "missing v19 task plan"
assert plan.get("status") == "ok", plan
assert plan.get("domain_locked") is True, plan
assert plan.get("trigger_found") is True, plan
assert plan.get("modal_active_on_load") is False, plan
assert plan.get("public_obstacle_seen") is False, plan
assert plan.get("target_sequence_count") >= 3, plan
assert plan.get("plan_ready") is True, plan
assert plan.get("safe_to_arm") is True, plan
assert plan.get("posted") is False, plan
assert plan.get("physical_input_posted") is False, plan
assert plan.get("os_driver_active") is False, plan

steps = plan.get("target_sequence") or []
assert [step.get("step_id") for step in steps[:3]] == [
    "step-0-trigger-modal",
    "step-1-fill-text-field",
    "step-2-commit-form",
], steps
assert steps[0].get("control_type") in {"button", "pressable"}, steps[0]
assert steps[1].get("control_type") == "text_input", steps[1]
assert steps[2].get("control_type") == "button", steps[2]
assert all(step.get("posted") is False for step in steps), steps
assert all(step.get("physical_input_posted") is False for step in steps), steps

termination = plan.get("termination_conditions") or {}
assert termination.get("url_must_remain_within_domain_lock") is True, termination
assert termination.get("expect_static_text_contains") == "Verification Result", termination

summary = next((event for event in events if event.get("event") == "v190_public_task_planner_summary"), None)
assert summary, "missing v19 summary"
assert summary.get("plan_ready") is True, summary
assert summary.get("posted") is False, summary
assert summary.get("physical_input_posted") is False, summary
assert summary.get("os_driver_active") is False, summary

print(json.dumps({
    "event": "v190_public_task_planner_assertions",
    "status": "ok",
    "target_sequence_count": plan.get("target_sequence_count"),
    "trigger_found": plan.get("trigger_found"),
    "safe_to_arm": plan.get("safe_to_arm"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v19.0 validation complete"
echo "========================================================================"
