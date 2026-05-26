#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V58_LOG:-/tmp/genesis_validate_v58_fire_at_id.log}"

echo "========================================================================"
echo "Genesis v5.8 Fire-at-ID Validation"
echo "========================================================================"

GENESIS_V58_TARGET_ID="${GENESIS_V58_TARGET_ID:-native-heal-b}" \
    ./scripts/run_v58_fire_at_id.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
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
    raise SystemExit("[v5.8] missing vision_target_set event")
if target_set_event.get("capture_scope") != "window":
    raise SystemExit(f"[v5.8] expected window capture, got {target_set_event.get('capture_scope')!r}")

target_set = target_set_event.get("target_set")
if not isinstance(target_set, list) or len(target_set) < 3:
    raise SystemExit(f"[v5.8] expected at least 3 mapped targets, got {target_set!r}")

ids = [item.get("target_id") for item in target_set]
expected = ["native-heal-a", "native-heal-b", "native-heal-c"]
if ids[:3] != expected:
    raise SystemExit(f"[v5.8] expected target ids {expected!r}, got {ids!r}")
if target_set_event.get("unmapped_candidate_count") != 0:
    raise SystemExit(f"[v5.8] expected no unmapped candidates, got {target_set_event.get('unmapped_candidate_count')!r}")

for item in target_set[:3]:
    if item.get("candidate_distance_px") != 0.0:
        raise SystemExit(f"[v5.8] expected exact candidate mapping, got {item!r}")
    if "global_coregraphics_point" not in item:
        raise SystemExit(f"[v5.8] mapped target lacks global point: {item!r}")

if selection is None:
    raise SystemExit("[v5.8] missing selection_policy event")
selected = selection.get("selected") or {}
if selection.get("requested_target_id") != "native-heal-b":
    raise SystemExit(f"[v5.8] expected native-heal-b request, got {selection!r}")
if selected.get("target_id") != "native-heal-b" or selected.get("candidate_id") != "marker-1":
    raise SystemExit(f"[v5.8] expected marker-1/native-heal-b selection, got {selected!r}")

if action_point is None or action_point.get("target_id") != "native-heal-b":
    raise SystemExit(f"[v5.8] invalid vision_action_point {action_point!r}")
if not posted_values or any(posted_values):
    raise SystemExit(f"[v5.8] validation must remain dry-run, posted values={posted_values!r}")

print(json.dumps({
    "event": "v58_fire_at_id_assertions",
    "target_ids": ids[:3],
    "selected_target_id": selected["target_id"],
    "selected_candidate_id": selected["candidate_id"],
    "posted_values": posted_values,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v5.8 Fire-at-ID validation passed"
echo "========================================================================"
