#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V180_OUTPUT_DIR:-/tmp/genesis_v180_long_clock_business_mutation_loop}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
CLEARANCE_BIN="${GENESIS_V180_CLEARANCE_BIN:-$OUTPUT_DIR/ax_obstacle_clearance_probe}"
FORM_BIN="${GENESIS_V180_FORM_BIN:-$OUTPUT_DIR/ax_v180_composite_business_probe}"
OS_SOCKET="${GENESIS_V180_OS_SOCKET:-/tmp/genesis_os_driver_v180.sock}"
DRIVER_LOG="${GENESIS_V180_DRIVER_LOG:-/tmp/genesis_os_driver_v180.log}"
BROWSER_APP="${GENESIS_V180_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V180_BROWSER_BUNDLE_ID:-com.apple.Safari}"
START_URL="${GENESIS_V180_START_URL:-$(python3 - "$ROOT_DIR/fixtures/v18/page0.html" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)}"
URL_DOMAIN_LOCK="${GENESIS_V180_URL_DOMAIN_LOCK:-/fixtures/v18/}"
WINDOW_TITLE="${GENESIS_V180_WINDOW_TITLE:-Genesis v18.0 Long-Clock Business}"
COMMIT_TITLE="${GENESIS_V180_COMMIT_TITLE:-Commit profile}"
NEXT_TITLE="${GENESIS_V180_NEXT_TITLE:-Next chapter}"
FIELD_TITLE="${GENESIS_V180_FIELD_TITLE:-Operator Code}"
CHECKBOX_TITLE="${GENESIS_V180_CHECKBOX_TITLE:-Enable survey mode}"
COMBO_TITLE="${GENESIS_V180_COMBO_TITLE:-Favorite Fruit}"
COMBO_VALUE="${GENESIS_V180_COMBO_VALUE:-Banana}"
MAX_STEPS="${GENESIS_V180_MAX_STEPS:-3}"
POLL_TIMEOUT_MS="${GENESIS_V180_POLL_TIMEOUT_MS:-3500}"
POLL_INTERVAL_MS="${GENESIS_V180_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V180_ARMED_LONG_CLOCK_BUSINESS"
AUTO_FIRE_TOKEN="GENESIS_V180_AUTO_FIRE_LONG_CLOCK_BUSINESS"
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
    echo "[v18.0] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v180-long-clock-business-{namespace}",
    "action_id": f"act-v180-long-clock-business-{namespace}-{action}",
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
        osascript - "$WINDOW_TITLE" "$URL_DOMAIN_LOCK" <<'OSA'
on run argv
    set titleNeedle to item 1 of argv
    set urlNeedle to item 2 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontName to name of front document
                set frontUrl to URL of front document
                if (frontName contains titleNeedle or frontUrl contains urlNeedle) and frontUrl is not missing value then return frontUrl
            end try
        end if
        repeat with candidate in documents
            try
                set candidateName to name of candidate
                set candidateUrl to URL of candidate
                if (candidateName contains titleNeedle or candidateUrl contains urlNeedle) and candidateUrl is not missing value then return candidateUrl
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
    echo "[v18.0] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v180_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v18.0] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_clearance_probe() {
    local target_title="$1"
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V130_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V130_TARGET_TITLE="$target_title" \
    GENESIS_V130_AX_MAX_DEPTH="${GENESIS_V180_AX_MAX_DEPTH:-16}" \
    GENESIS_V130_AX_MAX_NODES="${GENESIS_V180_AX_MAX_NODES:-3600}" \
        "$CLEARANCE_BIN"
}

run_form_probe() {
    local operator_code="$1"
    local expected_status="$2"
    GENESIS_V180_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V180_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V180_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V180_FIELD_TITLE="$FIELD_TITLE" \
    GENESIS_V180_CHECKBOX_TITLE="$CHECKBOX_TITLE" \
    GENESIS_V180_COMBO_TITLE="$COMBO_TITLE" \
    GENESIS_V180_COMBO_VALUE="$COMBO_VALUE" \
    GENESIS_V180_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V180_NEXT_TITLE="$NEXT_TITLE" \
    GENESIS_V180_OPERATOR_CODE="$operator_code" \
    GENESIS_V180_EXPECT_STATUS_CONTAINS="$expected_status" \
        "$FORM_BIN"
}

set_field_and_combo() {
    local operator_code="$1"
    local expected_status="$2"
    GENESIS_V180_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V180_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V180_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V180_FIELD_TITLE="$FIELD_TITLE" \
    GENESIS_V180_CHECKBOX_TITLE="$CHECKBOX_TITLE" \
    GENESIS_V180_COMBO_TITLE="$COMBO_TITLE" \
    GENESIS_V180_COMBO_VALUE="$COMBO_VALUE" \
    GENESIS_V180_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V180_NEXT_TITLE="$NEXT_TITLE" \
    GENESIS_V180_OPERATOR_CODE="$operator_code" \
    GENESIS_V180_EXPECT_STATUS_CONTAINS="$expected_status" \
    GENESIS_V180_SET_FIELD=1 \
    GENESIS_V180_MUTATE_CONFIRM=GENESIS_V180_MUTATE_COMPOSITE_FORM \
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
    local target_title="$1"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_clearance_probe "$target_title" 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" "$target_title" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
target_title = sys.argv[2]
ok = payload.get("status") == "ok" and (
    payload.get("target_found") is True or target_title == "terminal-ok"
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v18.0] ERROR: clearance probe did not stabilize for $target_title" >&2
    exit 1
}

wait_for_form_ready() {
    local operator_code="$1"
    local expected_status="$2"
    local require_status="${3:-0}"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_form_probe "$operator_code" "$expected_status" 2>/dev/null)"
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
    and payload.get("checkbox_found") is True
    and payload.get("combo_found") is True
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
    echo "[v18.0] ERROR: form probe did not stabilize" >&2
    exit 1
}

wait_for_combo_option() {
    local operator_code="$1"
    local expected_status="$2"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_form_probe "$operator_code" "$expected_status" 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = (
    payload.get("status") == "ok"
    and payload.get("combo_found") is True
    and payload.get("option_found") is True
    and payload.get("option_point") is not None
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v18.0] ERROR: combo option did not become visible" >&2
    exit 1
}

wait_for_url_change() {
    local previous_url="$1"
    local timeout_sec="${2:-8}"
    local deadline=$((SECONDS + timeout_sec))
    local url=""
    while (( SECONDS <= deadline )); do
        url="$(current_url || true)"
        if [[ -n "$url" && "$url" != "$previous_url" ]]; then
            printf '%s\n' "$url"
            return
        fi
        sleep 0.15
    done
    printf '%s\n' "$url"
}

posted_bool() {
    python3 - "$1" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print("true" if (payload.get("receipt") or {}).get("posted") is True else "false")
PY
}

echo "========================================================================"
echo "Genesis v18.0 Long-Clock Business Mutation Loop"
echo "========================================================================"
echo "[v18.0] URL: $START_URL"
echo "[v18.0] MAX_STEPS=$MAX_STEPS"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V180_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V180_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v18.0] Armed loop requires GENESIS_V180_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v18.0] ARMED requested. It will run bounded local business mutation and pagination."
else
    echo "[v18.0] Dry-run mode. It will stop before the first physical business mutation."
fi

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$CLEARANCE_BIN"
swiftc scripts/ax_v180_composite_business_probe.swift -o "$FORM_BIN"
open_start_url "$START_URL"
wait_for_domain_url >/dev/null

if [[ "$ARMED" == true ]]; then
    rm -f "$OS_SOCKET" "$DRIVER_LOG"
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
    DRIVER_PID=$!
    wait_for_socket "$OS_SOCKET"
    PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v180-long-clock-business","act":"probe"}')"
    emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
fi

step=0
isr_triggered_count=0
business_mutation_count=0
business_state_asserted_count=0
main_click_posted_count=0
clearance_click_posted_count=0
commit_click_posted_count=0
checkbox_click_posted_count=0
field_fallback_used_count=0
state_pollution_detected=false
terminal_success=false
stop_reason=""

while (( step < MAX_STEPS )); do
    current="$(current_url || true)"
    assert_domain_lock "$current"

    operator_code="GENESIS-V18-STEP-${step}"
    expected_status="profile_saved:${step}:${operator_code}:survey_on"

    collision_payload="$(wait_for_clearance_probe "$COMMIT_TITLE")"
    emit "$(python3 - "$collision_payload" "$step" "$current" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_business_collision_probe"
payload["step"] = int(sys.argv[2])
payload["url"] = sys.argv[3]
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

    if [[ "$(json_get "$collision_payload" "occlusion_clear")" == "true" ]]; then
        stop_reason="expected_modal_absent"
        break
    fi
    isr_triggered_count=$((isr_triggered_count + 1))

    if [[ "$ARMED" != true ]]; then
        emit "$(python3 - "$collision_payload" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v180_long_clock_business_mutation_summary",
    "armed": False,
    "step": int(sys.argv[2]),
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "candidate_count": payload.get("candidate_count"),
    "legal_candidate_count": payload.get("legal_candidate_count"),
    "business_mutation_count": 0,
    "business_state_asserted_count": 0,
    "main_click_posted_count": 0,
    "sequence_complete": False,
    "stop_reason": "dry_run_business_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
        echo "========================================================================"
        echo "Genesis v18.0 long-clock business mutation complete"
        echo "========================================================================"
        exit 0
    fi

    clearance_x="$(json_get "$collision_payload" "clearance_point.x")"
    clearance_y="$(json_get "$collision_payload" "clearance_point.y")"
    if [[ -z "$clearance_x" || -z "$clearance_y" ]]; then
        stop_reason="obstacle_unresolved"
        break
    fi

    CLEAR_MOVE_JSON="$(post_action "step_${step}_isr_clearance" "move" "$clearance_x" "$clearance_y" "move_mouse")"
    emit "$(python3 - "$CLEAR_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "isr_clearance", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    CLEAR_CLICK_JSON="$(post_action "step_${step}_isr_clearance" "click" "$clearance_x" "$clearance_y" "click_point")"
    emit "$(python3 - "$CLEAR_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "isr_clearance", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    if [[ "$(posted_bool "$CLEAR_CLICK_JSON")" == "true" ]]; then
        clearance_click_posted_count=$((clearance_click_posted_count + 1))
    fi

    sleep 0.25
    post_clearance="$(wait_for_clearance_probe "$COMMIT_TITLE")"
    emit "$(python3 - "$post_clearance" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_post_isr_fresh_remap"
payload["step"] = int(sys.argv[2])
payload["fresh_remap_done"] = True
payload["requires_fresh_v12_remap"] = True
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$post_clearance" "occlusion_clear")" != "true" ]]; then
        stop_reason="isr_remap_failed"
        break
    fi

    pre_form="$(wait_for_form_ready "$operator_code" "$expected_status" 0)"
    emit "$(python3 - "$pre_form" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_composite_business_ground_state"
payload["step"] = int(sys.argv[2])
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    pre_checkbox_state="$(json_get "$pre_form" "checkbox_state")"

    set_payload="$(set_field_and_combo "$operator_code" "$expected_status")"
    emit "$(python3 - "$set_payload" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_composite_ax_mutation"
payload["step"] = int(sys.argv[2])
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

    field_ready=false
    field_transport="ax_value"
    field_value_after_set="$(json_get "$set_payload" "field_value")"
    if [[ "$field_value_after_set" == "$operator_code" ]]; then
        field_ready=true
    else
        field_transport="system_events_after_ax_value"
        field_fallback_used_count=$((field_fallback_used_count + 1))
        field_x="$(json_get "$set_payload" "field_point.x")"
        field_y="$(json_get "$set_payload" "field_point.y")"
        FIELD_MOVE_JSON="$(post_action "step_${step}_field_focus" "move" "$field_x" "$field_y" "move_mouse")"
        emit "$(python3 - "$FIELD_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "business_field_focus", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        FIELD_CLICK_JSON="$(post_action "step_${step}_field_focus" "click" "$field_x" "$field_y" "click_point")"
        emit "$(python3 - "$FIELD_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "business_field_focus", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        sleep 0.1
        type_text_with_system_events "$operator_code" >/dev/null
        sleep 0.15
        fallback_payload="$(wait_for_form_ready "$operator_code" "$expected_status" 0)"
        emit "$(python3 - "$fallback_payload" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_text_input_fallback"
payload["step"] = int(sys.argv[2])
payload["transport"] = "system_events_after_ax_value"
payload["posted"] = True
print(json.dumps(payload, sort_keys=True))
PY
)"
        if [[ "$(json_get "$fallback_payload" "field_value")" == "$operator_code" ]]; then
            field_ready=true
        fi
    fi
    if [[ "$field_ready" != "true" ]]; then
        stop_reason="field_mutation_failed"
        break
    fi

    checkbox_x="$(json_get "$set_payload" "checkbox_point.x")"
    checkbox_y="$(json_get "$set_payload" "checkbox_point.y")"
    CHECK_MOVE_JSON="$(post_action "step_${step}_checkbox" "move" "$checkbox_x" "$checkbox_y" "move_mouse")"
    emit "$(python3 - "$CHECK_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "business_checkbox", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    CHECK_CLICK_JSON="$(post_action "step_${step}_checkbox" "click" "$checkbox_x" "$checkbox_y" "click_point")"
    emit "$(python3 - "$CHECK_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "business_checkbox", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    if [[ "$(posted_bool "$CHECK_CLICK_JSON")" == "true" ]]; then
        checkbox_click_posted_count=$((checkbox_click_posted_count + 1))
    fi
    sleep 0.15

    post_toggle="$(wait_for_form_ready "$operator_code" "$expected_status" 0)"
    emit "$(python3 - "$post_toggle" "$step" "$pre_checkbox_state" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_checkbox_fresh_remap"
payload["step"] = int(sys.argv[2])
payload["pre_checkbox_state"] = sys.argv[3]
payload["post_checkbox_state"] = payload.get("checkbox_state")
payload["fresh_remap_done"] = True
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$post_toggle" "checkbox_state")" != "true" ]]; then
        stop_reason="checkbox_mutation_failed"
        break
    fi

    post_business_ready="$(wait_for_form_ready "$operator_code" "$expected_status" 0)"
    emit "$(python3 - "$post_business_ready" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_business_ready_fresh_remap"
payload["step"] = int(sys.argv[2])
payload["fresh_remap_done"] = True
payload["combobox_state_inherited_from"] = "v17.0b"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

    commit_x="$(json_get "$post_business_ready" "commit_point.x")"
    commit_y="$(json_get "$post_business_ready" "commit_point.y")"
    before_business_url="$(current_url || true)"
    COMMIT_MOVE_JSON="$(post_action "step_${step}_business_commit" "move" "$commit_x" "$commit_y" "move_mouse")"
    emit "$(python3 - "$COMMIT_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "business_commit", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    COMMIT_CLICK_JSON="$(post_action "step_${step}_business_commit" "click" "$commit_x" "$commit_y" "click_point")"
    emit "$(python3 - "$COMMIT_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "business_commit", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    if [[ "$(posted_bool "$COMMIT_CLICK_JSON")" == "true" ]]; then
        commit_click_posted_count=$((commit_click_posted_count + 1))
    fi
    sleep 0.2

    business_assert="$(wait_for_form_ready "$operator_code" "$expected_status" 1)"
    after_business_url="$(current_url || true)"
    emit "$(python3 - "$business_assert" "$step" "$before_business_url" "$after_business_url" "$field_transport" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_business_state_assertion"
payload["step"] = int(sys.argv[2])
payload["before_url"] = sys.argv[3]
payload["after_url"] = sys.argv[4]
payload["url_unchanged"] = sys.argv[3] == sys.argv[4]
payload["field_transport"] = sys.argv[5]
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$business_assert" "business_state_asserted")" != "true" || "$before_business_url" != "$after_business_url" ]]; then
        stop_reason="business_state_assertion_failed"
        break
    fi
    business_mutation_count=$((business_mutation_count + 1))
    business_state_asserted_count=$((business_state_asserted_count + 1))

    next_probe="$(wait_for_clearance_probe "$NEXT_TITLE")"
    emit "$(python3 - "$next_probe" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_post_business_fresh_remap"
payload["step"] = int(sys.argv[2])
payload["fresh_remap_done"] = True
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$next_probe" "target_found")" != "true" || "$(json_get "$next_probe" "occlusion_clear")" != "true" ]]; then
        stop_reason="post_business_next_remap_failed"
        break
    fi

    next_x="$(json_get "$next_probe" "target_point.x")"
    next_y="$(json_get "$next_probe" "target_point.y")"
    before_next_url="$(current_url || true)"
    NEXT_MOVE_JSON="$(post_action "step_${step}_pagination" "move" "$next_x" "$next_y" "move_mouse")"
    emit "$(python3 - "$NEXT_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "main_pagination", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    NEXT_CLICK_JSON="$(post_action "step_${step}_pagination" "click" "$next_x" "$next_y" "click_point")"
    emit "$(python3 - "$NEXT_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "main_pagination", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    if [[ "$(posted_bool "$NEXT_CLICK_JSON")" == "true" ]]; then
        main_click_posted_count=$((main_click_posted_count + 1))
    fi
    after_next_url="$(wait_for_url_change "$before_next_url")"
    url_changed=false
    if [[ -n "$after_next_url" && "$after_next_url" != "$before_next_url" ]]; then
        url_changed=true
    fi
    emit "$(python3 - "$step" "$before_next_url" "$after_next_url" "$url_changed" "$operator_code" "$expected_status" "$field_transport" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v180_business_pagination_step_receipt",
    "step": int(sys.argv[1]),
    "from_url": sys.argv[2],
    "to_url": sys.argv[3],
    "url_changed": sys.argv[4] == "true",
    "operator_code": sys.argv[5],
    "expected_status": sys.argv[6],
    "field_transport": sys.argv[7],
    "clearance_click_posted": True,
    "checkbox_click_posted": True,
    "commit_click_posted": True,
    "main_click_posted": True,
    "business_state_asserted": True,
    "posted": True,
}, sort_keys=True))
PY
)"
    if [[ "$url_changed" != "true" ]]; then
        stop_reason="pagination_url_unchanged"
        break
    fi

    step=$((step + 1))
done

if [[ -z "$stop_reason" ]] && (( step >= MAX_STEPS )); then
    terminal_probe="$(run_clearance_probe "$NEXT_TITLE" || true)"
    emit "$(python3 - "$terminal_probe" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v180_terminal_probe"
payload["step"] = int(sys.argv[2])
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$terminal_probe" "target_found")" != "true" ]]; then
        terminal_success=true
        stop_reason="target_not_found_terminal_ok"
    else
        stop_reason="max_steps_reached"
    fi
fi

if [[ -z "$stop_reason" ]]; then
    stop_reason="loop_exited"
fi

emit "$(python3 - "$MAX_STEPS" "$step" "$isr_triggered_count" "$clearance_click_posted_count" "$business_mutation_count" "$business_state_asserted_count" "$checkbox_click_posted_count" "$commit_click_posted_count" "$main_click_posted_count" "$field_fallback_used_count" "$stop_reason" "$terminal_success" "$state_pollution_detected" <<'PY'
import json
import sys
expected_steps = int(sys.argv[1])
steps = int(sys.argv[2])
isr_count = int(sys.argv[3])
clearance_count = int(sys.argv[4])
business_count = int(sys.argv[5])
business_asserted = int(sys.argv[6])
checkbox_count = int(sys.argv[7])
commit_count = int(sys.argv[8])
main_clicks = int(sys.argv[9])
fallback_count = int(sys.argv[10])
stop_reason = sys.argv[11]
terminal_success = sys.argv[12] == "true"
state_pollution_detected = sys.argv[13] == "true"
sequence_complete = (
    terminal_success
    and stop_reason == "target_not_found_terminal_ok"
    and steps == expected_steps
    and isr_count == expected_steps
    and clearance_count == expected_steps
    and business_count == expected_steps
    and business_asserted == expected_steps
    and checkbox_count == expected_steps
    and commit_count == expected_steps
    and main_clicks == expected_steps
    and not state_pollution_detected
)
print(json.dumps({
    "event": "v180_long_clock_business_mutation_summary",
    "armed": True,
    "posted": True,
    "total_business_steps": steps,
    "expected_business_steps": expected_steps,
    "isr_triggered_count": isr_count,
    "clearance_click_posted_count": clearance_count,
    "business_mutation_count": business_count,
    "business_state_asserted_count": business_asserted,
    "checkbox_click_posted_count": checkbox_count,
    "commit_click_posted_count": commit_count,
    "main_click_posted_count": main_clicks,
    "field_fallback_used_count": fallback_count,
    "terminal_success": terminal_success,
    "final_stop_reason": stop_reason,
    "state_pollution_detected": state_pollution_detected,
    "target_not_found_terminal_ok": stop_reason == "target_not_found_terminal_ok",
    "sequence_complete": sequence_complete,
}, sort_keys=True))
PY
)"

if [[ "$stop_reason" != "target_not_found_terminal_ok" ]]; then
    echo "[v18.0] ERROR: long-clock business loop stopped with $stop_reason" >&2
    exit 8
fi

echo "========================================================================"
echo "Genesis v18.0 long-clock business mutation complete"
echo "========================================================================"
