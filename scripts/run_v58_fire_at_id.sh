#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VISION_SOCKET="${GENESIS_V58_VISION_SOCKET:-/tmp/genesis_vision_daemon_v58.sock}"
OS_SOCKET="${GENESIS_V58_OS_SOCKET:-/tmp/genesis_os_driver_v58.sock}"
DUMMY_BIN="${GENESIS_V58_DUMMY_BIN:-/tmp/genesis_native_dummy_window_v58}"
DUMMY_LOG="${GENESIS_V58_DUMMY_LOG:-/tmp/genesis_native_dummy_window_v58.log}"
VISION_LOG="${GENESIS_V58_VISION_LOG:-/tmp/genesis_vision_daemon_v58.log}"
DRIVER_LOG="${GENESIS_V58_DRIVER_LOG:-/tmp/genesis_os_driver_v58.log}"
ARMED_TOKEN="GENESIS_V58_ARMED_FIRE_AT_ID"
AUTO_FIRE_TOKEN="GENESIS_V58_AUTO_FIRE_NATIVE_DUMMY"
FIRE_TOKEN="FIRE"
VISION_HZ="${GENESIS_V58_VISION_HZ:-10}"
TARGET_ID="${GENESIS_V58_TARGET_ID:-native-heal-b}"
MARKER_WAIT_SEC="${GENESIS_V58_MARKER_WAIT_SEC:-8}"
POST_CLICK_SETTLE_SEC="${GENESIS_V58_POST_CLICK_SETTLE_SEC:-0.7}"
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
    echo "[v5.8] ERROR: timed out waiting for $socket_path" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v5.8 Fire-at-ID Tactical Gate"
echo "========================================================================"
echo "[v5.8] Target ID: $TARGET_ID"

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
        echo "[v5.8] Native dummy ready: $READY_JSON"
        break
    fi
    sleep 0.1
done
if [[ -z "$READY_JSON" ]]; then
    echo "[v5.8] ERROR: native dummy did not report ready geometry"
    exit 1
fi

VISION_SETUP="$(python3 - "$READY_JSON" "$TARGET_ID" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
target_id = sys.argv[2]
window_id = payload.get("window_number")
if not window_id:
    raise SystemExit("Native Dummy did not expose window_number")
frame = payload["window_frame"]
screen_height = payload["screen_logical_height"]
window_top_y = screen_height - (frame["y"] + frame["height"])
targets = payload.get("targets") or []
target = next((item for item in targets if item.get("id") == target_id), None)
if target is None:
    raise SystemExit(f"target_id not present in Native Dummy target set: {target_id}")
center = target["marker_coregraphics_screen_center"]
sample_x = center["x"] - frame["x"]
sample_y = center["y"] - window_top_y
print(f'{window_id} {frame["width"]} {frame["height"]} {sample_x} {sample_y}')
PY
)"
read -r WINDOW_ID WINDOW_LOGICAL_WIDTH WINDOW_LOGICAL_HEIGHT SAMPLE_X SAMPLE_Y <<< "$VISION_SETUP"
echo "[v5.8] Using window-scoped capture for Native Dummy window_id=$WINDOW_ID"

rm -f "$VISION_SOCKET" "$OS_SOCKET" "$VISION_LOG" "$DRIVER_LOG"
GENESIS_VISION_WINDOW_ID="$WINDOW_ID" \
GENESIS_VISION_WINDOW_LOGICAL_WIDTH="$WINDOW_LOGICAL_WIDTH" \
GENESIS_VISION_WINDOW_LOGICAL_HEIGHT="$WINDOW_LOGICAL_HEIGHT" \
GENESIS_VISION_SAMPLE_X="$SAMPLE_X" \
GENESIS_VISION_SAMPLE_Y="$SAMPLE_Y" \
    cargo run -p genesis-frame-grabber -- daemon --socket "$VISION_SOCKET" --hz "$VISION_HZ" \
    > "$VISION_LOG" 2>&1 &
VISION_PID=$!
wait_for_socket "$VISION_SOCKET"

ARMED=false
if [[ "${GENESIS_V58_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    echo "[v5.8] ARMED mode requested. This will select one target by ID and post one real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v5.8] Dry-run mode. Set GENESIS_V58_ARMED_CONFIRM=$ARMED_TOKEN to post a real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

if [[ "$ARMED" == true && "${GENESIS_V58_AUTO_FIRE_CONFIRM:-}" == "$AUTO_FIRE_TOKEN" ]]; then
    echo "[v5.8] Auto-fire confirmation accepted for controlled Native Dummy."
elif [[ "$ARMED" == true ]]; then
    echo "[v5.8] Native dummy is open. Type FIRE and press Enter to post the selected click."
    read -r FIRE_INPUT
    if [[ "$FIRE_INPUT" != "$FIRE_TOKEN" ]]; then
        echo "[v5.8] Fire confirmation was not FIRE; refusing armed click."
        exit 1
    fi
fi

python3 - "$VISION_SOCKET" "$OS_SOCKET" "$ARMED" "$MARKER_WAIT_SEC" "$READY_JSON" "$TARGET_ID" <<'PY'
import json
import math
import socket
import sys
import time

vision_socket = sys.argv[1]
os_socket = sys.argv[2]
armed = sys.argv[3] == "true"
marker_wait_sec = float(sys.argv[4])
ready = json.loads(sys.argv[5])
target_id = sys.argv[6]


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


def window_top_y():
    frame = ready["window_frame"]
    return ready["screen_logical_height"] - (frame["y"] + frame["height"])


def to_window_local_coregraphics(global_coregraphics_point):
    frame = ready["window_frame"]
    top_y = window_top_y()
    return {
        "x": global_coregraphics_point["x"] - frame["x"],
        "y": global_coregraphics_point["y"] - top_y,
    }


def to_global_coregraphics(local_coregraphics_point):
    frame = ready["window_frame"]
    top_y = window_top_y()
    return {
        "x": frame["x"] + local_coregraphics_point["x"],
        "y": top_y + local_coregraphics_point["y"],
    }


deadline = time.monotonic() + marker_wait_sec
last_state = None
candidates = []
while time.monotonic() < deadline:
    response = roundtrip(
        vision_socket,
        {"request_id": "vision-target-set-v58", "act": "frame_state"},
    )
    if response.get("status") != "ok":
        raise SystemExit(f"[v5.8] vision state failed: {response}")
    last_state = response["frame_state"]
    candidates = last_state.get("marker_candidates") or []
    if candidates:
        break
    time.sleep(0.2)

if not candidates:
    raise SystemExit("[v5.8] marker_candidates is empty; refusing selection")

targets = ready.get("targets") or []
target_set = []
used_candidate_ids = set()
for target in targets:
    expected = to_window_local_coregraphics(target["marker_coregraphics_screen_center"])
    best = None
    for candidate in candidates:
        if candidate["candidate_id"] in used_candidate_ids:
            continue
        actual = candidate["coregraphics_logical_center"]
        distance = math.hypot(actual["x"] - expected["x"], actual["y"] - expected["y"])
        if best is None or distance < best[0]:
            best = (distance, candidate)
    if best is None:
        continue
    distance, candidate = best
    used_candidate_ids.add(candidate["candidate_id"])
    local_point = candidate["coregraphics_logical_center"]
    target_set.append({
        "target_id": target["id"],
        "candidate_id": candidate["candidate_id"],
        "candidate_distance_px": distance,
        "bbox": candidate["bbox"],
        "pixel_count": candidate["pixel_count"],
        "window_coregraphics_point": local_point,
        "global_coregraphics_point": to_global_coregraphics(local_point),
    })

print(json.dumps({
    "event": "vision_target_set",
    "capture_scope": last_state.get("capture_scope"),
    "window_id": last_state.get("window_id"),
    "target_set": target_set,
    "unmapped_candidate_count": max(0, len(candidates) - len(target_set)),
}, sort_keys=True))

selected = next((item for item in target_set if item["target_id"] == target_id), None)
if selected is None:
    raise SystemExit(f"[v5.8] target_id not found in mapped target set: {target_id}")
if selected["candidate_distance_px"] > 8.0:
    raise SystemExit(
        f"[v5.8] target candidate mapping drift too large: {selected['candidate_distance_px']}"
    )

print(json.dumps({
    "event": "selection_policy",
    "policy": "explicit_target_id",
    "requested_target_id": target_id,
    "selected": selected,
}, sort_keys=True))

point = selected["global_coregraphics_point"]
print(json.dumps({
    "event": "vision_action_point",
    "target_id": target_id,
    "candidate_id": selected["candidate_id"],
    "coregraphics_logical_point": point,
}, sort_keys=True))

probe = roundtrip(os_socket, {"request_id": "probe-v58", "act": "probe"})
print(json.dumps({"event": "os_driver_probe", "probe": probe}, sort_keys=True))
if armed and not probe.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v5.8] Accessibility is not trusted; refusing armed click.")

move = roundtrip(
    os_socket,
    {
        "request_id": "move-v58-fire-at-id",
        "action_id": f"act-v58-{target_id}-move",
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
        "request_id": "click-v58-fire-at-id",
        "action_id": f"act-v58-{target_id}",
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
    echo "[v5.8] Armed Fire-at-ID completed. Native dummy log:"
    cat "$DUMMY_LOG" || true
else
    echo "[v5.8] Dry-run Fire-at-ID completed."
fi

echo "========================================================================"
echo "Genesis v5.8 Fire-at-ID tactical gate complete"
echo "========================================================================"
