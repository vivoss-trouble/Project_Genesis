#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V103_MAPPER_BIN:-/tmp/genesis_v103_open_web_shadow_map}"
AX_BIN="${GENESIS_V103_AX_BIN:-/tmp/genesis_v103_ax_scroll_to_visible_probe}"
OUTPUT_DIR="${GENESIS_V103_OUTPUT_DIR:-/tmp/genesis_v103_open_web_ax_scroll_to_visible}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V103_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V103_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V103_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V103_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_TITLE="${GENESIS_V103_AX_TARGET_TITLE:-Final Project}"
ARMED_TOKEN="GENESIS_V103_ARMED_OPEN_WEB_AX_SCROLL_TO_VISIBLE"
AUTO_AX_TOKEN="GENESIS_V103_AUTO_AX_SCROLL_TO_VISIBLE"

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
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
    echo "[v10.3] ERROR: target browser URL did not settle on $url (current: $current)" >&2
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
    local attempts="${GENESIS_V103_MAP_TARGET_ATTEMPTS:-12}"
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
    echo "[v10.3] ERROR: failed to capture target window matching title '$WINDOW_TITLE'" >&2
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
        print(f"GENESIS_V103_POINT_X={float(point['x'])}")
        print(f"GENESIS_V103_POINT_Y={float(point['y'])}")
        break
PY
}

analyze_scroll_to_visible() {
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
        raise SystemExit(f"[v10.3] missing map event in {path}")
    return event

def targets_by_id(event):
    return {
        item.get("target_id"): item
        for item in event.get("targets") or []
        if item.get("target_id")
    }

pre = read_map(pre_log)
post = read_map(post_log)
ax = json.loads(ax_raw)
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
material_content_shift = max_abs_delta_y is not None and max_abs_delta_y >= 2.0
url_changed = bool(base_url and post_url and base_url != post_url)
mutation = ax.get("ax_mutation_attempted") is True
target_frame = ax.get("target_frame_after_action")
target_visible_after = False
if isinstance(target_frame, dict):
    center_y = target_frame.get("center_y")
    if center_y is not None:
        bounds = post.get("window_bounds") or {}
        y0 = float(bounds.get("y", 0))
        y1 = y0 + float(bounds.get("height", 0))
        target_visible_after = y0 <= float(center_y) <= y1

print(json.dumps({
    "event": "v103_ax_scroll_to_visible_result",
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
    "material_content_shift_detected": material_content_shift,
    "visual_change_detected": material_content_shift,
    "ax_status": ax.get("status"),
    "web_area_found": ax.get("web_area_found"),
    "target_found": ax.get("target_found"),
    "scroll_to_visible_available": ax.get("scroll_to_visible_available"),
    "scroll_to_visible_status": ax.get("scroll_to_visible_status"),
    "marker_bridge": ax.get("marker_bridge"),
    "selected_target": ax.get("selected_target"),
    "target_frame_after_action": target_frame,
    "target_visible_after_action": target_visible_after,
    "ax_mutation_attempted": mutation,
    "ax_scroll_to_visible_moved_content": mutation and not url_changed and (
        target_visible_after or material_content_shift or signature_changed
    ),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v10.3 Open-Web AX ScrollToVisible Probe"
echo "========================================================================"
echo "[v10.3] URL: $TARGET_URL"
echo "[v10.3] Browser: $BROWSER_APP"
echo "[v10.3] Window title needle: $WINDOW_TITLE"
echo "[v10.3] AX target title needle: $TARGET_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
swiftc scripts/ax_scroll_to_visible_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V103_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V103_AUTO_AX_CONFIRM:-}" != "$AUTO_AX_TOKEN" ]]; then
        echo "[v10.3] Armed ScrollToVisible probe requires GENESIS_V103_AUTO_AX_CONFIRM=$AUTO_AX_TOKEN" >&2
        exit 1
    fi
    echo "[v10.3] ARMED AX ScrollToVisible probe requested. It will perform one bounded AX action only."
else
    echo "[v10.3] Dry-run mode. Target bridge is resolved, but AXScrollToVisible is not performed."
fi

open_target_url "$TARGET_URL"
wait_for_target_url "$TARGET_URL"
sleep "${GENESIS_V103_BROWSER_SETTLE_SEC:-2.5}"
BASE_URL="$(target_document_url)"

map_open_web "pre_ax"
PRE_LOG="$OUTPUT_DIR/pre_ax.log"

POINT_ENV="$(extract_marker_point_env "$PRE_LOG" || true)"
POINT_X=""
POINT_Y=""
if [[ -n "$POINT_ENV" ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            GENESIS_V103_POINT_X) POINT_X="$value" ;;
            GENESIS_V103_POINT_Y) POINT_Y="$value" ;;
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

sleep "${GENESIS_V103_POST_AX_SETTLE_SEC:-1.0}"
POST_URL="$(target_document_url)"

map_open_web "post_ax"
POST_LOG="$OUTPUT_DIR/post_ax.log"

RESULT_JSON="$(analyze_scroll_to_visible "$PRE_LOG" "$POST_LOG" "$AX_JSON" "$BASE_URL" "$POST_URL")"
emit "$RESULT_JSON"

if [[ "$ARMED" == true ]]; then
    ABORT_JSON="$(python3 - "$RESULT_JSON" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
if not result.get("url_changed_after_ax"):
    raise SystemExit(0)

print(json.dumps({
    "event": "v103_ax_scroll_to_visible_abort",
    "stop_reason": "url_changed_after_ax_scroll_to_visible",
    "base_url": result.get("base_url"),
    "post_url": result.get("post_url"),
    "target_found": result.get("target_found"),
}, sort_keys=True))
PY
)"
    if [[ -n "$ABORT_JSON" ]]; then
        emit "$ABORT_JSON"
        echo "[v10.3] ERROR: AXScrollToVisible changed URL; fail-fast stop engaged" >&2
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
    raise SystemExit(f"[v10.3] AXScrollToVisible changed URL: {result}")
if not armed and result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.3] dry-run attempted AX mutation: {result}")
if not armed and result.get("visual_change_detected") is True:
    raise SystemExit(f"[v10.3] dry-run changed visual topology: {result}")

print(json.dumps({
    "event": "v103_open_web_ax_scroll_to_visible_summary",
    "armed": armed,
    "web_area_found": result.get("web_area_found"),
    "target_found": result.get("target_found"),
    "scroll_to_visible_available": result.get("scroll_to_visible_available"),
    "scroll_to_visible_status": result.get("scroll_to_visible_status"),
    "target_visible_after_action": result.get("target_visible_after_action"),
    "ax_mutation_attempted": result.get("ax_mutation_attempted"),
    "ax_scroll_to_visible_moved_content": result.get("ax_scroll_to_visible_moved_content"),
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
echo "Genesis v10.3 open-web AX ScrollToVisible probe complete"
echo "========================================================================"
