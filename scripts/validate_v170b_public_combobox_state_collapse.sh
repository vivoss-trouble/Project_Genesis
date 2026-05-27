#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V170B_LOG:-/tmp/genesis_validate_v170b_public_combobox_state_collapse.log}"

echo "========================================================================"
echo "Genesis v17.0b Public Combobox State Collapse Validation"
echo "========================================================================"

./scripts/run_v170b_public_combobox_state_collapse.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
summary = next((event for event in events if event.get("event") == "v170b_public_combobox_state_collapse_summary"), None)
assert summary, "missing v17.0b dry-run summary"
assert summary.get("armed") is False, summary
assert summary.get("combo_found") is True, summary
assert summary.get("pre_value") == "Choose a Fruit", summary
assert summary.get("combo_click_posted") is False, summary
assert summary.get("option_click_posted") is False, summary
assert summary.get("business_state_asserted") is False, summary
assert summary.get("physical_input_posted") is False, summary
print(json.dumps({
    "event": "v170b_public_combobox_dry_run_assertions",
    "status": "ok",
    "pre_value": summary.get("pre_value"),
    "combo_click_posted": summary.get("combo_click_posted"),
}, sort_keys=True))
PY

GENESIS_V170B_ARMED_CONFIRM=GENESIS_V170B_ARMED_PUBLIC_COMBOBOX_STATE \
GENESIS_V170B_AUTO_FIRE_CONFIRM=GENESIS_V170B_AUTO_FIRE_PUBLIC_COMBOBOX_STATE \
    ./scripts/run_v170b_public_combobox_state_collapse.sh | tee -a "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
armed = [event for event in events if event.get("event") == "v170b_public_combobox_state_collapse_summary" and event.get("armed") is True]
assert armed, "missing v17.0b armed summary"
summary = armed[-1]
assert summary.get("pre_value") == "Choose a Fruit", summary
assert summary.get("post_value") == "Banana", summary
assert summary.get("combo_click_posted") is True, summary
assert summary.get("option_click_posted") is True, summary
assert summary.get("popup_expanded_seen") is True, summary
assert summary.get("popup_collapsed_after") is True, summary
assert summary.get("fresh_remap_done") is True, summary
assert summary.get("value_changed_once") is True, summary
assert summary.get("url_unchanged") is True, summary
assert summary.get("business_state_asserted") is True, summary
assert summary.get("sequence_complete") is True, summary
clicks = [event for event in events if event.get("event") == "os_driver_click"]
armed_clicks = [event for event in clicks if (event.get("click", {}).get("receipt") or {}).get("posted") is True]
assert any(event.get("phase") == "combo_expand" for event in armed_clicks), armed_clicks
assert any(event.get("phase") == "option_select" for event in armed_clicks), armed_clicks
print(json.dumps({
    "event": "v170b_public_combobox_armed_assertions",
    "status": "ok",
    "pre_value": summary.get("pre_value"),
    "post_value": summary.get("post_value"),
    "url_unchanged": summary.get("url_unchanged"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v17.0b validation complete"
echo "========================================================================"
