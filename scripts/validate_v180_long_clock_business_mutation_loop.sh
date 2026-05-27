#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V180_LOG:-/tmp/genesis_validate_v180_long_clock_business_mutation_loop.log}"

echo "========================================================================"
echo "Genesis v18.0 Long-Clock Business Mutation Loop Validation"
echo "========================================================================"

./scripts/run_v180_long_clock_business_mutation_loop.sh | tee "$LOG_PATH"

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
        if event.get("event") == "v180_long_clock_business_mutation_summary"
        and event.get("armed") is False
    ),
    None,
)
assert summary, "missing v18.0 dry-run summary"
assert summary.get("interrupt_requested") is True, summary
assert summary.get("main_loop_frozen") is True, summary
assert summary.get("physical_input_posted") is False, summary
assert summary.get("sequence_complete") is False, summary
assert summary.get("stop_reason") == "dry_run_business_projection_stop", summary
assert summary.get("candidate_count") == 4, summary
assert summary.get("legal_candidate_count") == 1, summary

print(json.dumps({
    "event": "v180_long_clock_business_dry_run_assertions",
    "status": "ok",
    "stop_reason": summary.get("stop_reason"),
    "candidate_count": summary.get("candidate_count"),
    "legal_candidate_count": summary.get("legal_candidate_count"),
}, sort_keys=True))
PY

GENESIS_V180_ARMED_CONFIRM=GENESIS_V180_ARMED_LONG_CLOCK_BUSINESS \
GENESIS_V180_AUTO_FIRE_CONFIRM=GENESIS_V180_AUTO_FIRE_LONG_CLOCK_BUSINESS \
    ./scripts/run_v180_long_clock_business_mutation_loop.sh | tee -a "$LOG_PATH"

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
    if event.get("event") == "v180_long_clock_business_mutation_summary"
    and event.get("armed") is True
]
assert armed, "missing v18.0 armed summary"
summary = armed[-1]
assert summary.get("total_business_steps") == 3, summary
assert summary.get("expected_business_steps") == 3, summary
assert summary.get("isr_triggered_count") == 3, summary
assert summary.get("clearance_click_posted_count") == 3, summary
assert summary.get("business_mutation_count") == 3, summary
assert summary.get("business_state_asserted_count") == 3, summary
assert summary.get("checkbox_click_posted_count") == 3, summary
assert summary.get("commit_click_posted_count") == 3, summary
assert summary.get("main_click_posted_count") == 3, summary
assert summary.get("field_fallback_used_count") >= 1, summary
assert summary.get("terminal_success") is True, summary
assert summary.get("target_not_found_terminal_ok") is True, summary
assert summary.get("final_stop_reason") == "target_not_found_terminal_ok", summary
assert summary.get("state_pollution_detected") is False, summary
assert summary.get("sequence_complete") is True, summary

receipts = [
    event for event in events
    if event.get("event") == "v180_business_pagination_step_receipt"
]
assert len(receipts) == 3, receipts
assert [receipt.get("step") for receipt in receipts] == [0, 1, 2], receipts
assert all(receipt.get("clearance_click_posted") is True for receipt in receipts), receipts
assert all(receipt.get("checkbox_click_posted") is True for receipt in receipts), receipts
assert all(receipt.get("commit_click_posted") is True for receipt in receipts), receipts
assert all(receipt.get("main_click_posted") is True for receipt in receipts), receipts
assert all(receipt.get("business_state_asserted") is True for receipt in receipts), receipts
assert all(receipt.get("url_changed") is True for receipt in receipts), receipts
assert all("survey_on" in receipt.get("expected_status", "") for receipt in receipts), receipts

ready_remaps = [
    event for event in events
    if event.get("event") == "v180_business_ready_fresh_remap"
]
assert ready_remaps, "missing v18 business ready fresh remaps"
assert all(event.get("combobox_state_inherited_from") == "v17.0b" for event in ready_remaps), ready_remaps

print(json.dumps({
    "event": "v180_long_clock_business_armed_assertions",
    "status": "ok",
    "total_business_steps": summary.get("total_business_steps"),
    "isr_triggered_count": summary.get("isr_triggered_count"),
    "final_stop_reason": summary.get("final_stop_reason"),
    "state_pollution_detected": summary.get("state_pollution_detected"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v18.0 validation complete"
echo "========================================================================"
