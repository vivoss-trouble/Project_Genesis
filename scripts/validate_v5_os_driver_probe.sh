#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================================================"
echo "Genesis v5 OS Driver Probe Validation"
echo "========================================================================"

SOCKET_PATH="/tmp/genesis_os_driver_validate.sock"
DRIVER_PID=""

cleanup() {
    if [[ -n "$DRIVER_PID" ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
        kill "$DRIVER_PID" 2>/dev/null || true
        wait "$DRIVER_PID" 2>/dev/null || true
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
    echo "[v5-os-driver] ERROR: timed out waiting for $SOCKET_PATH" >&2
    exit 1
}

cargo check -p genesis-os-driver --all-targets
cargo run -p genesis-os-driver -- probe
cargo run -p genesis-os-driver -- selftest

GENESIS_OS_VIEWPORT_X=10 \
GENESIS_OS_VIEWPORT_Y=20 \
    cargo run -p genesis-os-driver -- daemon --socket "$SOCKET_PATH" \
    > /tmp/genesis_os_driver_validate.log 2>&1 &
DRIVER_PID=$!
wait_for_socket

python3 - "$SOCKET_PATH" <<'PY'
import json
import socket
import sys

path = sys.argv[1]

def roundtrip(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(path)
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode("utf-8"))

probe = roundtrip({"request_id": "probe-1", "act": "probe"})
assert probe["status"] == "ok", probe
assert probe["request_id"] == "probe-1", probe
assert probe["probe"]["backend"] in {"macos-coregraphics", "unsupported"}, probe

click = roundtrip(
    {
        "request_id": "click-1",
        "action_id": "act-v5-1",
        "act": "click_point",
        "x": 100,
        "y": 100,
    }
)
assert click["status"] == "ok", click
assert click["action_id"] == "act-v5-1", click
assert click["receipt"]["armed"] is False, click
assert click["receipt"]["posted"] is False, click
assert click["viewport_offset"] == {"x": 10.0, "y": 20.0}, click
assert click["receipt"]["point"] == {"x": 110.0, "y": 120.0}, click
print("[v5-os-driver] daemon dry-run protocol passed")
PY

echo "========================================================================"
echo "Genesis v5 OS driver probe validation passed"
echo "========================================================================"
