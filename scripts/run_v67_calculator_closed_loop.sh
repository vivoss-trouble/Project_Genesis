#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${GENESIS_V67_WORK_DIR:-/tmp/genesis_v67_calculator_closed_loop}"
BASELINE_DIR="$WORK_DIR/baselines"
SEQUENCE_WORK_DIR="$WORK_DIR/sequence"
SEQUENCE_LOG="$WORK_DIR/sequence.jsonl"
ASSERT_LOG="$WORK_DIR/assert.jsonl"
SUMMARY_LOG="$WORK_DIR/summary.jsonl"
SEQUENCE_RAW="${GENESIS_V67_TARGET_SEQUENCE:-calculator-cell-r3-c0,calculator-cell-r3-c3,calculator-cell-r3-c1,calculator-cell-r4-c3}"
SETTLE_MODE="${GENESIS_V67_SETTLE_MODE:-hybrid}"
SETTLE_MS="${GENESIS_V67_SETTLE_MS:-500}"
EXPECTED_BASELINE_JSON="${GENESIS_V67_EXPECTED_BASELINE_JSON:-}"
ARMED_TOKEN="GENESIS_V67_ARMED_CALCULATOR_CLOSED_LOOP"
AUTO_FIRE_TOKEN="GENESIS_V67_AUTO_FIRE_CLOSED_LOOP"

echo "========================================================================"
echo "Genesis v6.7 Calculator Closed Loop Gate"
echo "========================================================================"
echo "[v6.7] Sequence: $SEQUENCE_RAW"
echo "[v6.7] Settle mode: $SETTLE_MODE"

python3 - "$SEQUENCE_RAW" "$SETTLE_MODE" "$SETTLE_MS" <<'PY'
import sys

sequence, settle_mode, settle_ms = sys.argv[1:4]
targets = [item.strip() for item in sequence.split(",") if item.strip()]
if not targets:
    raise SystemExit("[v6.7] GENESIS_V67_TARGET_SEQUENCE is empty")
if settle_mode not in {"fixed", "dynamic", "hybrid"}:
    raise SystemExit("[v6.7] GENESIS_V67_SETTLE_MODE must be fixed, dynamic, or hybrid")
try:
    settle = int(settle_ms)
except ValueError as error:
    raise SystemExit(f"[v6.7] GENESIS_V67_SETTLE_MS must be an integer: {error}")
if settle < 0 or settle > 5000:
    raise SystemExit("[v6.7] GENESIS_V67_SETTLE_MS must be within 0..5000")
for target in targets:
    if not target.startswith("calculator-cell-r"):
        raise SystemExit(f"[v6.7] unsupported target id: {target}")
PY

rm -rf "$WORK_DIR"
mkdir -p "$BASELINE_DIR" "$SEQUENCE_WORK_DIR"

ARMED=false
if [[ "${GENESIS_V67_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V67_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v6.7] Armed mode requires GENESIS_V67_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    if [[ -z "$EXPECTED_BASELINE_JSON" ]]; then
        echo "[v6.7] Armed closed loop requires GENESIS_V67_EXPECTED_BASELINE_JSON" >&2
        exit 1
    fi
    if [[ ! -f "$EXPECTED_BASELINE_JSON" ]]; then
        echo "[v6.7] Expected baseline JSON not found: $EXPECTED_BASELINE_JSON" >&2
        exit 1
    fi
    echo "[v6.7] ARMED closed loop requested. This will run the sequence with real Calculator clicks."
else
    echo "[v6.7] Dry-run mode. No physical click will be posted."
fi

if [[ -z "$EXPECTED_BASELINE_JSON" ]]; then
    echo "[v6.7] No expected baseline supplied; capturing current display as dry-run self-baseline."
    GENESIS_V66_BASELINE_DIR="$BASELINE_DIR" \
    GENESIS_V66_BASELINE_NAME=display_self_baseline \
        ./scripts/capture_v66_calculator_display_baseline.sh | tee "$WORK_DIR/baseline_capture.log"
    EXPECTED_BASELINE_JSON="$BASELINE_DIR/display_self_baseline.json"
fi

if [[ "$ARMED" == true ]]; then
    GENESIS_V63_TARGET_SEQUENCE="$SEQUENCE_RAW" \
    GENESIS_V63_SETTLE_MS="$SETTLE_MS" \
    GENESIS_V65_SETTLE_MODE="$SETTLE_MODE" \
    GENESIS_V63_WORK_DIR="$SEQUENCE_WORK_DIR" \
    GENESIS_V63_ARMED_CONFIRM=GENESIS_V63_ARMED_CALCULATOR \
    GENESIS_V63_AUTO_FIRE_CONFIRM=GENESIS_V63_AUTO_FIRE_SEQUENCE \
        ./scripts/run_v63_calculator_sequence.sh | tee "$SEQUENCE_LOG"
else
    GENESIS_V63_TARGET_SEQUENCE="$SEQUENCE_RAW" \
    GENESIS_V63_SETTLE_MS="$SETTLE_MS" \
    GENESIS_V65_SETTLE_MODE="$SETTLE_MODE" \
    GENESIS_V63_WORK_DIR="$SEQUENCE_WORK_DIR" \
        ./scripts/run_v63_calculator_sequence.sh | tee "$SEQUENCE_LOG"
fi

GENESIS_V66_BASELINE_JSON="$EXPECTED_BASELINE_JSON" \
GENESIS_V66_ASSERT_CROP_PNG="$WORK_DIR/final_assert.png" \
GENESIS_V66_ASSERT_DEBUG_PNG="$WORK_DIR/final_assert_debug.png" \
    ./scripts/assert_v66_calculator_display.sh | tee "$ASSERT_LOG"

python3 - "$SEQUENCE_LOG" "$ASSERT_LOG" "$EXPECTED_BASELINE_JSON" "$ARMED" "$SEQUENCE_RAW" "$SETTLE_MODE" "$SUMMARY_LOG" <<'PY'
import json
import sys

sequence_log, assert_log, baseline_json, armed_raw, sequence_raw, settle_mode, summary_log = sys.argv[1:8]
armed = armed_raw == "true"
expected_targets = [item.strip() for item in sequence_raw.split(",") if item.strip()]
sequence_summary = None
settles = []
clicks = []
receipts = []
assert_event = None

with open(sequence_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v63_sequence_summary":
            sequence_summary = payload
        elif event == "v65_sequence_settle":
            settles.append(payload)
        elif event == "os_driver_click":
            clicks.append(payload)
        elif event == "v63_sequence_step_receipts":
            receipts.append(payload)

with open(assert_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "calculator_display_hash":
                assert_event = payload

if sequence_summary is None:
    raise SystemExit("[v6.7] missing v63 sequence summary")
if assert_event is None:
    raise SystemExit("[v6.7] missing v66 assertion event")
if len(clicks) != len(expected_targets):
    raise SystemExit(f"[v6.7] click count drift: expected {len(expected_targets)} got {len(clicks)}")
if len(settles) != len(expected_targets):
    raise SystemExit(f"[v6.7] settle count drift: expected {len(expected_targets)} got {len(settles)}")
if sequence_summary.get("posted") is not armed:
    raise SystemExit(f"[v6.7] sequence posted drift: {sequence_summary}")
if sequence_summary.get("settle_mode") != settle_mode:
    raise SystemExit(f"[v6.7] settle mode drift: {sequence_summary}")

for index, click in enumerate(clicks):
    payload = click.get("click") or {}
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v6.7] click posted drift at step {index}: {click}")
for receipt_summary in receipts:
    if receipt_summary.get("click_posted") is not armed:
        raise SystemExit(f"[v6.7] receipt posted drift: {receipt_summary}")
for settle in settles:
    if settle.get("posted") is not False:
        raise SystemExit(f"[v6.7] settle must remain read-only: {settle}")

assert_match = assert_event.get("match") is True
summary = {
    "event": "v67_closed_loop_summary",
    "sequence_complete": sequence_summary.get("step_count") == len(expected_targets),
    "step_count": sequence_summary.get("step_count"),
    "sequence": expected_targets,
    "armed": armed,
    "posted": armed,
    "settle_mode": settle_mode,
    "baseline_json": baseline_json,
    "assert_match": assert_match,
    "assert_changed_pixel_ratio": assert_event.get("changed_pixel_ratio"),
    "assert_hash_distance": assert_event.get("hash_distance"),
    "assert_crop_png": assert_event.get("crop_png"),
    "assert_debug_overlay": assert_event.get("debug_overlay"),
}
with open(summary_log, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(summary, sort_keys=True) + "\n")
print(json.dumps(summary, sort_keys=True))
if not summary["sequence_complete"]:
    raise SystemExit("[v6.7] sequence did not complete")
if not assert_match:
    raise SystemExit("[v6.7] final visual assertion failed")
PY

echo "========================================================================"
echo "Genesis v6.7 Calculator closed loop gate complete"
echo "Artifacts: $WORK_DIR"
echo "========================================================================"
