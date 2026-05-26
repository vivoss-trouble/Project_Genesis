#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V94_MAPPER_BIN:-/tmp/genesis_v94_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V94_OS_SOCKET:-/tmp/genesis_os_driver_v94.sock}"
DRIVER_LOG="${GENESIS_V94_DRIVER_LOG:-/tmp/genesis_os_driver_v94.log}"
OUTPUT_DIR="${GENESIS_V94_OUTPUT_DIR:-/tmp/genesis_v94_open_web_hunter_controller}"
TARGET_URL="${GENESIS_V94_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V94_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V94_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V94_TARGET_ID:-}"
TARGET_KIND="${GENESIS_V94_TARGET_KIND:-link-like}"
TARGET_STRATEGY="${GENESIS_V94_TARGET_STRATEGY:-bottommost}"
SAFE_CENTER_RATIO="${GENESIS_V94_SAFE_CENTER_RATIO:-0.45}"
SAFE_BAND_PX="${GENESIS_V94_SAFE_BAND_PX:-64}"
MAX_SCROLL_ABS="${GENESIS_V94_MAX_SCROLL_ABS:-720}"
MAX_STEPS="${GENESIS_V94_MAX_STEPS:-4}"
DRY_RUN_MAX_STEPS="${GENESIS_V94_DRY_RUN_MAX_STEPS:-1}"
SCROLL_DX="${GENESIS_V94_SCROLL_DX:-0}"
ARMED_TOKEN="GENESIS_V94_ARMED_OPEN_WEB_HUNTER"
AUTO_FIRE_TOKEN="GENESIS_V94_AUTO_FIRE_HUNTER_SHOT"
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
    echo "[v9.4] ERROR: timed out waiting for $socket_path" >&2
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

posted_of() {
    python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print("true" if (payload.get("receipt") or {}).get("posted") is True else "false")
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
        if not (exists front document) then
            make new document with properties {URL:targetUrl}
        else
            set URL of front document to targetUrl
        end if
    end tell
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

wait_for_target_url() {
    local url="$1"
    local current=""
    for _ in $(seq 1 80); do
        current="$(front_url || true)"
        if [[ "$current" == "$url"* ]]; then
            return
        fi
        sleep 0.25
    done
    echo "[v9.4] ERROR: front browser URL did not settle on $url (current: $current)" >&2
    exit 1
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
    local step="$1"
    local debug_path="$OUTPUT_DIR/step_${step}_map.png"
    local log_path="$OUTPUT_DIR/step_${step}_map.log"
    GENESIS_V81_DEBUG_PNG="$debug_path" \
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
        "$MAPPER_BIN" | tee "$log_path"
}

plan_step() {
    local log_path="$1"
    local step="$2"
    python3 - "$log_path" "$step" "$TARGET_ID" "$TARGET_KIND" "$TARGET_STRATEGY" "$SAFE_CENTER_RATIO" "$SAFE_BAND_PX" "$MAX_SCROLL_ABS" <<'PY'
import json
import math
import sys

(
    log_path,
    step_raw,
    requested_target_id,
    target_kind,
    target_strategy,
    safe_center_ratio_raw,
    safe_band_raw,
    max_scroll_raw,
) = sys.argv[1:9]

step = int(step_raw)
safe_center_ratio = float(safe_center_ratio_raw)
safe_band_px = float(safe_band_raw)
max_scroll_abs = float(max_scroll_raw)

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
    raise SystemExit(f"[v9.4] missing open_web_shadow_map event in {log_path}")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v9.4] map must remain read-only: {event}")

targets = event.get("targets") or []
sticky_targets = [target for target in targets if target.get("control_kind") == "sticky-like"]
window_bounds = event.get("window_bounds") or {}
try:
    window_x = float(window_bounds["x"])
    window_y = float(window_bounds["y"])
    window_width = float(window_bounds["width"])
    window_height = float(window_bounds["height"])
except KeyError as exc:
    raise SystemExit(f"[v9.4] map missing window bound {exc}: {event}") from exc

def inside_bbox(point, bbox):
    return (
        bbox.get("x", math.inf) <= point.get("x", -math.inf) <= bbox.get("x", math.inf) + bbox.get("width", -1)
        and bbox.get("y", math.inf) <= point.get("y", -math.inf) <= bbox.get("y", math.inf) + bbox.get("height", -1)
    )

if requested_target_id:
    selected = next((item for item in targets if item.get("target_id") == requested_target_id), None)
    if selected is None:
        target_not_found_reason = "requested_target_id_missing"
else:
    candidates = [
        item for item in targets
        if item.get("control_kind") == target_kind
        and item.get("motion_role") != "sticky_occluder"
    ]
    if target_strategy == "bottommost":
        candidates.sort(key=lambda item: (
            -(item.get("window_coregraphics_point") or item.get("global_coregraphics_point") or {}).get("y", -1e9),
            (item.get("window_coregraphics_point") or item.get("global_coregraphics_point") or {}).get("x", 1e9),
            item.get("target_id", ""),
        ))
    elif target_strategy == "topmost":
        candidates.sort(key=lambda item: (
            (item.get("window_coregraphics_point") or item.get("global_coregraphics_point") or {}).get("y", 1e9),
            (item.get("window_coregraphics_point") or item.get("global_coregraphics_point") or {}).get("x", 1e9),
            item.get("target_id", ""),
        ))
    elif target_strategy == "nearest_safe_center":
        safe_y = window_height * safe_center_ratio
        candidates.sort(key=lambda item: (
            abs((item.get("window_coregraphics_point") or {}).get("y", 1e9) - safe_y),
            item.get("target_id", ""),
        ))
    else:
        raise SystemExit(f"[v9.4] unsupported target strategy: {target_strategy}")
    selected = candidates[0] if candidates else None
    if selected is None:
        target_not_found_reason = "no_candidate_for_kind"

if selected is None:
    scroll_point = {
        "x": window_x + window_width * 0.55,
        "y": window_y + window_height * 0.55,
    }
    print(json.dumps({
        "event": "open_web_hunter_step_plan",
        "step": step,
        "target_found": False,
        "target_not_found_reason": target_not_found_reason,
        "requested_target_id": requested_target_id,
        "target_id": None,
        "target_kind": target_kind,
        "target_strategy": target_strategy,
        "map_target_count": len(targets),
        "window_bounds": window_bounds,
        "safe_center_ratio": safe_center_ratio,
        "safe_band_px": safe_band_px,
        "damping_factor": 0.0,
        "damping_band": "target_not_found",
        "planned_scroll_delta": {"dx": 0.0, "dy": 0.0},
        "scroll_point": scroll_point,
        "occlusion_clear": False,
        "sticky_occluders": [],
        "ready_to_fire": False,
        "planner_contract": "bounded_hunter_controller_remap_required",
        "posted": False,
    }, sort_keys=True))
    raise SystemExit(0)

point = selected.get("global_coregraphics_point") or {}
window_point = selected.get("window_coregraphics_point") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v9.4] selected target has no global point: {selected}")
if window_point.get("x") is None or window_point.get("y") is None:
    window_point = {"x": float(point["x"]) - window_x, "y": float(point["y"]) - window_y}

pixel_center = selected.get("pixel_center") or {}
occluders = [
    sticky.get("target_id")
    for sticky in sticky_targets
    if inside_bbox(pixel_center, sticky.get("bbox") or {})
]
occlusion_clear = not occluders

safe_center_window_y = window_height * safe_center_ratio
distance_to_safe_center_px = float(window_point["y"]) - safe_center_window_y
abs_distance = abs(distance_to_safe_center_px)

if abs_distance <= safe_band_px:
    factor = 0.0
    planned_scroll_dy = 0.0
    damping_band = "in_safe_band"
elif abs_distance >= 420.0:
    factor = 0.75
    damping_band = "far"
elif abs_distance >= 220.0:
    factor = 0.60
    damping_band = "mid"
elif abs_distance >= 90.0:
    factor = 0.45
    damping_band = "near"
else:
    factor = 0.25
    damping_band = "micro"

if factor:
    raw_abs = abs_distance * factor
    clamped_abs = min(raw_abs, max_scroll_abs, abs_distance * 0.85)
    if abs_distance >= 180.0:
        clamped_abs = max(80.0, clamped_abs)
    else:
        clamped_abs = max(24.0, clamped_abs)
    clamped_abs = min(clamped_abs, max_scroll_abs, abs_distance * 0.85)
    planned_scroll_dy = clamped_abs if distance_to_safe_center_px > 0 else -clamped_abs

ready_to_fire = occlusion_clear and abs_distance <= safe_band_px
scroll_point = {
    "x": window_x + window_width * 0.55,
    "y": window_y + window_height * 0.55,
}

print(json.dumps({
    "event": "open_web_hunter_step_plan",
    "step": step,
    "target_found": True,
    "target_id": selected.get("target_id"),
    "target_kind": selected.get("control_kind"),
    "target_strategy": target_strategy,
    "selected": selected,
    "window_bounds": window_bounds,
    "safe_center_ratio": safe_center_ratio,
    "safe_center_window_y": safe_center_window_y,
    "safe_band_px": safe_band_px,
    "distance_to_safe_center_px": distance_to_safe_center_px,
    "abs_distance_to_safe_center_px": abs_distance,
    "damping_factor": factor,
    "damping_band": damping_band,
    "planned_scroll_delta": {"dx": 0.0, "dy": planned_scroll_dy},
    "scroll_point": scroll_point,
    "occlusion_clear": occlusion_clear,
    "sticky_occluders": occluders,
    "ready_to_fire": ready_to_fire,
    "planner_contract": "bounded_hunter_controller_remap_required",
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
expression = sys.argv[2]
value = payload
for part in expression.split("."):
    value = value[part]
print(value)
PY
}

echo "========================================================================"
echo "Genesis v9.4 Open-Web Hunter Controller"
echo "========================================================================"
echo "[v9.4] URL: $TARGET_URL"
echo "[v9.4] Window title needle: $WINDOW_TITLE"
echo "[v9.4] Target kind: $TARGET_KIND"
echo "[v9.4] Target strategy: $TARGET_STRATEGY"
echo "[v9.4] Max steps: $MAX_STEPS"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V94_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(front_url)"

ARMED=false
if [[ "${GENESIS_V94_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V94_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v9.4] Armed hunter requires GENESIS_V94_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v9.4] ARMED hunter requested. Controller may post bounded scrolls and one click."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v9.4] Dry-run mode. Controller emits one unarmed scroll proposal and stops."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v94-open-web","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v9.4] Accessibility is not trusted; refusing armed open-web hunter")
PY
fi

LOOP_LIMIT="$MAX_STEPS"
if [[ "$ARMED" != true ]]; then
    LOOP_LIMIT="$DRY_RUN_MAX_STEPS"
fi

SCROLL_COUNT=0
FIRED=false
STOP_REASON="max_steps_exceeded"
LAST_PLAN_JSON="{}"
ANY_SCROLL_POSTED=false
MOVE_POSTED=false
CLICK_POSTED=false

for STEP in $(seq 0 $((LOOP_LIMIT - 1))); do
    map_open_web "$STEP"
    STEP_LOG="$OUTPUT_DIR/step_${STEP}_map.log"
    PLAN_JSON="$(plan_step "$STEP_LOG" "$STEP")"
    LAST_PLAN_JSON="$PLAN_JSON"
    echo "$PLAN_JSON"

    TARGET_FOUND="$(json_get "$PLAN_JSON" "target_found")"
    if [[ "$TARGET_FOUND" == "False" || "$TARGET_FOUND" == "false" ]]; then
        STOP_REASON="target_not_found"
        break
    fi

    READY="$(json_get "$PLAN_JSON" "ready_to_fire")"
    if [[ "$READY" == "True" || "$READY" == "true" ]]; then
        POINT_X="$(json_get "$PLAN_JSON" "selected.global_coregraphics_point.x")"
        POINT_Y="$(json_get "$PLAN_JSON" "selected.global_coregraphics_point.y")"
        SELECTED_ID="$(json_get "$PLAN_JSON" "target_id")"

        MOVE_PAYLOAD="$(python3 - "$SELECTED_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "move-v94-open-web-hunter",
    "action_id": f"act-v94-{target_id}-move",
    "act": "move_mouse",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
        MOVE_JSON="$(roundtrip_os_driver "$MOVE_PAYLOAD")"
        echo "{\"event\":\"os_driver_move\",\"move\":$MOVE_JSON}"
        MOVE_POSTED="$(posted_of "$MOVE_JSON")"

        CLICK_PAYLOAD="$(python3 - "$SELECTED_ID" "$POINT_X" "$POINT_Y" <<'PY'
import json
import sys
target_id, x, y = sys.argv[1:4]
print(json.dumps({
    "request_id": "click-v94-open-web-hunter",
    "action_id": f"act-v94-{target_id}",
    "act": "click_point",
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
        CLICK_JSON="$(roundtrip_os_driver "$CLICK_PAYLOAD")"
        echo "{\"event\":\"os_driver_click\",\"click\":$CLICK_JSON}"
        CLICK_POSTED="$(posted_of "$CLICK_JSON")"

        FIRED=true
        STOP_REASON="fired"
        sleep "${GENESIS_V94_POST_CLICK_SETTLE_SEC:-1.0}"
        break
    fi

    SCROLL_X="$(json_get "$PLAN_JSON" "scroll_point.x")"
    SCROLL_Y="$(json_get "$PLAN_JSON" "scroll_point.y")"
    SCROLL_DY="$(json_get "$PLAN_JSON" "planned_scroll_delta.dy")"

    SCROLL_PAYLOAD="$(python3 - "$SCROLL_X" "$SCROLL_Y" "$SCROLL_DX" "$SCROLL_DY" "$STEP" <<'PY'
import json
import sys
x, y, dx, dy, step = sys.argv[1:6]
print(json.dumps({
    "request_id": f"scroll-v94-open-web-hunter-step-{step}",
    "action_id": f"act-v94-open-web-hunter-scroll-step-{step}",
    "act": "scroll_wheel",
    "x": float(x),
    "y": float(y),
    "dx": float(dx),
    "dy": float(dy),
}, sort_keys=True))
PY
)"
    SCROLL_JSON="$(roundtrip_os_driver "$SCROLL_PAYLOAD")"
    echo "{\"event\":\"os_driver_scroll\",\"step\":$STEP,\"scroll\":$SCROLL_JSON}"
    SCROLL_COUNT=$((SCROLL_COUNT + 1))
    if [[ "$(posted_of "$SCROLL_JSON")" == "true" ]]; then
        ANY_SCROLL_POSTED=true
    fi

    if [[ "$ARMED" != true ]]; then
        STOP_REASON="dry_run_projection_stop"
        break
    fi
    sleep "${GENESIS_V94_POST_SCROLL_SETTLE_SEC:-0.8}"
done

POST_URL="$(front_url)"
python3 - "$ARMED" "$FIRED" "$STOP_REASON" "$SCROLL_COUNT" "$ANY_SCROLL_POSTED" "$MOVE_POSTED" "$CLICK_POSTED" "$BASE_URL" "$POST_URL" "$LAST_PLAN_JSON" "$MAX_STEPS" <<'PY'
import json
import sys

armed = sys.argv[1] == "true"
fired = sys.argv[2] == "true"
stop_reason = sys.argv[3]
scroll_count = int(sys.argv[4])
any_scroll_posted = sys.argv[5] == "true"
move_posted = sys.argv[6] == "true"
click_posted = sys.argv[7] == "true"
base_url = sys.argv[8]
post_url = sys.argv[9]
last_plan = json.loads(sys.argv[10])
max_steps = int(sys.argv[11])
url_changed = bool(base_url and post_url and base_url != post_url)

if armed and fired and not click_posted:
    raise SystemExit("[v9.4] armed fired path did not post click")
if not armed and (any_scroll_posted or move_posted or click_posted or url_changed):
    raise SystemExit("[v9.4] dry-run leaked physical state")

print(json.dumps({
    "event": "v94_open_web_hunter_controller_summary",
    "armed": armed,
    "fired": fired,
    "stop_reason": stop_reason,
    "scroll_count": scroll_count,
    "scroll_posted": any_scroll_posted,
    "move_posted": move_posted,
    "click_posted": click_posted,
    "target_found": last_plan.get("target_found"),
    "target_not_found_reason": last_plan.get("target_not_found_reason"),
    "target_id": last_plan.get("target_id"),
    "last_damping_band": last_plan.get("damping_band"),
    "last_damping_factor": last_plan.get("damping_factor"),
    "last_distance_to_safe_center_px": last_plan.get("distance_to_safe_center_px"),
    "last_planned_scroll_delta": last_plan.get("planned_scroll_delta"),
    "base_url": base_url,
    "post_url": post_url,
    "url_changed": url_changed,
    "max_steps": max_steps,
    "posted": any_scroll_posted or move_posted or click_posted,
}, sort_keys=True))
PY

if [[ "$ARMED" == true && "$FIRED" != true ]]; then
    echo "[v9.4] ERROR: armed hunter exhausted max steps without firing" >&2
    exit 1
fi

echo "========================================================================"
echo "Genesis v9.4 open-web hunter controller complete"
echo "========================================================================"
