#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_DIR="${GENESIS_VALIDATE_V59_LOG_DIR:-/tmp/genesis_validate_v59_spatial_policy}"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

echo "========================================================================"
echo "Genesis v5.9 Spatial Selection Policy Validation"
echo "========================================================================"

run_case() {
    local policy="$1"
    local expected_target="$2"
    local expected_candidate="$3"
    local log_path="$LOG_DIR/${policy}.log"

    echo "[v5.9] Validating policy=$policy"
    GENESIS_V58_SELECTION_POLICY="$policy" \
    GENESIS_V58_TARGET_ID="native-heal-b" \
        ./scripts/run_v58_fire_at_id.sh | tee "$log_path"

    python3 - "$log_path" "$policy" "$expected_target" "$expected_candidate" <<'PY'
import json
import sys

log_path, expected_policy, expected_target, expected_candidate = sys.argv[1:5]
target_set_event = None
selection = None
action_point = None
posted_values = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if payload.get("event") == "vision_target_set":
            target_set_event = payload
        elif payload.get("event") == "selection_policy":
            selection = payload
        elif payload.get("event") == "vision_action_point":
            action_point = payload
        for key in ("move", "click"):
            receipt = payload.get(key, {}).get("receipt")
            if isinstance(receipt, dict) and "posted" in receipt:
                posted_values.append(receipt["posted"])

if target_set_event is None:
    raise SystemExit("[v5.9] missing vision_target_set")
target_set = target_set_event.get("target_set") or []
if [item.get("target_id") for item in target_set[:3]] != ["native-heal-a", "native-heal-b", "native-heal-c"]:
    raise SystemExit(f"[v5.9] target_set ordering drifted: {target_set!r}")

if selection is None:
    raise SystemExit("[v5.9] missing selection_policy")
selected = selection.get("selected") or {}
if selection.get("policy") != expected_policy:
    raise SystemExit(f"[v5.9] expected policy {expected_policy}, got {selection!r}")
if selected.get("target_id") != expected_target:
    raise SystemExit(f"[v5.9] expected target {expected_target}, got {selected!r}")
if selected.get("candidate_id") != expected_candidate:
    raise SystemExit(f"[v5.9] expected candidate {expected_candidate}, got {selected!r}")
if action_point is None:
    raise SystemExit("[v5.9] missing vision_action_point")
if action_point.get("target_id") != expected_target:
    raise SystemExit(f"[v5.9] action target drifted: {action_point!r}")
if action_point.get("selected_target_id") != expected_target:
    raise SystemExit(f"[v5.9] selected action target drifted: {action_point!r}")
if action_point.get("candidate_id") != expected_candidate:
    raise SystemExit(f"[v5.9] action candidate drifted: {action_point!r}")
if not posted_values or any(posted_values):
    raise SystemExit(f"[v5.9] validation must remain dry-run, posted={posted_values!r}")

print(json.dumps({
    "event": "v59_policy_assertion",
    "policy": expected_policy,
    "selected_target_id": selected["target_id"],
    "selected_candidate_id": selected["candidate_id"],
    "posted_values": posted_values,
}, sort_keys=True))
PY
}

run_case "leftmost" "native-heal-a" "marker-0"
run_case "rightmost" "native-heal-c" "marker-2"
run_case "nearest_to_window_center" "native-heal-b" "marker-1"

echo "========================================================================"
echo "Genesis v5.9 spatial selection policy validation passed"
echo "========================================================================"
