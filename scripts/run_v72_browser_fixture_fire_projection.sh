#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V72_MAPPER_BIN:-/tmp/genesis_v72_browser_fixture_readonly_map}"
OS_SOCKET="${GENESIS_V72_OS_SOCKET:-/tmp/genesis_os_driver_v72.sock}"
DRIVER_LOG="${GENESIS_V72_DRIVER_LOG:-/tmp/genesis_os_driver_v72.log}"
MAP_LOG="${GENESIS_V72_MAP_LOG:-/tmp/genesis_v72_browser_fixture_map.log}"
DEBUG_PNG="${GENESIS_V72_DEBUG_PNG:-/tmp/genesis_v72_browser_fixture_debug.png}"
FIXTURE_PATH="$ROOT_DIR/fixtures/v7/browser_fixture.html"
BROWSER_APP="${GENESIS_V72_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V72_TARGET_ID:-browser-button-like-0}"
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
    echo "[v7.2] ERROR: timed out waiting for $socket_path" >&2
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
echo "Genesis v7.2 Browser Fixture Fire Projection Gate"
echo "========================================================================"
echo "[v7.2] Target ID: $TARGET_ID"
echo "[v7.2] Projection-only mode. OS Driver will remain unarmed."

open -a "$BROWSER_APP" "file://$FIXTURE_PATH" || open "file://$FIXTURE_PATH"
sleep "${GENESIS_V72_BROWSER_SETTLE_SEC:-1.5}"

swiftc scripts/browser_fixture_readonly_map.swift -o "$MAPPER_BIN"
GENESIS_V71_DEBUG_PNG="$DEBUG_PNG" "$MAPPER_BIN" | tee "$MAP_LOG"

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
        if payload.get("event") == "browser_fixture_readonly_map":
            event = payload

if event is None:
    raise SystemExit("[v7.2] missing browser_fixture_readonly_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v7.2] mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v7.2] pre-fire map must be read-only: {event}")
if not os.path.exists(debug_png) or os.path.getsize(debug_png) <= 0:
    raise SystemExit(f"[v7.2] debug overlay missing: {debug_png}")

targets = event.get("targets") or []
selected = next((item for item in targets if item.get("target_id") == target_id), None)
if selected is None:
    raise SystemExit(f"[v7.2] target_id not found in Browser fixture map: {target_id}")

point = selected.get("global_coregraphics_point") or {}
bbox = selected.get("bbox") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v7.2] selected target has no global point: {selected}")
if bbox.get("width", 0) <= 0 or bbox.get("height", 0) <= 0:
    raise SystemExit(f"[v7.2] selected target has invalid bbox: {selected}")

print(json.dumps({
    "event": "browser_fixture_fire_projection_target",
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

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v72-browser-fixture","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

MOVE_PAYLOAD="$(python3 - "$TARGET_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "move-v72-browser-fixture",
    "action_id": f"act-v72-{target_id}-move",
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
    "request_id": "click-v72-browser-fixture",
    "action_id": f"act-v72-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
echo "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"

python3 - "$SELECTED_JSON" "$MOVE_JSON" "$CLICK_JSON" <<'PY'
import json
import math
import sys

selected_event = json.loads(sys.argv[1])
move = json.loads(sys.argv[2])
click = json.loads(sys.argv[3])
expected = selected_event["selected"]["global_coregraphics_point"]

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v7.2] os-driver {label} failed: {payload}")
    if payload.get("armed") is not False:
        raise SystemExit(f"[v7.2] os-driver {label} unexpectedly armed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not False:
        raise SystemExit(f"[v7.2] projection {label} must not post: {payload}")
    point = receipt.get("point") or {}
    if math.hypot(point.get("x", 1e9) - expected["x"], point.get("y", 1e9) - expected["y"]) > 0.001:
        raise SystemExit(f"[v7.2] {label} point drifted from selected target: {payload}")

print(json.dumps({
    "event": "v72_browser_fixture_fire_projection_receipts",
    "target_id": selected_event["target_id"],
    "control_kind": selected_event["selected"].get("control_kind"),
    "move_posted": move["receipt"]["posted"],
    "click_posted": click["receipt"]["posted"],
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.2 Browser fixture fire projection gate complete"
echo "========================================================================"
