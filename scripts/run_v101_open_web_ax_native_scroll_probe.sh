#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V101_MAPPER_BIN:-/tmp/genesis_v101_open_web_shadow_map}"
AX_BIN="${GENESIS_V101_AX_BIN:-/tmp/genesis_v101_ax_native_scroll_probe}"
OUTPUT_DIR="${GENESIS_V101_OUTPUT_DIR:-/tmp/genesis_v101_open_web_ax_native_scroll_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V101_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V101_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V101_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V101_BROWSER_BUNDLE_ID:-com.apple.Safari}"
POST_AX_SETTLE_SEC="${GENESIS_V101_POST_AX_SETTLE_SEC:-0.8}"
ARMED_TOKEN="GENESIS_V101_ARMED_OPEN_WEB_AX_NATIVE_SCROLL"
AUTO_AX_TOKEN="GENESIS_V101_AUTO_AX_NATIVE_SCROLL_PROBE"

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
    echo "[v10.1] ERROR: front browser URL did not settle on $url (current: $current)" >&2
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

analyze_ax_scroll() {
    local pre_log="$1"
    local post_log="$2"
    local ax_json="$3"
    local base_url="$4"
    local post_url="$5"
    python3 - "$pre_log" "$post_log" "$ax_json" "$base_url" "$post_url" <<'PY'
import json
import sys

pre_log, post_log, ax_raw, base_url, post_url = sys.argv[1:6]

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
        raise SystemExit(f"[v10.1] missing map event in {path}")
    return event

pre = read_map(pre_log)
post = read_map(post_log)
ax = json.loads(ax_raw)

def targets_by_id(event):
    return {
        item.get("target_id"): item
        for item in event.get("targets") or []
        if item.get("target_id")
    }

pre_targets = targets_by_id(pre)
post_targets = targets_by_id(post)
common_ids = sorted(set(pre_targets) & set(post_targets))
deltas = []
for target_id in common_ids:
    pre_point = pre_targets[target_id].get("window_coregraphics_point") or {}
    post_point = post_targets[target_id].get("window_coregraphics_point") or {}
    if pre_point.get("y") is not None and post_point.get("y") is not None:
        deltas.append(float(post_point["y"]) - float(pre_point["y"]))

max_abs_delta_y = max((abs(value) for value in deltas), default=None)
mean_delta_y = sum(deltas) / len(deltas) if deltas else None
signature_changed = set(pre_targets) != set(post_targets)
visual_change = signature_changed or (max_abs_delta_y is not None and max_abs_delta_y >= 2.0)
url_changed = bool(base_url and post_url and base_url != post_url)
ax_mutation_attempted = ax.get("ax_mutation_attempted") is True
ax_content_moved = ax_mutation_attempted and visual_change and not url_changed

print(json.dumps({
    "event": "v101_ax_native_scroll_probe_result",
    "base_url": base_url,
    "post_url": post_url,
    "url_changed_after_ax": url_changed,
    "pre_window_id": pre.get("window_id"),
    "post_window_id": post.get("window_id"),
    "window_id_stable": pre.get("window_id") == post.get("window_id"),
    "pre_target_count": len(pre_targets),
    "post_target_count": len(post_targets),
    "common_target_count": len(common_ids),
    "target_intersection_ratio": len(common_ids) / max(len(pre_targets), 1),
    "target_signature_changed": signature_changed,
    "mean_common_target_window_y_delta": mean_delta_y,
    "max_abs_common_target_window_y_delta": max_abs_delta_y,
    "visual_change_detected": visual_change,
    "ax_status": ax.get("status"),
    "web_area_found": ax.get("web_area_found"),
    "scroll_area_found": ax.get("scroll_area_found"),
    "vertical_scrollbar_found": ax.get("vertical_scrollbar_found"),
    "web_area_actions": ax.get("web_area_actions"),
    "scroll_area_actions": ax.get("scroll_area_actions"),
    "vertical_scrollbar_value_settable": ax.get("vertical_scrollbar_value_settable"),
    "action_on_web_area_available": ax.get("action_on_web_area_available"),
    "action_on_scroll_area_available": ax.get("action_on_scroll_area_available"),
    "scrollbar_write_available": ax.get("scrollbar_write_available"),
    "selected_primitive": ax.get("selected_primitive"),
    "selected_action_target": ax.get("selected_action_target"),
    "execute_requested": ax.get("execute_requested"),
    "ax_mutation_attempted": ax_mutation_attempted,
    "perform_action_status": ax.get("perform_action_status"),
    "scrollbar_set_status": ax.get("scrollbar_set_status"),
    "scrollbar_old_value": ax.get("scrollbar_old_value"),
    "scrollbar_new_value": ax.get("scrollbar_new_value"),
    "ax_content_moved": ax_content_moved,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v10.1 Open-Web AX Native Scroll Probe"
echo "========================================================================"
echo "[v10.1] URL: $TARGET_URL"
echo "[v10.1] Browser: $BROWSER_APP"
echo "[v10.1] Window title needle: $WINDOW_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_native_scroll_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V101_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V101_AUTO_AX_CONFIRM:-}" != "$AUTO_AX_TOKEN" ]]; then
        echo "[v10.1] Armed AX native scroll probe requires GENESIS_V101_AUTO_AX_CONFIRM=$AUTO_AX_TOKEN" >&2
        exit 1
    fi
    echo "[v10.1] ARMED AX native scroll probe requested. It will call one bounded AX primitive only."
else
    echo "[v10.1] Dry-run mode. AX capabilities are enumerated, but no AX mutation is attempted."
fi

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V101_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(front_url)"

map_open_web "pre_ax"
PRE_AX_LOG="$OUTPUT_DIR/pre_ax.log"

AX_JSON="$(
    GENESIS_V101_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V101_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V101_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V101_AX_EXECUTE="$([[ "$ARMED" == true ]] && echo 1 || echo 0)" \
        "$AX_BIN"
)"
emit "$AX_JSON"

sleep "$POST_AX_SETTLE_SEC"
POST_URL="$(front_url)"

map_open_web "post_ax"
POST_AX_LOG="$OUTPUT_DIR/post_ax.log"

RESULT_JSON="$(analyze_ax_scroll "$PRE_AX_LOG" "$POST_AX_LOG" "$AX_JSON" "$BASE_URL" "$POST_URL")"
emit "$RESULT_JSON"

if [[ "$ARMED" == true ]]; then
    ABORT_JSON="$(python3 - "$RESULT_JSON" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
if not result.get("url_changed_after_ax"):
    raise SystemExit(0)

print(json.dumps({
    "event": "v101_ax_native_scroll_abort",
    "stop_reason": "url_changed_after_ax_native_scroll",
    "base_url": result.get("base_url"),
    "post_url": result.get("post_url"),
    "selected_primitive": result.get("selected_primitive"),
    "selected_action_target": result.get("selected_action_target"),
}, sort_keys=True))
PY
)"
    if [[ -n "$ABORT_JSON" ]]; then
        emit "$ABORT_JSON"
        echo "[v10.1] ERROR: AX native scroll changed URL; fail-fast stop engaged" >&2
        exit 2
    fi
fi

SUMMARY_JSON="$(python3 - "$RESULT_JSON" "$ARMED" "$RESULTS_LOG" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
armed = sys.argv[2] == "true"
results_log = sys.argv[3]

if result.get("url_changed_after_ax"):
    raise SystemExit(f"[v10.1] AX native scroll changed URL: {result}")
if not armed and result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.1] dry-run attempted AX mutation: {result}")
if not armed and result.get("visual_change_detected") is True:
    raise SystemExit(f"[v10.1] dry-run changed visual topology: {result}")

print(json.dumps({
    "event": "v101_open_web_ax_native_scroll_probe_summary",
    "armed": armed,
    "web_area_found": result.get("web_area_found"),
    "scroll_area_found": result.get("scroll_area_found"),
    "vertical_scrollbar_found": result.get("vertical_scrollbar_found"),
    "selected_primitive": result.get("selected_primitive"),
    "selected_action_target": result.get("selected_action_target"),
    "ax_mutation_attempted": result.get("ax_mutation_attempted"),
    "ax_content_moved": result.get("ax_content_moved"),
    "url_changed_after_ax": result.get("url_changed_after_ax"),
    "window_id_stable": result.get("window_id_stable"),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "results_log": results_log,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v10.1 open-web AX native scroll probe complete"
echo "========================================================================"
