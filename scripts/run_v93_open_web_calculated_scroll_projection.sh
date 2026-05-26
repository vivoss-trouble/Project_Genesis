#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V93_MAPPER_BIN:-/tmp/genesis_v93_open_web_shadow_map}"
OS_SOCKET="${GENESIS_V93_OS_SOCKET:-/tmp/genesis_os_driver_v93.sock}"
DRIVER_LOG="${GENESIS_V93_DRIVER_LOG:-/tmp/genesis_os_driver_v93.log}"
OUTPUT_DIR="${GENESIS_V93_OUTPUT_DIR:-/tmp/genesis_v93_open_web_calculated_scroll}"
MAP_LOG="$OUTPUT_DIR/map.log"
DEBUG_PNG="$OUTPUT_DIR/map.png"
TARGET_URL="${GENESIS_V93_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V93_WINDOW_TITLE:-The Rust Programming Language}"
BROWSER_APP="${GENESIS_V93_BROWSER_APP:-Safari}"
TARGET_ID="${GENESIS_V93_TARGET_ID:-}"
TARGET_KIND="${GENESIS_V93_TARGET_KIND:-link-like}"
TARGET_STRATEGY="${GENESIS_V93_TARGET_STRATEGY:-bottommost}"
SAFE_CENTER_RATIO="${GENESIS_V93_SAFE_CENTER_RATIO:-0.45}"
SAFE_BAND_PX="${GENESIS_V93_SAFE_BAND_PX:-64}"
MAX_SCROLL_ABS="${GENESIS_V93_MAX_SCROLL_ABS:-720}"
SCROLL_DX="${GENESIS_V93_SCROLL_DX:-0}"
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
    echo "[v9.3] ERROR: timed out waiting for $socket_path" >&2
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
        open location targetUrl
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

map_open_web() {
    GENESIS_V81_DEBUG_PNG="$DEBUG_PNG" \
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
        "$MAPPER_BIN" | tee "$MAP_LOG"
}

plan_scroll() {
    local log_path="$1"
    python3 - "$log_path" "$TARGET_ID" "$TARGET_KIND" "$TARGET_STRATEGY" "$SAFE_CENTER_RATIO" "$SAFE_BAND_PX" "$MAX_SCROLL_ABS" <<'PY'
import json
import math
import sys

(
    log_path,
    requested_target_id,
    target_kind,
    target_strategy,
    safe_center_ratio_raw,
    safe_band_raw,
    max_scroll_raw,
) = sys.argv[1:8]

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
    raise SystemExit(f"[v9.3] missing open_web_shadow_map event in {log_path}")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v9.3] map must remain read-only: {event}")

targets = event.get("targets") or []
window_bounds = event.get("window_bounds") or {}
try:
    window_x = float(window_bounds["x"])
    window_y = float(window_bounds["y"])
    window_width = float(window_bounds["width"])
    window_height = float(window_bounds["height"])
except KeyError as exc:
    raise SystemExit(f"[v9.3] map missing window bound {exc}: {event}") from exc

if requested_target_id:
    selected = next((item for item in targets if item.get("target_id") == requested_target_id), None)
    if selected is None:
        raise SystemExit(f"[v9.3] target_id not found: {requested_target_id}")
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
        raise SystemExit(f"[v9.3] unsupported target strategy: {target_strategy}")
    selected = candidates[0] if candidates else None
    if selected is None:
        raise SystemExit(f"[v9.3] no target with control_kind={target_kind}")

point = selected.get("global_coregraphics_point") or {}
window_point = selected.get("window_coregraphics_point") or {}
if point.get("x") is None or point.get("y") is None:
    raise SystemExit(f"[v9.3] selected target has no global point: {selected}")
if window_point.get("x") is None or window_point.get("y") is None:
    window_point = {"x": float(point["x"]) - window_x, "y": float(point["y"]) - window_y}

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

scroll_point = {
    "x": window_x + window_width * 0.55,
    "y": window_y + window_height * 0.55,
}

print(json.dumps({
    "event": "open_web_calculated_scroll_plan",
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
    "planner_contract": "piecewise_undershoot_remap_required",
    "posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v9.3 Open-Web Calculated Scroll Projection"
echo "========================================================================"
echo "[v9.3] URL: $TARGET_URL"
echo "[v9.3] Window title needle: $WINDOW_TITLE"
echo "[v9.3] Target kind: $TARGET_KIND"
echo "[v9.3] Target strategy: $TARGET_STRATEGY"
echo "[v9.3] Safe center ratio: $SAFE_CENTER_RATIO"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

open_target_url "$TARGET_URL"
sleep "${GENESIS_V93_BROWSER_SETTLE_SEC:-2.5}"

BASE_URL="$(front_url)"
map_open_web
PLAN_JSON="$(plan_scroll "$MAP_LOG")"
echo "$PLAN_JSON"

SCROLL_X="$(python3 - "$PLAN_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["scroll_point"]["x"])
PY
)"
SCROLL_Y="$(python3 - "$PLAN_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["scroll_point"]["y"])
PY
)"
SCROLL_DY="$(python3 - "$PLAN_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["planned_scroll_delta"]["dy"])
PY
)"

rm -f "$OS_SOCKET" "$DRIVER_LOG"
echo "[v9.3] Projection-only mode. Calculated scroll is emitted as an unarmed OS-driver receipt; Remap remains the only truth source."
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v93-open-web","act":"probe"}')"
echo "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

SCROLL_PAYLOAD="$(python3 - "$SCROLL_X" "$SCROLL_Y" "$SCROLL_DX" "$SCROLL_DY" <<'PY'
import json
import sys
x, y, dx, dy = sys.argv[1:5]
print(json.dumps({
    "request_id": "scroll-v93-open-web-calculated",
    "action_id": "act-v93-open-web-calculated-scroll",
    "act": "scroll_wheel",
    "x": float(x),
    "y": float(y),
    "dx": float(dx),
    "dy": float(dy),
}, sort_keys=True))
PY
)"
SCROLL_JSON="$(roundtrip_os_driver "$SCROLL_PAYLOAD")"
echo "{\"event\":\"os_driver_scroll\",\"scroll\":$SCROLL_JSON}"

POST_URL="$(front_url)"
python3 - "$PLAN_JSON" "$SCROLL_JSON" "$BASE_URL" "$POST_URL" <<'PY'
import json
import math
import sys

plan = json.loads(sys.argv[1])
scroll = json.loads(sys.argv[2])
base_url = sys.argv[3]
post_url = sys.argv[4]

if scroll.get("status") != "ok":
    raise SystemExit(f"[v9.3] os-driver scroll failed: {scroll}")
receipt = scroll.get("receipt") or {}
if receipt.get("posted") is not False:
    raise SystemExit(f"[v9.3] projection leaked physical scroll: {scroll}")

expected = plan["planned_scroll_delta"]
actual = receipt.get("scroll_delta") or {}
if abs(actual.get("dx", 1e9) - expected["dx"]) > 0.001 or abs(actual.get("dy", 1e9) - expected["dy"]) > 0.001:
    raise SystemExit(f"[v9.3] scroll receipt drifted from plan: plan={plan} scroll={scroll}")

url_changed = bool(base_url and post_url and base_url != post_url)
if url_changed:
    raise SystemExit(f"[v9.3] projection unexpectedly changed URL: base={base_url!r} post={post_url!r}")

print(json.dumps({
    "event": "v93_open_web_calculated_scroll_summary",
    "target_id": plan["target_id"],
    "target_kind": plan["target_kind"],
    "target_strategy": plan["target_strategy"],
    "damping_band": plan["damping_band"],
    "damping_factor": plan["damping_factor"],
    "distance_to_safe_center_px": plan["distance_to_safe_center_px"],
    "planned_scroll_delta": expected,
    "scroll_posted": receipt.get("posted"),
    "url_changed": url_changed,
    "planner_contract": plan["planner_contract"],
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.3 open-web calculated scroll projection complete"
echo "========================================================================"
