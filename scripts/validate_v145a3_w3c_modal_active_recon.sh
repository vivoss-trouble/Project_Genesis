#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V145A3_LOG:-/tmp/genesis_validate_v145a3_w3c_modal_active_recon.log}"

echo "========================================================================"
echo "Genesis v14.5a-3 W3C Modal Active Recon Validation"
echo "========================================================================"

./scripts/run_v145a3_w3c_modal_active_recon.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v145a3_w3c_modal_active_recon_summary"), None)
if summary is None:
    raise SystemExit("[v14.5a-3] missing active recon summary")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v14.5a-3] active recon must not post OS input: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.5a-3] active recon leaked physical input: {payload}")

if summary.get("trigger_found_before") is not True:
    raise SystemExit(f"[v14.5a-3] trigger not found before activation: {summary}")
if summary.get("modal_inactive_before") is not True:
    raise SystemExit(f"[v14.5a-3] modal was not inactive before trigger: {summary}")
if summary.get("trigger_ax_mutation_attempted") is not True:
    raise SystemExit(f"[v14.5a-3] trigger mutation not attempted: {summary}")
if summary.get("trigger_press_status") != "success":
    raise SystemExit(f"[v14.5a-3] trigger press failed: {summary}")
if summary.get("public_obstacle_seen") is not True:
    raise SystemExit(f"[v14.5a-3] modal not observed after trigger: {summary}")
if summary.get("occluder_kind") != "modal":
    raise SystemExit(f"[v14.5a-3] expected modal occluder after trigger: {summary}")
if summary.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v14.5a-3] expected exactly one legal modal clearance candidate: {summary}")
if summary.get("rejected_candidate_count", 0) < 1:
    raise SystemExit(f"[v14.5a-3] expected at least one rejected modal decoy: {summary}")
if summary.get("safe_to_arm") is not True:
    raise SystemExit(f"[v14.5a-3] active recon did not reach safe_to_arm: {summary}")

print(json.dumps({
    "event": "v145a3_w3c_modal_active_recon_assertions",
    "trigger_press_status": "success",
    "public_obstacle_seen": True,
    "occluder_kind": "modal",
    "safe_to_arm": True,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a-3 W3C modal active recon validation passed"
echo "========================================================================"
