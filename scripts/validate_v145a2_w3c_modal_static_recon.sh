#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V145A2_LOG:-/tmp/genesis_validate_v145a2_w3c_modal_static_recon.log}"

echo "========================================================================"
echo "Genesis v14.5a-2 W3C Modal Static Recon Validation"
echo "========================================================================"

./scripts/run_v145a2_w3c_modal_static_recon.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v145a2_w3c_modal_static_recon_summary"), None)
if summary is None:
    raise SystemExit("[v14.5a-2] missing W3C modal static recon summary")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v14.5a-2] static recon must not post: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.5a-2] static recon leaked physical input: {payload}")
    if payload.get("ax_mutation_attempted") not in (None, False):
        raise SystemExit(f"[v14.5a-2] static recon attempted AX mutation: {payload}")

if summary.get("trigger_found") is not True:
    raise SystemExit(f"[v14.5a-2] trigger button was not found: {summary}")
if summary.get("public_obstacle_seen") is not False:
    raise SystemExit(f"[v14.5a-2] modal should be inactive on load: {summary}")
if summary.get("safe_to_arm") is not False:
    raise SystemExit(f"[v14.5a-2] static recon must not arm: {summary}")
if summary.get("modal_inactive_on_load") is not True:
    raise SystemExit(f"[v14.5a-2] inactive modal baseline not proven: {summary}")

print(json.dumps({
    "event": "v145a2_w3c_modal_static_recon_assertions",
    "trigger_found": True,
    "public_obstacle_seen": False,
    "modal_inactive_on_load": True,
    "safe_to_arm": False,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a-2 W3C modal static recon validation passed"
echo "========================================================================"
