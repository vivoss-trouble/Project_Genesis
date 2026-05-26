#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V65_LOG:-/tmp/genesis_validate_v65_dynamic_settle.log}"
FALLBACK_LOG_PATH="${GENESIS_VALIDATE_V65_FALLBACK_LOG:-/tmp/genesis_validate_v65_dynamic_settle_fallback.log}"
SEQUENCE="${GENESIS_V63_TARGET_SEQUENCE:-calculator-cell-r3-c0,calculator-cell-r3-c3,calculator-cell-r3-c1}"
FALLBACK_SEQUENCE="${GENESIS_VALIDATE_V65_FALLBACK_SEQUENCE:-calculator-cell-r3-c0}"
SETTLE_MS="${GENESIS_V63_SETTLE_MS:-500}"
SETTLE_MODE="${GENESIS_V65_SETTLE_MODE:-hybrid}"

echo "========================================================================"
echo "Genesis v6.5 Hybrid Dynamic Settle Dry-Run Validation"
echo "========================================================================"

GENESIS_V63_TARGET_SEQUENCE="$SEQUENCE" \
GENESIS_V63_SETTLE_MS="$SETTLE_MS" \
GENESIS_V65_SETTLE_MODE="$SETTLE_MODE" \
    ./scripts/run_v63_calculator_sequence.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$SEQUENCE" "$SETTLE_MODE" <<'PY'
import json
import sys

log_path, sequence_raw, settle_mode = sys.argv[1:4]
expected_targets = [item.strip() for item in sequence_raw.split(",") if item.strip()]
settles = []
moves = []
clicks = []
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v65_sequence_settle":
            settles.append(payload)
        elif event == "os_driver_move":
            moves.append(payload)
        elif event == "os_driver_click":
            clicks.append(payload)
        elif event == "v63_sequence_summary":
            summary = payload

if len(settles) != len(expected_targets):
    raise SystemExit(f"[v6.5] expected {len(expected_targets)} settle events, got {len(settles)}")
if len(moves) != len(expected_targets) or len(clicks) != len(expected_targets):
    raise SystemExit(f"[v6.5] expected one move/click per target, got moves={len(moves)} clicks={len(clicks)}")

for index, expected_target in enumerate(expected_targets):
    settle = settles[index]
    if settle.get("step_index") != index:
        raise SystemExit(f"[v6.5] settle step index drift: {settle}")
    if settle.get("target_id") != expected_target:
        raise SystemExit(f"[v6.5] settle target drift: {settle}")
    if settle.get("mode") != settle_mode:
        raise SystemExit(f"[v6.5] settle mode drift: {settle}")
    if settle.get("posted") is not False:
        raise SystemExit(f"[v6.5] settle must remain read-only: {settle}")
    if float(settle.get("elapsed_ms", -1)) < 0:
        raise SystemExit(f"[v6.5] settle elapsed invalid: {settle}")
    if settle_mode == "hybrid" and settle.get("fallback_used") is False:
        if settle.get("stable") is not True:
            raise SystemExit(f"[v6.5] non-fallback hybrid settle must be stable: {settle}")
        if settle.get("probe_log") in (None, ""):
            raise SystemExit(f"[v6.5] hybrid settle missing probe log: {settle}")

    for label, event_list, payload_key in [("move", moves, "move"), ("click", clicks, "click")]:
        event = event_list[index]
        payload = event.get(payload_key) or {}
        receipt = payload.get("receipt") or {}
        if receipt.get("posted") is not False:
            raise SystemExit(f"[v6.5] dry-run {label} must not post: {payload}")

if summary is None:
    raise SystemExit("[v6.5] missing sequence summary")
if summary.get("settle_mode") != settle_mode:
    raise SystemExit(f"[v6.5] summary settle mode drift: {summary}")
if summary.get("armed") is not False or summary.get("posted") is not False:
    raise SystemExit(f"[v6.5] dry-run summary must not post: {summary}")

print(json.dumps({
    "event": "v65_dynamic_settle_assertions",
    "sequence": expected_targets,
    "settle_mode": settle_mode,
    "settle_events": len(settles),
    "posted": False,
}, sort_keys=True))
PY

echo "[v6.5] Forcing probe failure to validate hybrid fixed fallback..."
GENESIS_V63_TARGET_SEQUENCE="$FALLBACK_SEQUENCE" \
GENESIS_V63_SETTLE_MS="$SETTLE_MS" \
GENESIS_V65_SETTLE_MODE=hybrid \
GENESIS_V64_WINDOW_OWNER=__genesis_no_such_calculator_window__ \
GENESIS_V63_WORK_DIR="${GENESIS_VALIDATE_V65_FALLBACK_WORK_DIR:-/tmp/genesis_v65_dynamic_settle_fallback}" \
    ./scripts/run_v63_calculator_sequence.sh | tee "$FALLBACK_LOG_PATH"

python3 - "$FALLBACK_LOG_PATH" "$FALLBACK_SEQUENCE" <<'PY'
import json
import sys

log_path, sequence_raw = sys.argv[1:3]
expected_targets = [item.strip() for item in sequence_raw.split(",") if item.strip()]
settles = []
clicks = []
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v65_sequence_settle":
            settles.append(payload)
        elif event == "os_driver_click":
            clicks.append(payload)
        elif event == "v63_sequence_summary":
            summary = payload

if len(settles) != len(expected_targets):
    raise SystemExit(f"[v6.5] fallback expected {len(expected_targets)} settle events, got {len(settles)}")
if len(clicks) != len(expected_targets):
    raise SystemExit(f"[v6.5] fallback expected {len(expected_targets)} clicks, got {len(clicks)}")
for settle in settles:
    if settle.get("mode") != "hybrid":
        raise SystemExit(f"[v6.5] fallback settle mode drift: {settle}")
    if settle.get("fallback_used") is not True:
        raise SystemExit(f"[v6.5] hybrid fallback did not engage: {settle}")
    if settle.get("probe_exit_code") in (0, None):
        raise SystemExit(f"[v6.5] fallback probe exit code invalid: {settle}")
    if settle.get("posted") is not False:
        raise SystemExit(f"[v6.5] fallback settle must remain read-only: {settle}")
for click in clicks:
    receipt = (click.get("click") or {}).get("receipt") or {}
    if receipt.get("posted") is not False:
        raise SystemExit(f"[v6.5] fallback dry-run click must not post: {click}")
if summary is None or summary.get("posted") is not False:
    raise SystemExit(f"[v6.5] fallback summary drift: {summary}")

print(json.dumps({
    "event": "v65_hybrid_fallback_assertions",
    "sequence": expected_targets,
    "fallback_events": len(settles),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.5 hybrid dynamic settle dry-run validation passed"
echo "========================================================================"
