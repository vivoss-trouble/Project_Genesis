#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V110_MAPPER_BIN:-/tmp/genesis_v110_open_web_shadow_map}"
AX_BIN="${GENESIS_V110_AX_BIN:-/tmp/genesis_v110_ax_scroll_to_visible_probe}"
OS_SOCKET="${GENESIS_V110_OS_SOCKET:-/tmp/genesis_os_driver_v110.sock}"
DRIVER_LOG="${GENESIS_V110_DRIVER_LOG:-/tmp/genesis_os_driver_v110.log}"
OUTPUT_DIR="${GENESIS_V110_OUTPUT_DIR:-/tmp/genesis_v110_open_web_conditional_sequence}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
START_URL="${GENESIS_V110_URL:-https://doc.rust-lang.org/book/}"
BASE_URL="${GENESIS_V110_BASE_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V110_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V110_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V110_BROWSER_BUNDLE_ID:-com.apple.Safari}"
ARMED_TOKEN="GENESIS_V110_ARMED_OPEN_WEB_CONDITIONAL_SEQUENCE"
AUTO_FIRE_TOKEN="GENESIS_V110_AUTO_FIRE_CONDITIONAL_SEQUENCE"
DRIVER_PID=""
SHADOW_STABLE_LOG=""

STEP_IDS=("step-0-final-project" "step-1-next-chapter")
STEP_TARGETS=("Final Project" "Next chapter")
STEP_EXPECT_URLS=("ch21-00-final-project-a-web-server.html" "ch21-01-single-threaded.html")
STEP_EXPECT_TITLES=("Final Project" "Single-Threaded")
STEP_SOURCE_TITLES=("The Rust Programming Language" "Final Project")
STEP_REQUIRE_VISIBLE=("0" "0")
STEP_PREFER_VISIBLE=("0" "1")
STEP_TIE_BREAKERS=("first" "max_y")

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
    echo "[v11.0] ERROR: timed out waiting for $socket_path" >&2
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
    echo "[v11.0] ERROR: URL did not satisfy '$needle' (current: $current)" >&2
    exit 4
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
    local attempts="${GENESIS_V110_MAP_TARGET_ATTEMPTS:-12}"
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
    echo "[v11.0] ERROR: failed to capture target window matching title '$WINDOW_TITLE'" >&2
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
        print(f"GENESIS_V110_POINT_X={float(point['x'])}")
        print(f"GENESIS_V110_POINT_Y={float(point['y'])}")
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
    raise SystemExit("[v11.0] missing post-tractor Shadow Map")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v11.0] Shadow Map must remain read-only: {event}")

target_frame = ax.get("target_frame_after_action")
if not isinstance(target_frame, dict):
    target_frame = (ax.get("selected_target") or {}).get("frame")
if not isinstance(target_frame, dict):
    raise SystemExit(f"[v11.0] missing AX target frame: {ax}")

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
    "event": "v110_sequence_step_target",
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
    local expected_title="$2"
    local previous_sig=""
    local attempts="${GENESIS_V110_SHADOW_SETTLE_ATTEMPTS:-8}"
    SHADOW_STABLE_LOG=""

    for attempt in $(seq 1 "$attempts"); do
        local phase="${step_id}_settle_${attempt}"
        map_open_web "$phase"
        local log_path="$OUTPUT_DIR/${phase}.log"
        local sig
        sig="$(shadow_signature "$log_path")"
        local title_ok
        title_ok="$(python3 - "$log_path" "$expected_title" <<'PY'
import json
import sys

log_path, expected = sys.argv[1:3]
expected = expected.lower()
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "open_web_shadow_map":
                event = payload
name = (event or {}).get("window_name") or ""
print("true" if expected in name.lower() else "false")
PY
)"
        if [[ "$title_ok" == "true" && -n "$previous_sig" && "$sig" == "$previous_sig" ]]; then
            SHADOW_STABLE_LOG="$log_path"
            emit "$(python3 - "$step_id" "$attempt" "$sig" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v110_shadow_settle",
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
        sleep "${GENESIS_V110_SHADOW_SETTLE_INTERVAL_SEC:-0.35}"
    done

    emit "$(python3 - "$step_id" "$previous_sig" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v110_shadow_settle",
    "step_id": sys.argv[1],
    "shadow_stable": False,
    "signature": json.loads(sys.argv[2]) if sys.argv[2] else {},
    "posted": False,
}, sort_keys=True))
PY
)"
    echo "[v11.0] ERROR: shadow did not settle for $step_id" >&2
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
    "request_id": f"{action}-v110-{step_id}",
    "action_id": f"act-v110-{step_id}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

run_step() {
    local index="$1"
    local step_id="${STEP_IDS[$index]}"
    local target_title="${STEP_TARGETS[$index]}"
    local expect_url="${STEP_EXPECT_URLS[$index]}"
    local expect_title="${STEP_EXPECT_TITLES[$index]}"
    local source_title="${STEP_SOURCE_TITLES[$index]}"
    local require_visible="${STEP_REQUIRE_VISIBLE[$index]}"
    local prefer_visible="${STEP_PREFER_VISIBLE[$index]}"
    local tie_breaker="${STEP_TIE_BREAKERS[$index]}"

    emit "$(python3 - "$step_id" "$target_title" "$expect_url" "$expect_title" "$require_visible" "$prefer_visible" "$tie_breaker" <<'PY'
import json
import sys
step_id, target_title, expect_url, expect_title, require_visible, prefer_visible, tie_breaker = sys.argv[1:8]
require = ["occlusion_clear_after_traction"]
if require_visible == "1":
    require = ["visible", "occlusion_clear"]
elif prefer_visible == "1":
    require = ["prefer_visible", "occlusion_clear_after_traction"]
print(json.dumps({
    "event": "v110_sequence_step_start",
    "step_id": step_id,
    "target_title": target_title,
    "expect_url_contains": expect_url,
    "expect_window_title_contains": expect_title,
    "resolution_policy": {
        "require": require,
        "tie_breaker": tie_breaker,
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
                GENESIS_V110_POINT_X) point_x="$value" ;;
                GENESIS_V110_POINT_Y) point_y="$value" ;;
            esac
        done <<< "$point_env"
    fi

    local ax_json
    ax_json="$(
        GENESIS_V103_BROWSER_APP="$BROWSER_APP" \
        GENESIS_V103_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
        GENESIS_V103_WINDOW_TITLE="$source_title" \
        GENESIS_V103_AX_TARGET_TITLE="$target_title" \
        GENESIS_V103_AX_EXECUTE="$([[ "$ARMED" == true ]] && echo 1 || echo 0)" \
        GENESIS_V103_TARGET_REQUIRE_VISIBLE="$require_visible" \
        GENESIS_V103_TARGET_PREFER_VISIBLE="$prefer_visible" \
        GENESIS_V103_TARGET_TIE_BREAKER="$tie_breaker" \
        GENESIS_V103_POINT_X="$point_x" \
        GENESIS_V103_POINT_Y="$point_y" \
            "$AX_BIN"
    )"
    ax_json="$(json_add_step "$ax_json" "$step_id")"
    emit "$ax_json"

    sleep "${GENESIS_V110_POST_AX_SETTLE_SEC:-1.0}"
    local post_ax_url
    post_ax_url="$(target_document_url)"
    map_open_web "${step_id}_post_tractor"
    local post_ax_log="$OUTPUT_DIR/${step_id}_post_tractor.log"

    local target_json
    target_json="$(assess_tractor_target "$step_id" "$post_ax_log" "$ax_json")"
    emit "$target_json"

    local target_found occlusion_clear point_x point_y
    target_found="$(json_get "$target_json" "target_found")"
    occlusion_clear="$(json_get "$target_json" "occlusion_clear")"
    point_x="$(json_get "$target_json" "click_point.x")"
    point_y="$(json_get "$target_json" "click_point.y")"

    if [[ "$target_found" != "True" && "$target_found" != "true" ]]; then
        echo "[v11.0] ERROR: $step_id target not found" >&2
        exit 2
    fi

    if [[ "$ARMED" != true ]]; then
        emit "$(python3 - "$step_id" "$post_ax_url" "$target_json" <<'PY'
import json
import sys
step_id, post_ax_url, target_raw = sys.argv[1:4]
target = json.loads(target_raw)
print(json.dumps({
    "event": "v110_sequence_step_summary",
    "step_id": step_id,
    "armed": False,
    "step_complete": False,
    "stop_reason": "dry_run_projection_stop",
    "post_ax_url": post_ax_url,
    "target_found": target.get("target_found"),
    "candidate_count": target.get("candidate_count"),
    "visible_candidate_count": target.get("visible_candidate_count"),
    "survivor_count": target.get("survivor_count"),
    "occlusion_clear": target.get("occlusion_clear"),
    "move_posted": False,
    "click_posted": False,
    "url_assert": False,
    "shadow_stable": False,
    "reanchor_ok": False,
    "posted": False,
}, sort_keys=True))
PY
)"
        return 10
    fi

    if [[ "$occlusion_clear" != "True" && "$occlusion_clear" != "true" ]]; then
        echo "[v11.0] ERROR: $step_id target is not clear after traction" >&2
        exit 2
    fi

    local move_json click_json
    move_json="$(post_action "$step_id" "move" "$point_x" "$point_y" "move_mouse")"
    emit "$(python3 - "$step_id" "$move_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "step_id": sys.argv[1], "move": json.loads(sys.argv[2])}, sort_keys=True))
PY
)"
    click_json="$(post_action "$step_id" "click" "$point_x" "$point_y" "click_point")"
    emit "$(python3 - "$step_id" "$click_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "step_id": sys.argv[1], "click": json.loads(sys.argv[2])}, sort_keys=True))
PY
)"

    wait_for_url_contains "$expect_url" "${GENESIS_V110_URL_GATE_TIMEOUT_SEC:-12}"
    local post_click_url
    post_click_url="$(target_document_url)"
    shadow_settle "$step_id" "$expect_title"
    local stable_log="$SHADOW_STABLE_LOG"

    local summary_json
    summary_json="$(python3 - "$step_id" "$expect_url" "$expect_title" "$post_ax_url" "$post_click_url" "$target_json" "$move_json" "$click_json" "$stable_log" <<'PY'
import json
import math
import sys

step_id, expect_url, expect_title, post_ax_url, post_click_url, target_raw, move_raw, click_raw, stable_log = sys.argv[1:10]
target = json.loads(target_raw)
move = json.loads(move_raw)
click = json.loads(click_raw)
expected = target.get("click_point") or {}

for label, payload in [("move", move), ("click", click)]:
    if payload.get("status") != "ok":
        raise SystemExit(f"[v11.0] {step_id} {label} failed: {payload}")
    receipt = payload.get("receipt") or {}
    if receipt.get("posted") is not True:
        raise SystemExit(f"[v11.0] {step_id} {label} did not post: {payload}")
    point = receipt.get("point") or {}
    if math.hypot(point.get("x", 1e9) - expected["x"], point.get("y", 1e9) - expected["y"]) > 0.001:
        raise SystemExit(f"[v11.0] {step_id} {label} point drifted from target: {payload}")

stable_map = None
with open(stable_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "open_web_shadow_map":
                stable_map = payload
if stable_map is None:
    raise SystemExit(f"[v11.0] {step_id} missing stable map")

url_assert = expect_url in post_click_url
title_assert = expect_title.lower() in (stable_map.get("window_name") or "").lower()
print(json.dumps({
    "event": "v110_sequence_step_summary",
    "step_id": step_id,
    "armed": True,
    "step_complete": url_assert and title_assert,
    "target_title": (target.get("selected_target") or {}).get("title"),
    "candidate_count": target.get("candidate_count"),
    "visible_candidate_count": target.get("visible_candidate_count"),
    "survivor_count": target.get("survivor_count"),
    "selected_candidate_index": target.get("selected_candidate_index"),
    "occlusion_clear": target.get("occlusion_clear"),
    "post_ax_url": post_ax_url,
    "post_click_url": post_click_url,
    "url_assert": url_assert,
    "title_assert": title_assert,
    "shadow_stable": True,
    "reanchor_ok": url_assert and title_assert,
    "move_posted": (move.get("receipt") or {}).get("posted"),
    "click_posted": (click.get("receipt") or {}).get("posted"),
    "posted": True,
}, sort_keys=True))
PY
)"
    emit "$summary_json"
}

echo "========================================================================"
echo "Genesis v11.0 Open-Web Conditional Sequence"
echo "========================================================================"
echo "[v11.0] URL: $START_URL"
echo "[v11.0] Browser: $BROWSER_APP"
echo "[v11.0] Window title needle: $WINDOW_TITLE"
echo "[v11.0] Steps: ${STEP_IDS[*]}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_scroll_to_visible_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V110_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V110_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v11.0] Armed sequence requires GENESIS_V110_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v11.0] ARMED conditional sequence requested. It will post bounded clicks only."
else
    echo "[v11.0] Dry-run mode. It will project step 0 and stop before mutation."
fi

open_target_url "$START_URL"
wait_for_url_contains "${GENESIS_V110_INITIAL_URL_CONTAINS:-book/}" 12
sleep "${GENESIS_V110_BROWSER_SETTLE_SEC:-2.5}"

if [[ "$ARMED" == true ]]; then
    rm -f "$OS_SOCKET" "$DRIVER_LOG"
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
    DRIVER_PID=$!
    wait_for_socket "$OS_SOCKET"
    PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v110-open-web-sequence","act":"probe"}')"
    emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v11.0] Accessibility is not trusted; refusing sequence")
PY
fi

SEQUENCE_COMPLETE=true
STOP_REASON="complete"
for index in "${!STEP_IDS[@]}"; do
    set +e
    run_step "$index"
    status=$?
    set -e
    if [[ "$status" == "10" ]]; then
        SEQUENCE_COMPLETE=false
        STOP_REASON="dry_run_projection_stop"
        break
    elif [[ "$status" != "0" ]]; then
        exit "$status"
    fi
done

emit "$(python3 - "$ARMED" "$SEQUENCE_COMPLETE" "$STOP_REASON" "$RESULTS_LOG" <<'PY'
import json
import sys
armed, complete, stop_reason, results_log = sys.argv[1:5]
print(json.dumps({
    "event": "v110_open_web_conditional_sequence_summary",
    "armed": armed == "true",
    "sequence_complete": complete == "true",
    "stop_reason": stop_reason,
    "results_log": results_log,
    "posted": armed == "true",
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v11.0 open-web conditional sequence complete"
echo "========================================================================"
