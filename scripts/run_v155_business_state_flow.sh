#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V155_OUTPUT_DIR:-/tmp/genesis_v155_business_state_flow}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
CLEARANCE_BIN="${GENESIS_V155_CLEARANCE_BIN:-$OUTPUT_DIR/ax_obstacle_clearance_probe}"
FORM_BIN="${GENESIS_V155_FORM_BIN:-$OUTPUT_DIR/ax_v155_business_form_probe}"
OS_SOCKET="${GENESIS_V155_OS_SOCKET:-/tmp/genesis_os_driver_v155.sock}"
DRIVER_LOG="${GENESIS_V155_DRIVER_LOG:-/tmp/genesis_os_driver_v155.log}"
BROWSER_APP="${GENESIS_V155_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V155_BROWSER_BUNDLE_ID:-com.apple.Safari}"
START_URL="${GENESIS_V155_START_URL:-$(python3 - "$ROOT_DIR/fixtures/v15_5/business_form.html" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)}"
URL_DOMAIN_LOCK="${GENESIS_V155_URL_DOMAIN_LOCK:-/fixtures/v15_5/}"
WINDOW_TITLE="${GENESIS_V155_WINDOW_TITLE:-Genesis v15.5 Business Flow}"
COMMIT_TITLE="${GENESIS_V155_COMMIT_TITLE:-Commit profile}"
FIELD_TITLE="${GENESIS_V155_FIELD_TITLE:-Operator Code}"
OPERATOR_CODE="${GENESIS_V155_OPERATOR_CODE:-GENESIS-V155}"
EXPECTED_STATUS="${GENESIS_V155_EXPECT_STATUS_CONTAINS:-profile_saved:${OPERATOR_CODE}:standby}"
POLL_TIMEOUT_MS="${GENESIS_V155_POLL_TIMEOUT_MS:-2500}"
POLL_INTERVAL_MS="${GENESIS_V155_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V155_ARMED_BUSINESS_STATE_FLOW"
AUTO_FIRE_TOKEN="GENESIS_V155_AUTO_FIRE_BUSINESS_STATE_FLOW"
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

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v15.5] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v155-business-state-{namespace}",
    "action_id": f"act-v155-business-state-{namespace}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

open_start_url() {
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
        osascript - "$WINDOW_TITLE" <<'OSA'
on run argv
    set titleNeedle to item 1 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontName to name of front document
                set frontUrl to URL of front document
                if frontName contains titleNeedle and frontUrl is not missing value then return frontUrl
            end try
        end if
        repeat with candidate in documents
            try
                set candidateName to name of candidate
                set candidateUrl to URL of candidate
                if candidateName contains titleNeedle and candidateUrl is not missing value then return candidateUrl
            end try
        end repeat
        return ""
    end tell
end run
OSA
    else
        printf ''
    fi
}

wait_for_domain_url() {
    local url=""
    local deadline_ms=$(( $(now_ms) + 8000 ))
    while (( $(now_ms) <= deadline_ms )); do
        url="$(current_url || true)"
        if [[ -n "$url" && "$url" != "missing value" && "$url" == *"$URL_DOMAIN_LOCK"* ]]; then
            printf '%s\n' "$url"
            return
        fi
        sleep 0.2
    done
    echo "[v15.5] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v155_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v15.5] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_clearance_probe() {
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V130_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V130_TARGET_TITLE="$COMMIT_TITLE" \
    GENESIS_V130_AX_MAX_DEPTH="${GENESIS_V155_AX_MAX_DEPTH:-14}" \
    GENESIS_V130_AX_MAX_NODES="${GENESIS_V155_AX_MAX_NODES:-2800}" \
        "$CLEARANCE_BIN"
}

run_form_probe() {
    GENESIS_V155_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V155_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V155_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V155_FIELD_TITLE="$FIELD_TITLE" \
    GENESIS_V155_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V155_OPERATOR_CODE="$OPERATOR_CODE" \
    GENESIS_V155_EXPECT_STATUS_CONTAINS="$EXPECTED_STATUS" \
        "$FORM_BIN"
}

set_form_field() {
    GENESIS_V155_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V155_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V155_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V155_FIELD_TITLE="$FIELD_TITLE" \
    GENESIS_V155_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V155_OPERATOR_CODE="$OPERATOR_CODE" \
    GENESIS_V155_EXPECT_STATUS_CONTAINS="$EXPECTED_STATUS" \
    GENESIS_V155_SET_FIELD=1 \
    GENESIS_V155_MUTATE_CONFIRM=GENESIS_V155_MUTATE_FORM_STATE \
        "$FORM_BIN"
}

type_text_with_system_events() {
    local text="$1"
    osascript - "$text" <<'OSA'
on run argv
    set textValue to item 1 of argv
    tell application "System Events"
        keystroke textValue
    end tell
    return "ok"
end run
OSA
}

wait_for_clearance_probe() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_clearance_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = payload.get("status") == "ok" and payload.get("target_found") is True
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v15.5] ERROR: clearance probe did not stabilize" >&2
    exit 1
}

wait_for_clearance_clear() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_clearance_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = (
    payload.get("status") == "ok"
    and payload.get("target_found") is True
    and payload.get("occlusion_clear") is True
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v15.5] ERROR: modal did not clear after ISR click" >&2
    exit 1
}

wait_for_form_probe() {
    local require_status="${1:-0}"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_form_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" "$require_status" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
require_status = sys.argv[2] == "1"
ok = (
    payload.get("status") == "ok"
    and payload.get("field_found") is True
    and payload.get("commit_found") is True
    and (not require_status or payload.get("business_state_asserted") is True)
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v15.5] ERROR: form probe did not stabilize" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v15.5 Business State Flow"
echo "========================================================================"
echo "[v15.5] URL: $START_URL"
echo "[v15.5] Field: $FIELD_TITLE -> $OPERATOR_CODE"
echo "[v15.5] Commit target: $COMMIT_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V155_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V155_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v15.5] Armed business flow requires GENESIS_V155_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v15.5] ARMED requested. It will clear the modal, set one field through AX, then click one commit button."
else
    echo "[v15.5] Dry-run mode. It will stop at the business-flow projection boundary."
fi

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$CLEARANCE_BIN"
swiftc scripts/ax_v155_business_form_probe.swift -o "$FORM_BIN"
open_start_url "$START_URL"
wait_for_domain_url >/dev/null
assert_domain_lock "$(current_url || true)"

initial_clearance="$(wait_for_clearance_probe)"
emit "$(python3 - "$initial_clearance" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v155_initial_collision_probe"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

emit "$(python3 - "$initial_clearance" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
interrupt = payload.get("target_found") is True and payload.get("occlusion_clear") is False
print(json.dumps({
    "event": "v155_business_flow_interrupt",
    "interrupt_requested": "obstacle_clearance" if interrupt else None,
    "main_loop_frozen": interrupt,
    "target_title": "Commit profile",
    "target_point": payload.get("target_point"),
    "occluder_kind": payload.get("occluder_kind"),
    "candidate_count": payload.get("candidate_count"),
    "legal_candidate_count": payload.get("legal_candidate_count"),
    "requires_fresh_remap": True,
    "posted": False,
}, sort_keys=True))
PY
)"

if [[ "$(json_get "$initial_clearance" "occlusion_clear")" == "true" ]]; then
    echo "[v15.5] ERROR: expected modal obstacle before business flow" >&2
    exit 2
fi

if [[ "$(json_get "$initial_clearance" "legal_candidate_count")" != "1" ]]; then
    echo "[v15.5] ERROR: expected exactly one legal clearance candidate" >&2
    exit 3
fi

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$initial_clearance" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v155_business_state_flow_summary",
    "armed": False,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "clearance_resolved": payload.get("clearance_resolved"),
    "selected_clearance": (payload.get("selected_clearance") or {}).get("title"),
    "field_set_success": False,
    "commit_click_posted": False,
    "business_state_asserted": False,
    "stop_reason": "dry_run_business_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v15.5 business state flow complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v155-business-state","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

clearance_x="$(json_get "$initial_clearance" "clearance_point.x")"
clearance_y="$(json_get "$initial_clearance" "clearance_point.y")"
if [[ -z "$clearance_x" || -z "$clearance_y" ]]; then
    echo "[v15.5] ERROR: missing clearance point" >&2
    exit 4
fi

CLEAR_MOVE_JSON="$(post_action "clearance" "move" "$clearance_x" "$clearance_y" "move_mouse")"
emit "$(python3 - "$CLEAR_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "isr_clearance", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
CLEAR_CLICK_JSON="$(post_action "clearance" "click" "$clearance_x" "$clearance_y" "click_point")"
emit "$(python3 - "$CLEAR_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "isr_clearance", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

post_clearance="$(wait_for_clearance_clear)"
emit "$(python3 - "$post_clearance" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v155_post_clearance_fresh_remap"
payload["fresh_remap_done"] = True
payload["requires_fresh_remap"] = True
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

if [[ "$(json_get "$post_clearance" "occlusion_clear")" != "true" ]]; then
    echo "[v15.5] ERROR: modal remained after clearance" >&2
    exit 5
fi

set_payload="$(set_form_field)"
emit "$(python3 - "$set_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v155_form_state_mutation"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

if [[ "$(json_get "$set_payload" "input_set_success")" != "true" ]]; then
    echo "[v15.5] ERROR: AX field mutation failed" >&2
    exit 7
fi

field_transport="ax_value"
field_ready=false
field_value_after_set="$(json_get "$set_payload" "field_value_after_set")"
text_fallback_used=false
text_fallback_status="not_needed"
text_fallback_field_click_posted=false
text_fallback_verify_payload="$set_payload"

if [[ "$field_value_after_set" == "$OPERATOR_CODE" ]]; then
    field_ready=true
else
    field_transport="system_events_after_ax_value"
    text_fallback_used=true
    field_x="$(json_get "$set_payload" "field_point.x")"
    field_y="$(json_get "$set_payload" "field_point.y")"
    if [[ -z "$field_x" || -z "$field_y" ]]; then
        echo "[v15.5] ERROR: missing field point for text fallback" >&2
        exit 10
    fi
    FIELD_FOCUS_MOVE_JSON="$(post_action "field_focus" "move" "$field_x" "$field_y" "move_mouse")"
    emit "$(python3 - "$FIELD_FOCUS_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "business_field_focus", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    FIELD_FOCUS_CLICK_JSON="$(post_action "field_focus" "click" "$field_x" "$field_y" "click_point")"
    text_fallback_field_click_posted="$(python3 - "$FIELD_FOCUS_CLICK_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print("true" if (payload.get("receipt") or {}).get("posted") is True else "false")
PY
)"
    emit "$(python3 - "$FIELD_FOCUS_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "business_field_focus", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    sleep 0.1
    set +e
    text_fallback_status="$(type_text_with_system_events "$OPERATOR_CODE" 2>&1)"
    text_fallback_exit=$?
    set -e
    if [[ $text_fallback_exit -ne 0 ]]; then
        emit "$(python3 - "$text_fallback_status" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v155_text_input_fallback",
    "transport": "system_events_after_ax_value",
    "status": "error",
    "error": sys.argv[1],
    "posted": True,
}, sort_keys=True))
PY
)"
        echo "[v15.5] ERROR: System Events text fallback failed" >&2
        exit 11
    fi
    sleep 0.15
    text_fallback_verify_payload="$(wait_for_form_probe 0)"
    emit "$(python3 - "$text_fallback_verify_payload" "$text_fallback_field_click_posted" "$text_fallback_status" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v155_text_input_fallback"
payload["transport"] = "system_events_after_ax_value"
payload["field_click_posted"] = sys.argv[2] == "true"
payload["system_events_status"] = sys.argv[3]
payload["posted"] = True
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$text_fallback_verify_payload" "field_value")" == "$OPERATOR_CODE" ]]; then
        field_ready=true
    fi
fi

if [[ "$field_ready" != "true" ]]; then
    echo "[v15.5] ERROR: field value was not applied to the live form" >&2
    exit 12
fi

commit_x="$(json_get "$set_payload" "commit_point.x")"
commit_y="$(json_get "$set_payload" "commit_point.y")"
if [[ -z "$commit_x" || -z "$commit_y" ]]; then
    echo "[v15.5] ERROR: missing commit point" >&2
    exit 8
fi

before_url="$(current_url || true)"
COMMIT_MOVE_JSON="$(post_action "business_commit" "move" "$commit_x" "$commit_y" "move_mouse")"
emit "$(python3 - "$COMMIT_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "business_commit", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
COMMIT_CLICK_JSON="$(post_action "business_commit" "click" "$commit_x" "$commit_y" "click_point")"
emit "$(python3 - "$COMMIT_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "business_commit", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

sleep 0.25
assert_payload="$(wait_for_form_probe 1)"
emit "$(python3 - "$assert_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v155_business_state_assertion"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
after_url="$(current_url || true)"

emit "$(python3 - "$CLEAR_CLICK_JSON" "$COMMIT_CLICK_JSON" "$set_payload" "$assert_payload" "$before_url" "$after_url" "$field_ready" "$field_transport" "$text_fallback_used" "$text_fallback_status" "$text_fallback_field_click_posted" "$text_fallback_verify_payload" <<'PY'
import json
import sys
clear_click, commit_click, set_payload, assert_payload = [json.loads(arg) for arg in sys.argv[1:5]]
before_url, after_url = sys.argv[5:7]
field_ready = sys.argv[7] == "true"
field_transport = sys.argv[8]
text_fallback_used = sys.argv[9] == "true"
text_fallback_status = sys.argv[10]
text_fallback_field_click_posted = sys.argv[11] == "true"
text_fallback_verify_payload = json.loads(sys.argv[12])
clearance_click_posted = (clear_click.get("receipt") or {}).get("posted") is True
commit_click_posted = (commit_click.get("receipt") or {}).get("posted") is True
field_set_success = set_payload.get("input_set_success") is True
business_state_asserted = assert_payload.get("business_state_asserted") is True
url_unchanged = before_url == after_url
sequence_complete = (
    clearance_click_posted
    and commit_click_posted
    and field_set_success
    and field_ready
    and business_state_asserted
    and url_unchanged
)
print(json.dumps({
    "event": "v155_business_state_flow_summary",
    "armed": True,
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "clearance_click_posted": clearance_click_posted,
    "fresh_remap_done": True,
    "field_set_success": field_set_success,
    "field_value_after_set": set_payload.get("field_value_after_set"),
    "field_value_after_transport": text_fallback_verify_payload.get("field_value"),
    "field_ready": field_ready,
    "field_transport": field_transport,
    "text_fallback_used": text_fallback_used,
    "text_fallback_status": text_fallback_status,
    "text_fallback_field_click_posted": text_fallback_field_click_posted,
    "mode_control_found": set_payload.get("mode_control_found"),
    "commit_click_posted": commit_click_posted,
    "business_state_asserted": business_state_asserted,
    "url_unchanged": url_unchanged,
    "sequence_complete": sequence_complete,
    "posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v15.5 business state flow complete"
echo "========================================================================"
