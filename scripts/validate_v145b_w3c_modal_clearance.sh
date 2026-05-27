#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V145B_LOG:-/tmp/genesis_validate_v145b_w3c_modal_clearance.log}"

echo "========================================================================"
echo "Genesis v14.5b W3C Modal Clearance Validation"
echo "========================================================================"

./scripts/run_v145b_w3c_modal_clearance.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v145b_w3c_modal_clearance_summary"), None)
if summary is None:
    raise SystemExit("[v14.5b] missing W3C modal clearance summary")

for payload in events:
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.5b] dry-run leaked physical input: {payload}")
    if payload.get("event", "").startswith("os_driver_"):
        raise SystemExit(f"[v14.5b] dry-run must not start OS driver: {payload}")

if summary.get("armed") is not False:
    raise SystemExit(f"[v14.5b] validation must run unarmed: {summary}")
if summary.get("public_obstacle_seen_before") is not True:
    raise SystemExit(f"[v14.5b] active modal not observed before clearance: {summary}")
if summary.get("candidate_count", 0) < 2:
    raise SystemExit(f"[v14.5b] expected modal candidate set with decoys: {summary}")
if summary.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v14.5b] expected exactly one legal clearance candidate: {summary}")
if summary.get("rejected_candidate_count", 0) < 1:
    raise SystemExit(f"[v14.5b] expected at least one rejected decoy: {summary}")
if summary.get("selected_clearance") != "Cancel":
    raise SystemExit(f"[v14.5b] expected Cancel as selected clearance: {summary}")
if summary.get("click_posted") is not False:
    raise SystemExit(f"[v14.5b] dry-run clicked unexpectedly: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v14.5b] dry-run posted unexpectedly: {summary}")
if summary.get("stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v14.5b] expected dry-run projection stop: {summary}")

print(json.dumps({
    "event": "v145b_w3c_modal_clearance_assertions",
    "public_obstacle_seen_before": True,
    "selected_clearance": "Cancel",
    "legal_candidate_count": 1,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5b W3C modal clearance validation passed"
echo "========================================================================"
