#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V147_LOG:-/tmp/genesis_validate_v147_public_isr_harmless_main_click.log}"

echo "========================================================================"
echo "Genesis v14.7 Public ISR Harmless Main Click Validation"
echo "========================================================================"

./scripts/run_v147_public_isr_harmless_main_click.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.strip()
    if raw.startswith("{"):
        events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v147_public_isr_harmless_main_click_summary"), None)
collision = next((event for event in events if event.get("event") == "v147_main_collision"), None)
state_freeze = next((event for event in events if event.get("event") == "v147_state_freeze"), None)

assert summary, "missing v14.7 summary"
assert collision, "missing v14.7 collision receipt"
assert state_freeze, "missing v14.7 state freeze receipt"
assert summary.get("armed") is False, summary
assert summary.get("interrupt_requested") is True, summary
assert summary.get("main_loop_frozen") is True, summary
assert summary.get("child_clearance_resolved") is True, summary
assert summary.get("selected_clearance") == "Cancel", summary
assert summary.get("harmless_target_found") is True, summary
assert summary.get("clearance_click_posted") is False, summary
assert summary.get("main_click_posted") is False, summary
assert summary.get("stop_reason") == "dry_run_isr_projection_stop", summary
assert summary.get("posted") is False, summary
assert summary.get("physical_input_posted") is False, summary
assert collision.get("harmless_target_found_before_trap") is True, collision
assert state_freeze.get("legal_candidate_count") == 1, state_freeze
assert not any(event.get("event", "").startswith("os_driver_") for event in events), "dry-run leaked os-driver events"

print(json.dumps({
    "event": "v147_public_isr_harmless_main_click_assertions",
    "status": "ok",
    "dry_run_projection_stop": True,
    "harmless_target_found": summary.get("harmless_target_found"),
    "selected_clearance": summary.get("selected_clearance"),
    "physical_input_posted": summary.get("physical_input_posted"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.7 validation complete"
echo "========================================================================"
