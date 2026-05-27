#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V170C_LOG:-/tmp/genesis_validate_v170c_public_composite_form_mutation.log}"

echo "========================================================================"
echo "Genesis v17.0c Public Composite Form Mutation Validation"
echo "========================================================================"

./scripts/run_v170c_public_composite_form_mutation.sh | tee "$LOG_PATH"

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
        if event.get("event") == "v170c_public_composite_form_mutation_summary"
    ),
    None,
)
assert summary, "missing v17.0c dry-run summary"
assert summary.get("armed") is False, summary
assert summary.get("step_count") == 3, summary
assert summary.get("sequence_complete") is False, summary
assert summary.get("business_state_asserted_all") is False, summary
assert summary.get("state_pollution_detected") is False, summary
assert summary.get("stop_reason") == "dry_run_composite_projection_stop", summary

receipts = [
    event for event in events
    if event.get("event") == "v170c_composite_step_receipt"
    and event.get("armed") is False
]
assert len(receipts) == 3, receipts

print(json.dumps({
    "event": "v170c_public_composite_dry_run_assertions",
    "status": "ok",
    "step_count": summary.get("step_count"),
    "stop_reason": summary.get("stop_reason"),
}, sort_keys=True))
PY

GENESIS_V170C_ARMED_CONFIRM=GENESIS_V170C_ARMED_PUBLIC_COMPOSITE_FORM \
GENESIS_V170C_AUTO_FIRE_CONFIRM=GENESIS_V170C_AUTO_FIRE_PUBLIC_COMPOSITE_FORM \
    ./scripts/run_v170c_public_composite_form_mutation.sh | tee -a "$LOG_PATH"

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
    if event.get("event") == "v170c_public_composite_form_mutation_summary"
    and event.get("armed") is True
]
assert armed, "missing v17.0c armed summary"
summary = armed[-1]
assert summary.get("step_count") == 3, summary
assert summary.get("textfield_state_asserted") is True, summary
assert summary.get("checkbox_state_asserted") is True, summary
assert summary.get("combobox_state_asserted") is True, summary
assert summary.get("url_unchanged_all") is True, summary
assert summary.get("business_state_asserted_all") is True, summary
assert summary.get("state_pollution_detected") is False, summary
assert summary.get("sequence_complete") is True, summary
assert summary.get("stop_reason") == "complete", summary
assert summary.get("combobox_post_value") == "Banana", summary
assert summary.get("checkbox_pre_state") != summary.get("checkbox_post_state"), summary

receipts = [
    event for event in events
    if event.get("event") == "v170c_composite_step_receipt"
    and event.get("armed") is True
]
assert len(receipts) == 3, receipts

print(json.dumps({
    "event": "v170c_public_composite_armed_assertions",
    "status": "ok",
    "sequence_complete": summary.get("sequence_complete"),
    "url_unchanged_all": summary.get("url_unchanged_all"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v17.0c validation complete"
echo "========================================================================"
