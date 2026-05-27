#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OS_SOCKET="${GENESIS_V130_OS_SOCKET:-/tmp/genesis_os_driver_v130.sock}"
DRIVER_LOG="${GENESIS_V130_DRIVER_LOG:-/tmp/genesis_os_driver_v130.log}"
OUTPUT_DIR="${GENESIS_V130_OUTPUT_DIR:-/tmp/genesis_v130_obstacle_clearance_probe}"
AX_BIN="${GENESIS_V130_AX_BIN:-$OUTPUT_DIR/ax_obstacle_clearance_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
FIXTURE_PATH="${GENESIS_V130_FIXTURE_PATH:-$ROOT_DIR/fixtures/v13/obstacle_clearance_fixture.html}"
FIXTURE_URL="$(python3 - "$FIXTURE_PATH" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"
BROWSER_APP="${GENESIS_V130_BROWSER_APP:-Safari}"
WINDOW_TITLE="${GENESIS_V130_WINDOW_TITLE:-Genesis v13.0 Obstacle Fixture}"
ARMED_TOKEN="GENESIS_V130_ARMED_OBSTACLE_CLEARANCE"
AUTO_FIRE_TOKEN="GENESIS_V130_AUTO_FIRE_OBSTACLE_CLEARANCE"
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

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v13.0] ERROR: timed out waiting for $socket_path" >&2
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

open_fixture_url() {
    local url="$1"
    if [[ "$url" == file://* ]]; then
        open -a "$BROWSER_APP" "$url" || open "$url"
        return
    fi
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

run_probe() {
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_WINDOW_TITLE="$WINDOW_TITLE" \
        "$AX_BIN"
}

wait_for_fixture_probe() {
    local last_payload=""
    for _ in $(seq 1 40); do
        set +e
        last_payload="$(run_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$last_payload" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if payload.get("status") == "ok" and payload.get("target_found") is True:
    raise SystemExit(0)
raise SystemExit(1)
PY
        then
            echo "$last_payload"
            return 0
        fi
        sleep 0.25
    done
    echo "${last_payload:-{\"event\":\"v130_obstacle_clearance_probe\",\"status\":\"error\",\"error\":\"fixture window did not become ready\",\"posted\":false,\"physical_input_posted\":false,\"ax_mutation_attempted\":false}}"
    return 1
}

post_action() {
    local action="$1"
    local x="$2"
    local y="$3"
    local request_action="$4"
    local payload
    payload="$(python3 - "$action" "$x" "$y" "$request_action" <<'PY'
import json
import sys
action, x, y, request_action = sys.argv[1:5]
print(json.dumps({
    "request_id": f"{action}-v130-obstacle-clearance",
    "action_id": f"act-v130-obstacle-clearance-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

echo "========================================================================"
echo "Genesis v13.0 Obstacle Clearance Probe"
echo "========================================================================"
echo "[v13.0] Fixture: $FIXTURE_PATH"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$AX_BIN"

ARMED=false
if [[ "${GENESIS_V130_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V130_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v13.0] Armed clearance requires GENESIS_V130_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v13.0] ARMED obstacle clearance requested. It will click one whitelisted candidate only."
else
    echo "[v13.0] Dry-run mode. It will adjudicate the obstacle without physical input."
fi

open_fixture_url "$FIXTURE_URL"
sleep "${GENESIS_V130_BROWSER_SETTLE_SEC:-1.5}"

set +e
PRE_JSON="$(wait_for_fixture_probe)"
PROBE_READY_STATUS=$?
set -e
emit "$PRE_JSON"
if [[ $PROBE_READY_STATUS -ne 0 ]]; then
    echo "[v13.0] ERROR: fixture window did not become probe-ready" >&2
    exit 1
fi

python3 - "$PRE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if payload.get("status") != "ok":
    raise SystemExit(f"[v13.0] probe failed: {payload}")
if payload.get("target_found") is not True:
    raise SystemExit(f"[v13.0] target missing: {payload}")
if payload.get("occlusion_clear") is not False:
    raise SystemExit(f"[v13.0] fixture should start occluded: {payload}")
if payload.get("candidate_count") != 4:
    raise SystemExit(f"[v13.0] expected four modal candidates: {payload}")
if payload.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v13.0] expected exactly one legal clearance candidate: {payload}")
selected = payload.get("selected_clearance") or {}
label = " ".join(str(selected.get(k) or "") for k in ("title", "description", "value")).strip().lower()
if "close" not in label:
    raise SystemExit(f"[v13.0] legal candidate is not Close: {payload}")
for candidate in payload.get("candidates") or []:
    label = (candidate.get("label") or "").lower()
    if any(term in label for term in ("accept", "subscribe", "continue")) and candidate.get("legal_candidate") is True:
        raise SystemExit(f"[v13.0] trap candidate survived: {candidate}")
PY

POINT_X="$(json_get "$PRE_JSON" "clearance_point.x")"
POINT_Y="$(json_get "$PRE_JSON" "clearance_point.y")"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$PRE_JSON" <<'PY'
import json
import sys
pre = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v130_obstacle_clearance_summary",
    "armed": False,
    "clearance_resolved": pre.get("clearance_resolved"),
    "candidate_count": pre.get("candidate_count"),
    "legal_candidate_count": pre.get("legal_candidate_count"),
    "rejected_candidate_count": pre.get("rejected_candidate_count"),
    "target_occluded_before": not pre.get("occlusion_clear"),
    "click_posted": False,
    "target_clear_after": False,
    "stop_reason": "dry_run_projection_stop",
    "posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v13.0 obstacle clearance probe complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v130-obstacle-clearance","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
python3 - "$PROBE_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if not payload.get("probe", {}).get("accessibility_trusted"):
    raise SystemExit("[v13.0] Accessibility is not trusted; refusing obstacle clearance")
PY

MOVE_JSON="$(post_action "move" "$POINT_X" "$POINT_Y" "move_mouse")"
emit "$(python3 - "$MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
CLICK_JSON="$(post_action "click" "$POINT_X" "$POINT_Y" "click_point")"
emit "$(python3 - "$CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

sleep "${GENESIS_V130_POST_CLEARANCE_SETTLE_SEC:-0.8}"
POST_JSON="$(run_probe)"
emit "$POST_JSON"

emit "$(python3 - "$PRE_JSON" "$MOVE_JSON" "$CLICK_JSON" "$POST_JSON" <<'PY'
import json
import sys
pre, move, click, post = [json.loads(arg) for arg in sys.argv[1:5]]
move_posted = (move.get("receipt") or {}).get("posted") is True
click_posted = (click.get("receipt") or {}).get("posted") is True
target_clear_after = post.get("occlusion_clear") is True
if not target_clear_after:
    raise SystemExit(f"[v13.0] obstacle unresolved after clearance click: {post}")
print(json.dumps({
    "event": "v130_obstacle_clearance_summary",
    "armed": True,
    "clearance_resolved": pre.get("clearance_resolved"),
    "candidate_count": pre.get("candidate_count"),
    "legal_candidate_count": pre.get("legal_candidate_count"),
    "rejected_candidate_count": pre.get("rejected_candidate_count"),
    "target_occluded_before": not pre.get("occlusion_clear"),
    "move_posted": move_posted,
    "click_posted": click_posted,
    "target_clear_after": target_clear_after,
    "stop_reason": "complete",
    "posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v13.0 obstacle clearance probe complete"
echo "========================================================================"
