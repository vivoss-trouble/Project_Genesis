#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V63_MAPPER_BIN:-/tmp/genesis_calculator_readonly_map_v63}"
PROBE_BIN="${GENESIS_V65_PROBE_BIN:-/tmp/genesis_v65_calculator_frame_stability_probe}"
OS_SOCKET="${GENESIS_V63_OS_SOCKET:-/tmp/genesis_os_driver_v63.sock}"
DRIVER_LOG="${GENESIS_V63_DRIVER_LOG:-/tmp/genesis_os_driver_v63.log}"
WORK_DIR="${GENESIS_V63_WORK_DIR:-/tmp/genesis_v63_calculator_sequence}"
SEQUENCE_RAW="${GENESIS_V63_TARGET_SEQUENCE:-calculator-cell-r3-c0,calculator-cell-r3-c3,calculator-cell-r3-c1}"
SETTLE_MS="${GENESIS_V63_SETTLE_MS:-500}"
SETTLE_MODE="${GENESIS_V65_SETTLE_MODE:-hybrid}"
ARMED_TOKEN="GENESIS_V63_ARMED_CALCULATOR"
AUTO_FIRE_TOKEN="GENESIS_V63_AUTO_FIRE_SEQUENCE"
DRIVER_PID=""

cleanup() {
    if [[ -n "$DRIVER_PID" ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
        kill "$DRIVER_PID" 2>/dev/null || true
        wait "$DRIVER_PID" 2>/dev/null || true
    fi
    rm -f "$OS_SOCKET"
}
trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v6.3] ERROR: timed out waiting for $socket_path" >&2
    exit 1
}

roundtrip_os_driver() {
    local payload="$1"
    python3 - "$OS_SOCKET" "$payload" <<'PY'
import json
import socket
import sys

socket_path, payload_raw = sys.argv[1:3]
payload = json.loads(payload_raw)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(15)
    client.connect(socket_path)
    client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
print(data.decode("utf-8").strip())
PY
}

now_ms() {
    python3 - <<'PY'
import time
print(f"{time.time() * 1000.0:.3f}")
PY
}

sleep_ms() {
    local millis="$1"
    python3 - "$millis" <<'PY'
import sys
import time

time.sleep(int(sys.argv[1]) / 1000.0)
PY
}

settle_step() {
    local step_index="$1"
    local target_id="$2"
    local started_ms
    started_ms="$(now_ms)"

    if [[ "$SETTLE_MODE" == "fixed" ]]; then
        sleep_ms "$SETTLE_MS"
        python3 - "$started_ms" "$(now_ms)" "$step_index" "$target_id" "$SETTLE_MODE" "$SETTLE_MS" <<'PY'
import json
import sys

started_ms, ended_ms, step_index, target_id, mode, settle_ms = sys.argv[1:7]
print(json.dumps({
    "event": "v65_sequence_settle",
    "step_index": int(step_index),
    "target_id": target_id,
    "mode": mode,
    "stable": True,
    "elapsed_ms": round(float(ended_ms) - float(started_ms), 3),
    "fallback_used": False,
    "fixed_settle_ms": int(settle_ms),
    "probe_log": None,
    "posted": False,
}, sort_keys=True))
PY
        return 0
    fi

    local probe_log="$WORK_DIR/settle_step_${step_index}_${target_id}.jsonl"
    set +e
    "$PROBE_BIN" > "$probe_log" 2>&1
    local probe_status=$?
    set -e

    if [[ "$probe_status" -eq 0 ]]; then
        python3 - "$started_ms" "$(now_ms)" "$probe_log" "$probe_status" "$step_index" "$target_id" "$SETTLE_MODE" "$SETTLE_MS" <<'PY'
import json
import sys

started_ms, ended_ms, probe_log, probe_status, step_index, target_id, mode, settle_ms = sys.argv[1:9]
summary = None
with open(probe_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "frame_stability_summary":
            summary = payload
if summary is None:
    raise SystemExit(f"[v6.5] missing frame_stability_summary in {probe_log}")
print(json.dumps({
    "event": "v65_sequence_settle",
    "step_index": int(step_index),
    "target_id": target_id,
    "mode": mode,
    "stable": bool(summary.get("stable")),
    "elapsed_ms": round(float(ended_ms) - float(started_ms), 3),
    "probe_elapsed_ms": summary.get("elapsed_ms"),
    "probe_sample_count": summary.get("sample_count"),
    "probe_stable_run": summary.get("stable_run"),
    "last_changed_pixel_ratio": summary.get("last_changed_pixel_ratio"),
    "probe_exit_code": int(probe_status),
    "fallback_used": False,
    "fixed_settle_ms": int(settle_ms),
    "probe_log": probe_log,
    "posted": False,
}, sort_keys=True))
PY
        return 0
    fi

    if [[ "$SETTLE_MODE" == "dynamic" ]]; then
        python3 - "$started_ms" "$(now_ms)" "$probe_log" "$probe_status" "$step_index" "$target_id" "$SETTLE_MODE" "$SETTLE_MS" <<'PY'
import json
import sys

started_ms, ended_ms, probe_log, probe_status, step_index, target_id, mode, settle_ms = sys.argv[1:9]
print(json.dumps({
    "event": "v65_sequence_settle",
    "step_index": int(step_index),
    "target_id": target_id,
    "mode": mode,
    "stable": False,
    "elapsed_ms": round(float(ended_ms) - float(started_ms), 3),
    "probe_exit_code": int(probe_status),
    "fallback_used": False,
    "fixed_settle_ms": int(settle_ms),
    "probe_log": probe_log,
    "posted": False,
}, sort_keys=True))
PY
        echo "[v6.5] dynamic settle failed for step $step_index ($target_id); see $probe_log" >&2
        exit 1
    fi

    sleep_ms "$SETTLE_MS"
    python3 - "$started_ms" "$(now_ms)" "$probe_log" "$probe_status" "$step_index" "$target_id" "$SETTLE_MODE" "$SETTLE_MS" <<'PY'
import json
import sys

started_ms, ended_ms, probe_log, probe_status, step_index, target_id, mode, settle_ms = sys.argv[1:9]
summary = None
with open(probe_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "frame_stability_summary":
            summary = payload
print(json.dumps({
    "event": "v65_sequence_settle",
    "step_index": int(step_index),
    "target_id": target_id,
    "mode": mode,
    "stable": bool(summary.get("stable")) if summary else False,
    "elapsed_ms": round(float(ended_ms) - float(started_ms), 3),
    "probe_elapsed_ms": summary.get("elapsed_ms") if summary else None,
    "probe_sample_count": summary.get("sample_count") if summary else None,
    "probe_stable_run": summary.get("stable_run") if summary else None,
    "last_changed_pixel_ratio": summary.get("last_changed_pixel_ratio") if summary else None,
    "probe_exit_code": int(probe_status),
    "fallback_used": True,
    "fixed_settle_ms": int(settle_ms),
    "probe_log": probe_log,
    "posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v6.3/v6.5 Calculator Sequence Fire-Control Gate"
echo "========================================================================"
echo "[v6.3] Sequence: $SEQUENCE_RAW"
echo "[v6.3] Fixed settle: ${SETTLE_MS}ms"
echo "[v6.5] Settle mode: $SETTLE_MODE"

python3 - "$SEQUENCE_RAW" "$SETTLE_MS" "$SETTLE_MODE" <<'PY'
import sys

sequence, settle_ms, settle_mode = sys.argv[1:4]
targets = [item.strip() for item in sequence.split(",") if item.strip()]
if not targets:
    raise SystemExit("[v6.3] GENESIS_V63_TARGET_SEQUENCE is empty")
try:
    settle = int(settle_ms)
except ValueError as error:
    raise SystemExit(f"[v6.3] GENESIS_V63_SETTLE_MS must be an integer: {error}")
if settle < 0 or settle > 5000:
    raise SystemExit("[v6.3] GENESIS_V63_SETTLE_MS must be within 0..5000")
if settle_mode not in {"fixed", "dynamic", "hybrid"}:
    raise SystemExit("[v6.5] GENESIS_V65_SETTLE_MODE must be fixed, dynamic, or hybrid")
for target in targets:
    if not target.startswith("calculator-cell-r"):
        raise SystemExit(f"[v6.3] unsupported target id: {target}")
PY

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
rm -f "$OS_SOCKET" "$DRIVER_LOG"

open -a Calculator || true
sleep "${GENESIS_V63_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/calculator_readonly_map.swift -o "$MAPPER_BIN"
if [[ "$SETTLE_MODE" != "fixed" ]]; then
    swiftc scripts/probe_v64_calculator_frame_stability.swift -o "$PROBE_BIN"
fi

ARMED=false
if [[ "${GENESIS_V63_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V63_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v6.3] Armed mode requires GENESIS_V63_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v6.3] ARMED sequence requested. This will post one click per sequence item."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v6.3] Dry-run mode. Set GENESIS_V63_ARMED_CONFIRM=$ARMED_TOKEN and GENESIS_V63_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN to post real clicks."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v63-calculator","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v6.3] Accessibility is not trusted; refusing armed Calculator sequence")
PY
fi

IFS=',' read -r -a TARGETS <<< "$SEQUENCE_RAW"
STEP_COUNT=0
for raw_target in "${TARGETS[@]}"; do
    TARGET_ID="$(python3 - "$raw_target" <<'PY'
import sys
print(sys.argv[1].strip())
PY
)"
    [[ -n "$TARGET_ID" ]] || continue
    DEBUG_PNG="$WORK_DIR/step_${STEP_COUNT}_${TARGET_ID}.png"
    MAP_LOG="$WORK_DIR/step_${STEP_COUNT}_${TARGET_ID}.jsonl"

    GENESIS_V61_DEBUG_PNG="$DEBUG_PNG" "$MAPPER_BIN" | tee "$MAP_LOG"

    SELECTED_JSON="$(python3 - "$MAP_LOG" "$TARGET_ID" "$DEBUG_PNG" "$STEP_COUNT" "$SETTLE_MS" <<'PY'
import json
import os
import sys

log_path, target_id, debug_png, step_index_raw, settle_ms_raw = sys.argv[1:6]
step_index = int(step_index_raw)
settle_ms = int(settle_ms_raw)
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "calculator_readonly_map":
            event = payload

if event is None:
    raise SystemExit(f"[v6.3] step {step_index}: missing calculator_readonly_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v6.3] step {step_index}: mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v6.3] step {step_index}: pre-fire map must be read-only: {event}")
if not os.path.exists(debug_png) or os.path.getsize(debug_png) <= 0:
    raise SystemExit(f"[v6.3] step {step_index}: debug overlay missing: {debug_png}")

targets = event.get("targets") or []
selected = next((item for item in targets if item.get("target_id") == target_id), None)
if selected is None:
    raise SystemExit(f"[v6.3] step {step_index}: target_id not found: {target_id}")
point = selected.get("global_coregraphics_point") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v6.3] step {step_index}: target missing global point: {selected}")

print(json.dumps({
    "event": "calculator_sequence_step_target",
    "step_index": step_index,
    "target_id": target_id,
    "selected": selected,
    "debug_overlay": debug_png,
    "map_target_count": len(targets),
    "map_latency_ms": event.get("capture_latency_ms"),
    "settle_ms": settle_ms,
    "posted": False,
}, sort_keys=True))
PY
)"
    echo "$SELECTED_JSON"

    POINT_X="$(python3 - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["selected"]["global_coregraphics_point"]["x"])
PY
)"
    POINT_Y="$(python3 - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["selected"]["global_coregraphics_point"]["y"])
PY
)"

    MOVE_PAYLOAD="$(python3 - "$TARGET_ID" "$STEP_COUNT" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, step_index, x, y = sys.argv[1:5]
print(json.dumps({
    "request_id": f"move-v63-calculator-step-{step_index}",
    "action_id": f"act-v63-step-{step_index}-{target_id}-move",
    "act": "move_mouse",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    MOVE_JSON="$(roundtrip_os_driver "$MOVE_PAYLOAD")"
    echo "{\"event\":\"os_driver_move\",\"step_index\":$STEP_COUNT,\"move\":$MOVE_JSON}"

    CLICK_PAYLOAD="$(python3 - "$TARGET_ID" "$STEP_COUNT" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, step_index, x, y = sys.argv[1:5]
print(json.dumps({
    "request_id": f"click-v63-calculator-step-{step_index}",
    "action_id": f"act-v63-step-{step_index}-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
    echo "{\"event\":\"os_driver_click\",\"step_index\":$STEP_COUNT,\"click\":$CLICK_JSON}"

    python3 - "$MOVE_JSON" "$CLICK_JSON" "$ARMED" "$STEP_COUNT" "$TARGET_ID" <<'PY'
import json
import sys

move_raw, click_raw, armed_raw, step_index, target_id = sys.argv[1:6]
move = json.loads(move_raw)
click = json.loads(click_raw)
armed = armed_raw == "true"
for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v6.3] step {step_index} os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v6.3] step {step_index} {label} posted mismatch: {payload}")
    if target_id not in (payload.get("action_id") or ""):
        raise SystemExit(f"[v6.3] step {step_index} {label} action_id missing target: {payload}")
print(json.dumps({
    "event": "v63_sequence_step_receipts",
    "step_index": int(step_index),
    "target_id": target_id,
    "armed": armed,
    "move_posted": move["receipt"]["posted"],
    "click_posted": click["receipt"]["posted"],
}, sort_keys=True))
PY

    settle_step "$STEP_COUNT" "$TARGET_ID"
    STEP_COUNT=$((STEP_COUNT + 1))
done

echo "{\"event\":\"v63_sequence_summary\",\"armed\":$ARMED,\"step_count\":$STEP_COUNT,\"settle_ms\":$SETTLE_MS,\"settle_mode\":\"$SETTLE_MODE\",\"posted\":$ARMED}"
echo "========================================================================"
echo "Genesis v6.3 Calculator sequence gate complete"
echo "========================================================================"
