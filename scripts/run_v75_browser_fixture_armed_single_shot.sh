#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V75_MAPPER_BIN:-/tmp/genesis_v75_browser_fixture_readonly_map}"
OS_SOCKET="${GENESIS_V75_OS_SOCKET:-/tmp/genesis_os_driver_v75.sock}"
DRIVER_LOG="${GENESIS_V75_DRIVER_LOG:-/tmp/genesis_os_driver_v75.log}"
PRE_LOG="${GENESIS_V75_PRE_MAP_LOG:-/tmp/genesis_v75_browser_fixture_pre_map.log}"
POST_LOG="${GENESIS_V75_POST_MAP_LOG:-/tmp/genesis_v75_browser_fixture_post_map.log}"
PRE_DEBUG="${GENESIS_V75_PRE_DEBUG_PNG:-/tmp/genesis_v75_browser_fixture_pre.png}"
POST_DEBUG="${GENESIS_V75_POST_DEBUG_PNG:-/tmp/genesis_v75_browser_fixture_post.png}"
FIXTURE_PATH="$ROOT_DIR/fixtures/v7/browser_fixture.html"
BROWSER_APP="${GENESIS_V75_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V75_TARGET_ID:-browser-button-like-0}"
ARMED_TOKEN="GENESIS_V75_ARMED_BROWSER_FIXTURE"
AUTO_FIRE_TOKEN="GENESIS_V75_AUTO_FIRE_SINGLE_SHOT"
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
    echo "[v7.5] ERROR: timed out waiting for $socket_path" >&2
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
    local debug_path="$1"
    local log_path="$2"
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
    raise SystemExit(f"[v7.5] missing browser map in {log_path}")
if event.get("status") == "error":
    raise SystemExit(f"[v7.5] mapper error: {event}")
if event.get("posted") is not False:
    raise SystemExit(f"[v7.5] map must remain read-only: {event}")
selected = next((item for item in event.get("targets") or [] if item.get("target_id") == target_id), None)
if selected is None:
    raise SystemExit(f"[v7.5] target_id {target_id} not found in {log_path}")

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
echo "Genesis v7.5 Browser Fixture Armed Single-Shot Gate"
echo "========================================================================"
echo "[v7.5] Target ID: $TARGET_ID"

swiftc scripts/browser_fixture_readonly_map.swift -o "$MAPPER_BIN"

open_fixture_url "file://$FIXTURE_PATH"
sleep "${GENESIS_V75_BROWSER_SETTLE_SEC:-1.5}"

map_fixture "$PRE_DEBUG" "$PRE_LOG"
SELECTED_JSON="$(select_target "$PRE_LOG" "$TARGET_ID" "browser_fixture_armed_single_shot_target")"
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
if [[ "${GENESIS_V75_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V75_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v7.5] Armed mode requires GENESIS_V75_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v7.5] ARMED browser fixture single-shot requested. One click will be posted."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v7.5] Dry-run mode. Set GENESIS_V75_ARMED_CONFIRM=$ARMED_TOKEN and GENESIS_V75_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN to post one real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v75-browser-fixture","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v7.5] Accessibility is not trusted; refusing armed browser click")
PY
fi

MOVE_PAYLOAD="$(python3 - "$TARGET_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "move-v75-browser-fixture",
    "action_id": f"act-v75-{target_id}-move",
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
    "request_id": "click-v75-browser-fixture",
    "action_id": f"act-v75-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
echo "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"

sleep "${GENESIS_V75_POST_CLICK_SETTLE_SEC:-0.5}"
map_fixture "$POST_DEBUG" "$POST_LOG"

python3 - "$MOVE_JSON" "$CLICK_JSON" "$ARMED" "$POST_LOG" <<'PY'
import json
import sys

move = json.loads(sys.argv[1])
click = json.loads(sys.argv[2])
armed = sys.argv[3] == "true"
post_log = sys.argv[4]

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v7.5] os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v7.5] {label} posted state mismatch: {payload}")

post_map = None
with open(post_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "browser_fixture_readonly_map":
            post_map = payload
if post_map is None:
    raise SystemExit("[v7.5] missing post-click map")

kinds = {target.get("control_kind") for target in post_map.get("targets") or []}
assert_match = "fired-button" in kinds
if armed and not assert_match:
    raise SystemExit(f"[v7.5] armed click posted but fired-button assertion failed: {post_map}")
if not armed and assert_match:
    raise SystemExit(f"[v7.5] dry-run unexpectedly changed fixture state: {post_map}")

print(json.dumps({
    "event": "v75_browser_fixture_single_shot_summary",
    "armed": armed,
    "move_posted": move["receipt"]["posted"],
    "click_posted": click["receipt"]["posted"],
    "assert_match": assert_match,
    "posted": armed,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.5 Browser fixture armed single-shot gate complete"
echo "========================================================================"
