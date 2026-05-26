#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V62_MAPPER_BIN:-/tmp/genesis_calculator_readonly_map_v62}"
OS_SOCKET="${GENESIS_V62_OS_SOCKET:-/tmp/genesis_os_driver_v62.sock}"
DRIVER_LOG="${GENESIS_V62_DRIVER_LOG:-/tmp/genesis_os_driver_v62.log}"
MAP_LOG="${GENESIS_V62_MAP_LOG:-/tmp/genesis_v62_calculator_map.log}"
DEBUG_PNG="${GENESIS_V62_DEBUG_PNG:-/tmp/genesis_v62_debug.png}"
TARGET_ID="${GENESIS_V62_TARGET_ID:-calculator-cell-r4-c2}"
ARMED_TOKEN="GENESIS_V62_ARMED_CALCULATOR"
AUTO_FIRE_TOKEN="GENESIS_V62_AUTO_FIRE_SINGLE_SHOT"
POST_CLICK_SETTLE_SEC="${GENESIS_V62_POST_CLICK_SETTLE_SEC:-0.5}"
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
    echo "[v6.2] ERROR: timed out waiting for $socket_path" >&2
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

echo "========================================================================"
echo "Genesis v6.2 Calculator Single-Shot Gate"
echo "========================================================================"
echo "[v6.2] Target ID: $TARGET_ID"

open -a Calculator || true
sleep "${GENESIS_V62_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/calculator_readonly_map.swift -o "$MAPPER_BIN"
GENESIS_V61_DEBUG_PNG="$DEBUG_PNG" "$MAPPER_BIN" | tee "$MAP_LOG"

SELECTED_JSON="$(python3 - "$MAP_LOG" "$TARGET_ID" "$DEBUG_PNG" <<'PY'
import json
import os
import sys

log_path, target_id, debug_png = sys.argv[1:4]
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
    raise SystemExit("[v6.2] missing calculator_readonly_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v6.2] mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v6.2] pre-fire map must be read-only: {event}")
if not os.path.exists(debug_png) or os.path.getsize(debug_png) <= 0:
    raise SystemExit(f"[v6.2] debug overlay missing: {debug_png}")

targets = event.get("targets") or []
selected = next((item for item in targets if item.get("target_id") == target_id), None)
if selected is None:
    raise SystemExit(f"[v6.2] target_id not found in Calculator map: {target_id}")

bbox = selected.get("bbox") or {}
point = selected.get("global_coregraphics_point") or {}
if bbox.get("width", 0) <= 0 or bbox.get("height", 0) <= 0:
    raise SystemExit(f"[v6.2] selected target has invalid bbox: {selected}")
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v6.2] selected target has no global point: {selected}")

print(json.dumps({
    "event": "calculator_single_shot_target",
    "target_id": target_id,
    "selected": selected,
    "debug_overlay": debug_png,
    "map_target_count": len(targets),
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

ARMED=false
if [[ "${GENESIS_V62_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V62_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v6.2] Armed mode requires GENESIS_V62_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v6.2] ARMED single-shot requested for Calculator. One click will be posted."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v6.2] Dry-run mode. Set GENESIS_V62_ARMED_CONFIRM=$ARMED_TOKEN and GENESIS_V62_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN to post one real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v62-calculator","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v6.2] Accessibility is not trusted; refusing armed Calculator click")
PY
fi

MOVE_PAYLOAD="$(python3 - "$TARGET_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "move-v62-calculator",
    "action_id": f"act-v62-{target_id}-move",
    "act": "move_mouse",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
MOVE_JSON="$(roundtrip_os_driver "$MOVE_PAYLOAD")"
echo "{\"event\":\"os_driver_move\",\"move\":$MOVE_JSON}"

CLICK_PAYLOAD="$(python3 - "$TARGET_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "click-v62-calculator",
    "action_id": f"act-v62-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
echo "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"

python3 - "$MOVE_JSON" "$CLICK_JSON" "$ARMED" <<'PY'
import json
import sys

move = json.loads(sys.argv[1])
click = json.loads(sys.argv[2])
armed = sys.argv[3] == "true"
for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v6.2] os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v6.2] {label} posted state mismatch: {payload}")
print(json.dumps({
    "event": "v62_single_shot_receipts",
    "armed": armed,
    "move_posted": move["receipt"]["posted"],
    "click_posted": click["receipt"]["posted"],
}, sort_keys=True))
PY

if [[ "$ARMED" == true ]]; then
    sleep "$POST_CLICK_SETTLE_SEC"
fi

echo "========================================================================"
echo "Genesis v6.2 Calculator single-shot gate complete"
echo "========================================================================"
