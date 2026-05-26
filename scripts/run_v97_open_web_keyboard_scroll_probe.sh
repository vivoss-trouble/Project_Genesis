#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V97_MAPPER_BIN:-/tmp/genesis_v97_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V97_OS_SOCKET:-/tmp/genesis_os_driver_v97.sock}"
DRIVER_LOG="${GENESIS_V97_DRIVER_LOG:-/tmp/genesis_os_driver_v97.log}"
OUTPUT_DIR="${GENESIS_V97_OUTPUT_DIR:-/tmp/genesis_v97_open_web_keyboard_scroll_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V97_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V97_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V97_BROWSER_APP:-Safari}"
KEY_VARIANTS="${GENESIS_V97_KEY_VARIANTS:-page_down,space,arrow_down}"
POST_KEY_SETTLE_SEC="${GENESIS_V97_POST_KEY_SETTLE_SEC:-0.8}"
ARMED_TOKEN="GENESIS_V97_ARMED_OPEN_WEB_KEYBOARD_SCROLL"
AUTO_KEY_TOKEN="GENESIS_V97_AUTO_KEYBOARD_SCROLL_PROBE"
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
    echo "[v9.7] ERROR: timed out waiting for $socket_path" >&2
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
    echo "[v9.7] ERROR: front browser URL did not settle on $url (current: $current)" >&2
    exit 1
}

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
}

map_open_web() {
    local variant_index="$1"
    local phase="$2"
    local debug_path="$OUTPUT_DIR/variant_${variant_index}_${phase}.png"
    local log_path="$OUTPUT_DIR/variant_${variant_index}_${phase}.log"
    GENESIS_V81_DEBUG_PNG="$debug_path" \
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
        "$MAPPER_BIN" | tee "$log_path"
}

analyze_variant() {
    local variant_index="$1"
    local key_name="$2"
    local pre_log="$3"
    local post_log="$4"
    local key_json="$5"
    local base_url="$6"
    local post_url="$7"
    python3 - "$variant_index" "$key_name" "$pre_log" "$post_log" "$key_json" "$base_url" "$post_url" <<'PY'
import json
import sys

variant_index_raw, requested_key, pre_log, post_log, key_raw, base_url, post_url = sys.argv[1:8]

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
        raise SystemExit(f"[v9.7] missing map event in {path}")
    return event

pre = read_map(pre_log)
post = read_map(post_log)
key_response = json.loads(key_raw)
receipt = key_response.get("receipt") or {}
receipt_key = receipt.get("key") or {}

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
mean_delta_y = None
max_abs_delta_y = None
if common_ids:
    deltas = []
    for target_id in common_ids:
        pre_point = pre_targets[target_id].get("window_coregraphics_point") or {}
        post_point = post_targets[target_id].get("window_coregraphics_point") or {}
        if pre_point.get("y") is not None and post_point.get("y") is not None:
            deltas.append(float(post_point["y"]) - float(pre_point["y"]))
    if deltas:
        mean_delta_y = sum(deltas) / len(deltas)
        max_abs_delta_y = max(abs(value) for value in deltas)

signature_changed = pre_ids != post_ids
intersection_ratio = len(common_ids) / max(len(pre_ids), 1)
visual_change_detected = signature_changed or (
    max_abs_delta_y is not None and max_abs_delta_y >= 2.0
)

print(json.dumps({
    "event": "v97_keyboard_scroll_variant",
    "variant_index": int(variant_index_raw),
    "requested_key": requested_key,
    "receipt_key": receipt_key,
    "key_status": key_response.get("status"),
    "key_posted": receipt.get("posted"),
    "key_point": receipt.get("point"),
    "cursor_position": receipt.get("cursor_position"),
    "pre_target_count": len(pre_ids),
    "post_target_count": len(post_ids),
    "common_target_count": len(common_ids),
    "target_intersection_ratio": intersection_ratio,
    "mean_common_target_window_y_delta": mean_delta_y,
    "max_abs_common_target_window_y_delta": max_abs_delta_y,
    "target_signature_changed": signature_changed,
    "visual_change_detected": visual_change_detected,
    "base_url": base_url,
    "post_url": post_url,
    "url_changed": bool(base_url and post_url and base_url != post_url),
    "posted": receipt.get("posted"),
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v9.7 Open-Web Keyboard Scroll Probe"
echo "========================================================================"
echo "[v9.7] URL: $TARGET_URL"
echo "[v9.7] Keys: $KEY_VARIANTS"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

ARMED=false
if [[ "${GENESIS_V97_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V97_AUTO_KEY_CONFIRM:-}" != "$AUTO_KEY_TOKEN" ]]; then
        echo "[v9.7] Armed keyboard scroll probe requires GENESIS_V97_AUTO_KEY_CONFIRM=$AUTO_KEY_TOKEN" >&2
        exit 1
    fi
    echo "[v9.7] ARMED keyboard scroll probe requested. It will post bounded key events only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v9.7] Dry-run mode. Key requests are routed through unarmed os-driver only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v97-open-web-keyboard-scroll","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v9.7] Accessibility is not trusted; refusing armed keyboard scroll probe")
PY
fi

IFS=',' read -r -a VARIANT_ARRAY <<< "$KEY_VARIANTS"
VARIANT_INDEX=0
for KEY_NAME in "${VARIANT_ARRAY[@]}"; do
    KEY_NAME="$(echo "$KEY_NAME" | tr -d '[:space:]')"
    if [[ -z "$KEY_NAME" ]]; then
        echo "[v9.7] ERROR: empty key variant" >&2
        exit 1
    fi

    open_target_url "$TARGET_URL"
    wait_for_target_url "$TARGET_URL"
    sleep "${GENESIS_V97_BROWSER_SETTLE_SEC:-2.5}"
    BASE_URL="$(front_url)"

    map_open_web "$VARIANT_INDEX" "pre"
    PRE_LOG="$OUTPUT_DIR/variant_${VARIANT_INDEX}_pre.log"

    KEY_PAYLOAD="$(python3 - "$VARIANT_INDEX" "$KEY_NAME" <<'PY'
import json
import sys
variant_index, key_name = sys.argv[1:3]
print(json.dumps({
    "request_id": f"key-v97-open-web-keyboard-scroll-{variant_index}",
    "action_id": f"act-v97-open-web-key-{key_name}-{variant_index}",
    "act": "key_press",
    "key": key_name,
}, sort_keys=True))
PY
)"
    KEY_JSON="$(roundtrip_os_driver "$KEY_PAYLOAD")"
    echo "{\"event\":\"os_driver_key\",\"variant_index\":$VARIANT_INDEX,\"key\":\"$KEY_NAME\",\"key_response\":$KEY_JSON}"
    sleep "$POST_KEY_SETTLE_SEC"
    POST_URL="$(front_url)"
    map_open_web "$VARIANT_INDEX" "post"
    POST_LOG="$OUTPUT_DIR/variant_${VARIANT_INDEX}_post.log"
    VARIANT_RESULT="$(analyze_variant "$VARIANT_INDEX" "$KEY_NAME" "$PRE_LOG" "$POST_LOG" "$KEY_JSON" "$BASE_URL" "$POST_URL")"
    emit "$VARIANT_RESULT"

    if [[ "$ARMED" == true ]]; then
        ABORT_JSON="$(python3 - "$VARIANT_RESULT" <<'PY'
import json
import sys

variant = json.loads(sys.argv[1])
if not variant.get("url_changed"):
    raise SystemExit(0)

print(json.dumps({
    "event": "v97_keyboard_scroll_abort",
    "stop_reason": "url_changed_after_key",
    "variant_index": variant.get("variant_index"),
    "requested_key": variant.get("requested_key"),
    "base_url": variant.get("base_url"),
    "post_url": variant.get("post_url"),
    "key_posted": variant.get("key_posted"),
    "target_signature_changed": variant.get("target_signature_changed"),
}, sort_keys=True))
PY
)"
        if [[ -n "$ABORT_JSON" ]]; then
            emit "$ABORT_JSON"
            echo "[v9.7] ERROR: armed keyboard probe changed URL after $KEY_NAME; fail-fast stop engaged" >&2
            exit 2
        fi
    fi

    VARIANT_INDEX=$((VARIANT_INDEX + 1))
done

SUMMARY_JSON="$(python3 - "$RESULTS_LOG" "$ARMED" <<'PY'
import json
import sys

results_path, armed_raw = sys.argv[1:3]
armed = armed_raw == "true"
variants = []
with open(results_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        payload = json.loads(raw)
        if payload.get("event") == "v97_keyboard_scroll_variant":
            variants.append(payload)

if not variants:
    raise SystemExit("[v9.7] no keyboard scroll variants were recorded")

posted_values = [item.get("key_posted") for item in variants]
url_changed_values = [item.get("url_changed") for item in variants]
visual_change_values = [item.get("visual_change_detected") for item in variants]
keys = [item.get("receipt_key", {}).get("key") for item in variants]

if not armed and any(posted_values):
    raise SystemExit(f"[v9.7] dry-run leaked physical key press: {variants}")
if any(url_changed_values):
    raise SystemExit(f"[v9.7] keyboard scroll probe changed URL: {variants}")

print(json.dumps({
    "event": "v97_open_web_keyboard_scroll_probe_summary",
    "armed": armed,
    "variant_count": len(variants),
    "keys": keys,
    "key_posted_values": posted_values,
    "visual_change_values": visual_change_values,
    "any_visual_change_detected": any(visual_change_values),
    "url_changed": any(url_changed_values),
    "posted": any(posted_values),
    "results_log": results_path,
}, sort_keys=True))
PY
)"
emit "$SUMMARY_JSON"

echo "========================================================================"
echo "Genesis v9.7 open-web keyboard scroll probe complete"
echo "========================================================================"
