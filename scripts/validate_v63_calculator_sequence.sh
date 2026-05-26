#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V63_LOG:-/tmp/genesis_validate_v63_calculator_sequence.log}"
SEQUENCE="${GENESIS_V63_TARGET_SEQUENCE:-calculator-cell-r3-c0,calculator-cell-r3-c3,calculator-cell-r3-c1}"
SETTLE_MS="${GENESIS_V63_SETTLE_MS:-500}"

echo "========================================================================"
echo "Genesis v6.3 Calculator Sequence Dry-Run Validation"
echo "========================================================================"

GENESIS_V63_TARGET_SEQUENCE="$SEQUENCE" \
GENESIS_V63_SETTLE_MS="$SETTLE_MS" \
GENESIS_V65_SETTLE_MODE=fixed \
    ./scripts/run_v63_calculator_sequence.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$SEQUENCE" "$SETTLE_MS" <<'PY'
import json
import sys

log_path, sequence_raw, settle_ms_raw = sys.argv[1:4]
expected_targets = [item.strip() for item in sequence_raw.split(",") if item.strip()]
expected_settle_ms = int(settle_ms_raw)
step_targets = []
moves = []
clicks = []
receipts = []
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "calculator_sequence_step_target":
            step_targets.append(payload)
        elif event == "os_driver_move":
            moves.append(payload)
        elif event == "os_driver_click":
            clicks.append(payload)
        elif event == "v63_sequence_step_receipts":
            receipts.append(payload)
        elif event == "v63_sequence_summary":
            summary = payload

if len(step_targets) != len(expected_targets):
    raise SystemExit(f"[v6.3] expected {len(expected_targets)} target maps, got {len(step_targets)}")
if len(moves) != len(expected_targets) or len(clicks) != len(expected_targets):
    raise SystemExit(f"[v6.3] expected one move/click per target, got moves={len(moves)} clicks={len(clicks)}")
if len(receipts) != len(expected_targets):
    raise SystemExit(f"[v6.3] expected one receipt summary per target, got {len(receipts)}")

for index, expected_target in enumerate(expected_targets):
    target = step_targets[index]
    if target.get("step_index") != index:
        raise SystemExit(f"[v6.3] target step index drift: {target}")
    if target.get("target_id") != expected_target:
        raise SystemExit(f"[v6.3] target id drift: {target}")
    if target.get("posted") is not False:
        raise SystemExit(f"[v6.3] map target must be read-only: {target}")
    if target.get("settle_ms") != expected_settle_ms:
        raise SystemExit(f"[v6.3] settle evidence drift: {target}")
    point = target.get("selected", {}).get("global_coregraphics_point") or {}
    if point.get("x") is None or point.get("y") is None:
        raise SystemExit(f"[v6.3] target missing global point: {target}")

    for label, event_list, payload_key in [("move", moves, "move"), ("click", clicks, "click")]:
        event = event_list[index]
        payload = event.get(payload_key) or {}
        if event.get("step_index") != index:
            raise SystemExit(f"[v6.3] {label} step index drift: {event}")
        if payload.get("status") != "ok":
            raise SystemExit(f"[v6.3] {label} failed: {payload}")
        if expected_target not in (payload.get("action_id") or ""):
            raise SystemExit(f"[v6.3] {label} action id missing target: {payload}")
        receipt = payload.get("receipt") or {}
        if receipt.get("posted") is not False:
            raise SystemExit(f"[v6.3] dry-run {label} must not post: {payload}")

    receipt_summary = receipts[index]
    if receipt_summary.get("armed") is not False:
        raise SystemExit(f"[v6.3] dry-run receipt armed drift: {receipt_summary}")
    if receipt_summary.get("move_posted") is not False or receipt_summary.get("click_posted") is not False:
        raise SystemExit(f"[v6.3] dry-run receipt posted drift: {receipt_summary}")

if summary is None:
    raise SystemExit("[v6.3] missing sequence summary")
if summary.get("step_count") != len(expected_targets):
    raise SystemExit(f"[v6.3] summary step count drift: {summary}")
if summary.get("armed") is not False or summary.get("posted") is not False:
    raise SystemExit(f"[v6.3] dry-run summary must not post: {summary}")
if summary.get("settle_ms") != expected_settle_ms:
    raise SystemExit(f"[v6.3] summary settle drift: {summary}")

print(json.dumps({
    "event": "v63_calculator_sequence_assertions",
    "sequence": expected_targets,
    "step_count": len(expected_targets),
    "settle_ms": expected_settle_ms,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.3 Calculator sequence dry-run validation passed"
echo "========================================================================"
