#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOCKET_PATH="${GENESIS_V53_OS_SOCKET:-/tmp/genesis_os_driver_v53.sock}"
DUMMY_BIN="${GENESIS_V53_DUMMY_BIN:-/tmp/genesis_native_dummy_window}"
DUMMY_LOG="${GENESIS_V53_DUMMY_LOG:-/tmp/genesis_native_dummy_window.log}"
DRIVER_LOG="${GENESIS_V53_DRIVER_LOG:-/tmp/genesis_os_driver_v53.log}"
ARMED_TOKEN="GENESIS_V53_ARMED_NATIVE_DUMMY"
FIRE_TOKEN="FIRE"
COORDINATE_DOMAIN="${GENESIS_V53_COORDINATE_DOMAIN:-coregraphics}"
POST_CLICK_SETTLE_SEC="${GENESIS_V53_POST_CLICK_SETTLE_SEC:-0.5}"
PRE_CLICK_SETTLE_SEC="${GENESIS_V53_PRE_CLICK_SETTLE_SEC:-0.3}"
DRIVER_PID=""
DUMMY_PID=""

cleanup() {
    if [[ -n "$DRIVER_PID" ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
        kill "$DRIVER_PID" 2>/dev/null || true
        wait "$DRIVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$DUMMY_PID" ]] && kill -0 "$DUMMY_PID" 2>/dev/null; then
        kill "$DUMMY_PID" 2>/dev/null || true
        wait "$DUMMY_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH"
}
trap cleanup EXIT INT TERM

wait_for_socket() {
    for _ in $(seq 1 80); do
        if [[ -S "$SOCKET_PATH" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v5.3] ERROR: timed out waiting for $SOCKET_PATH" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v5.3 Armed Native Dummy Manual Gate"
echo "========================================================================"

swiftc scripts/native_dummy_window.swift -o "$DUMMY_BIN"
TARGET_JSON="$("$DUMMY_BIN" --selftest)"
printf '%s\n' "$TARGET_JSON"

ARMED=false
if [[ "${GENESIS_V53_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    echo "[v5.3] ARMED mode requested. This will open a native window and post one real click."
    : > "$DUMMY_LOG"
    "$DUMMY_BIN" > "$DUMMY_LOG" 2>&1 &
    DUMMY_PID=$!
    for _ in $(seq 1 80); do
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
            TARGET_JSON="$READY_JSON"
            echo "[v5.3] Native dummy ready: $TARGET_JSON"
            break
        fi
        sleep 0.1
    done
    if [[ -z "${READY_JSON:-}" ]]; then
        echo "[v5.3] ERROR: native dummy did not report ready geometry"
        exit 1
    fi
    cargo run -p genesis-os-driver -- daemon --socket "$SOCKET_PATH" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v5.3] Dry-run mode. Set GENESIS_V53_ARMED_CONFIRM=$ARMED_TOKEN to post a real click."
    cargo run -p genesis-os-driver -- daemon --socket "$SOCKET_PATH" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket

if [[ "$ARMED" == true && "${GENESIS_V53_FIRE_CONFIRM:-}" != "$FIRE_TOKEN" ]]; then
    echo "[v5.3] Native dummy is open. Type FIRE and press Enter to post the single click."
    read -r FIRE_INPUT
    if [[ "$FIRE_INPUT" != "$FIRE_TOKEN" ]]; then
        echo "[v5.3] Fire confirmation was not FIRE; refusing armed click."
        exit 1
    fi
fi

python3 - "$SOCKET_PATH" "$TARGET_JSON" "$ARMED" <<'PY'
import json
import os
import socket
import sys
import time

socket_path = sys.argv[1]
target = json.loads(sys.argv[2])
armed = sys.argv[3] == "true"
coordinate_domain = os.environ.get("GENESIS_V53_COORDINATE_DOMAIN", "coregraphics")
if coordinate_domain == "appkit":
    center = target.get("target_appkit_screen_center") or target["target_global_logical_center"]
elif coordinate_domain in ("coregraphics", "quartz"):
    center = target.get("target_coregraphics_screen_center") or target["target_quartz_logical_center"]
else:
    raise SystemExit(f"[v5.3] Unsupported GENESIS_V53_COORDINATE_DOMAIN={coordinate_domain!r}")

def roundtrip(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(8192)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode("utf-8"))

probe = roundtrip({"request_id": "probe-v53", "act": "probe"})
print(json.dumps({
    "event": "os_driver_probe",
    "coordinate_domain": coordinate_domain,
    "target_center": center,
    "probe": probe,
}, sort_keys=True))
if armed and not probe.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit(
        "[v5.3] Accessibility is not trusted; refusing armed click. "
        "Grant Accessibility to the terminal/Codex host, then rerun."
    )

move = roundtrip(
    {
        "request_id": "move-v53-native-dummy",
        "action_id": "act-v53-native-dummy-move",
        "act": "move_mouse",
        "x": center["x"],
        "y": center["y"],
    }
)
print(json.dumps({"event": "os_driver_move", "move": move}, sort_keys=True))
assert move["status"] == "ok", move
assert move["receipt"]["point"] == {"x": center["x"], "y": center["y"]}, move
assert move["receipt"]["posted"] is armed, move
time.sleep(float(os.environ.get("GENESIS_V53_PRE_CLICK_SETTLE_SEC", "0.3")))

click = roundtrip(
    {
        "request_id": "click-v53-native-dummy",
        "action_id": "act-v53-native-dummy",
        "act": "click_point",
        "x": center["x"],
        "y": center["y"],
    }
)
print(json.dumps({"event": "os_driver_click", "click": click}, sort_keys=True))

assert click["status"] == "ok", click
assert click["action_id"] == "act-v53-native-dummy", click
assert click["receipt"]["point"] == {"x": center["x"], "y": center["y"]}, click
assert click["receipt"]["posted"] is armed, click
PY

if [[ "$ARMED" == true ]]; then
    sleep "$POST_CLICK_SETTLE_SEC"
    echo "[v5.3] Armed single-shot completed. Native dummy log:"
    cat "$DUMMY_LOG" || true
else
    echo "[v5.3] Dry-run single-shot completed."
fi

echo "========================================================================"
echo "Genesis v5.3 manual gate complete"
echo "========================================================================"
