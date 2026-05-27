#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V146_OUTPUT_DIR:-/tmp/genesis_v146_public_isr_e2e}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V146_AX_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
OS_SOCKET="${GENESIS_V146_OS_SOCKET:-/tmp/genesis_os_driver_v146.sock}"
DRIVER_LOG="${GENESIS_V146_DRIVER_LOG:-/tmp/genesis_os_driver_v146.log}"
BROWSER_APP="${GENESIS_V146_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V146_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V146_WINDOW_TITLE:-Modal Dialog Example}"
MAIN_TARGET_TITLE="${GENESIS_V146_MAIN_TARGET_TITLE:-Add Delivery Address}"
POLL_TIMEOUT_MS="${GENESIS_V146_POLL_TIMEOUT_MS:-1000}"
POLL_INTERVAL_MS="${GENESIS_V146_POLL_INTERVAL_MS:-50}"
ARMED_TOKEN="GENESIS_V146_ARMED_PUBLIC_ISR_E2E"
AUTO_FIRE_TOKEN="GENESIS_V146_AUTO_FIRE_PUBLIC_ISR_E2E"
MAIN_FIRE_TOKEN="GENESIS_V146_MAIN_FIRE_W3C_TRIGGER"
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
    GENESIS_V145A2_TRIGGER_TITLE="$MAIN_TARGET_TITLE" \
        "$AX_BIN"
}

trigger_modal() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_TITLE="$MAIN_TARGET_TITLE" \
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

sleep_ms() {
    python3 - "$1" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
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
    echo "[v14.6] ERROR: timed out waiting for $socket_path" >&2
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
    local namespace="$1"
    local action="$2"
    local x="$3"
    local y="$4"
    local request_action="$5"
    local payload
    payload="$(python3 - "$namespace" "$action" "$x" "$y" "$request_action" <<'PY'
import json
import sys
namespace, action, x, y, request_action = sys.argv[1:6]
print(json.dumps({
    "request_id": f"{action}-v146-public-isr-e2e-{namespace}",
    "action_id": f"act-v146-public-isr-e2e-{namespace}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

json_get() {
    local payload="$1"
    local path="$2"
    python3 - "$payload" "$path" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
value = payload
for part in sys.argv[2].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list) and part.isdigit():
        index = int(part)
        value = value[index] if 0 <= index < len(value) else None
    else:
        value = None
        break
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

wait_for_pre_trigger() {
    local payload status
    local deadline_ms=$(( $(now_ms) + 5000 ))
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
ok = (
    payload.get("status") == "ok"
    and payload.get("trigger_found") is True
    and payload.get("public_obstacle_seen") is False
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep 0.2
    done
    echo "[v14.6] ERROR: W3C main target baseline was not found" >&2
    exit 1
}

wait_for_active_modal() {
    local payload sample
    local deadline_ms=$(( $(now_ms) + 5000 ))
    local attempt=0
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
        if python3 - "$sample" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("safe_to_arm") is True else 1)
PY
        then
            printf '%s\n' "$sample"
            return
        fi
        sleep 0.2
    done
    echo "[v14.6] ERROR: W3C modal did not reach ISR safe_to_arm" >&2
    exit 1
}

wait_for_ground_state() {
    local payload sample
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    local attempt=0
    while (( $(now_ms) <= deadline_ms )); do
        attempt=$((attempt + 1))
        payload="$(run_probe)"
        sample="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "fresh_remap_poll"
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
        if python3 - "$sample" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = payload.get("public_obstacle_seen") is False and payload.get("trigger_found") is True
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$sample"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v14.6] ERROR: fresh remap did not return to ground state" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v14.6 Public ISR E2E"
echo "========================================================================"
echo "[v14.6] URL: $TARGET_URL"
echo "[v14.6] Main target: $MAIN_TARGET_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V146_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi
MAIN_FIRE=false
if [[ "${GENESIS_V146_MAIN_FIRE_CONFIRM:-}" == "$MAIN_FIRE_TOKEN" ]]; then
    MAIN_FIRE=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V146_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v14.6] Armed ISR E2E requires GENESIS_V146_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v14.6] ARMED ISR E2E requested. It will physically clear the modal only."
else
    echo "[v14.6] Dry-run mode. It will stop at the ISR projection boundary."
fi

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$AX_BIN"
open_public_url "$TARGET_URL"

pre_payload="$(wait_for_pre_trigger)"
emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "pre_trap_ground_state"
print(json.dumps(payload, sort_keys=True))
PY
)"

trigger_payload="$(trigger_modal)"
emit "$(python3 - "$trigger_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "trap_activation"
print(json.dumps(payload, sort_keys=True))
PY
)"

active_payload="$(wait_for_active_modal)"
emit "$active_payload"

emit "$(python3 - "$pre_payload" "$active_payload" "$MAIN_TARGET_TITLE" <<'PY'
import json
import sys
pre, active = [json.loads(arg) for arg in sys.argv[1:3]]
target_title = sys.argv[3]
trigger = (pre.get("trigger_candidates") or [{}])[0]
dialog = (active.get("dialog_candidates") or [{}])[0]
interrupt = active.get("public_obstacle_seen") is True and active.get("safe_to_arm") is True
print(json.dumps({
    "event": "v146_main_collision",
    "step_id": "step-0-w3c-public-isr",
    "target_title": target_title,
    "target_found_before_trap": pre.get("trigger_found"),
    "target_point_before_trap": (trigger.get("frame") or {}),
    "public_obstacle_seen": active.get("public_obstacle_seen"),
    "occluder_kind": active.get("occluder_kind"),
    "occluder_frame": (dialog.get("frame") or {}),
    "occlusion_clear": False if interrupt else True,
    "interrupt_requested": "obstacle_clearance" if interrupt else None,
    "main_loop_frozen": interrupt,
    "posted": False,
}, sort_keys=True))
PY
)"

emit "$(python3 - "$pre_payload" "$active_payload" "$MAIN_TARGET_TITLE" <<'PY'
import json
import sys
pre, active = [json.loads(arg) for arg in sys.argv[1:3]]
target_title = sys.argv[3]
trigger = (pre.get("trigger_candidates") or [{}])[0]
dialog = (active.get("dialog_candidates") or [{}])[0]
print(json.dumps({
    "event": "v146_state_freeze",
    "step_id": "step-0-w3c-public-isr",
    "target_title": target_title,
    "target_point": (trigger.get("frame") or {}),
    "occluder_frame": (dialog.get("frame") or {}),
    "candidate_count": active.get("candidate_count"),
    "legal_candidate_count": active.get("legal_candidate_count"),
    "rejected_candidate_count": active.get("rejected_candidate_count"),
    "clearance_point": active.get("clearance_point"),
    "posted": False,
}, sort_keys=True))
PY
)"

POINT_X="$(json_get "$active_payload" "clearance_point.x")"
POINT_Y="$(json_get "$active_payload" "clearance_point.y")"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$active_payload" <<'PY'
import json
import sys
active = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v146_child_clearance_summary",
    "armed": False,
    "child_stop_reason": "dry_run_projection_stop",
    "child_clearance_resolved": active.get("safe_to_arm"),
    "child_click_posted": False,
    "child_target_clear_after": False,
    "child_candidate_count": active.get("candidate_count"),
    "child_legal_candidate_count": active.get("legal_candidate_count"),
    "child_rejected_candidate_count": active.get("rejected_candidate_count"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "posted": False,
}, sort_keys=True))
PY
)"
    emit "$(python3 - <<'PY'
import json
print(json.dumps({
    "event": "v146_public_isr_e2e_summary",
    "armed": False,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "isr_complete": False,
    "resume_allowed": False,
    "requires_fresh_v12_remap": False,
    "main_fire_mode": "projection_only",
    "main_click_posted": False,
    "stop_reason": "dry_run_isr_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v14.6 public ISR E2E complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v146-public-isr-e2e","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

MOVE_JSON="$(post_action "clearance" "move" "$POINT_X" "$POINT_Y" "move_mouse")"
emit "$(python3 - "$MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "isr_clearance", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
CLICK_JSON="$(post_action "clearance" "click" "$POINT_X" "$POINT_Y" "click_point")"
emit "$(python3 - "$CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "isr_clearance", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

post_payload="$(wait_for_ground_state)"
emit "$post_payload"

emit "$(python3 - "$active_payload" "$MOVE_JSON" "$CLICK_JSON" "$post_payload" <<'PY'
import json
import sys
active, move, click, post = [json.loads(arg) for arg in sys.argv[1:5]]
move_posted = (move.get("receipt") or {}).get("posted") is True
click_posted = (click.get("receipt") or {}).get("posted") is True
target_clear_after = post.get("public_obstacle_seen") is False and post.get("trigger_found") is True
print(json.dumps({
    "event": "v146_child_clearance_summary",
    "armed": True,
    "child_stop_reason": "complete" if target_clear_after else "modal_not_cleared",
    "child_clearance_resolved": active.get("safe_to_arm"),
    "child_move_posted": move_posted,
    "child_click_posted": click_posted,
    "child_target_clear_after": target_clear_after,
    "child_candidate_count": active.get("candidate_count"),
    "child_legal_candidate_count": active.get("legal_candidate_count"),
    "child_rejected_candidate_count": active.get("rejected_candidate_count"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "posted": move_posted and click_posted,
}, sort_keys=True))
PY
)"

fresh_remap_ok="$(python3 - "$post_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print("true" if payload.get("public_obstacle_seen") is False and payload.get("trigger_found") is True else "false")
PY
)"

MAIN_MOVE_POSTED=false
MAIN_CLICK_POSTED=false
if [[ "$MAIN_FIRE" == true ]]; then
    MAIN_X="$(json_get "$post_payload" "trigger_candidates.0.frame.center_x")"
    MAIN_Y="$(json_get "$post_payload" "trigger_candidates.0.frame.center_y")"
    if [[ -z "$MAIN_X" || -z "$MAIN_Y" ]]; then
        echo "[v14.6] ERROR: main target was not available for optional main fire" >&2
        exit 1
    fi
    MAIN_MOVE_JSON="$(post_action "main" "move" "$MAIN_X" "$MAIN_Y" "move_mouse")"
    emit "$(python3 - "$MAIN_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "main_fire", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    MAIN_CLICK_JSON="$(post_action "main" "click" "$MAIN_X" "$MAIN_Y" "click_point")"
    emit "$(python3 - "$MAIN_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "main_fire", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    MAIN_MOVE_POSTED="$(python3 - "$MAIN_MOVE_JSON" <<'PY'
import json, sys
print("true" if (json.loads(sys.argv[1]).get("receipt") or {}).get("posted") is True else "false")
PY
)"
    MAIN_CLICK_POSTED="$(python3 - "$MAIN_CLICK_JSON" <<'PY'
import json, sys
print("true" if (json.loads(sys.argv[1]).get("receipt") or {}).get("posted") is True else "false")
PY
)"
fi

emit "$(python3 - "$fresh_remap_ok" "$MAIN_FIRE" "$MAIN_MOVE_POSTED" "$MAIN_CLICK_POSTED" <<'PY'
import json
import sys
fresh_remap_ok = sys.argv[1] == "true"
main_fire = sys.argv[2] == "true"
main_move_posted = sys.argv[3] == "true"
main_click_posted = sys.argv[4] == "true"
print(json.dumps({
    "event": "v146_public_isr_e2e_summary",
    "armed": True,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "isr_complete": fresh_remap_ok,
    "resume_allowed": fresh_remap_ok,
    "requires_fresh_v12_remap": True,
    "fresh_remap_done": fresh_remap_ok,
    "main_fire_mode": "armed_optional" if main_fire else "projection_only",
    "main_move_posted": main_move_posted,
    "main_click_posted": main_click_posted,
    "sequence_complete": fresh_remap_ok and (not main_fire or main_click_posted),
    "stop_reason": "complete" if fresh_remap_ok else "isr_remap_failed",
    "posted": True,
    "physical_input_posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v14.6 public ISR E2E complete"
echo "========================================================================"
