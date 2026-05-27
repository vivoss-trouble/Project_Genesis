#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V170A_LOG:-/tmp/genesis_validate_v170a_public_binary_state_collapse.log}"

echo "========================================================================"
echo "Genesis v17.0a Public Binary State Collapse Validation"
echo "========================================================================"

./scripts/run_v170a_public_binary_state_collapse.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
summary = next((event for event in events if event.get("event") == "v170a_public_binary_state_collapse_summary"), None)
assert summary, "missing v17.0a dry-run summary"
assert summary.get("armed") is False, summary
assert summary.get("pre_state") in {True, False}, summary
assert summary.get("mutation_posted") is False, summary
assert summary.get("post_state") is None, summary
assert summary.get("business_state_asserted") is False, summary
assert summary.get("physical_input_posted") is False, summary
print(json.dumps({
    "event": "v170a_public_binary_dry_run_assertions",
    "status": "ok",
    "pre_state": summary.get("pre_state"),
    "mutation_posted": summary.get("mutation_posted"),
}, sort_keys=True))
PY

GENESIS_V170A_ARMED_CONFIRM=GENESIS_V170A_ARMED_PUBLIC_BINARY_STATE \
GENESIS_V170A_AUTO_FIRE_CONFIRM=GENESIS_V170A_AUTO_FIRE_PUBLIC_BINARY_STATE \
    ./scripts/run_v170a_public_binary_state_collapse.sh | tee -a "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys
events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
armed = [event for event in events if event.get("event") == "v170a_public_binary_state_collapse_summary" and event.get("armed") is True]
assert armed, "missing v17.0a armed summary"
summary = armed[-1]
assert summary.get("target_kind") in {"checkbox", "radio", "checkbox_or_radio"}, summary
assert summary.get("pre_state") in {True, False}, summary
assert summary.get("post_state") in {True, False}, summary
assert summary.get("mutation_posted") is True, summary
assert summary.get("fresh_remap_done") is True, summary
assert summary.get("state_changed_once") is True, summary
assert summary.get("url_unchanged") is True, summary
assert summary.get("business_state_asserted") is True, summary
assert summary.get("sequence_complete") is True, summary
clicks = [event for event in events if event.get("event") == "os_driver_click"]
armed_clicks = [event for event in clicks if (event.get("click", {}).get("receipt") or {}).get("posted") is True]
assert any(event.get("phase") == "binary_state_toggle" for event in armed_clicks), armed_clicks
print(json.dumps({
    "event": "v170a_public_binary_armed_assertions",
    "status": "ok",
    "pre_state": summary.get("pre_state"),
    "post_state": summary.get("post_state"),
    "url_unchanged": summary.get("url_unchanged"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v17.0a validation complete"
echo "========================================================================"
