#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V96_MAPPER_BIN:-/tmp/genesis_v96_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V96_OS_SOCKET:-/tmp/genesis_os_driver_v96.sock}"
DRIVER_LOG="${GENESIS_V96_DRIVER_LOG:-/tmp/genesis_os_driver_v96.log}"
OUTPUT_DIR="${GENESIS_V96_OUTPUT_DIR:-/tmp/genesis_v96_open_web_scroll_delivery_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
TARGET_URL="${GENESIS_V96_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V96_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V96_BROWSER_APP:-Safari}"
SCROLL_VARIANTS="${GENESIS_V96_SCROLL_VARIANTS:-pixel:66,line:3,pixel:240,line:6}"
POST_SCROLL_SETTLE_SEC="${GENESIS_V96_POST_SCROLL_SETTLE_SEC:-0.8}"
ARMED_TOKEN="GENESIS_V96_ARMED_OPEN_WEB_SCROLL_PROBE"
AUTO_SCROLL_TOKEN="GENESIS_V96_AUTO_SCROLL_DELIVERY_PROBE"
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
    echo "[v9.6] ERROR: timed out waiting for $socket_path" >&2
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
    echo "[v9.6] ERROR: front browser URL did not settle on $url (current: $current)" >&2
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

plan_scroll_point() {
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
    raise SystemExit("[v9.6] missing open_web_shadow_map event")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v9.6] map must remain read-only: {event}")

bounds = event.get("window_bounds") or {}
x = float(bounds["x"]) + float(bounds["width"]) * 0.55
y = float(bounds["y"]) + float(bounds["height"]) * 0.55
targets = event.get("targets") or []
print(json.dumps({
    "scroll_point": {"x": x, "y": y},
    "target_count": len(targets),
    "target_signature": sorted(item.get("target_id") for item in targets if item.get("target_id")),
    "window_bounds": bounds,
}, sort_keys=True))
PY
}

analyze_variant() {
    local variant_index="$1"
    local unit="$2"
    local dy="$3"
    local pre_log="$4"
    local post_log="$5"
    local scroll_json="$6"
    local base_url="$7"
    local post_url="$8"
    python3 - "$variant_index" "$unit" "$dy" "$pre_log" "$post_log" "$scroll_json" "$base_url" "$post_url" <<'PY'
import json
import sys

(
    variant_index_raw,
    requested_unit,
    requested_dy_raw,
    pre_log,
    post_log,
    scroll_raw,
    base_url,
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
        raise SystemExit(f"[v9.6] missing map event in {path}")
    return event

pre = read_map(pre_log)
post = read_map(post_log)
scroll = json.loads(scroll_raw)
receipt = scroll.get("receipt") or {}
delta = receipt.get("scroll_delta") or {}

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
if common_ids:
    deltas = []
    for target_id in common_ids:
        pre_point = pre_targets[target_id].get("window_coregraphics_point") or {}
        post_point = post_targets[target_id].get("window_coregraphics_point") or {}
        if pre_point.get("y") is not None and post_point.get("y") is not None:
            deltas.append(float(post_point["y"]) - float(pre_point["y"]))
    if deltas:
        mean_delta_y = sum(deltas) / len(deltas)

signature_changed = pre_ids != post_ids
intersection_ratio = len(common_ids) / max(len(pre_ids), 1)
visual_change_detected = signature_changed or (
    mean_delta_y is not None and abs(mean_delta_y) >= 2.0
)

print(json.dumps({
    "event": "v96_scroll_delivery_variant",
    "variant_index": int(variant_index_raw),
    "requested_scroll_unit": requested_unit,
    "requested_dy": float(requested_dy_raw),
    "receipt_scroll_unit": delta.get("unit"),
    "receipt_scroll_delta": delta,
    "scroll_status": scroll.get("status"),
    "scroll_posted": receipt.get("posted"),
    "scroll_point": receipt.get("point"),
    "cursor_position": receipt.get("cursor_position"),
    "pre_target_count": len(pre_ids),
    "post_target_count": len(post_ids),
    "common_target_count": len(common_ids),
    "target_intersection_ratio": intersection_ratio,
    "mean_common_target_window_y_delta": mean_delta_y,
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
echo "Genesis v9.6 Open-Web Scroll Delivery Probe"
echo "========================================================================"
echo "[v9.6] URL: $TARGET_URL"
echo "[v9.6] Variants: $SCROLL_VARIANTS"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

ARMED=false
if [[ "${GENESIS_V96_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V96_AUTO_SCROLL_CONFIRM:-}" != "$AUTO_SCROLL_TOKEN" ]]; then
        echo "[v9.6] Armed scroll probe requires GENESIS_V96_AUTO_SCROLL_CONFIRM=$AUTO_SCROLL_TOKEN" >&2
        exit 1
    fi
    echo "[v9.6] ARMED scroll delivery probe requested. It will post bounded scroll events only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
else
    echo "[v9.6] Dry-run mode. Scroll requests are routed through unarmed os-driver only."
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        > "$DRIVER_LOG" 2>&1 &
fi
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v96-open-web-scroll","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
if [[ "$ARMED" == true ]]; then
    python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v9.6] Accessibility is not trusted; refusing armed scroll delivery probe")
PY
fi

IFS=',' read -r -a VARIANT_ARRAY <<< "$SCROLL_VARIANTS"
VARIANT_INDEX=0
for VARIANT in "${VARIANT_ARRAY[@]}"; do
    UNIT="${VARIANT%%:*}"
    DY="${VARIANT#*:}"
    if [[ "$UNIT" == "$DY" || -z "$UNIT" || -z "$DY" ]]; then
        echo "[v9.6] ERROR: variant must be unit:dy, got '$VARIANT'" >&2
        exit 1
    fi

    open_target_url "$TARGET_URL"
    wait_for_target_url "$TARGET_URL"
    sleep "${GENESIS_V96_BROWSER_SETTLE_SEC:-2.5}"
    BASE_URL="$(front_url)"

    map_open_web "$VARIANT_INDEX" "pre"
    PRE_LOG="$OUTPUT_DIR/variant_${VARIANT_INDEX}_pre.log"
    PLAN_JSON="$(plan_scroll_point "$PRE_LOG")"
    echo "{\"event\":\"v96_scroll_delivery_plan\",\"variant_index\":$VARIANT_INDEX,\"scroll_unit\":\"$UNIT\",\"dy\":$DY,\"plan\":$PLAN_JSON}"
    SCROLL_X="$(python3 - "$PLAN_JSON" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["scroll_point"]["x"])
PY
)"
    SCROLL_Y="$(python3 - "$PLAN_JSON" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["scroll_point"]["y"])
PY
)"

    SCROLL_PAYLOAD="$(python3 - "$VARIANT_INDEX" "$UNIT" "$SCROLL_X" "$SCROLL_Y" "$DY" <<'PY'
import json
import sys
variant_index, unit, x, y, dy = sys.argv[1:6]
print(json.dumps({
    "request_id": f"scroll-v96-open-web-delivery-{variant_index}",
    "action_id": f"act-v96-open-web-scroll-{unit}-{variant_index}",
    "act": "scroll_wheel",
    "x": float(x),
    "y": float(y),
    "dx": 0.0,
    "dy": float(dy),
    "scroll_unit": unit,
}, sort_keys=True))
PY
)"
    SCROLL_JSON="$(roundtrip_os_driver "$SCROLL_PAYLOAD")"
    echo "{\"event\":\"os_driver_scroll\",\"variant_index\":$VARIANT_INDEX,\"scroll\":$SCROLL_JSON}"
    sleep "$POST_SCROLL_SETTLE_SEC"
    POST_URL="$(front_url)"
    map_open_web "$VARIANT_INDEX" "post"
    POST_LOG="$OUTPUT_DIR/variant_${VARIANT_INDEX}_post.log"
    VARIANT_RESULT="$(analyze_variant "$VARIANT_INDEX" "$UNIT" "$DY" "$PRE_LOG" "$POST_LOG" "$SCROLL_JSON" "$BASE_URL" "$POST_URL")"
    emit "$VARIANT_RESULT"
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
        if payload.get("event") == "v96_scroll_delivery_variant":
            variants.append(payload)

if not variants:
    raise SystemExit("[v9.6] no scroll delivery variants were recorded")

posted_values = [item.get("scroll_posted") for item in variants]
url_changed_values = [item.get("url_changed") for item in variants]
visual_change_values = [item.get("visual_change_detected") for item in variants]
units = [item.get("receipt_scroll_unit") for item in variants]

if not armed and any(posted_values):
    raise SystemExit(f"[v9.6] dry-run leaked physical scroll: {variants}")
if any(url_changed_values):
    raise SystemExit(f"[v9.6] scroll delivery probe changed URL: {variants}")

print(json.dumps({
    "event": "v96_open_web_scroll_delivery_probe_summary",
    "armed": armed,
    "variant_count": len(variants),
    "scroll_units": units,
    "scroll_posted_values": posted_values,
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
echo "Genesis v9.6 open-web scroll delivery probe complete"
echo "========================================================================"
