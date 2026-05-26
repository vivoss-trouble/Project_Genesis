#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOCKET="/tmp/genesis_vision_daemon_validate.sock"
LOG="/tmp/genesis_vision_daemon_validate.log"

cleanup() {
    if [[ -n "${DAEMON_PID:-}" ]]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

echo "========================================================================"
echo "Genesis v5 Low-Entropy Vision Daemon Validation"
echo "========================================================================"

cargo check -p genesis-frame-grabber --all-targets
rm -f "$SOCKET" "$LOG"

cargo run -p genesis-frame-grabber -- daemon --socket "$SOCKET" --hz 5 >"$LOG" 2>&1 &
DAEMON_PID=$!

for _ in {1..200}; do
    if [[ -S "$SOCKET" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$SOCKET" ]]; then
    echo "vision daemon failed to create socket"
    cat "$LOG" || true
    exit 1
fi

python3 - "$SOCKET" <<'PY'
import json
import socket
import sys
import time

sock_path = sys.argv[1]

def request(request_id):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(15)
    client.connect(sock_path)
    payload = json.dumps({"request_id": request_id, "act": "frame_state"}) + "\n"
    client.sendall(payload.encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    client.close()
    return json.loads(data.decode())

first = request("state-1")
time.sleep(0.35)
second = request("state-2")

for response in (first, second):
    assert response["status"] == "ok", response
    assert response["request_id"], response
    state = response["frame_state"]
    assert state["frame_id"] >= 1, response
    assert state["captured_at_ms"] > 0, response
    assert state["served_at_ms"] >= state["captured_at_ms"], response
    assert state["backend"] in {"macos-coregraphics", "unsupported"}, response
    assert isinstance(state["capture_supported"], bool), response
    assert isinstance(state["screen_capture_allowed"], bool), response
    assert state["capture_latency_ms"] >= 0, response

    if state["capture_supported"]:
        physical = state["physical_pixels"]
        logical = state["logical_bounds"]
        assert physical and physical["width"] > 0 and physical["height"] > 0, response
        assert logical and logical["width"] > 0 and logical["height"] > 0, response
        assert state["scale_factor"] and state["scale_factor"] > 0, response

assert second["frame_state"]["frame_id"] >= first["frame_state"]["frame_id"], (first, second)
print("[v5-vision-daemon] frame_state protocol passed")
PY

echo "========================================================================"
echo "Genesis v5 low-entropy vision daemon validation passed"
echo "========================================================================"
