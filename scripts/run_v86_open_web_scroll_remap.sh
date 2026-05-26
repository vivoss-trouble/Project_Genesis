#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V86_MAPPER_BIN:-/tmp/genesis_v86_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V86_OS_SOCKET:-/tmp/genesis_os_driver_v86.sock}"
DRIVER_LOG="${GENESIS_V86_DRIVER_LOG:-/tmp/genesis_os_driver_v86.log}"
PRE_LOG="${GENESIS_V86_PRE_MAP_LOG:-/tmp/genesis_v86_open_web_pre_map.log}"
POST_LOG="${GENESIS_V86_POST_MAP_LOG:-/tmp/genesis_v86_open_web_post_map.log}"
PRE_DEBUG="${GENESIS_V86_PRE_DEBUG_PNG:-/tmp/genesis_v86_open_web_pre.png}"
POST_DEBUG="${GENESIS_V86_POST_DEBUG_PNG:-/tmp/genesis_v86_open_web_post.png}"
FIXTURE_PATH="$ROOT_DIR/fixtures/v8/open_web_shadow_sample.html"
BROWSER_APP="${GENESIS_V86_BROWSER_APP:-Safari}"
SCROLL_DY="${GENESIS_V86_SCROLL_DY:--240}"
SCROLL_DX="${GENESIS_V86_SCROLL_DX:-0}"
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
    echo "[v8.6] ERROR: timed out waiting for $socket_path" >&2
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

map_open_web() {
    local url="$1"
    local debug_path="$2"
    local log_path="$3"
    open_target_url "$url"
    sleep "${GENESIS_V86_BROWSER_SETTLE_SEC:-1.5}"
    GENESIS_V81_DEBUG_PNG="$debug_path" "$MAPPER_BIN" | tee "$log_path"
}

select_scroll_region() {
    local log_path="$1"
    python3 - "$log_path" <<'PY'
import json
import sys

event = None
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit("[v8.6] missing open-web map")
if event.get("status") == "error":
    raise SystemExit(f"[v8.6] mapper error: {event}")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.6] map must stay read-only: {event}")

regions = [
    region for region in event.get("scroll_regions") or []
    if region.get("control_kind") == "scroll-region" and region.get("child_target_ids")
]
if not regions:
    raise SystemExit(f"[v8.6] no active scroll-region found: {event}")

selected = sorted(regions, key=lambda item: (-len(item.get("child_target_ids") or []), item["pixel_center"]["y"]))[0]
print(json.dumps({
    "event": "open_web_scroll_projection_target",
    "selected": selected,
    "target_id": selected["target_id"],
    "child_target_ids": selected.get("child_target_ids") or [],
    "posted": False,
}, sort_keys=True))
PY
}

select_child_target() {
    local log_path="$1"
    local container_id="$2"
    local child_kind="$3"
    local event_name="$4"
    python3 - "$log_path" "$container_id" "$child_kind" "$event_name" <<'PY'
import json
import sys

log_path, container_id, child_kind, event_name = sys.argv[1:5]
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
    raise SystemExit(f"[v8.6] missing map in {log_path}")

matches = [
    target for target in event.get("targets") or []
    if target.get("container_id") == container_id and target.get("control_kind") == child_kind
]
if not matches:
    raise SystemExit(f"[v8.6] no child kind={child_kind} in container={container_id}: {event}")

selected = sorted(matches, key=lambda item: item["pixel_center"]["y"])[0]
print(json.dumps({
    "event": event_name,
    "selected": selected,
    "target_id": selected["target_id"],
    "container_id": container_id,
    "tracked_kind": child_kind,
    "posted": False,
}, sort_keys=True))
PY
}

select_outside_target() {
    local log_path="$1"
    local reference_json="$2"
    local event_name="$3"
    python3 - "$log_path" "$reference_json" "$event_name" <<'PY'
import json
import math
import sys

log_path, reference_raw, event_name = sys.argv[1:4]
reference = json.loads(reference_raw)
reference_target = reference["selected"]
target_id = reference_target["target_id"]
target_kind = reference_target["control_kind"]
reference_point = reference_target["window_coregraphics_point"]
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
    raise SystemExit(f"[v8.6] missing map in {log_path}")

selected = next((target for target in event.get("targets") or [] if target.get("target_id") == target_id), None)
if selected is None:
    candidates = [
        target for target in event.get("targets") or []
        if not target.get("container_id") and target.get("control_kind") == target_kind
    ]
    if not candidates:
        raise SystemExit(f"[v8.6] outside baseline target disappeared: {target_id}")
    selected = sorted(
        candidates,
        key=lambda target: math.hypot(
            target["window_coregraphics_point"]["x"] - reference_point["x"],
            target["window_coregraphics_point"]["y"] - reference_point["y"],
        ),
    )[0]

print(json.dumps({
    "event": event_name,
    "reference_target_id": target_id,
    "selected": selected,
    "target_id": selected["target_id"],
    "posted": False,
}, sort_keys=True))
PY
}

select_initial_outside_target() {
    local log_path="$1"
    python3 - "$log_path" <<'PY'
import json
import sys

event = None
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit("[v8.6] missing map")

targets = [
    target for target in event.get("targets") or []
    if not target.get("container_id") and target.get("control_kind") in {"button-like", "link-like", "heading"}
]
if not targets:
    raise SystemExit(f"[v8.6] no outside baseline target found: {event}")

priority = {"button-like": 0, "link-like": 1, "heading": 2}
selected = sorted(targets, key=lambda item: (priority.get(item.get("control_kind"), 9), item["pixel_center"]["y"]))[0]
print(json.dumps({
    "event": "open_web_pre_scroll_outside_target",
    "selected": selected,
    "target_id": selected["target_id"],
    "posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v8.6 Open-Web Scroll Projection & Remap"
echo "========================================================================"
echo "[v8.6] Projection-only mode. OS Driver will remain unarmed."

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

BASE_URL="file://$FIXTURE_PATH"
SCROLLED_URL="file://$FIXTURE_PATH?state=scrolled"
map_open_web "$BASE_URL" "$PRE_DEBUG" "$PRE_LOG"

SCROLL_REGION_JSON="$(select_scroll_region "$PRE_LOG")"
echo "$SCROLL_REGION_JSON"
SCROLL_ID="$(python3 - "$SCROLL_REGION_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["target_id"])
PY
)"
TRACKED_KIND="${GENESIS_V86_TRACKED_KIND:-link-like}"
PRE_CHILD_JSON="$(select_child_target "$PRE_LOG" "$SCROLL_ID" "$TRACKED_KIND" "open_web_pre_scroll_child_target")"
echo "$PRE_CHILD_JSON"
PRE_OUTSIDE_JSON="$(select_initial_outside_target "$PRE_LOG")"
echo "$PRE_OUTSIDE_JSON"

POINT_X="$(python3 - "$SCROLL_REGION_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["selected"]["global_coregraphics_point"]["x"])
PY
)"
POINT_Y="$(python3 - "$SCROLL_REGION_JSON" <<'PY'
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

SCROLL_PAYLOAD="$(python3 - "$SCROLL_ID" "$POINT_X" "$POINT_Y" "$SCROLL_DX" "$SCROLL_DY" <<'PY'
import json
import sys
target_id, x, y, dx, dy = sys.argv[1:6]
print(json.dumps({
    "request_id": "scroll-v86-open-web",
    "action_id": f"act-v86-{target_id}-scroll",
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

sleep "${GENESIS_V86_SETTLE_SEC:-0.25}"
map_open_web "$SCROLLED_URL" "$POST_DEBUG" "$POST_LOG"
POST_OUTSIDE_JSON="$(select_outside_target "$POST_LOG" "$PRE_OUTSIDE_JSON" "open_web_post_scroll_outside_target")"
echo "$POST_OUTSIDE_JSON"
POST_SCROLL_REGION_JSON="$(select_scroll_region "$POST_LOG")"
POST_SCROLL_ID="$(python3 - "$POST_SCROLL_REGION_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["target_id"])
PY
)"
POST_CHILD_JSON="$(select_child_target "$POST_LOG" "$POST_SCROLL_ID" "$TRACKED_KIND" "open_web_post_scroll_child_target")"
echo "$POST_CHILD_JSON"
echo "$(python3 - "$POST_SCROLL_REGION_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "open_web_post_scroll_projection_target"
print(json.dumps(payload, sort_keys=True))
PY
)"

python3 - "$SCROLL_REGION_JSON" "$POST_SCROLL_REGION_JSON" "$PRE_CHILD_JSON" "$POST_CHILD_JSON" "$PRE_OUTSIDE_JSON" "$POST_OUTSIDE_JSON" "$SCROLL_JSON" "$SCROLL_DX" "$SCROLL_DY" <<'PY'
import json
import sys

pre_region, post_region, pre_child, post_child, pre_outside, post_outside, scroll = [
    json.loads(arg) for arg in sys.argv[1:8]
]
expected_dx = float(sys.argv[8])
expected_dy = float(sys.argv[9])

receipt = scroll.get("receipt") or {}
if scroll.get("status") != "ok":
    raise SystemExit(f"[v8.6] os-driver scroll failed: {scroll}")
if scroll.get("armed") is not False or receipt.get("posted") is not False:
    raise SystemExit(f"[v8.6] scroll projection must remain unarmed: {scroll}")
delta = receipt.get("scroll_delta") or {}
if abs(delta.get("dx", 1e9) - expected_dx) > 0.001 or abs(delta.get("dy", 1e9) - expected_dy) > 0.001:
    raise SystemExit(f"[v8.6] scroll delta drifted: {scroll}")

def point(payload, key="selected"):
    return payload[key]["window_coregraphics_point"]

pre_child_y = point(pre_child)["y"]
post_child_y = point(post_child)["y"]
child_delta = post_child_y - pre_child_y
pre_outside_y = point(pre_outside)["y"]
post_outside_y = point(post_outside)["y"]
outside_delta = post_outside_y - pre_outside_y
pre_region_y = point(pre_region)["y"]
post_region_y = point(post_region)["y"]
region_delta = post_region_y - pre_region_y

if child_delta > -20:
    raise SystemExit(f"[v8.6] child target did not remap upward enough: {child_delta}")
if abs(outside_delta) > 5.0:
    raise SystemExit(f"[v8.6] outside target drifted during scroll-state projection: {outside_delta}")
if abs(region_delta) > 5.0:
    raise SystemExit(f"[v8.6] scroll-region shell drifted during content remap: {region_delta}")

print(json.dumps({
    "event": "v86_open_web_scroll_remap_summary",
    "scroll_region_id": pre_region["target_id"],
    "tracked_kind": pre_child["tracked_kind"],
    "pre_child_target_id": pre_child["target_id"],
    "post_child_target_id": post_child["target_id"],
    "child_window_y_delta": child_delta,
    "outside_target_id": pre_outside["target_id"],
    "outside_window_y_delta": outside_delta,
    "scroll_region_window_y_delta": region_delta,
    "scroll_delta": delta,
    "scroll_posted": receipt["posted"],
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.6 open-web scroll projection & remap complete"
echo "========================================================================"
