#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V150_LOG:-/tmp/genesis_validate_v150_long_clock_isr_pagination_loop.log}"

echo "========================================================================"
echo "Genesis v15.0 Long-Clock ISR Pagination Loop Validation"
echo "========================================================================"

GENESIS_V150_ARMED_CONFIRM=GENESIS_V150_ARMED_LONG_CLOCK_ISR_PAGINATION \
GENESIS_V150_AUTO_FIRE_CONFIRM=GENESIS_V150_AUTO_FIRE_LONG_CLOCK_ISR_PAGINATION \
    ./scripts/run_v150_long_clock_isr_pagination_loop.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v150_long_clock_isr_pagination_summary" and event.get("armed") is True), None)
interrupts = [event for event in events if event.get("event") == "v150_isr_interrupt"]
fresh_remaps = [event for event in events if event.get("event") == "v150_post_isr_fresh_remap"]
step_receipts = [event for event in events if event.get("event") == "v150_step_receipt"]

assert summary, "missing v15.0 armed summary"
assert summary.get("total_pagination_steps") == 3, summary
assert summary.get("expected_pagination_steps") == 3, summary
assert summary.get("isr_triggered_count") == 1, summary
assert summary.get("isr_step_interventions") == [1], summary
assert summary.get("clearance_click_posted") is True, summary
assert summary.get("main_click_posted_count") == 3, summary
assert summary.get("pagination_complete") is True, summary
assert summary.get("sequence_complete") is True, summary
assert summary.get("final_stop_reason") == "target_not_found_terminal_ok", summary
assert summary.get("state_pollution_detected") is False, summary
assert summary.get("recursive_occlusion_fatal") is False, summary
assert len(interrupts) == 1, interrupts
assert interrupts[0].get("step") == 1, interrupts[0]
assert interrupts[0].get("main_loop_frozen") is True, interrupts[0]
assert interrupts[0].get("requires_fresh_v12_remap") is True, interrupts[0]
assert len(fresh_remaps) == 1, fresh_remaps
assert fresh_remaps[0].get("step") == 1, fresh_remaps[0]
assert fresh_remaps[0].get("occlusion_clear") is True, fresh_remaps[0]
assert fresh_remaps[0].get("same_url_count_after_isr") == 0, fresh_remaps[0]
assert len(step_receipts) == 3, step_receipts
assert all(receipt.get("url_changed") is True for receipt in step_receipts), step_receipts
assert [receipt.get("step") for receipt in step_receipts] == [0, 1, 2], step_receipts

driver_clicks = [event for event in events if event.get("event") == "os_driver_click"]
assert len(driver_clicks) == 4, driver_clicks
assert sum(1 for event in driver_clicks if event.get("phase") == "isr_clearance") == 1, driver_clicks
assert sum(1 for event in driver_clicks if event.get("phase") == "main_pagination") == 3, driver_clicks
for event in driver_clicks:
    assert (event.get("click", {}).get("receipt") or {}).get("posted") is True, event

print(json.dumps({
    "event": "v150_long_clock_isr_pagination_assertions",
    "status": "ok",
    "total_pagination_steps": summary.get("total_pagination_steps"),
    "isr_triggered_count": summary.get("isr_triggered_count"),
    "final_stop_reason": summary.get("final_stop_reason"),
    "state_pollution_detected": summary.get("state_pollution_detected"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v15.0 validation complete"
echo "========================================================================"
