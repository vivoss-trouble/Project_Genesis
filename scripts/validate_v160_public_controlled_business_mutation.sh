#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V160_LOG:-/tmp/genesis_validate_v160_public_controlled_business_mutation.log}"

echo "========================================================================"
echo "Genesis v16.0 Public Controlled Business Mutation Validation"
echo "========================================================================"

./scripts/run_v160_public_controlled_business_mutation.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
summary = next((event for event in events if event.get("event") == "v160_public_controlled_business_mutation_summary"), None)
assert summary, "missing v16.0 dry-run summary"
assert summary.get("armed") is False, summary
assert summary.get("baseline_public_obstacle_seen") is False, summary
assert summary.get("form_dialog_found") is True, summary
assert summary.get("field_found") is True, summary
assert summary.get("commit_found") is True, summary
assert summary.get("field_ready") is False, summary
assert summary.get("commit_click_posted") is False, summary
assert summary.get("business_state_asserted") is False, summary
assert summary.get("physical_input_posted") is False, summary
print(json.dumps({
    "event": "v160_public_business_mutation_dry_run_assertions",
    "status": "ok",
    "field_found": summary.get("field_found"),
    "commit_found": summary.get("commit_found"),
    "physical_input_posted": summary.get("physical_input_posted"),
}, sort_keys=True))
PY

GENESIS_V160_ARMED_CONFIRM=GENESIS_V160_ARMED_PUBLIC_BUSINESS_MUTATION \
GENESIS_V160_AUTO_FIRE_CONFIRM=GENESIS_V160_AUTO_FIRE_PUBLIC_BUSINESS_MUTATION \
    ./scripts/run_v160_public_controlled_business_mutation.sh | tee -a "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
armed = [event for event in events if event.get("event") == "v160_public_controlled_business_mutation_summary" and event.get("armed") is True]
assert armed, "missing v16.0 armed summary"
summary = armed[-1]
assert summary.get("field_set_success") is True, summary
assert summary.get("field_ready") is True, summary
assert summary.get("field_transport") in {"ax_value", "system_events_after_ax_value"}, summary
assert summary.get("field_value_after_transport") == "42 Genesis Way", summary
assert summary.get("commit_click_posted") is True, summary
assert summary.get("business_state_asserted") is True, summary
assert summary.get("url_unchanged") is True, summary
assert summary.get("sequence_complete") is True, summary
clicks = [event for event in events if event.get("event") == "os_driver_click"]
armed_clicks = [event for event in clicks if (event.get("click", {}).get("receipt") or {}).get("posted") is True]
assert any(event.get("phase") == "public_business_verify" for event in armed_clicks), armed_clicks
print(json.dumps({
    "event": "v160_public_business_mutation_armed_assertions",
    "status": "ok",
    "field_transport": summary.get("field_transport"),
    "business_state_asserted": summary.get("business_state_asserted"),
    "url_unchanged": summary.get("url_unchanged"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v16.0 validation complete"
echo "========================================================================"
