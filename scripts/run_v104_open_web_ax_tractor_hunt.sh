#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V104_MAPPER_BIN:-/tmp/genesis_v104_open_web_shadow_map}"
AX_BIN="${GENESIS_V104_AX_BIN:-/tmp/genesis_v104_ax_scroll_to_visible_probe}"
OS_SOCKET="${GENESIS_V104_OS_SOCKET:-/tmp/genesis_os_driver_v104.sock}"
DRIVER_LOG="${GENESIS_V104_DRIVER_LOG:-/tmp/genesis_os_driver_v104.log}"
OUTPUT_DIR="${GENESIS_V104_OUTPUT_DIR:-/tmp/genesis_v104_open_web_ax_tractor_hunt}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V104_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V104_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V104_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V104_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_TITLE="${GENESIS_V104_AX_TARGET_TITLE:-Final Project}"
ARMED_TOKEN="GENESIS_V104_ARMED_OPEN_WEB_AX_TRACTOR_HUNT"
AUTO_FIRE_TOKEN="GENESIS_V104_AUTO_FIRE_AX_TRACTOR_HUNT"
DRIVER_PID=""

cleanup() {
    if [[ -n "$DRIVER_PID" ]] && kill -0 "$DRIVER_PID" 2>/dev/null; then
        kill "$DRIVER_PID" 2>/dev/null || true
        wait "$DRIVER_PID" 2>/dev/null || true
    fi
    rm -f "$OS_SOCKET"
}
trap cleanup EXIT INT TERM

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
}

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v10.4] ERROR: timed out waiting for $socket_path" >&2
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
        osascript - "$url" >/dev/null <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        set targetDoc to make new document with properties {URL:targetUrl}
    end tell
    return ""
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

target_document_url() {
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$TARGET_URL" "$WINDOW_TITLE" <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    set titleNeedle to item 2 of argv
    tell application "Safari"
        repeat with candidate in documents
            try
                set candidateUrl to URL of candidate
                set candidateName to name of candidate
                if candidateUrl starts with targetUrl then return candidateUrl
                if candidateName contains titleNeedle then return candidateUrl
            end try
        end repeat
        if not (exists front document) then return ""
        return URL of front document
    end tell
end run
OSA
    else
        printf ''
    fi
}

wait_for_target_url() {
    local url="$1"
    local current=""
    for _ in $(seq 1 80); do
        current="$(target_document_url || true)"
        if [[ "$current" == "$url"* ]]; then
            return
        fi
        sleep 0.25
    done
    echo "[v10.4] ERROR: target browser URL did not settle on $url (current: $current)" >&2
    exit 1
}

map_log_matches_target_window() {
    local log_path="$1"
    python3 - "$log_path" "$WINDOW_TITLE" <<'PY'
import json
import sys

log_path, title = sys.argv[1:3]
title = title.lower()
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload
if not event:
    raise SystemExit(1)
name = (event.get("window_name") or "").lower()
raise SystemExit(0 if title in name else 1)
PY
}

map_open_web() {
    local phase="$1"
    local debug_path="$OUTPUT_DIR/${phase}.png"
    local log_path="$OUTPUT_DIR/${phase}.log"
    local attempts="${GENESIS_V104_MAP_TARGET_ATTEMPTS:-12}"
    local tmp_log=""
    local tmp_png=""

    for attempt in $(seq 1 "$attempts"); do
        tmp_log="$OUTPUT_DIR/${phase}_attempt_${attempt}.log"
        tmp_png="$OUTPUT_DIR/${phase}_attempt_${attempt}.png"
        GENESIS_V81_DEBUG_PNG="$tmp_png" \
        GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
        GENESIS_V81_WINDOW_OWNER="$BROWSER_APP" \
            "$MAPPER_BIN" > "$tmp_log"
        if map_log_matches_target_window "$tmp_log"; then
            cp "$tmp_log" "$log_path"
            if [[ -f "$tmp_png" ]]; then
                cp "$tmp_png" "$debug_path"
            fi
            cat "$log_path" | tee -a "$RESULTS_LOG"
            return
        fi
        sleep 0.35
    done

    if [[ -n "$tmp_log" && -f "$tmp_log" ]]; then
        cp "$tmp_log" "$log_path"
        cat "$log_path" | tee -a "$RESULTS_LOG"
    fi
    echo "[v10.4] ERROR: failed to capture target window matching title '$WINDOW_TITLE'" >&2
    exit 3
}

extract_marker_point_env() {
    local map_log="$1"
    python3 - "$map_log" <<'PY'
import json
import sys

map_log = sys.argv[1]
event = None
with open(map_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload
if not event:
    raise SystemExit(0)
for target in event.get("targets") or []:
    point = target.get("global_coregraphics_point") or {}
    if point.get("x") is not None and point.get("y") is not None:
        print(f"GENESIS_V104_POINT_X={float(point['x'])}")
        print(f"GENESIS_V104_POINT_Y={float(point['y'])}")
        break
PY
}

assess_tractor_target() {
    local post_log="$1"
    local ax_json="$2"
    python3 - "$post_log" "$ax_json" <<'PY'
import json
import math
import sys

post_log, ax_raw = sys.argv[1:3]
ax = json.loads(ax_raw)
event = None
with open(post_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit("[v10.4] missing post-tractor Shadow Map")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v10.4] Shadow Map must remain read-only: {event}")

target_frame = ax.get("target_frame_after_action")
if not isinstance(target_frame, dict):
    target_frame = (ax.get("selected_target") or {}).get("frame")
if not isinstance(target_frame, dict):
    raise SystemExit(f"[v10.4] missing AX target frame: {ax}")

center_x = float(target_frame["center_x"])
center_y = float(target_frame["center_y"])
bounds = event.get("window_bounds") or {}
window_x = float(bounds["x"])
window_y = float(bounds["y"])
window_width = float(bounds["width"])
window_height = float(bounds["height"])
visible = window_x <= center_x <= window_x + window_width and window_y <= center_y <= window_y + window_height

scale_x = float(event.get("scale_x") or 1.0)
scale_y = float(event.get("scale_y") or 1.0)
pixel_center = {
    "x": (center_x - window_x) * scale_x,
    "y": (center_y - window_y) * scale_y,
}

def inside_bbox(point, bbox):
    return (
        bbox.get("x", math.inf) <= point.get("x", -math.inf) <= bbox.get("x", math.inf) + bbox.get("width", -1)
        and bbox.get("y", math.inf) <= point.get("y", -math.inf) <= bbox.get("y", math.inf) + bbox.get("height", -1)
    )

targets = event.get("targets") or []
sticky_targets = [target for target in targets if target.get("control_kind") == "sticky-like"]
occluders = [
    sticky.get("target_id")
    for sticky in sticky_targets
    if inside_bbox(pixel_center, sticky.get("bbox") or {})
]
occlusion_clear = visible and not occluders

print(json.dumps({
    "event": "v104_ax_tractor_fire_target",
    "target_found": ax.get("target_found") is True,
    "scroll_to_visible_status": ax.get("scroll_to_visible_status"),
    "ax_mutation_attempted": ax.get("ax_mutation_attempted") is True,
    "selected_target": ax.get("selected_target"),
    "target_frame_after_action": target_frame,
    "click_point": {"x": center_x, "y": center_y},
    "window_bounds": bounds,
    "target_visible_after_action": visible,
    "target_pixel_center_for_occlusion": pixel_center,
    "sticky_occluder_count": len(sticky_targets),
    "sticky_occluders": occluders,
    "occlusion_clear": occlusion_clear,
    "post_tractor_target_count": len(targets),
    "posted": False,
}, sort_keys=True))
PY
}

json_get() {
    local payload="$1"
    local expression="$2"
    python3 - "$payload" "$expression" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
value = payload
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

echo "========================================================================"
echo "Genesis v10.4 Open-Web AX Tractor Hunt"
echo "========================================================================"
echo "[v10.4] URL: $TARGET_URL"
echo "[v10.4] Browser: $BROWSER_APP"
echo "[v10.4] Window title needle: $WINDOW_TITLE"
echo "[v10.4] AX target title needle: $TARGET_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_scroll_to_visible_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V104_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V104_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v10.4] Armed tractor hunt requires GENESIS_V104_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v10.4] ARMED tractor hunt requested. It will AX-tract one target and post one click."
else
    echo "[v10.4] Dry-run mode. Target bridge is resolved, but AX mutation and click are not performed."
fi

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V104_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(target_document_url)"

map_open_web "pre_tractor"
PRE_LOG="$OUTPUT_DIR/pre_tractor.log"

POINT_ENV="$(extract_marker_point_env "$PRE_LOG" || true)"
POINT_X=""
POINT_Y=""
if [[ -n "$POINT_ENV" ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            GENESIS_V104_POINT_X) POINT_X="$value" ;;
            GENESIS_V104_POINT_Y) POINT_Y="$value" ;;
        esac
    done <<< "$POINT_ENV"
fi

AX_JSON="$(
    GENESIS_V103_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V103_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V103_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V103_AX_TARGET_TITLE="$TARGET_TITLE" \
    GENESIS_V103_AX_EXECUTE="$([[ "$ARMED" == true ]] && echo 1 || echo 0)" \
    GENESIS_V103_POINT_X="$POINT_X" \
    GENESIS_V103_POINT_Y="$POINT_Y" \
        "$AX_BIN"
)"
emit "$AX_JSON"

sleep "${GENESIS_V104_POST_AX_SETTLE_SEC:-1.0}"
POST_AX_URL="$(target_document_url)"
map_open_web "post_tractor"
POST_AX_LOG="$OUTPUT_DIR/post_tractor.log"

TARGET_JSON="$(assess_tractor_target "$POST_AX_LOG" "$AX_JSON")"
emit "$TARGET_JSON"

TARGET_FOUND="$(json_get "$TARGET_JSON" "target_found")"
OCCLUSION_CLEAR="$(json_get "$TARGET_JSON" "occlusion_clear")"
POINT_X="$(json_get "$TARGET_JSON" "click_point.x")"
POINT_Y="$(json_get "$TARGET_JSON" "click_point.y")"
SELECTED_TITLE="$(json_get "$TARGET_JSON" "selected_target.title")"

if [[ "$TARGET_FOUND" != "True" && "$TARGET_FOUND" != "true" ]]; then
    echo "[v10.4] ERROR: AX target was not found; refusing click" >&2
    exit 2
fi
if [[ "$ARMED" == true && "$OCCLUSION_CLEAR" != "True" && "$OCCLUSION_CLEAR" != "true" ]]; then
    echo "[v10.4] ERROR: target is not visible and clear after AX traction; refusing click" >&2
    exit 2
fi

MOVE_JSON='{"status":"ok","receipt":{"posted":false,"point":{"x":0,"y":0}}}'
CLICK_JSON='{"status":"ok","receipt":{"posted":false,"point":{"x":0,"y":0}}}'

if [[ "$ARMED" == true ]]; then
    rm -f "$OS_SOCKET" "$DRIVER_LOG"
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
    DRIVER_PID=$!
    wait_for_socket "$OS_SOCKET"

    PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v104-open-web-ax-tractor-hunt","act":"probe"}')"
    emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v10.4] Accessibility is not trusted; refusing armed click")
PY

    MOVE_PAYLOAD="$(python3 - "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
x, y = map(float, sys.argv[1:3])
print(json.dumps({
    "request_id": "move-v104-open-web-ax-tractor-hunt",
    "action_id": "act-v104-ax-tractor-hunt-move",
    "act": "move_mouse",
    "x": x,
    "y": y,
}, sort_keys=True))
PY
)"
    MOVE_JSON="$(roundtrip_os_driver "$MOVE_PAYLOAD")"
    emit "{\"event\":\"os_driver_move\",\"move\":$MOVE_JSON}"

    CLICK_PAYLOAD="$(python3 - "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
x, y = map(float, sys.argv[1:3])
print(json.dumps({
    "request_id": "click-v104-open-web-ax-tractor-hunt",
    "action_id": "act-v104-ax-tractor-hunt-click",
    "act": "click_point",
    "x": x,
    "y": y,
}, sort_keys=True))
PY
)"
    CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
    emit "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"
fi

sleep "${GENESIS_V104_POST_CLICK_SETTLE_SEC:-1.2}"
POST_CLICK_URL="$(target_document_url)"
map_open_web "post_click"
POST_CLICK_LOG="$OUTPUT_DIR/post_click.log"

SUMMARY_JSON="$(python3 - "$BASE_URL" "$POST_AX_URL" "$POST_CLICK_URL" "$AX_JSON" "$TARGET_JSON" "$MOVE_JSON" "$CLICK_JSON" "$ARMED" "$POST_CLICK_LOG" "$RESULTS_LOG" <<'PY'
import json
import math
import sys

(
    base_url,
    post_ax_url,
    post_click_url,
    ax_raw,
    target_raw,
    move_raw,
    click_raw,
    armed_raw,
    post_click_log,
    results_log,
) = sys.argv[1:11]
ax = json.loads(ax_raw)
target = json.loads(target_raw)
move = json.loads(move_raw)
click = json.loads(click_raw)
armed = armed_raw == "true"
expected = target.get("click_point") or {}

post_map = None
with open(post_click_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            post_map = payload
if post_map is None:
    raise SystemExit("[v10.4] missing post-click Shadow Map")

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v10.4] os-driver {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not armed:
        raise SystemExit(f"[v10.4] {label} posted state mismatch: {payload}")
    if armed:
        point = receipt.get("point") or {}
        if math.hypot(point.get("x", 1e9) - expected["x"], point.get("y", 1e9) - expected["y"]) > 0.001:
            raise SystemExit(f"[v10.4] {label} point drifted from target: {payload}")

url_changed_after_ax = bool(base_url and post_ax_url and base_url != post_ax_url)
url_changed_after_click = bool(post_ax_url and post_click_url and post_ax_url != post_click_url)

if url_changed_after_ax:
    raise SystemExit(f"[v10.4] AX traction changed URL: base={base_url!r} post_ax={post_ax_url!r}")
if armed and not url_changed_after_click:
    raise SystemExit(f"[v10.4] armed click did not change URL: post_ax={post_ax_url!r} post_click={post_click_url!r}")
if not armed and url_changed_after_click:
    raise SystemExit(f"[v10.4] dry-run unexpectedly changed URL: post_ax={post_ax_url!r} post_click={post_click_url!r}")

print(json.dumps({
    "event": "v104_open_web_ax_tractor_hunt_summary",
    "armed": armed,
    "target_title": (target.get("selected_target") or {}).get("title"),
    "web_area_found": ax.get("web_area_found"),
    "target_found": target.get("target_found"),
    "ax_mutation_attempted": ax.get("ax_mutation_attempted"),
    "scroll_to_visible_status": ax.get("scroll_to_visible_status"),
    "target_visible_after_action": target.get("target_visible_after_action"),
    "occlusion_clear": target.get("occlusion_clear"),
    "move_posted": (move.get("receipt") or {}).get("posted"),
    "click_posted": (click.get("receipt") or {}).get("posted"),
    "base_url": base_url,
    "post_ax_url": post_ax_url,
    "post_click_url": post_click_url,
    "url_changed_after_ax": url_changed_after_ax,
    "url_changed_after_click": url_changed_after_click,
    "post_click_target_count": post_map.get("target_count"),
    "assert_match": url_changed_after_click if armed else not url_changed_after_click,
    "posted": armed,
    "physical_input_posted": armed,
    "os_driver_active": armed,
    "results_log": results_log,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v10.4 open-web AX tractor hunt complete"
echo "========================================================================"
