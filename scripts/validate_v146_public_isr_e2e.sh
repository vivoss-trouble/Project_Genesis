#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V146_LOG:-/tmp/genesis_validate_v146_public_isr_e2e.log}"

echo "========================================================================"
echo "Genesis v14.6 Public ISR E2E Validation"
echo "========================================================================"

./scripts/run_v146_public_isr_e2e.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

collision = next((event for event in events if event.get("event") == "v146_main_collision"), None)
freeze = next((event for event in events if event.get("event") == "v146_state_freeze"), None)
child = next((event for event in events if event.get("event") == "v146_child_clearance_summary"), None)
summary = next((event for event in events if event.get("event") == "v146_public_isr_e2e_summary"), None)

if collision is None or freeze is None or child is None or summary is None:
    raise SystemExit("[v14.6] missing ISR E2E receipt")

for payload in events:
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.6] dry-run leaked physical input: {payload}")
    if payload.get("event", "").startswith("os_driver_"):
        raise SystemExit(f"[v14.6] dry-run must not start OS driver: {payload}")

if collision.get("interrupt_requested") != "obstacle_clearance":
    raise SystemExit(f"[v14.6] interrupt not requested: {collision}")
if collision.get("main_loop_frozen") is not True:
    raise SystemExit(f"[v14.6] main loop did not freeze: {collision}")
if collision.get("occlusion_clear") is not False:
    raise SystemExit(f"[v14.6] collision must mark target occluded: {collision}")
if freeze.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v14.6] frozen court did not have one legal candidate: {freeze}")
if freeze.get("rejected_candidate_count", 0) < 1:
    raise SystemExit(f"[v14.6] frozen court did not reject decoys: {freeze}")
if child.get("selected_clearance") != "Cancel":
    raise SystemExit(f"[v14.6] expected Cancel as ISR clearance: {child}")
if child.get("child_click_posted") is not False:
    raise SystemExit(f"[v14.6] dry-run ISR clicked unexpectedly: {child}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v14.6] validation must run unarmed: {summary}")
if summary.get("resume_allowed") is not False:
    raise SystemExit(f"[v14.6] dry-run must not resume: {summary}")
if summary.get("stop_reason") != "dry_run_isr_projection_stop":
    raise SystemExit(f"[v14.6] expected dry-run ISR projection stop: {summary}")

print(json.dumps({
    "event": "v146_public_isr_e2e_assertions",
    "interrupt_requested": "obstacle_clearance",
    "main_loop_frozen": True,
    "selected_clearance": "Cancel",
    "resume_allowed": False,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.6 public ISR E2E validation passed"
echo "========================================================================"
