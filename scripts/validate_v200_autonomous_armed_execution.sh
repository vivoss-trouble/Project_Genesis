#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V200_LOG:-/tmp/genesis_validate_v200_autonomous_armed_execution.log}"

echo "========================================================================"
echo "Genesis v20.0 Autonomous Armed Execution Validation"
echo "========================================================================"

./scripts/run_v200_autonomous_armed_execution.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next(
    (
        event for event in events
        if event.get("event") == "v200_autonomous_execution_summary"
        and event.get("armed") is False
    ),
    None,
)
assert summary, "missing v20 dry-run summary"
assert summary.get("plan_consumed") is True, summary
assert summary.get("plan_ready") is True, summary
assert summary.get("safe_to_arm") is True, summary
assert summary.get("execution_started") is False, summary
assert summary.get("sequence_complete") is False, summary
assert summary.get("stop_reason") == "dry_run_plan_execution_boundary", summary
assert summary.get("posted") is False, summary
assert summary.get("physical_input_posted") is False, summary
assert summary.get("os_driver_active") is False, summary
assert summary.get("stale_plan_coordinates_used") is False, summary

print(json.dumps({
    "event": "v200_autonomous_execution_dry_run_assertions",
    "status": "ok",
    "target_sequence_count": summary.get("target_sequence_count"),
    "stop_reason": summary.get("stop_reason"),
}, sort_keys=True))
PY

GENESIS_V200_ARMED_CONFIRM=GENESIS_V200_ARMED_AUTONOMOUS_EXECUTION \
GENESIS_V200_AUTO_FIRE_CONFIRM=GENESIS_V200_AUTO_FIRE_FROM_PLAN \
    ./scripts/run_v200_autonomous_armed_execution.sh | tee -a "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

armed = [
    event for event in events
    if event.get("event") == "v200_autonomous_execution_summary"
    and event.get("armed") is True
]
assert armed, "missing v20 armed summary"
summary = armed[-1]
assert summary.get("plan_consumed") is True, summary
assert summary.get("plan_ready") is True, summary
assert summary.get("safe_to_arm") is True, summary
assert summary.get("execution_started") is True, summary
assert summary.get("fresh_remap_before_each_step") is True, summary
assert summary.get("stale_plan_coordinates_used") is False, summary
assert summary.get("field_ready") is True, summary
assert summary.get("field_transport") in {"ax_value", "system_events_after_ax_value"}, summary
assert summary.get("commit_click_posted") is True, summary
assert summary.get("business_state_asserted") is True, summary
assert summary.get("url_unchanged") is True, summary
assert summary.get("sequence_complete") is True, summary
assert summary.get("stop_reason") == "complete", summary

receipts = [
    event for event in events
    if event.get("event") == "v200_execution_step_receipt"
]
assert len(receipts) >= 3, receipts
latest = receipts[-3:]
assert [receipt.get("step_id") for receipt in latest] == [
    "step-0-trigger-modal",
    "step-1-fill-text-field",
    "step-2-commit-form",
], latest
assert all(receipt.get("resolved_from_plan_intent") is True for receipt in latest), latest
assert all(receipt.get("stale_plan_coordinates_used") is False for receipt in latest), latest
assert all(receipt.get("fresh_remap_done") is True for receipt in latest), latest
assert all(receipt.get("asserted") is True for receipt in latest), latest

print(json.dumps({
    "event": "v200_autonomous_execution_armed_assertions",
    "status": "ok",
    "field_transport": summary.get("field_transport"),
    "sequence_complete": summary.get("sequence_complete"),
    "fresh_remap_before_each_step": summary.get("fresh_remap_before_each_step"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v20.0 validation complete"
echo "========================================================================"
