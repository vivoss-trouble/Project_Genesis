#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V147_OUTPUT_DIR:-/tmp/genesis_v147_public_isr_harmless_main_click}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V147_AX_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
OS_SOCKET="${GENESIS_V147_OS_SOCKET:-/tmp/genesis_os_driver_v147.sock}"
DRIVER_LOG="${GENESIS_V147_DRIVER_LOG:-/tmp/genesis_os_driver_v147.log}"
BROWSER_APP="${GENESIS_V147_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V147_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V147_WINDOW_TITLE:-Modal Dialog Example}"
MAIN_TARGET_TITLE="${GENESIS_V147_MAIN_TARGET_TITLE:-Add Delivery Address}"
HARMLESS_TITLE="${GENESIS_V147_HARMLESS_TITLE:-}"
POLL_TIMEOUT_MS="${GENESIS_V147_POLL_TIMEOUT_MS:-1000}"
POLL_INTERVAL_MS="${GENESIS_V147_POLL_INTERVAL_MS:-50}"
ARMED_TOKEN="GENESIS_V147_ARMED_PUBLIC_ISR_HARMLESS_MAIN"
AUTO_FIRE_TOKEN="GENESIS_V147_AUTO_FIRE_PUBLIC_ISR_HARMLESS_MAIN"
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

current_url() {
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript <<'OSA'
tell application "Safari"
    return URL of front document
end tell
OSA
    else
        printf '%s\n' ""
    fi
}

run_probe() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_TITLE="$MAIN_TARGET_TITLE" \
    GENESIS_V145A2_HARMLESS_TITLE="$HARMLESS_TITLE" \
        "$AX_BIN"
}

trigger_modal() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_TITLE="$MAIN_TARGET_TITLE" \
    GENESIS_V145A2_HARMLESS_TITLE="$HARMLESS_TITLE" \
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
    echo "[v14.7] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v147-public-isr-harmless-main-{namespace}",
    "action_id": f"act-v147-public-isr-harmless-main-{namespace}-{action}",
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
    and payload.get("harmless_target_found") is True
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
    echo "[v14.7] ERROR: W3C baseline or harmless target was not found" >&2
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
    echo "[v14.7] ERROR: W3C modal did not reach ISR safe_to_arm" >&2
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
ok = (
    payload.get("public_obstacle_seen") is False
    and payload.get("trigger_found") is True
    and payload.get("harmless_target_found") is True
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$sample"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v14.7] ERROR: fresh remap did not return to harmless ground state" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v14.7 Public ISR Harmless Main Click"
echo "========================================================================"
echo "[v14.7] URL: $TARGET_URL"
echo "[v14.7] Modal trigger: $MAIN_TARGET_TITLE"
echo "[v14.7] Harmless target filter: ${HARMLESS_TITLE:-<auto>}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V147_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V147_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v14.7] Armed harmless main click requires GENESIS_V147_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v14.7] ARMED requested. It will clear the modal, fresh-remap, then click one harmless web-content target."
else
    echo "[v14.7] Dry-run mode. It will stop at the ISR projection boundary."
fi

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$AX_BIN"
open_public_url "$TARGET_URL"

pre_payload="$(wait_for_pre_trigger)"
emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "pre_trap_harmless_ground_state"
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
harmless = pre.get("selected_harmless_target") or {}
dialog = (active.get("dialog_candidates") or [{}])[0]
interrupt = active.get("public_obstacle_seen") is True and active.get("safe_to_arm") is True
print(json.dumps({
    "event": "v147_main_collision",
    "step_id": "step-0-w3c-public-isr-harmless-main",
    "modal_trigger_title": target_title,
    "main_target_kind": "harmless_static_web_content",
    "harmless_target_found_before_trap": pre.get("harmless_target_found"),
    "harmless_target": harmless,
    "harmless_point_before_trap": pre.get("harmless_point"),
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

emit "$(python3 - "$pre_payload" "$active_payload" <<'PY'
import json
import sys
pre, active = [json.loads(arg) for arg in sys.argv[1:3]]
dialog = (active.get("dialog_candidates") or [{}])[0]
print(json.dumps({
    "event": "v147_state_freeze",
    "step_id": "step-0-w3c-public-isr-harmless-main",
    "main_target": pre.get("selected_harmless_target") or {},
    "main_target_point": pre.get("harmless_point"),
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
    emit "$(python3 - "$pre_payload" "$active_payload" <<'PY'
import json
import sys
pre, active = [json.loads(arg) for arg in sys.argv[1:3]]
print(json.dumps({
    "event": "v147_public_isr_harmless_main_click_summary",
    "armed": False,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "child_clearance_resolved": active.get("safe_to_arm"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "harmless_target_found": pre.get("harmless_target_found"),
    "selected_harmless_label": (pre.get("selected_harmless_target") or {}).get("label"),
    "clearance_click_posted": False,
    "main_click_posted": False,
    "modal_remains_absent": False,
    "url_unchanged": None,
    "stop_reason": "dry_run_isr_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v14.7 public ISR harmless main click complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v147-public-isr-harmless-main","act":"probe"}')"
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

post_clear_payload="$(wait_for_ground_state)"
emit "$post_clear_payload"

MAIN_X="$(json_get "$post_clear_payload" "harmless_point.x")"
MAIN_Y="$(json_get "$post_clear_payload" "harmless_point.y")"
if [[ -z "$MAIN_X" || -z "$MAIN_Y" ]]; then
    echo "[v14.7] ERROR: harmless target was not available after fresh remap" >&2
    exit 1
fi

before_main_url="$(current_url)"

MAIN_MOVE_JSON="$(post_action "main_harmless" "move" "$MAIN_X" "$MAIN_Y" "move_mouse")"
emit "$(python3 - "$MAIN_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "main_harmless_fire", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
MAIN_CLICK_JSON="$(post_action "main_harmless" "click" "$MAIN_X" "$MAIN_Y" "click_point")"
emit "$(python3 - "$MAIN_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "main_harmless_fire", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

sleep 0.25
after_main_payload="$(wait_for_ground_state)"
emit "$(python3 - "$after_main_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "post_main_harmless_remap"
print(json.dumps(payload, sort_keys=True))
PY
)"
after_main_url="$(current_url)"

emit "$(python3 - "$active_payload" "$MOVE_JSON" "$CLICK_JSON" "$post_clear_payload" "$MAIN_MOVE_JSON" "$MAIN_CLICK_JSON" "$after_main_payload" "$before_main_url" "$after_main_url" <<'PY'
import json
import sys
active, clearance_move, clearance_click, post_clear, main_move, main_click, after_main = [
    json.loads(arg) for arg in sys.argv[1:8]
]
before_url, after_url = sys.argv[8:10]
clearance_move_posted = (clearance_move.get("receipt") or {}).get("posted") is True
clearance_click_posted = (clearance_click.get("receipt") or {}).get("posted") is True
main_move_posted = (main_move.get("receipt") or {}).get("posted") is True
main_click_posted = (main_click.get("receipt") or {}).get("posted") is True
child_target_clear_after = post_clear.get("public_obstacle_seen") is False and post_clear.get("harmless_target_found") is True
modal_remains_absent = after_main.get("public_obstacle_seen") is False
url_unchanged = before_url == after_url
sequence_complete = (
    clearance_move_posted
    and clearance_click_posted
    and child_target_clear_after
    and main_move_posted
    and main_click_posted
    and modal_remains_absent
    and url_unchanged
)
print(json.dumps({
    "event": "v147_public_isr_harmless_main_click_summary",
    "armed": True,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "child_clearance_resolved": active.get("safe_to_arm"),
    "selected_clearance": (active.get("selected_clearance") or {}).get("title"),
    "clearance_move_posted": clearance_move_posted,
    "clearance_click_posted": clearance_click_posted,
    "child_target_clear_after": child_target_clear_after,
    "fresh_remap_done": child_target_clear_after,
    "requires_fresh_v12_remap": True,
    "resume_allowed": child_target_clear_after,
    "main_target_kind": "harmless_static_web_content",
    "selected_harmless_label": (post_clear.get("selected_harmless_target") or {}).get("label"),
    "selected_harmless_role": (post_clear.get("selected_harmless_target") or {}).get("role"),
    "main_move_posted": main_move_posted,
    "main_click_posted": main_click_posted,
    "modal_remains_absent": modal_remains_absent,
    "url_before_main_click": before_url,
    "url_after_main_click": after_url,
    "url_unchanged": url_unchanged,
    "sequence_complete": sequence_complete,
    "stop_reason": "complete" if sequence_complete else "post_main_assert_failed",
    "posted": clearance_move_posted and clearance_click_posted and main_move_posted and main_click_posted,
    "physical_input_posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v14.7 public ISR harmless main click complete"
echo "========================================================================"
