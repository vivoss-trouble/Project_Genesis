#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V100_MAPPER_BIN:-/tmp/genesis_v100_open_web_shadow_map}"
FOCUS_BIN="${GENESIS_V100_FOCUS_BIN:-/tmp/genesis_v100_ax_focus_web_area}"
OS_SOCKET="${GENESIS_V100_OS_SOCKET:-/tmp/genesis_os_driver_v100.sock}"
DRIVER_LOG="${GENESIS_V100_DRIVER_LOG:-/tmp/genesis_os_driver_v100.log}"
OUTPUT_DIR="${GENESIS_V100_OUTPUT_DIR:-/tmp/genesis_v100_open_web_ax_webarea_key_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V100_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V100_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V100_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V100_BROWSER_BUNDLE_ID:-com.apple.Safari}"
KEY_NAME="${GENESIS_V100_KEY:-page_down}"
POST_KEY_SETTLE_SEC="${GENESIS_V100_POST_KEY_SETTLE_SEC:-0.8}"
ARMED_TOKEN="GENESIS_V100_ARMED_OPEN_WEB_AX_WEBAREA_KEY"
AUTO_KEY_TOKEN="GENESIS_V100_AUTO_KEY_WEBAREA_PROBE"
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
    echo "[v10.0] ERROR: timed out waiting for $socket_path" >&2
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
    echo "[v10.0] ERROR: front browser URL did not settle on $url (current: $current)" >&2
    exit 1
}

map_open_web() {
    local phase="$1"
    local debug_path="$OUTPUT_DIR/${phase}.png"
    local log_path="$OUTPUT_DIR/${phase}.log"
    GENESIS_V81_DEBUG_PNG="$debug_path" \
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V81_WINDOW_OWNER="$BROWSER_APP" \
        "$MAPPER_BIN" | tee "$log_path"
}

analyze_route() {
    local pre_focus_log="$1"
    local pre_key_log="$2"
    local post_key_log="$3"
    local focus_json="$4"
    local key_json="$5"
    local base_url="$6"
    local focus_url="$7"
    local post_url="$8"
    python3 - "$pre_focus_log" "$pre_key_log" "$post_key_log" "$focus_json" "$key_json" "$base_url" "$focus_url" "$post_url" <<'PY'
import json
import sys

(
    pre_focus_log,
    pre_key_log,
    post_key_log,
    focus_raw,
    key_raw,
    base_url,
    focus_url,
    post_url,
) = sys.argv[1:9]

def read_map(path):
    event = None
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw.startswith("{"):
                continue
            payload = json.loads(raw)
            if payload.get("event") == "open_web_shadow_map":
                event = payload
    if event is None:
        raise SystemExit(f"[v10.0] missing map event in {path}")
    return event

pre_focus = read_map(pre_focus_log)
pre_key = read_map(pre_key_log)
post_key = read_map(post_key_log)
focus = json.loads(focus_raw)
key_response = json.loads(key_raw)
receipt = key_response.get("receipt") or {}

def targets_by_id(event):
    return {
        item.get("target_id"): item
        for item in event.get("targets") or []
        if item.get("target_id")
    }

def compare_targets(lhs, rhs):
    lhs_targets = targets_by_id(lhs)
    rhs_targets = targets_by_id(rhs)
    lhs_ids = set(lhs_targets)
    rhs_ids = set(rhs_targets)
    common_ids = sorted(lhs_ids & rhs_ids)
    deltas = []
    for target_id in common_ids:
        lhs_point = lhs_targets[target_id].get("window_coregraphics_point") or {}
        rhs_point = rhs_targets[target_id].get("window_coregraphics_point") or {}
        if lhs_point.get("y") is not None and rhs_point.get("y") is not None:
            deltas.append(float(rhs_point["y"]) - float(lhs_point["y"]))
    max_abs_delta_y = max((abs(value) for value in deltas), default=None)
    mean_delta_y = sum(deltas) / len(deltas) if deltas else None
    signature_changed = lhs_ids != rhs_ids
    visual_change = signature_changed or (
        max_abs_delta_y is not None and max_abs_delta_y >= 2.0
    )
    return {
        "lhs_target_count": len(lhs_ids),
        "rhs_target_count": len(rhs_ids),
        "common_target_count": len(common_ids),
        "target_intersection_ratio": len(common_ids) / max(len(lhs_ids), 1),
        "target_signature_changed": signature_changed,
        "mean_common_target_window_y_delta": mean_delta_y,
        "max_abs_common_target_window_y_delta": max_abs_delta_y,
        "visual_change_detected": visual_change,
    }

focus_compare = compare_targets(pre_focus, pre_key)
key_compare = compare_targets(pre_key, post_key)
url_changed_after_focus = bool(base_url and focus_url and base_url != focus_url)
url_changed_after_key = bool(focus_url and post_url and focus_url != post_url)
key_absorbed_by_content = (
    receipt.get("posted") is True
    and not url_changed_after_key
    and key_compare["visual_change_detected"]
)

print(json.dumps({
    "event": "v100_ax_webarea_key_probe_result",
    "requested_key": receipt.get("key", {}).get("key"),
    "key_status": key_response.get("status"),
    "key_posted": receipt.get("posted"),
    "key_point": receipt.get("point"),
    "cursor_position": receipt.get("cursor_position"),
    "web_area_found": focus.get("web_area_found"),
    "web_area_focus_success": focus.get("web_area_focus_success"),
    "focused_role_after": focus.get("focused_role_after"),
    "set_focused_element_status": focus.get("set_focused_element_status"),
    "set_web_area_focused_status": focus.get("set_web_area_focused_status"),
    "accessibility_api_trusted": focus.get("accessibility_api_trusted"),
    "selected_window_title": focus.get("selected_window_title"),
    "visited_ax_node_count": focus.get("visited_count"),
    "role_counts": focus.get("role_counts"),
    "pre_focus_window_id": pre_focus.get("window_id"),
    "pre_key_window_id": pre_key.get("window_id"),
    "post_key_window_id": post_key.get("window_id"),
    "window_id_stable": pre_focus.get("window_id") == pre_key.get("window_id") == post_key.get("window_id"),
    "base_url": base_url,
    "focus_url": focus_url,
    "post_url": post_url,
    "url_changed_after_focus": url_changed_after_focus,
    "url_changed_after_key": url_changed_after_key,
    "focus_target_signature_changed": focus_compare["target_signature_changed"],
    "focus_visual_change_detected": focus_compare["visual_change_detected"],
    "focus_max_abs_common_target_window_y_delta": focus_compare["max_abs_common_target_window_y_delta"],
    "key_pre_target_count": key_compare["lhs_target_count"],
    "key_post_target_count": key_compare["rhs_target_count"],
    "key_common_target_count": key_compare["common_target_count"],
    "key_target_intersection_ratio": key_compare["target_intersection_ratio"],
    "key_target_signature_changed": key_compare["target_signature_changed"],
    "key_mean_common_target_window_y_delta": key_compare["mean_common_target_window_y_delta"],
    "key_max_abs_common_target_window_y_delta": key_compare["max_abs_common_target_window_y_delta"],
    "key_visual_change_detected": key_compare["visual_change_detected"],
    "key_absorbed_by_content": key_absorbed_by_content,
    "posted": receipt.get("posted"),
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v10.0 Open-Web AX WebArea Key Probe"
echo "========================================================================"
echo "[v10.0] URL: $TARGET_URL"
echo "[v10.0] Browser: $BROWSER_APP"
echo "[v10.0] Window title needle: $WINDOW_TITLE"
echo "[v10.0] Restricted key: $KEY_NAME"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_focus_web_area.swift -o "$FOCUS_BIN"

ARMED=false
if [[ "${GENESIS_V100_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V100_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(front_url)"

map_open_web "pre_focus"
PRE_FOCUS_LOG="$OUTPUT_DIR/pre_focus.log"

FOCUS_JSON="$(
    GENESIS_V100_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V100_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V100_WINDOW_TITLE="$WINDOW_TITLE" \
        "$FOCUS_BIN"
)"
emit "$FOCUS_JSON"
sleep "${GENESIS_V100_POST_FOCUS_SETTLE_SEC:-0.6}"
FOCUS_URL="$(front_url)"

map_open_web "pre_key"
PRE_KEY_LOG="$OUTPUT_DIR/pre_key.log"

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V100_AUTO_KEY_CONFIRM:-}" != "$AUTO_KEY_TOKEN" ]]; then
        echo "[v10.0] Armed AX WebArea key probe requires GENESIS_V100_AUTO_KEY_CONFIRM=$AUTO_KEY_TOKEN" >&2
        exit 1
    fi
    echo "[v10.0] ARMED AX WebArea key probe requested. It will post one bounded key event only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v10.0] Dry-run mode. Restricted key request is routed through unarmed os-driver only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v100-open-web-ax-webarea-key","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v10.0] Accessibility is not trusted; refusing armed key probe")
PY
fi

KEY_PAYLOAD="$(python3 - "$KEY_NAME" <<'PY'
import json
import sys
key_name = sys.argv[1]
print(json.dumps({
    "request_id": "key-v100-open-web-ax-webarea-key",
    "action_id": f"act-v100-open-web-ax-webarea-key-{key_name}",
    "act": "key_press",
    "key": key_name,
}, sort_keys=True))
PY
)"
KEY_JSON="$(roundtrip_os_driver "$KEY_PAYLOAD")"
echo "{\"event\":\"os_driver_key\",\"key\":\"$KEY_NAME\",\"key_response\":$KEY_JSON}"

sleep "$POST_KEY_SETTLE_SEC"
POST_URL="$(front_url)"
map_open_web "post_key"
POST_KEY_LOG="$OUTPUT_DIR/post_key.log"

RESULT_JSON="$(analyze_route "$PRE_FOCUS_LOG" "$PRE_KEY_LOG" "$POST_KEY_LOG" "$FOCUS_JSON" "$KEY_JSON" "$BASE_URL" "$FOCUS_URL" "$POST_URL")"
emit "$RESULT_JSON"

if [[ "$ARMED" == true ]]; then
    ABORT_JSON="$(python3 - "$RESULT_JSON" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
if not result.get("url_changed_after_key"):
    raise SystemExit(0)

print(json.dumps({
    "event": "v100_ax_webarea_key_abort",
    "stop_reason": "url_changed_after_restricted_key",
    "requested_key": result.get("requested_key"),
    "base_url": result.get("base_url"),
    "focus_url": result.get("focus_url"),
    "post_url": result.get("post_url"),
    "key_posted": result.get("key_posted"),
}, sort_keys=True))
PY
)"
    if [[ -n "$ABORT_JSON" ]]; then
        emit "$ABORT_JSON"
        echo "[v10.0] ERROR: armed restricted key changed URL; fail-fast stop engaged" >&2
        exit 2
    fi
fi

SUMMARY_JSON="$(python3 - "$RESULT_JSON" "$ARMED" "$RESULTS_LOG" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
armed = sys.argv[2] == "true"
results_log = sys.argv[3]

if result.get("url_changed_after_focus"):
    raise SystemExit(f"[v10.0] AX WebArea focus changed URL: {result}")
if result.get("url_changed_after_key"):
    raise SystemExit(f"[v10.0] restricted key changed URL: {result}")
if not armed and result.get("key_posted") is not False:
    raise SystemExit(f"[v10.0] dry-run leaked physical key input: {result}")

print(json.dumps({
    "event": "v100_open_web_ax_webarea_key_probe_summary",
    "armed": armed,
    "requested_key": result.get("requested_key"),
    "web_area_found": result.get("web_area_found"),
    "web_area_focus_success": result.get("web_area_focus_success"),
    "focused_role_after": result.get("focused_role_after"),
    "window_id_stable": result.get("window_id_stable"),
    "url_changed_after_focus": result.get("url_changed_after_focus"),
    "url_changed_after_key": result.get("url_changed_after_key"),
    "key_posted": result.get("key_posted"),
    "key_absorbed_by_content": result.get("key_absorbed_by_content"),
    "key_visual_change_detected": result.get("key_visual_change_detected"),
    "posted": result.get("posted"),
    "results_log": results_log,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v10.0 open-web AX WebArea key probe complete"
echo "========================================================================"
