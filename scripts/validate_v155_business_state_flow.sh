#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V155_LOG:-/tmp/genesis_validate_v155_business_state_flow.log}"

echo "========================================================================"
echo "Genesis v15.5 Business State Flow Validation"
echo "========================================================================"

./scripts/run_v155_business_state_flow.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
summary = next((event for event in events if event.get("event") == "v155_business_state_flow_summary"), None)
assert summary, "missing v15.5 dry-run summary"
assert summary.get("armed") is False, summary
assert summary.get("interrupt_requested") is True, summary
assert summary.get("main_loop_frozen") is True, summary
assert summary.get("clearance_resolved") is True, summary
assert summary.get("selected_clearance") == "Close", summary
assert summary.get("field_set_success") is False, summary
assert summary.get("commit_click_posted") is False, summary
assert summary.get("business_state_asserted") is False, summary
assert summary.get("physical_input_posted") is False, summary
print(json.dumps({
    "event": "v155_business_state_flow_dry_run_assertions",
    "status": "ok",
    "selected_clearance": summary.get("selected_clearance"),
    "physical_input_posted": summary.get("physical_input_posted"),
}, sort_keys=True))
PY

GENESIS_V155_ARMED_CONFIRM=GENESIS_V155_ARMED_BUSINESS_STATE_FLOW \
GENESIS_V155_AUTO_FIRE_CONFIRM=GENESIS_V155_AUTO_FIRE_BUSINESS_STATE_FLOW \
    ./scripts/run_v155_business_state_flow.sh | tee -a "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
armed = [event for event in events if event.get("event") == "v155_business_state_flow_summary" and event.get("armed") is True]
assert armed, "missing v15.5 armed summary"
summary = armed[-1]
assert summary.get("clearance_click_posted") is True, summary
assert summary.get("fresh_remap_done") is True, summary
assert summary.get("field_set_success") is True, summary
assert summary.get("field_ready") is True, summary
assert summary.get("field_transport") in {"ax_value", "system_events_after_ax_value"}, summary
assert summary.get("field_value_after_transport") == "GENESIS-V155", summary
assert summary.get("mode_control_found") is True, summary
assert summary.get("commit_click_posted") is True, summary
assert summary.get("business_state_asserted") is True, summary
assert summary.get("url_unchanged") is True, summary
assert summary.get("sequence_complete") is True, summary
clicks = [event for event in events if event.get("event") == "os_driver_click"]
armed_clicks = [event for event in clicks if (event.get("click", {}).get("receipt") or {}).get("posted") is True]
assert len(armed_clicks) >= 2, armed_clicks
assert any(event.get("phase") == "isr_clearance" for event in armed_clicks), armed_clicks
assert any(event.get("phase") == "business_commit" for event in armed_clicks), armed_clicks
print(json.dumps({
    "event": "v155_business_state_flow_armed_assertions",
    "status": "ok",
    "field_transport": summary.get("field_transport"),
    "field_value_after_transport": summary.get("field_value_after_transport"),
    "business_state_asserted": summary.get("business_state_asserted"),
    "url_unchanged": summary.get("url_unchanged"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v15.5 validation complete"
echo "========================================================================"
