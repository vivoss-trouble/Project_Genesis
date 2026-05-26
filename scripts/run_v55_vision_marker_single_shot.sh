#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VISION_SOCKET="${GENESIS_V55_VISION_SOCKET:-/tmp/genesis_vision_daemon_v55.sock}"
OS_SOCKET="${GENESIS_V55_OS_SOCKET:-/tmp/genesis_os_driver_v55.sock}"
DUMMY_BIN="${GENESIS_V55_DUMMY_BIN:-/tmp/genesis_native_dummy_window_v55}"
DUMMY_LOG="${GENESIS_V55_DUMMY_LOG:-/tmp/genesis_native_dummy_window_v55.log}"
VISION_LOG="${GENESIS_V55_VISION_LOG:-/tmp/genesis_vision_daemon_v55.log}"
DRIVER_LOG="${GENESIS_V55_DRIVER_LOG:-/tmp/genesis_os_driver_v55.log}"
ARMED_TOKEN="GENESIS_V55_ARMED_VISION_MARKER"
FIRE_TOKEN="FIRE"
VISIBLE_TOKEN="VISIBLE"
VISION_HZ="${GENESIS_V55_VISION_HZ:-10}"
MARKER_WAIT_SEC="${GENESIS_V55_MARKER_WAIT_SEC:-8}"
POST_CLICK_SETTLE_SEC="${GENESIS_V55_POST_CLICK_SETTLE_SEC:-0.7}"
DUMMY_PID=""
VISION_PID=""
DRIVER_PID=""

cleanup() {
    for pid in "$DRIVER_PID" "$VISION_PID" "$DUMMY_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -f "$VISION_SOCKET" "$OS_SOCKET"
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
    echo "[v5.5] ERROR: timed out waiting for $socket_path" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v5.5 Vision Marker Single-Shot Gate"
echo "========================================================================"

swiftc scripts/native_dummy_window.swift -o "$DUMMY_BIN"
"$DUMMY_BIN" --selftest

: > "$DUMMY_LOG"
"$DUMMY_BIN" > "$DUMMY_LOG" 2>&1 &
DUMMY_PID=$!

READY_JSON=""
for _ in $(seq 1 100); do
    READY_JSON="$(python3 - "$DUMMY_LOG" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            if payload.get("event") == "ready":
                print(json.dumps(payload, sort_keys=True))
                raise SystemExit(0)
except FileNotFoundError:
    pass
PY
)"
    if [[ -n "$READY_JSON" ]]; then
        echo "[v5.5] Native dummy ready: $READY_JSON"
        break
    fi
    sleep 0.1
done
if [[ -z "$READY_JSON" ]]; then
    echo "[v5.5] ERROR: native dummy did not report ready geometry"
    exit 1
fi

if [[ "${GENESIS_V55_VISIBLE_CONFIRM:-}" != "$VISIBLE_TOKEN" ]]; then
    echo "[v5.5] Move/uncover the Native Dummy so the magenta marker is visible."
    echo "[v5.5] Type VISIBLE and press Enter to start vision capture."
    read -r VISIBLE_INPUT
    if [[ "$VISIBLE_INPUT" != "$VISIBLE_TOKEN" ]]; then
        echo "[v5.5] Visibility confirmation was not VISIBLE; refusing vision capture."
        exit 1
    fi
fi

SAMPLE_XY="$(python3 - "$READY_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
center = payload["marker_coregraphics_screen_center"]
print(f'{center["x"]} {center["y"]}')
PY
)"
read -r SAMPLE_X SAMPLE_Y <<< "$SAMPLE_XY"

rm -f "$VISION_SOCKET" "$OS_SOCKET" "$VISION_LOG" "$DRIVER_LOG"
GENESIS_VISION_SAMPLE_X="$SAMPLE_X" GENESIS_VISION_SAMPLE_Y="$SAMPLE_Y" \
    cargo run -p genesis-frame-grabber -- daemon --socket "$VISION_SOCKET" --hz "$VISION_HZ" \
    > "$VISION_LOG" 2>&1 &
VISION_PID=$!
wait_for_socket "$VISION_SOCKET"

ARMED=false
if [[ "${GENESIS_V55_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    echo "[v5.5] ARMED mode requested. This will use live screen pixels and post one real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v5.5] Dry-run mode. Set GENESIS_V55_ARMED_CONFIRM=$ARMED_TOKEN to post a real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

if [[ "$ARMED" == true && "${GENESIS_V55_FIRE_CONFIRM:-}" != "$FIRE_TOKEN" ]]; then
    echo "[v5.5] Native dummy is open. Type FIRE and press Enter to post the vision-guided click."
    read -r FIRE_INPUT
    if [[ "$FIRE_INPUT" != "$FIRE_TOKEN" ]]; then
        echo "[v5.5] Fire confirmation was not FIRE; refusing armed click."
        exit 1
    fi
fi

python3 - "$VISION_SOCKET" "$OS_SOCKET" "$ARMED" "$MARKER_WAIT_SEC" <<'PY'
import json
import socket
import sys
import time

vision_socket = sys.argv[1]
os_socket = sys.argv[2]
armed = sys.argv[3] == "true"
marker_wait_sec = float(sys.argv[4])


def roundtrip(socket_path, payload):
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
    return json.loads(data.decode("utf-8"))


deadline = time.monotonic() + marker_wait_sec
last_state = None
marker = None
while time.monotonic() < deadline:
    response = roundtrip(
        vision_socket,
        {"request_id": "vision-marker-v55", "act": "frame_state"},
    )
    if response.get("status") != "ok":
        raise SystemExit(f"[v5.5] vision state failed: {response}")
    last_state = response["frame_state"]
    marker = last_state.get("marker_detection")
    if marker:
        break
    time.sleep(0.2)

print(json.dumps({
    "event": "vision_marker_state",
    "marker_detection": marker,
    "marker_sample": last_state.get("marker_sample") if last_state else None,
    "bits_per_pixel": last_state.get("bits_per_pixel") if last_state else None,
    "bytes_per_row": last_state.get("bytes_per_row") if last_state else None,
    "screen_capture_allowed": last_state.get("screen_capture_allowed") if last_state else None,
    "capture_latency_ms": last_state.get("capture_latency_ms") if last_state else None,
}, sort_keys=True))

if not marker:
    raise SystemExit(
        "[v5.5] marker_detection is null. Grant Screen Recording permission, "
        "keep Native Dummy visible and unobscured, then rerun. Inspect "
        "marker_sample.raw_bytes to see what the framebuffer contains at the "
        "expected target point."
    )

point = marker["coregraphics_logical_center"]
probe = roundtrip(os_socket, {"request_id": "probe-v55", "act": "probe"})
print(json.dumps({"event": "os_driver_probe", "probe": probe}, sort_keys=True))
if armed and not probe.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v5.5] Accessibility is not trusted; refusing armed click.")

move = roundtrip(
    os_socket,
    {
        "request_id": "move-v55-marker",
        "action_id": "act-v55-marker-move",
        "act": "move_mouse",
        "x": point["x"],
        "y": point["y"],
    },
)
print(json.dumps({"event": "os_driver_move", "move": move}, sort_keys=True))
assert move["status"] == "ok", move
assert move["receipt"]["posted"] is armed, move

time.sleep(0.25)

click = roundtrip(
    os_socket,
    {
        "request_id": "click-v55-marker",
        "action_id": "act-v55-marker",
        "act": "click_point",
        "x": point["x"],
        "y": point["y"],
    },
)
print(json.dumps({"event": "os_driver_click", "click": click}, sort_keys=True))
assert click["status"] == "ok", click
assert click["receipt"]["posted"] is armed, click
PY

if [[ "$ARMED" == true ]]; then
    sleep "$POST_CLICK_SETTLE_SEC"
    echo "[v5.5] Armed vision-guided single-shot completed. Native dummy log:"
    cat "$DUMMY_LOG" || true
else
    echo "[v5.5] Dry-run vision-guided single-shot completed."
fi

echo "========================================================================"
echo "Genesis v5.5 vision marker single-shot gate complete"
echo "========================================================================"
