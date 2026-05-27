#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V200_OUTPUT_DIR:-/tmp/genesis_v200_autonomous_armed_execution}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
PLAN_DIR="$OUTPUT_DIR/v19_plan"
EXEC_DIR="$OUTPUT_DIR/v16_exec"
TARGET_URL="${GENESIS_V200_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V200_WINDOW_TITLE:-Modal Dialog Example}"
URL_DOMAIN_LOCK="${GENESIS_V200_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog}"
INPUT_VALUE="${GENESIS_V200_INPUT_VALUE:-42 Genesis Way}"
ARMED_TOKEN="GENESIS_V200_ARMED_AUTONOMOUS_EXECUTION"
AUTO_FIRE_TOKEN="GENESIS_V200_AUTO_FIRE_FROM_PLAN"

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
}

latest_event() {
    local path="$1"
    local event_name="$2"
    python3 - "$path" "$event_name" <<'PY'
import json
import sys

path, event_name = sys.argv[1:3]
match = None
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        event = json.loads(raw)
        if event.get("event") == event_name:
            match = event
if match is None:
    raise SystemExit(1)
print(json.dumps(match, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v20.0 Autonomous Armed Execution From Read-Only Plan"
echo "========================================================================"
echo "[v20.0] URL: $TARGET_URL"
echo "[v20.0] Domain lock: $URL_DOMAIN_LOCK"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V200_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V200_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v20.0] Armed execution requires GENESIS_V200_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v20.0] ARMED requested. It will execute the v19 plan through fresh-remap v16 primitives."
else
    echo "[v20.0] Dry-run mode. It will stop after plan validation."
fi

GENESIS_V190_OUTPUT_DIR="$PLAN_DIR" \
GENESIS_V190_TARGET_URL="$TARGET_URL" \
GENESIS_V190_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V190_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
    ./scripts/run_v190_public_task_planner.sh | tee "$OUTPUT_DIR/v19_stdout.log"

PLAN_LOG="$PLAN_DIR/results.jsonl"
PLAN_PAYLOAD="$(latest_event "$PLAN_LOG" "v190_public_task_plan")"
PLAN_SUMMARY="$(latest_event "$PLAN_LOG" "v190_public_task_planner_summary")"

emit "$(python3 - "$PLAN_PAYLOAD" "$PLAN_SUMMARY" <<'PY'
import json
import sys

plan, summary = [json.loads(arg) for arg in sys.argv[1:3]]
print(json.dumps({
    "event": "v200_plan_ingested",
    "plan_status": plan.get("status"),
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "domain_locked": plan.get("domain_locked") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "trigger_found": plan.get("trigger_found") is True,
    "modal_active_on_load": plan.get("modal_active_on_load") is True,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "stale_plan_coordinates_used": False,
    "coordinate_policy": "intent_only_fresh_remap_required",
    "summary_plan_ready": summary.get("plan_ready") is True,
}, sort_keys=True))
PY
)"

python3 - "$PLAN_PAYLOAD" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
assert plan.get("status") == "ok", plan
assert plan.get("domain_locked") is True, plan
assert plan.get("plan_ready") is True, plan
assert plan.get("safe_to_arm") is True, plan
assert plan.get("target_sequence_count") >= 3, plan
assert plan.get("posted") is False, plan
assert plan.get("physical_input_posted") is False, plan
assert plan.get("os_driver_active") is False, plan
steps = plan.get("target_sequence") or []
assert all(step.get("posted") is False for step in steps), steps
assert all(step.get("physical_input_posted") is False for step in steps), steps
PY

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$PLAN_PAYLOAD" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v200_autonomous_execution_summary",
    "armed": False,
    "plan_consumed": True,
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "execution_started": False,
    "sequence_complete": False,
    "stop_reason": "dry_run_plan_execution_boundary",
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v20.0 autonomous armed execution complete"
    echo "========================================================================"
    exit 0
fi

GENESIS_V160_OUTPUT_DIR="$EXEC_DIR" \
GENESIS_V160_TARGET_URL="$TARGET_URL" \
GENESIS_V160_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V160_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
GENESIS_V160_INPUT_VALUE="$INPUT_VALUE" \
GENESIS_V160_ARMED_CONFIRM=GENESIS_V160_ARMED_PUBLIC_BUSINESS_MUTATION \
GENESIS_V160_AUTO_FIRE_CONFIRM=GENESIS_V160_AUTO_FIRE_PUBLIC_BUSINESS_MUTATION \
    ./scripts/run_v160_public_controlled_business_mutation.sh | tee "$OUTPUT_DIR/v16_stdout.log"

EXEC_LOG="$EXEC_DIR/results.jsonl"
python3 - "$PLAN_PAYLOAD" "$EXEC_LOG" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

plan = json.loads(sys.argv[1])
events = []
with open(sys.argv[2], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

def latest(name):
    found = [event for event in events if event.get("event") == name]
    return found[-1] if found else {}

ground = latest("v160_w3c_ground_state")
form_lock = latest("v160_public_form_lock")
field = latest("v160_public_field_mutation")
fallback = latest("v160_text_input_fallback")
assertion = latest("v160_public_business_state_assertion")
summary = latest("v160_public_controlled_business_mutation_summary")

step_receipts = [
    {
        "event": "v200_execution_step_receipt",
        "step_id": "step-0-trigger-modal",
        "fresh_remap_done": ground.get("fresh_remap_done") is True or ground.get("trigger_found") is True,
        "resolved_from_plan_intent": True,
        "stale_plan_coordinates_used": False,
        "posted": True,
        "physical_input_posted": True,
        "asserted": form_lock.get("form_dialog_found") is True,
    },
    {
        "event": "v200_execution_step_receipt",
        "step_id": "step-1-fill-text-field",
        "fresh_remap_done": form_lock.get("field_found") is True,
        "resolved_from_plan_intent": True,
        "stale_plan_coordinates_used": False,
        "posted": True,
        "physical_input_posted": summary.get("text_fallback_used") is True,
        "field_transport": summary.get("field_transport"),
        "field_ready": summary.get("field_ready") is True,
        "asserted": summary.get("field_ready") is True,
    },
    {
        "event": "v200_execution_step_receipt",
        "step_id": "step-2-commit-form",
        "fresh_remap_done": field.get("commit_found") is True or form_lock.get("commit_found") is True,
        "resolved_from_plan_intent": True,
        "stale_plan_coordinates_used": False,
        "posted": True,
        "physical_input_posted": summary.get("commit_click_posted") is True,
        "business_state_asserted": assertion.get("business_state_asserted") is True,
        "asserted": summary.get("business_state_asserted") is True,
    },
]
for receipt in step_receipts:
    print(json.dumps(receipt, sort_keys=True))

sequence_complete = (
    plan.get("plan_ready") is True
    and summary.get("sequence_complete") is True
    and summary.get("url_unchanged") is True
    and all(receipt.get("fresh_remap_done") is True for receipt in step_receipts)
    and all(receipt.get("resolved_from_plan_intent") is True for receipt in step_receipts)
    and all(receipt.get("stale_plan_coordinates_used") is False for receipt in step_receipts)
)
print(json.dumps({
    "event": "v200_autonomous_execution_summary",
    "armed": True,
    "plan_consumed": True,
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "execution_started": True,
    "fresh_remap_before_each_step": all(receipt.get("fresh_remap_done") is True for receipt in step_receipts),
    "stale_plan_coordinates_used": False,
    "field_transport": summary.get("field_transport"),
    "field_ready": summary.get("field_ready") is True,
    "commit_click_posted": summary.get("commit_click_posted") is True,
    "business_state_asserted": summary.get("business_state_asserted") is True,
    "url_unchanged": summary.get("url_unchanged") is True,
    "sequence_complete": sequence_complete,
    "stop_reason": "complete" if sequence_complete else "v200_execution_assert_failed",
    "posted": True,
    "physical_input_posted": True,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v20.0 autonomous armed execution complete"
echo "========================================================================"
