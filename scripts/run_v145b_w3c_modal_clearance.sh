#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V145B_OUTPUT_DIR:-/tmp/genesis_v145b_w3c_modal_clearance}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V145B_AX_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
OS_SOCKET="${GENESIS_V145B_OS_SOCKET:-/tmp/genesis_os_driver_v145b.sock}"
DRIVER_LOG="${GENESIS_V145B_DRIVER_LOG:-/tmp/genesis_os_driver_v145b.log}"
BROWSER_APP="${GENESIS_V145B_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V145B_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V145B_WINDOW_TITLE:-Modal Dialog Example}"
POLL_TIMEOUT_MS="${GENESIS_V145B_POLL_TIMEOUT_MS:-1000}"
POLL_INTERVAL_MS="${GENESIS_V145B_POLL_INTERVAL_MS:-50}"
ARMED_TOKEN="GENESIS_V145B_ARMED_W3C_MODAL_CLEARANCE"
AUTO_FIRE_TOKEN="GENESIS_V145B_AUTO_FIRE_W3C_MODAL_CLEARANCE"
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

open_public_url() {
    local url="$1"
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$url" >/dev/null <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        make new document with properties {URL:targetUrl}
    end tell
    return ""
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

run_probe() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
        "$AX_BIN"
}

trigger_modal() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_EXECUTE=1 \
    GENESIS_V145A2_TRIGGER_CONFIRM=GENESIS_V145A2_TRIGGER_W3C_MODAL \
        "$AX_BIN"
}

now_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
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
    echo "[v14.5b] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v145b-w3c-modal-clearance",
    "action_id": f"act-v145b-w3c-modal-clearance-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

echo "========================================================================"
echo "Genesis v14.5b W3C Modal Clearance"
echo "========================================================================"
echo "[v14.5b] URL: $TARGET_URL"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V145B_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V145B_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v14.5b] Armed modal clearance requires GENESIS_V145B_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v14.5b] ARMED W3C modal clearance requested. It will click the single legal candidate only."
else
    echo "[v14.5b] Dry-run mode. It will stop before OS Driver click."
fi

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$AX_BIN"
open_public_url "$TARGET_URL"

pre_payload=""
deadline_ms=$(( $(now_ms) + 5000 ))
while (( $(now_ms) <= deadline_ms )); do
    set +e
    payload="$(run_probe 2>/dev/null)"
    status=$?
    set -e
    if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if payload.get("status") == "ok" and payload.get("trigger_found") else 1)
PY
    then
        pre_payload="$payload"
        emit "$(python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "pre_trigger"
print(json.dumps(payload, sort_keys=True))
PY
)"
        break
    fi
    sleep 0.2
done

if [[ -z "$pre_payload" ]]; then
    echo "[v14.5b] ERROR: W3C trigger was not found before clearance" >&2
    exit 1
fi

trigger_payload="$(trigger_modal)"
emit "$(python3 - "$trigger_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "trigger"
print(json.dumps(payload, sort_keys=True))
PY
)"

active_payload=""
deadline_ms=$(( $(now_ms) + 5000 ))
attempt=0
while (( $(now_ms) <= deadline_ms )); do
    attempt=$((attempt + 1))
    payload="$(run_probe)"
    sample="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "active_modal_poll"
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
    emit "$sample"
    if python3 - "$sample" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("safe_to_arm") is True else 1)
PY
    then
        active_payload="$sample"
        break
    fi
    sleep 0.2
done

if [[ -z "$active_payload" ]]; then
    echo "[v14.5b] ERROR: W3C modal did not reach safe_to_arm" >&2
    exit 1
fi

POINT_X="$(python3 - "$active_payload" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["clearance_point"]["x"])
PY
)"
POINT_Y="$(python3 - "$active_payload" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["clearance_point"]["y"])
PY
)"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$active_payload" <<'PY'
import json
import sys
active = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v145b_w3c_modal_clearance_summary",
    "armed": False,
    "public_obstacle_seen_before": active.get("public_obstacle_seen"),
    "candidate_count": active.get("candidate_count"),
    "legal_candidate_count": active.get("legal_candidate_count"),
    "rejected_candidate_count": active.get("rejected_candidate_count"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "click_posted": False,
    "target_clear_after": False,
    "stop_reason": "dry_run_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v14.5b W3C modal clearance complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v145b-w3c-modal-clearance","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

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

post_payload=""
deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
attempt=0
while (( $(now_ms) <= deadline_ms )); do
    attempt=$((attempt + 1))
    payload="$(run_probe)"
    sample="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "post_clearance_poll"
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
    emit "$sample"
    if python3 - "$sample" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("public_obstacle_seen") is False else 1)
PY
    then
        post_payload="$sample"
        break
    fi
    sleep "$(python3 - "$POLL_INTERVAL_MS" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
)"
done

if [[ -z "$post_payload" ]]; then
    echo "[v14.5b] ERROR: W3C modal did not clear after click" >&2
    exit 1
fi

emit "$(python3 - "$active_payload" "$MOVE_JSON" "$CLICK_JSON" "$post_payload" <<'PY'
import json
import sys
active, move, click, post = [json.loads(arg) for arg in sys.argv[1:5]]
move_posted = (move.get("receipt") or {}).get("posted") is True
click_posted = (click.get("receipt") or {}).get("posted") is True
target_clear_after = post.get("public_obstacle_seen") is False
print(json.dumps({
    "event": "v145b_w3c_modal_clearance_summary",
    "armed": True,
    "public_obstacle_seen_before": active.get("public_obstacle_seen"),
    "candidate_count": active.get("candidate_count"),
    "legal_candidate_count": active.get("legal_candidate_count"),
    "rejected_candidate_count": active.get("rejected_candidate_count"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "move_posted": move_posted,
    "click_posted": click_posted,
    "target_clear_after": target_clear_after,
    "stop_reason": "complete" if target_clear_after else "modal_not_cleared",
    "posted": move_posted and click_posted,
    "physical_input_posted": move_posted and click_posted,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v14.5b W3C modal clearance complete"
echo "========================================================================"
