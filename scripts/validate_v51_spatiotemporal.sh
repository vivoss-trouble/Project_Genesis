#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOCKET_PATH="/tmp/genesis_os_driver_v51_validate.sock"
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
    echo "[v5.1] ERROR: timed out waiting for $SOCKET_PATH" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v5.1 Spatiotemporal Alignment Matrix Validation"
echo "========================================================================"

python3 scripts/vision_action_transform.py --selftest
cargo check -p genesis-os-driver --all-targets

GENESIS_OS_VIEWPORT_X=10 \
GENESIS_OS_VIEWPORT_Y=20 \
    cargo run -p genesis-os-driver -- daemon --socket "$SOCKET_PATH" \
    > /tmp/genesis_os_driver_v51_validate.log 2>&1 &
DRIVER_PID=$!
wait_for_socket

python3 - "$SOCKET_PATH" <<'PY'
import importlib.util
import json
import socket
import sys
from pathlib import Path

socket_path = sys.argv[1]
module_path = Path("scripts/vision_action_transform.py")
spec = importlib.util.spec_from_file_location("vision_action_transform", module_path)
vat = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["vision_action_transform"] = vat
spec.loader.exec_module(vat)

def roundtrip(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode("utf-8"))

action = vat.build_click_point_action(
    action_id="act-v51-matrix",
    target_id="heal",
    frame_id=42,
    physical_x=1000.0,
    physical_y=500.0,
    scale_factor=2.0,
    viewport=vat.ViewportOffset(x=10.0, y=20.0),
    captured_at_ms=1_000,
    served_at_ms=1_085,
    max_vision_lag_ms=150.0,
)
assert action["x"] == 490.0, action
assert action["y"] == 230.0, action

driver_response = roundtrip(
    {
        "request_id": "click-v51",
        "action_id": action["action_id"],
        "act": "click_point",
        "x": action["x"],
        "y": action["y"],
    }
)
assert driver_response["status"] == "ok", driver_response
assert driver_response["action_id"] == "act-v51-matrix", driver_response
assert driver_response["viewport_offset"] == {"x": 10.0, "y": 20.0}, driver_response
assert driver_response["receipt"]["armed"] is False, driver_response
assert driver_response["receipt"]["posted"] is False, driver_response
assert driver_response["receipt"]["point"] == {"x": 500.0, "y": 250.0}, driver_response

try:
    vat.build_click_point_action(
        action_id="act-v51-stale",
        target_id="heal",
        frame_id=43,
        physical_x=1000.0,
        physical_y=500.0,
        scale_factor=2.0,
        viewport=vat.ViewportOffset(x=10.0, y=20.0),
        captured_at_ms=1_000,
        served_at_ms=1_151,
        max_vision_lag_ms=150.0,
    )
except vat.AlignmentError as error:
    assert error.failure_kind == "StaleVision", error.failure_kind
    assert error.evidence["vision_lag_ms"] == 151, error.evidence
else:
    raise AssertionError("expected StaleVision")

print("[v5.1] pixel-domain detection mapped into OS-driver logical domain")
print("[v5.1] stale vision fuse classified StaleVision")
PY

echo "========================================================================"
echo "Genesis v5.1 spatiotemporal alignment validation passed"
echo "========================================================================"
