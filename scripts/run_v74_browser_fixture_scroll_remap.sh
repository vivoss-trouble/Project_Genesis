#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V74_MAPPER_BIN:-/tmp/genesis_v74_browser_fixture_readonly_map}"
OS_SOCKET="${GENESIS_V74_OS_SOCKET:-/tmp/genesis_os_driver_v74.sock}"
DRIVER_LOG="${GENESIS_V74_DRIVER_LOG:-/tmp/genesis_os_driver_v74.log}"
PRE_LOG="${GENESIS_V74_PRE_MAP_LOG:-/tmp/genesis_v74_browser_fixture_pre_map.log}"
POST_LOG="${GENESIS_V74_POST_MAP_LOG:-/tmp/genesis_v74_browser_fixture_post_map.log}"
PRE_DEBUG="${GENESIS_V74_PRE_DEBUG_PNG:-/tmp/genesis_v74_browser_fixture_pre.png}"
POST_DEBUG="${GENESIS_V74_POST_DEBUG_PNG:-/tmp/genesis_v74_browser_fixture_post.png}"
FIXTURE_PATH="$ROOT_DIR/fixtures/v7/browser_fixture.html"
SCROLLED_FIXTURE_PATH="$ROOT_DIR/fixtures/v7/browser_fixture_scrolled.html"
BROWSER_APP="${GENESIS_V74_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V74_TARGET_ID:-browser-scroll-container-0}"
TRACKED_TARGET_ID="${GENESIS_V74_TRACKED_TARGET_ID:-browser-async-target-0}"
SCROLL_DY="${GENESIS_V74_SCROLL_DY:--240}"
SCROLL_DX="${GENESIS_V74_SCROLL_DX:-0}"
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
    echo "[v7.4] ERROR: timed out waiting for $socket_path" >&2
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

open_fixture_url() {
    local url="$1"
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$url" <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        open location targetUrl
    end tell
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

map_fixture() {
    local url="$1"
    local debug_path="$2"
    local log_path="$3"
    open_fixture_url "$url"
    sleep "${GENESIS_V74_BROWSER_SETTLE_SEC:-1.5}"
    GENESIS_V71_DEBUG_PNG="$debug_path" "$MAPPER_BIN" | tee "$log_path"
}

select_target() {
    local log_path="$1"
    local target_id="$2"
    local event_name="$3"
    python3 - "$log_path" "$target_id" "$event_name" <<'PY'
import json
import sys

log_path, target_id, event_name = sys.argv[1:4]
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
    raise SystemExit(f"[v7.4] missing browser map in {log_path}")
if event.get("status") == "error":
    raise SystemExit(f"[v7.4] mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v7.4] map must remain read-only: {event}")
selected = next((item for item in event.get("targets") or [] if item.get("target_id") == target_id), None)
if selected is None:
    raise SystemExit(f"[v7.4] target_id {target_id} not found in {log_path}")

print(json.dumps({
    "event": event_name,
    "target_id": target_id,
    "selected": selected,
    "map_target_count": len(event.get("targets") or []),
    "posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v7.4 Browser Fixture Scroll-Remap Gate"
echo "========================================================================"
echo "[v7.4] Scroll target: $TARGET_ID"
echo "[v7.4] Tracked target: $TRACKED_TARGET_ID"
echo "[v7.4] Projection-only mode. OS Driver will remain unarmed."

swiftc scripts/browser_fixture_readonly_map.swift -o "$MAPPER_BIN"

BASE_URL="file://$FIXTURE_PATH"
SCROLLED_URL="file://$SCROLLED_FIXTURE_PATH"
map_fixture "$BASE_URL" "$PRE_DEBUG" "$PRE_LOG"
PRE_SELECTED_JSON="$(select_target "$PRE_LOG" "$TARGET_ID" "browser_fixture_scroll_projection_target")"
echo "$PRE_SELECTED_JSON"
PRE_TRACKED_JSON="$(select_target "$PRE_LOG" "$TRACKED_TARGET_ID" "browser_fixture_pre_scroll_tracked_target")"
echo "$PRE_TRACKED_JSON"

POINT_X="$(python3 - "$PRE_SELECTED_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["selected"]["global_coregraphics_point"]["x"])
PY
)"
POINT_Y="$(python3 - "$PRE_SELECTED_JSON" <<'PY'
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

SCROLL_PAYLOAD="$(python3 - "$TARGET_ID" "$POINT_X" "$POINT_Y" "$SCROLL_DX" "$SCROLL_DY" <<'PY'
import json
import sys
target_id, x, y, dx, dy = sys.argv[1:6]
print(json.dumps({
    "request_id": "scroll-v74-browser-fixture",
    "action_id": f"act-v74-{target_id}-scroll",
    "act": "scroll_wheel",
    "x": float(x),
    "y": float(y),
    "dx": float(dx),
    "dy": float(dy),
}, sort_keys=True))
PY
)"
SCROLL_JSON="$(roundtrip_os_driver "$SCROLL_PAYLOAD")"
echo "{\"event\":\"os_driver_scroll\",\"scroll\":$SCROLL_JSON}"

sleep "${GENESIS_V74_SETTLE_SEC:-0.2}"
map_fixture "$SCROLLED_URL" "$POST_DEBUG" "$POST_LOG"
POST_TRACKED_JSON="$(select_target "$POST_LOG" "$TRACKED_TARGET_ID" "browser_fixture_post_scroll_tracked_target")"
echo "$POST_TRACKED_JSON"

python3 - "$PRE_TRACKED_JSON" "$POST_TRACKED_JSON" "$SCROLL_JSON" "$SCROLL_DX" "$SCROLL_DY" <<'PY'
import json
import sys

pre = json.loads(sys.argv[1])
post = json.loads(sys.argv[2])
scroll = json.loads(sys.argv[3])
expected_dx = float(sys.argv[4])
expected_dy = float(sys.argv[5])

receipt = (scroll.get("receipt") or {})
if scroll.get("status") != "ok":
    raise SystemExit(f"[v7.4] os-driver scroll failed: {scroll}")
if scroll.get("armed") is not False or receipt.get("posted") is not False:
    raise SystemExit(f"[v7.4] scroll-remap must remain projection-only: {scroll}")
delta = receipt.get("scroll_delta") or {}
if abs(delta.get("dx", 1e9) - expected_dx) > 0.001 or abs(delta.get("dy", 1e9) - expected_dy) > 0.001:
    raise SystemExit(f"[v7.4] scroll delta drifted: {scroll}")

pre_y = pre["selected"]["global_coregraphics_point"]["y"]
post_y = post["selected"]["global_coregraphics_point"]["y"]
y_delta = post_y - pre_y
if abs(y_delta) < 20:
    raise SystemExit(f"[v7.4] tracked target did not materially remap after scroll simulation: {y_delta}")

print(json.dumps({
    "event": "v74_browser_fixture_scroll_remap_summary",
    "tracked_target_id": pre["target_id"],
    "pre_global_y": pre_y,
    "post_global_y": post_y,
    "observed_global_y_delta": y_delta,
    "scroll_delta": delta,
    "scroll_posted": receipt["posted"],
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.4 Browser fixture scroll-remap gate complete"
echo "========================================================================"
