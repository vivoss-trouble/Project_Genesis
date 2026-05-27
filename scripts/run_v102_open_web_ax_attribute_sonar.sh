#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V102_MAPPER_BIN:-/tmp/genesis_v102_open_web_shadow_map}"
SONAR_BIN="${GENESIS_V102_SONAR_BIN:-/tmp/genesis_v102_ax_webarea_attribute_sonar}"
OUTPUT_DIR="${GENESIS_V102_OUTPUT_DIR:-/tmp/genesis_v102_open_web_ax_attribute_sonar}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V102_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V102_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V102_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V102_BROWSER_BUNDLE_ID:-com.apple.Safari}"

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
    echo "[v10.2] ERROR: front browser URL did not settle on $url (current: $current)" >&2
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

analyze_sonar() {
    local pre_log="$1"
    local post_log="$2"
    local sonar_json="$3"
    local base_url="$4"
    local post_url="$5"
    python3 - "$pre_log" "$post_log" "$sonar_json" "$base_url" "$post_url" <<'PY'
import json
import sys

pre_log, post_log, sonar_raw, base_url, post_url = sys.argv[1:6]

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
        raise SystemExit(f"[v10.2] missing map event in {path}")
    return event

def targets_by_id(event):
    return {
        item.get("target_id"): item
        for item in event.get("targets") or []
        if item.get("target_id")
    }

pre = read_map(pre_log)
post = read_map(post_log)
sonar = json.loads(sonar_raw)
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

print(json.dumps({
    "event": "v102_ax_attribute_sonar_result",
    "base_url": base_url,
    "post_url": post_url,
    "url_changed_after_sonar": url_changed,
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
    "sonar_status": sonar.get("status"),
    "web_area_found": sonar.get("web_area_found"),
    "nearest_scroll_ancestor_found": sonar.get("nearest_scroll_ancestor_found"),
    "sonar_visited_count": sonar.get("sonar_visited_count"),
    "scroll_suspect_count": sonar.get("scroll_suspect_count"),
    "parameterized_suspect_count": sonar.get("parameterized_suspect_count"),
    "value_suspect_count": sonar.get("value_suspect_count"),
    "web_area_parameterized_attribute_names": sonar.get("web_area_parameterized_attribute_names"),
    "nearest_scroll_ancestor_parameterized_attribute_names": sonar.get("nearest_scroll_ancestor_parameterized_attribute_names"),
    "all_parameterized_attribute_names": sonar.get("all_parameterized_attribute_names"),
    "all_action_names": sonar.get("all_action_names"),
    "ax_mutation_attempted": sonar.get("ax_mutation_attempted"),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v10.2 Open-Web AX Attribute Sonar"
echo "========================================================================"
echo "[v10.2] URL: $TARGET_URL"
echo "[v10.2] Browser: $BROWSER_APP"
echo "[v10.2] Window title needle: $WINDOW_TITLE"
echo "[v10.2] Read-only AX sonar. No AX mutation and no os-driver."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_webarea_attribute_sonar.swift -o "$SONAR_BIN"

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V102_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(front_url)"

map_open_web "pre_sonar"
PRE_LOG="$OUTPUT_DIR/pre_sonar.log"

SONAR_JSON="$(
    GENESIS_V102_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V102_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V102_WINDOW_TITLE="$WINDOW_TITLE" \
        "$SONAR_BIN"
)"
emit "$SONAR_JSON"

sleep "${GENESIS_V102_POST_SONAR_SETTLE_SEC:-0.4}"
POST_URL="$(front_url)"

map_open_web "post_sonar"
POST_LOG="$OUTPUT_DIR/post_sonar.log"

RESULT_JSON="$(analyze_sonar "$PRE_LOG" "$POST_LOG" "$SONAR_JSON" "$BASE_URL" "$POST_URL")"
emit "$RESULT_JSON"

SUMMARY_JSON="$(python3 - "$RESULT_JSON" "$RESULTS_LOG" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
results_log = sys.argv[2]

if result.get("url_changed_after_sonar"):
    raise SystemExit(f"[v10.2] read-only sonar changed URL: {result}")
if result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.2] read-only sonar attempted AX mutation: {result}")
if result.get("visual_change_detected") is True:
    raise SystemExit(f"[v10.2] read-only sonar changed visual topology: {result}")

print(json.dumps({
    "event": "v102_open_web_ax_attribute_sonar_summary",
    "web_area_found": result.get("web_area_found"),
    "nearest_scroll_ancestor_found": result.get("nearest_scroll_ancestor_found"),
    "sonar_visited_count": result.get("sonar_visited_count"),
    "scroll_suspect_count": result.get("scroll_suspect_count"),
    "parameterized_suspect_count": result.get("parameterized_suspect_count"),
    "value_suspect_count": result.get("value_suspect_count"),
    "window_id_stable": result.get("window_id_stable"),
    "url_changed_after_sonar": result.get("url_changed_after_sonar"),
    "ax_mutation_attempted": result.get("ax_mutation_attempted"),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "results_log": results_log,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v10.2 open-web AX attribute sonar complete"
echo "========================================================================"
