#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V120_MAPPER_BIN:-/tmp/genesis_v120_open_web_shadow_map}"
AX_BIN="${GENESIS_V120_AX_BIN:-/tmp/genesis_v120_ax_scroll_to_visible_probe}"
OS_SOCKET="${GENESIS_V120_OS_SOCKET:-/tmp/genesis_os_driver_v120.sock}"
DRIVER_LOG="${GENESIS_V120_DRIVER_LOG:-/tmp/genesis_os_driver_v120.log}"
OUTPUT_DIR="${GENESIS_V120_OUTPUT_DIR:-/tmp/genesis_v120_open_web_pagination_loop}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
START_URL="${GENESIS_V120_URL:-https://doc.rust-lang.org/book/}"
BASE_URL="${GENESIS_V120_BASE_URL:-https://doc.rust-lang.org/book/}"
URL_DOMAIN_LOCK="${GENESIS_V120_URL_DOMAIN_LOCK:-rust-lang.org}"
WINDOW_TITLE="${GENESIS_V120_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V120_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V120_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_TITLE="${GENESIS_V120_TARGET_TITLE:-Next chapter}"
MAX_STEPS="${GENESIS_V120_MAX_STEPS:-3}"
MAX_SAME_URL_COUNT="${GENESIS_V120_MAX_SAME_URL_COUNT:-1}"
TARGET_NOT_FOUND_TERMINAL_OK="${GENESIS_V120_TARGET_NOT_FOUND_TERMINAL_OK:-1}"
STOP_TITLE_CONTAINS="${GENESIS_V120_STOP_TITLE_CONTAINS:-}"
ARMED_TOKEN="GENESIS_V120_ARMED_OPEN_WEB_PAGINATION_LOOP"
AUTO_FIRE_TOKEN="GENESIS_V120_AUTO_FIRE_PAGINATION_LOOP"
DRIVER_PID=""
SHADOW_STABLE_LOG=""

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

json_get() {
    local payload="$1"
    local expression="$2"
    python3 - "$payload" "$expression" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

json_add_step() {
    local payload="$1"
    local step_id="$2"
    python3 - "$payload" "$step_id" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["step_id"] = sys.argv[2]
print(json.dumps(payload, sort_keys=True))
PY
}

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v12.0] ERROR: timed out waiting for $socket_path" >&2
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
        osascript - "$BASE_URL" "$WINDOW_TITLE" <<'OSA'
on run argv
    set baseUrl to item 1 of argv
    set titleNeedle to item 2 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontUrl to URL of front document
                set frontName to name of front document
                if frontUrl starts with baseUrl then return frontUrl
                if frontName contains titleNeedle then return frontUrl
            end try
        end if
        repeat with candidate in documents
            try
                set candidateUrl to URL of candidate
                set candidateName to name of candidate
                if candidateUrl starts with baseUrl then return candidateUrl
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

target_document_title() {
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$BASE_URL" "$WINDOW_TITLE" <<'OSA'
on run argv
    set baseUrl to item 1 of argv
    set titleNeedle to item 2 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontUrl to URL of front document
                set frontName to name of front document
                if frontUrl starts with baseUrl then return frontName
                if frontName contains titleNeedle then return frontName
            end try
        end if
        repeat with candidate in documents
            try
                set candidateUrl to URL of candidate
                set candidateName to name of candidate
                if candidateUrl starts with baseUrl then return candidateName
                if candidateName contains titleNeedle then return candidateName
            end try
        end repeat
        if not (exists front document) then return ""
        return name of front document
    end tell
end run
OSA
    else
        printf ''
    fi
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v120_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v12.0] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

wait_for_url_contains() {
    local needle="$1"
    local timeout_sec="${2:-12}"
    local current=""
    local deadline=$((SECONDS + timeout_sec))
    while (( SECONDS <= deadline )); do
        current="$(target_document_url || true)"
        if [[ "$current" == *"$needle"* ]]; then
            return
        fi
        sleep 0.25
    done
    echo "[v12.0] ERROR: URL did not satisfy '$needle' (current: $current)" >&2
    exit 4
}

wait_for_url_change() {
    local previous_url="$1"
    local timeout_sec="${2:-12}"
    local current=""
    local deadline=$((SECONDS + timeout_sec))
    while (( SECONDS <= deadline )); do
        current="$(target_document_url || true)"
        if [[ -n "$current" && "$current" != "$previous_url" ]]; then
            echo "$current"
            return
        fi
        sleep 0.25
    done
    echo "$current"
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
    local attempts="${GENESIS_V120_MAP_TARGET_ATTEMPTS:-12}"
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
    echo "[v12.0] ERROR: failed to capture target window matching title '$WINDOW_TITLE'" >&2
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
        print(f"GENESIS_V120_POINT_X={float(point['x'])}")
        print(f"GENESIS_V120_POINT_Y={float(point['y'])}")
        break
PY
}

assess_tractor_target() {
    local step_id="$1"
    local post_log="$2"
    local ax_json="$3"
    python3 - "$step_id" "$post_log" "$ax_json" <<'PY'
import json
import math
import sys

step_id, post_log, ax_raw = sys.argv[1:4]
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
    raise SystemExit("[v12.0] missing post-tractor Shadow Map")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v12.0] Shadow Map must remain read-only: {event}")

target_frame = ax.get("target_frame_after_action")
if not isinstance(target_frame, dict):
    target_frame = (ax.get("selected_target") or {}).get("frame")
if not isinstance(target_frame, dict):
    raise SystemExit(f"[v12.0] missing AX target frame: {ax}")

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
    "event": "v120_pagination_step_target",
    "step_id": step_id,
    "target_found": ax.get("target_found") is True,
    "candidate_count": ax.get("candidate_count"),
    "visible_candidate_count": ax.get("visible_candidate_count"),
    "survivor_count": ax.get("survivor_count"),
    "selection_policy": ax.get("selection_policy"),
    "selected_candidate_index": ax.get("selected_candidate_index"),
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

shadow_signature() {
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
    raise SystemExit(1)
targets = event.get("targets") or []
signature = {
    "window_name": event.get("window_name"),
    "target_count": len(targets),
    "kinds": sorted(set(t.get("control_kind") for t in targets)),
    "ids": [t.get("target_id") for t in targets[:12]],
}
print(json.dumps(signature, sort_keys=True))
PY
}

shadow_settle() {
    local step_id="$1"
    local previous_sig=""
    local attempts="${GENESIS_V120_SHADOW_SETTLE_ATTEMPTS:-8}"
    SHADOW_STABLE_LOG=""

    for attempt in $(seq 1 "$attempts"); do
        local phase="${step_id}_settle_${attempt}"
        map_open_web "$phase"
        local log_path="$OUTPUT_DIR/${phase}.log"
        local sig
        sig="$(shadow_signature "$log_path")"
        if [[ -n "$previous_sig" && "$sig" == "$previous_sig" ]]; then
            SHADOW_STABLE_LOG="$log_path"
            emit "$(python3 - "$step_id" "$attempt" "$sig" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v120_shadow_settle",
    "step_id": sys.argv[1],
    "settle_attempt": int(sys.argv[2]),
    "shadow_stable": True,
    "signature": json.loads(sys.argv[3]),
    "posted": False,
}, sort_keys=True))
PY
)"
            return
        fi
        previous_sig="$sig"
        sleep "${GENESIS_V120_SHADOW_SETTLE_INTERVAL_SEC:-0.35}"
    done

    emit "$(python3 - "$step_id" "$previous_sig" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v120_shadow_settle",
    "step_id": sys.argv[1],
    "shadow_stable": False,
    "signature": json.loads(sys.argv[2]) if sys.argv[2] else {},
    "posted": False,
}, sort_keys=True))
PY
)"
    echo "[v12.0] ERROR: shadow did not settle for $step_id" >&2
    exit 5
}

post_action() {
    local step_id="$1"
    local action="$2"
    local x="$3"
    local y="$4"
    local request_action="$5"
    local payload
    payload="$(python3 - "$step_id" "$action" "$x" "$y" "$request_action" <<'PY'
import json
import sys
step_id, action, x, y, request_action = sys.argv[1:6]
print(json.dumps({
    "request_id": f"{action}-v120-{step_id}",
    "action_id": f"act-v120-{step_id}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

run_pagination_step() {
    local step_index="$1"
    local current_url="$2"
    local step_id="step-${step_index}-next-chapter"

    emit "$(python3 - "$step_id" "$step_index" "$current_url" "$TARGET_TITLE" "$MAX_STEPS" <<'PY'
import json
import sys
step_id, step_index, current_url, target_title, max_steps = sys.argv[1:6]
print(json.dumps({
    "event": "v120_pagination_step_start",
    "step_id": step_id,
    "step_index": int(step_index),
    "from_url": current_url,
    "target_title": target_title,
    "max_steps": int(max_steps),
    "resolution_policy": {
        "prefer": ["visible"],
        "require": ["occlusion_clear_after_traction"],
        "tie_breaker": "max_y",
        "log_telemetry": ["candidate_count", "visible_candidate_count", "survivor_count"],
    },
    "posted": False,
}, sort_keys=True))
PY
)"

    map_open_web "${step_id}_pre"
    local pre_log="$OUTPUT_DIR/${step_id}_pre.log"
    local point_env point_x="" point_y=""
    point_env="$(extract_marker_point_env "$pre_log" || true)"
    if [[ -n "$point_env" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                GENESIS_V120_POINT_X) point_x="$value" ;;
                GENESIS_V120_POINT_Y) point_y="$value" ;;
            esac
        done <<< "$point_env"
    fi

    local ax_json
    ax_json="$(
        GENESIS_V103_BROWSER_APP="$BROWSER_APP" \
        GENESIS_V103_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
        GENESIS_V103_WINDOW_TITLE="$WINDOW_TITLE" \
        GENESIS_V103_AX_TARGET_TITLE="$TARGET_TITLE" \
        GENESIS_V103_AX_EXECUTE="$([[ "$ARMED" == true ]] && echo 1 || echo 0)" \
        GENESIS_V103_TARGET_REQUIRE_VISIBLE="0" \
        GENESIS_V103_TARGET_PREFER_VISIBLE="1" \
        GENESIS_V103_TARGET_TIE_BREAKER="max_y" \
        GENESIS_V103_POINT_X="$point_x" \
        GENESIS_V103_POINT_Y="$point_y" \
            "$AX_BIN"
    )"
    ax_json="$(json_add_step "$ax_json" "$step_id")"
    emit "$ax_json"

    local target_found
    target_found="$(json_get "$ax_json" "target_found")"
    if [[ "$target_found" != "True" && "$target_found" != "true" ]]; then
        if [[ "$TARGET_NOT_FOUND_TERMINAL_OK" == "1" ]]; then
            emit "$(python3 - "$step_id" "$current_url" "$ax_json" <<'PY'
import json
import sys
step_id, current_url, ax_raw = sys.argv[1:4]
ax = json.loads(ax_raw)
print(json.dumps({
    "event": "v120_pagination_terminal",
    "step_id": step_id,
    "terminal_success": True,
    "stop_reason": "target_not_found_terminal",
    "current_url": current_url,
    "candidate_count": ax.get("candidate_count"),
    "visible_candidate_count": ax.get("visible_candidate_count"),
    "survivor_count": ax.get("survivor_count"),
    "posted": False,
}, sort_keys=True))
PY
)"
            return 20
        fi
        echo "[v12.0] ERROR: $step_id target not found" >&2
        exit 2
    fi

    sleep "${GENESIS_V120_POST_AX_SETTLE_SEC:-1.0}"
    local post_ax_url
    post_ax_url="$(target_document_url)"
    map_open_web "${step_id}_post_tractor"
    local post_ax_log="$OUTPUT_DIR/${step_id}_post_tractor.log"

    local target_json
    target_json="$(assess_tractor_target "$step_id" "$post_ax_log" "$ax_json")"
    emit "$target_json"

    local occlusion_clear click_x click_y
    occlusion_clear="$(json_get "$target_json" "occlusion_clear")"
    click_x="$(json_get "$target_json" "click_point.x")"
    click_y="$(json_get "$target_json" "click_point.y")"

    if [[ "$ARMED" != true ]]; then
        emit "$(python3 - "$step_id" "$current_url" "$post_ax_url" "$target_json" <<'PY'
import json
import sys
step_id, from_url, post_ax_url, target_raw = sys.argv[1:5]
target = json.loads(target_raw)
print(json.dumps({
    "event": "v120_pagination_step_summary",
    "step_id": step_id,
    "armed": False,
    "step_complete": False,
    "stop_reason": "dry_run_projection_stop",
    "from_url": from_url,
    "post_ax_url": post_ax_url,
    "target_found": target.get("target_found"),
    "candidate_count": target.get("candidate_count"),
    "visible_candidate_count": target.get("visible_candidate_count"),
    "survivor_count": target.get("survivor_count"),
    "occlusion_clear": target.get("occlusion_clear"),
    "move_posted": False,
    "click_posted": False,
    "url_changed": False,
    "shadow_stable": False,
    "reanchor_ok": False,
    "posted": False,
}, sort_keys=True))
PY
)"
        return 10
    fi

    if [[ "$occlusion_clear" != "True" && "$occlusion_clear" != "true" ]]; then
        emit "$(python3 - "$step_id" "$current_url" "$target_json" <<'PY'
import json
import sys
step_id, current_url, target_raw = sys.argv[1:4]
target = json.loads(target_raw)
print(json.dumps({
    "event": "v120_redline_stop",
    "step_id": step_id,
    "stop_reason": "occlusion_not_clear",
    "current_url": current_url,
    "target": target,
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v12.0] ERROR: $step_id target is not clear after traction" >&2
        exit 2
    fi

    local move_json click_json
    move_json="$(post_action "$step_id" "move" "$click_x" "$click_y" "move_mouse")"
    emit "$(python3 - "$step_id" "$move_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "step_id": sys.argv[1], "move": json.loads(sys.argv[2])}, sort_keys=True))
PY
)"
    click_json="$(post_action "$step_id" "click" "$click_x" "$click_y" "click_point")"
    emit "$(python3 - "$step_id" "$click_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "step_id": sys.argv[1], "click": json.loads(sys.argv[2])}, sort_keys=True))
PY
)"

    local new_url
    new_url="$(wait_for_url_change "$current_url" "${GENESIS_V120_URL_GATE_TIMEOUT_SEC:-12}")"
    assert_domain_lock "$new_url"
    shadow_settle "$step_id"
    local stable_log="$SHADOW_STABLE_LOG"

    local summary_json
    summary_json="$(python3 - "$step_id" "$current_url" "$new_url" "$post_ax_url" "$target_json" "$move_json" "$click_json" "$stable_log" <<'PY'
import json
import math
import sys

step_id, from_url, to_url, post_ax_url, target_raw, move_raw, click_raw, stable_log = sys.argv[1:9]
target = json.loads(target_raw)
move = json.loads(move_raw)
click = json.loads(click_raw)
expected = target.get("click_point") or {}

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v12.0] {step_id} {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not True:
        raise SystemExit(f"[v12.0] {step_id} {label} did not post: {payload}")
    point = receipt.get("point") or {}
    if math.hypot(point.get("x", 1e9) - expected["x"], point.get("y", 1e9) - expected["y"]) > 0.001:
        raise SystemExit(f"[v12.0] {step_id} {label} point drifted from target: {payload}")

stable_map = None
with open(stable_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "open_web_shadow_map":
                stable_map = payload
if stable_map is None:
    raise SystemExit(f"[v12.0] {step_id} missing stable map")

url_changed = to_url != from_url
print(json.dumps({
    "event": "v120_pagination_step_summary",
    "step_id": step_id,
    "armed": True,
    "step_complete": url_changed,
    "target_title": (target.get("selected_target") or {}).get("title"),
    "candidate_count": target.get("candidate_count"),
    "visible_candidate_count": target.get("visible_candidate_count"),
    "survivor_count": target.get("survivor_count"),
    "selected_candidate_index": target.get("selected_candidate_index"),
    "occlusion_clear": target.get("occlusion_clear"),
    "from_url": from_url,
    "post_ax_url": post_ax_url,
    "to_url": to_url,
    "url_changed": url_changed,
    "shadow_stable": True,
    "reanchor_ok": url_changed,
    "move_posted": (move.get("receipt") or {}).get("posted"),
    "click_posted": (click.get("receipt") or {}).get("posted"),
    "stable_window_name": stable_map.get("window_name"),
    "posted": True,
}, sort_keys=True))
PY
)"
    emit "$summary_json"

    if [[ "$new_url" == "$current_url" ]]; then
        return 11
    fi
    printf '%s\n' "$new_url" > "$OUTPUT_DIR/.next_url"
    return 0
}

echo "========================================================================"
echo "Genesis v12.0 Open-Web Pagination Loop"
echo "========================================================================"
echo "[v12.0] URL: $START_URL"
echo "[v12.0] Browser: $BROWSER_APP"
echo "[v12.0] Window title needle: $WINDOW_TITLE"
echo "[v12.0] Target: $TARGET_TITLE"
echo "[v12.0] Max steps: $MAX_STEPS"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_scroll_to_visible_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V120_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V120_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v12.0] Armed pagination requires GENESIS_V120_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v12.0] ARMED pagination requested. It will post bounded clicks only."
else
    echo "[v12.0] Dry-run mode. It will project one pagination step and stop before mutation."
fi

open_target_url "$START_URL"
wait_for_url_contains "${GENESIS_V120_INITIAL_URL_CONTAINS:-book/}" 12
sleep "${GENESIS_V120_BROWSER_SETTLE_SEC:-2.5}"

if [[ "$ARMED" == true ]]; then
    rm -f "$OS_SOCKET" "$DRIVER_LOG"
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
    DRIVER_PID=$!
    wait_for_socket "$OS_SOCKET"
    PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v120-open-web-pagination","act":"probe"}')"
    emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v12.0] Accessibility is not trusted; refusing pagination")
PY
fi

current_url="$(target_document_url)"
assert_domain_lock "$current_url"
same_url_count=0
steps_completed=0
PAGINATION_COMPLETE=true
TERMINAL_SUCCESS=false
STOP_REASON="max_steps_reached"

for step_index in $(seq 0 $((MAX_STEPS - 1))); do
    current_title="$(target_document_title || true)"
    if [[ -n "$STOP_TITLE_CONTAINS" && "$current_title" == *"$STOP_TITLE_CONTAINS"* ]]; then
        TERMINAL_SUCCESS=true
        STOP_REASON="stop_title_contains"
        break
    fi

    set +e
    run_pagination_step "$step_index" "$current_url"
    status=$?
    set -e

    if [[ "$status" == "10" ]]; then
        PAGINATION_COMPLETE=false
        STOP_REASON="dry_run_projection_stop"
        break
    elif [[ "$status" == "20" ]]; then
        TERMINAL_SUCCESS=true
        STOP_REASON="target_not_found_terminal"
        break
    elif [[ "$status" == "11" ]]; then
        same_url_count=$((same_url_count + 1))
        if (( same_url_count >= MAX_SAME_URL_COUNT )); then
            emit "$(python3 - "$current_url" "$same_url_count" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v120_redline_stop",
    "stop_reason": "same_url_deadlock",
    "url": sys.argv[1],
    "same_url_count": int(sys.argv[2]),
    "posted": False,
}, sort_keys=True))
PY
)"
            echo "[v12.0] ERROR: same URL deadlock at $current_url" >&2
            exit 7
        fi
    elif [[ "$status" != "0" ]]; then
        exit "$status"
    else
        same_url_count=0
        current_url="$(cat "$OUTPUT_DIR/.next_url")"
        steps_completed=$((steps_completed + 1))
        assert_domain_lock "$current_url"
    fi
done

emit "$(python3 - "$ARMED" "$PAGINATION_COMPLETE" "$TERMINAL_SUCCESS" "$STOP_REASON" "$steps_completed" "$MAX_STEPS" "$current_url" "$RESULTS_LOG" <<'PY'
import json
import sys
armed, complete, terminal, stop_reason, steps_completed, max_steps, current_url, results_log = sys.argv[1:9]
print(json.dumps({
    "event": "v120_open_web_pagination_loop_summary",
    "armed": armed == "true",
    "pagination_complete": complete == "true",
    "terminal_success": terminal == "true",
    "stop_reason": stop_reason,
    "steps_completed": int(steps_completed),
    "max_steps": int(max_steps),
    "current_url": current_url,
    "results_log": results_log,
    "posted": armed == "true",
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v12.0 open-web pagination loop complete"
echo "========================================================================"
