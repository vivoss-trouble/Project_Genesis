#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V98_MAPPER_BIN:-/tmp/genesis_v98_open_web_shadow_map}"
FOCUS_BIN="${GENESIS_V98_FOCUS_BIN:-/tmp/genesis_v98_ax_focus_browser_window}"
OUTPUT_DIR="${GENESIS_V98_OUTPUT_DIR:-/tmp/genesis_v98_open_web_focus_route_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V98_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V98_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V98_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V98_BROWSER_BUNDLE_ID:-com.apple.Safari}"

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
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
    echo "[v9.8] ERROR: front browser URL did not settle on $url (current: $current)" >&2
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

analyze_focus_route() {
    local pre_log="$1"
    local post_log="$2"
    local focus_json="$3"
    local base_url="$4"
    local post_url="$5"
    python3 - "$pre_log" "$post_log" "$focus_json" "$base_url" "$post_url" <<'PY'
import json
import sys

pre_log, post_log, focus_raw, base_url, post_url = sys.argv[1:6]
focus = json.loads(focus_raw)

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
        raise SystemExit(f"[v9.8] missing map event in {path}")
    return event

pre = read_map(pre_log)
post = read_map(post_log)

def targets_by_id(event):
    return {
        item.get("target_id"): item
        for item in event.get("targets") or []
        if item.get("target_id")
    }

pre_targets = targets_by_id(pre)
post_targets = targets_by_id(post)
pre_ids = set(pre_targets)
post_ids = set(post_targets)
common_ids = sorted(pre_ids & post_ids)

deltas = []
for target_id in common_ids:
    pre_point = pre_targets[target_id].get("window_coregraphics_point") or {}
    post_point = post_targets[target_id].get("window_coregraphics_point") or {}
    if pre_point.get("y") is not None and post_point.get("y") is not None:
        deltas.append(float(post_point["y"]) - float(pre_point["y"]))

max_abs_delta_y = max((abs(value) for value in deltas), default=None)
mean_delta_y = sum(deltas) / len(deltas) if deltas else None
signature_changed = pre_ids != post_ids
visual_change_detected = signature_changed or (
    max_abs_delta_y is not None and max_abs_delta_y >= 2.0
)
url_changed = bool(base_url and post_url and base_url != post_url)
ax_statuses = [
    focus.get("set_frontmost_status"),
    focus.get("raise_status"),
    focus.get("set_focused_window_status"),
    focus.get("set_main_status"),
    focus.get("set_focused_status"),
]
ax_success = (
    focus.get("status") == "ok"
    and focus.get("nsworkspace_activate") is True
    and any(status == "success" for status in ax_statuses)
)

print(json.dumps({
    "event": "v98_focus_route_probe_result",
    "ax_success": ax_success,
    "ax_status": focus.get("status"),
    "accessibility_api_trusted": focus.get("accessibility_api_trusted"),
    "selected_window_title": focus.get("selected_window_title"),
    "window_count": focus.get("window_count"),
    "pre_window_id": pre.get("window_id"),
    "post_window_id": post.get("window_id"),
    "window_id_stable": pre.get("window_id") == post.get("window_id"),
    "base_url": base_url,
    "post_url": post_url,
    "url_changed": url_changed,
    "pre_target_count": len(pre_ids),
    "post_target_count": len(post_ids),
    "common_target_count": len(common_ids),
    "target_intersection_ratio": len(common_ids) / max(len(pre_ids), 1),
    "target_signature_changed": signature_changed,
    "mean_common_target_window_y_delta": mean_delta_y,
    "max_abs_common_target_window_y_delta": max_abs_delta_y,
    "visual_change_detected": visual_change_detected,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v9.8 Open-Web Focus Route Probe"
echo "========================================================================"
echo "[v9.8] URL: $TARGET_URL"
echo "[v9.8] Browser: $BROWSER_APP"
echo "[v9.8] Window title needle: $WINDOW_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_focus_browser_window.swift -o "$FOCUS_BIN"

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V98_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(front_url)"

map_open_web "pre"
PRE_LOG="$OUTPUT_DIR/pre.log"

FOCUS_JSON="$(
    GENESIS_V98_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V98_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V98_WINDOW_TITLE="$WINDOW_TITLE" \
        "$FOCUS_BIN"
)"
emit "$FOCUS_JSON"

sleep "${GENESIS_V98_POST_FOCUS_SETTLE_SEC:-0.6}"
POST_URL="$(front_url)"
map_open_web "post"
POST_LOG="$OUTPUT_DIR/post.log"

RESULT_JSON="$(analyze_focus_route "$PRE_LOG" "$POST_LOG" "$FOCUS_JSON" "$BASE_URL" "$POST_URL")"
emit "$RESULT_JSON"

SUMMARY_JSON="$(python3 - "$RESULT_JSON" "$RESULTS_LOG" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
results_log = sys.argv[2]
if result.get("url_changed"):
    raise SystemExit(f"[v9.8] focus route changed URL: {result}")
if result.get("physical_input_posted") or result.get("posted") or result.get("os_driver_active"):
    raise SystemExit(f"[v9.8] focus route leaked physical input: {result}")

print(json.dumps({
    "event": "v98_open_web_focus_route_probe_summary",
    "ax_success": result.get("ax_success"),
    "accessibility_api_trusted": result.get("accessibility_api_trusted"),
    "window_id_stable": result.get("window_id_stable"),
    "url_changed": result.get("url_changed"),
    "visual_change_detected": result.get("visual_change_detected"),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "results_log": results_log,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v9.8 open-web focus route probe complete"
echo "========================================================================"
