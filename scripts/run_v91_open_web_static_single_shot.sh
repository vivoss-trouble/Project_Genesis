#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V91_MAPPER_BIN:-/tmp/genesis_v91_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V91_OS_SOCKET:-/tmp/genesis_os_driver_v91.sock}"
DRIVER_LOG="${GENESIS_V91_DRIVER_LOG:-/tmp/genesis_os_driver_v91.log}"
OUTPUT_DIR="${GENESIS_V91_OUTPUT_DIR:-/tmp/genesis_v91_open_web_static_single_shot}"
PRE_LOG="$OUTPUT_DIR/pre_map.log"
POST_LOG="$OUTPUT_DIR/post_map.log"
PRE_DEBUG="$OUTPUT_DIR/pre_map.png"
POST_DEBUG="$OUTPUT_DIR/post_map.png"
TARGET_URL="${GENESIS_V91_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V91_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V91_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V91_TARGET_ID:-}"
TARGET_KIND="${GENESIS_V91_TARGET_KIND:-link-like}"
ARMED_TOKEN="GENESIS_V91_ARMED_OPEN_WEB"
AUTO_FIRE_TOKEN="GENESIS_V91_AUTO_FIRE_STATIC_SINGLE_SHOT"
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
    echo "[v9.1] ERROR: timed out waiting for $socket_path" >&2
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

open_target_url() {
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

front_url() {
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript <<'OSA'
tell application "Safari"
    if not (exists front document) then return ""
    return URL of front document
end tell
OSA
    else
        printf ''
    fi
}

map_open_web() {
    local debug_path="$1"
    local log_path="$2"
    GENESIS_V81_DEBUG_PNG="$debug_path" \
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
        "$MAPPER_BIN" | tee "$log_path"
}

select_target() {
    local log_path="$1"
    local target_id="$2"
    local target_kind="$3"
    python3 - "$log_path" "$target_id" "$target_kind" <<'PY'
import json
import math
import sys

log_path, target_id, target_kind = sys.argv[1:4]
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit(f"[v9.1] missing open_web_shadow_map event in {log_path}")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v9.1] map must remain read-only: {event}")

targets = event.get("targets") or []
sticky_targets = [target for target in targets if target.get("control_kind") == "sticky-like"]

def inside_bbox(point, bbox):
    return (
        bbox.get("x", math.inf) <= point.get("x", -math.inf) <= bbox.get("x", math.inf) + bbox.get("width", -1)
        and bbox.get("y", math.inf) <= point.get("y", -math.inf) <= bbox.get("y", math.inf) + bbox.get("height", -1)
    )

if target_id:
    selected = next((item for item in targets if item.get("target_id") == target_id), None)
    if selected is None:
        raise SystemExit(f"[v9.1] target_id not found: {target_id}")
else:
    candidates = [
        item for item in targets
        if item.get("control_kind") == target_kind
        and item.get("motion_role") != "sticky_occluder"
    ]
    candidates.sort(key=lambda item: (
        item.get("bbox", {}).get("y", 1e9),
        item.get("bbox", {}).get("x", 1e9),
        item.get("target_id", ""),
    ))
    selected = candidates[0] if candidates else None
    if selected is None:
        raise SystemExit(f"[v9.1] no target with control_kind={target_kind}")

pixel_center = selected.get("pixel_center") or {}
occluders = [
    sticky.get("target_id")
    for sticky in sticky_targets
    if inside_bbox(pixel_center, sticky.get("bbox") or {})
]
if occluders:
    raise SystemExit(f"[v9.1] selected target is under sticky occluder(s) {occluders}: {selected}")

point = selected.get("global_coregraphics_point") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v9.1] selected target has no global point: {selected}")

print(json.dumps({
    "event": "open_web_static_single_shot_target",
    "target_id": selected.get("target_id"),
    "target_kind": selected.get("control_kind"),
    "selected": selected,
    "occlusion_clear": True,
    "sticky_occluder_count": len(sticky_targets),
    "map_target_count": len(targets),
    "posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v9.1 Open-Web Static Single-Shot Gate"
echo "========================================================================"
echo "[v9.1] URL: $TARGET_URL"
echo "[v9.1] Window title needle: $WINDOW_TITLE"
echo "[v9.1] Target kind: $TARGET_KIND"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

open_target_url "$TARGET_URL"
sleep "${GENESIS_V91_BROWSER_SETTLE_SEC:-2.5}"

BASE_URL="$(front_url)"
map_open_web "$PRE_DEBUG" "$PRE_LOG"
SELECTED_JSON="$(select_target "$PRE_LOG" "$TARGET_ID" "$TARGET_KIND")"
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
SELECTED_ID="$(python3 - "$SELECTED_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["target_id"])
PY
)"

ARMED=false
if [[ "${GENESIS_V91_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V91_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v9.1] Armed mode requires GENESIS_V91_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v9.1] ARMED open-web static shot requested. One click will be posted."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v9.1] Dry-run mode. Set GENESIS_V91_ARMED_CONFIRM=$ARMED_TOKEN and GENESIS_V91_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN to post one real click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v91-open-web","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v9.1] Accessibility is not trusted; refusing armed open-web click")
PY
fi

MOVE_PAYLOAD="$(python3 - "$SELECTED_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "move-v91-open-web",
    "action_id": f"act-v91-{target_id}-move",
    "act": "move_mouse",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
MOVE_JSON="$(roundtrip_os_driver "$MOVE_PAYLOAD")"
echo "{\"event\":\"os_driver_move\",\"move\":$MOVE_JSON}"

CLICK_PAYLOAD="$(python3 - "$SELECTED_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "click-v91-open-web",
    "action_id": f"act-v91-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
echo "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"

sleep "${GENESIS_V91_POST_CLICK_SETTLE_SEC:-1.0}"
POST_URL="$(front_url)"
map_open_web "$POST_DEBUG" "$POST_LOG"

python3 - "$SELECTED_JSON" "$MOVE_JSON" "$CLICK_JSON" "$ARMED" "$BASE_URL" "$POST_URL" "$POST_LOG" <<'PY'
import json
import math
import sys

selected_event = json.loads(sys.argv[1])
move = json.loads(sys.argv[2])
click = json.loads(sys.argv[3])
armed = sys.argv[4] == "true"
base_url = sys.argv[5]
post_url = sys.argv[6]
post_log = sys.argv[7]
expected = selected_event["selected"]["global_coregraphics_point"]

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v9.1] os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v9.1] {label} posted state mismatch: {payload}")
    point = receipt.get("point") or {}
    if math.hypot(point.get("x", 1e9) - expected["x"], point.get("y", 1e9) - expected["y"]) > 0.001:
        raise SystemExit(f"[v9.1] {label} point drifted from selected target: {payload}")

post_map = None
with open(post_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            post_map = payload
if post_map is None:
    raise SystemExit("[v9.1] missing post-shot open-web map")
if post_map.get("posted") is not False or post_map.get("os_driver_active") is not False:
    raise SystemExit(f"[v9.1] post map must remain read-only: {post_map}")

url_changed = bool(base_url and post_url and base_url != post_url)
if armed and not url_changed:
    raise SystemExit(f"[v9.1] armed open-web click did not change URL: base={base_url!r} post={post_url!r}")
if not armed and url_changed:
    raise SystemExit(f"[v9.1] dry-run unexpectedly changed URL: base={base_url!r} post={post_url!r}")

print(json.dumps({
    "event": "v91_open_web_static_single_shot_summary",
    "armed": armed,
    "target_id": selected_event["target_id"],
    "target_kind": selected_event["target_kind"],
    "move_posted": move["receipt"]["posted"],
    "click_posted": click["receipt"]["posted"],
    "base_url": base_url,
    "post_url": post_url,
    "url_changed": url_changed,
    "post_target_count": post_map.get("target_count"),
    "assert_match": url_changed if armed else not url_changed,
    "posted": armed,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.1 open-web static single-shot gate complete"
echo "========================================================================"
