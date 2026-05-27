#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V160_OUTPUT_DIR:-/tmp/genesis_v160_public_controlled_business_mutation}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
W3C_BIN="${GENESIS_V160_W3C_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
FORM_BIN="${GENESIS_V160_FORM_BIN:-$OUTPUT_DIR/ax_v160_w3c_business_form_probe}"
OS_SOCKET="${GENESIS_V160_OS_SOCKET:-/tmp/genesis_os_driver_v160.sock}"
DRIVER_LOG="${GENESIS_V160_DRIVER_LOG:-/tmp/genesis_os_driver_v160.log}"
BROWSER_APP="${GENESIS_V160_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V160_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_URL="${GENESIS_V160_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
URL_DOMAIN_LOCK="${GENESIS_V160_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog}"
WINDOW_TITLE="${GENESIS_V160_WINDOW_TITLE:-Modal Dialog Example}"
TRIGGER_TITLE="${GENESIS_V160_TRIGGER_TITLE:-Add Delivery Address}"
FORM_DIALOG_TITLE="${GENESIS_V160_FORM_DIALOG_TITLE:-Add Delivery Address}"
FIELD_LABEL="${GENESIS_V160_FIELD_LABEL:-Street}"
INPUT_VALUE="${GENESIS_V160_INPUT_VALUE:-42 Genesis Way}"
COMMIT_TITLE="${GENESIS_V160_COMMIT_TITLE:-Verify Address}"
EXPECTED_STATUS="${GENESIS_V160_EXPECT_STATUS_CONTAINS:-Verification Result}"
POLL_TIMEOUT_MS="${GENESIS_V160_POLL_TIMEOUT_MS:-5000}"
POLL_INTERVAL_MS="${GENESIS_V160_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V160_ARMED_PUBLIC_BUSINESS_MUTATION"
AUTO_FIRE_TOKEN="GENESIS_V160_AUTO_FIRE_PUBLIC_BUSINESS_MUTATION"
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
    echo "[v16.0] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v160-public-business-{namespace}",
    "action_id": f"act-v160-public-business-{namespace}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
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
    local deadline_ms=$(( $(now_ms) + 10000 ))
    while (( $(now_ms) <= deadline_ms )); do
        url="$(current_url || true)"
        if [[ -n "$url" && "$url" != "missing value" && "$url" == *"$URL_DOMAIN_LOCK"* ]]; then
            printf '%s\n' "$url"
            return
        fi
        sleep 0.2
    done
    echo "[v16.0] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v160_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v16.0] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_w3c_probe() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_TITLE="$TRIGGER_TITLE" \
        "$W3C_BIN"
}

trigger_modal() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_TITLE="$TRIGGER_TITLE" \
    GENESIS_V145A2_TRIGGER_EXECUTE=1 \
    GENESIS_V145A2_TRIGGER_CONFIRM=GENESIS_V145A2_TRIGGER_W3C_MODAL \
        "$W3C_BIN"
}

run_form_probe() {
    GENESIS_V160_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V160_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V160_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V160_FORM_DIALOG_TITLE="$FORM_DIALOG_TITLE" \
    GENESIS_V160_FIELD_LABEL="$FIELD_LABEL" \
    GENESIS_V160_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V160_INPUT_VALUE="$INPUT_VALUE" \
    GENESIS_V160_EXPECT_STATUS_CONTAINS="$EXPECTED_STATUS" \
        "$FORM_BIN"
}

set_form_field() {
    GENESIS_V160_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V160_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V160_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V160_FORM_DIALOG_TITLE="$FORM_DIALOG_TITLE" \
    GENESIS_V160_FIELD_LABEL="$FIELD_LABEL" \
    GENESIS_V160_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V160_INPUT_VALUE="$INPUT_VALUE" \
    GENESIS_V160_EXPECT_STATUS_CONTAINS="$EXPECTED_STATUS" \
    GENESIS_V160_SET_FIELD=1 \
    GENESIS_V160_MUTATE_CONFIRM=GENESIS_V160_MUTATE_PUBLIC_FORM_STATE \
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

wait_for_w3c_baseline() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_w3c_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
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
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v16.0] ERROR: W3C baseline did not stabilize" >&2
    exit 1
}

wait_for_form_ready() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_form_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = (
    payload.get("status") == "ok"
    and payload.get("form_dialog_found") is True
    and payload.get("field_found") is True
    and payload.get("commit_found") is True
    and payload.get("business_state_asserted") is False
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v16.0] ERROR: W3C business form did not stabilize" >&2
    exit 1
}

wait_for_business_assertion() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_form_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = payload.get("status") == "ok" and payload.get("business_state_asserted") is True
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v16.0] ERROR: W3C business state did not assert" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v16.0 Public Controlled Business Mutation"
echo "========================================================================"
echo "[v16.0] URL: $TARGET_URL"
echo "[v16.0] Trigger: $TRIGGER_TITLE"
echo "[v16.0] Field: $FIELD_LABEL -> $INPUT_VALUE"
echo "[v16.0] Commit target: $COMMIT_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V160_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V160_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v16.0] Armed public mutation requires GENESIS_V160_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v16.0] ARMED requested. It will type one public fixture field and click one non-persistent verification button."
else
    echo "[v16.0] Dry-run mode. It will stop at the public business mutation projection boundary."
fi

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$W3C_BIN"
swiftc scripts/ax_v160_w3c_business_form_probe.swift -o "$FORM_BIN"
open_public_url "$TARGET_URL"
wait_for_domain_url >/dev/null
assert_domain_lock "$(current_url || true)"

baseline_payload="$(wait_for_w3c_baseline)"
emit "$(python3 - "$baseline_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_w3c_ground_state"
payload["phase"] = "s0_baseline"
print(json.dumps(payload, sort_keys=True))
PY
)"

trigger_payload="$(trigger_modal)"
emit "$(python3 - "$trigger_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_w3c_modal_trigger"
payload["phase"] = "s1_form_surface_activation"
print(json.dumps(payload, sort_keys=True))
PY
)"

form_payload="$(wait_for_form_ready)"
emit "$(python3 - "$form_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_public_form_lock"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$baseline_payload" "$form_payload" <<'PY'
import json
import sys
baseline, form = [json.loads(arg) for arg in sys.argv[1:3]]
print(json.dumps({
    "event": "v160_public_controlled_business_mutation_summary",
    "armed": False,
    "baseline_public_obstacle_seen": baseline.get("public_obstacle_seen"),
    "form_dialog_found": form.get("form_dialog_found"),
    "field_found": form.get("field_found"),
    "commit_found": form.get("commit_found"),
    "field_ready": False,
    "commit_click_posted": False,
    "business_state_asserted": False,
    "url_unchanged": None,
    "stop_reason": "dry_run_public_business_projection_stop",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v16.0 public controlled business mutation complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v160-public-business","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

set_payload="$(set_form_field)"
emit "$(python3 - "$set_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_public_field_mutation"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

if [[ "$(json_get "$set_payload" "input_set_success")" != "true" ]]; then
    echo "[v16.0] ERROR: AX field mutation failed" >&2
    exit 7
fi

field_transport="ax_value"
field_ready=false
field_value_after_set="$(json_get "$set_payload" "field_value_after_set")"
text_fallback_used=false
text_fallback_status="not_needed"
text_fallback_field_click_posted=false
text_fallback_verify_payload="$set_payload"

if [[ "$field_value_after_set" == "$INPUT_VALUE" ]]; then
    field_ready=true
else
    field_transport="system_events_after_ax_value"
    text_fallback_used=true
    field_x="$(json_get "$set_payload" "field_point.x")"
    field_y="$(json_get "$set_payload" "field_point.y")"
    if [[ -z "$field_x" || -z "$field_y" ]]; then
        echo "[v16.0] ERROR: missing field point for text fallback" >&2
        exit 10
    fi
    FIELD_FOCUS_MOVE_JSON="$(post_action "field_focus" "move" "$field_x" "$field_y" "move_mouse")"
    emit "$(python3 - "$FIELD_FOCUS_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "public_business_field_focus", "move": json.loads(sys.argv[1])}, sort_keys=True))
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
print(json.dumps({"event": "os_driver_click", "phase": "public_business_field_focus", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    sleep 0.1
    set +e
    text_fallback_status="$(type_text_with_system_events "$INPUT_VALUE" 2>&1)"
    text_fallback_exit=$?
    set -e
    if [[ $text_fallback_exit -ne 0 ]]; then
        emit "$(python3 - "$text_fallback_status" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v160_text_input_fallback",
    "transport": "system_events_after_ax_value",
    "status": "error",
    "error": sys.argv[1],
    "posted": True,
}, sort_keys=True))
PY
)"
        echo "[v16.0] ERROR: System Events text fallback failed" >&2
        exit 11
    fi
    sleep 0.15
    text_fallback_verify_payload="$(wait_for_form_ready)"
    emit "$(python3 - "$text_fallback_verify_payload" "$text_fallback_field_click_posted" "$text_fallback_status" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_text_input_fallback"
payload["transport"] = "system_events_after_ax_value"
payload["field_click_posted"] = sys.argv[2] == "true"
payload["system_events_status"] = sys.argv[3]
payload["posted"] = True
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$text_fallback_verify_payload" "field_value")" == "$INPUT_VALUE" ]]; then
        field_ready=true
    fi
fi

if [[ "$field_ready" != "true" ]]; then
    echo "[v16.0] ERROR: field value was not applied to the public fixture form" >&2
    exit 12
fi

commit_x="$(json_get "$set_payload" "commit_point.x")"
commit_y="$(json_get "$set_payload" "commit_point.y")"
if [[ -z "$commit_x" || -z "$commit_y" ]]; then
    echo "[v16.0] ERROR: missing commit point" >&2
    exit 8
fi

before_url="$(current_url || true)"
COMMIT_MOVE_JSON="$(post_action "public_verify" "move" "$commit_x" "$commit_y" "move_mouse")"
emit "$(python3 - "$COMMIT_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "public_business_verify", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
COMMIT_CLICK_JSON="$(post_action "public_verify" "click" "$commit_x" "$commit_y" "click_point")"
emit "$(python3 - "$COMMIT_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "public_business_verify", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

assert_payload="$(wait_for_business_assertion)"
emit "$(python3 - "$assert_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v160_public_business_state_assertion"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
after_url="$(current_url || true)"

emit "$(python3 - "$COMMIT_CLICK_JSON" "$set_payload" "$assert_payload" "$before_url" "$after_url" "$field_ready" "$field_transport" "$text_fallback_used" "$text_fallback_status" "$text_fallback_field_click_posted" "$text_fallback_verify_payload" <<'PY'
import json
import sys
commit_click, set_payload, assert_payload = [json.loads(arg) for arg in sys.argv[1:4]]
before_url, after_url = sys.argv[4:6]
field_ready = sys.argv[6] == "true"
field_transport = sys.argv[7]
text_fallback_used = sys.argv[8] == "true"
text_fallback_status = sys.argv[9]
text_fallback_field_click_posted = sys.argv[10] == "true"
text_fallback_verify_payload = json.loads(sys.argv[11])
commit_click_posted = (commit_click.get("receipt") or {}).get("posted") is True
field_set_success = set_payload.get("input_set_success") is True
business_state_asserted = assert_payload.get("business_state_asserted") is True
url_unchanged = before_url == after_url
sequence_complete = (
    commit_click_posted
    and field_set_success
    and field_ready
    and business_state_asserted
    and url_unchanged
)
print(json.dumps({
    "event": "v160_public_controlled_business_mutation_summary",
    "armed": True,
    "target_url": before_url,
    "field_set_success": field_set_success,
    "field_value_after_set": set_payload.get("field_value_after_set"),
    "field_value_after_transport": text_fallback_verify_payload.get("field_value"),
    "field_ready": field_ready,
    "field_transport": field_transport,
    "text_fallback_used": text_fallback_used,
    "text_fallback_status": text_fallback_status,
    "text_fallback_field_click_posted": text_fallback_field_click_posted,
    "commit_click_posted": commit_click_posted,
    "business_state_asserted": business_state_asserted,
    "status_match_count": assert_payload.get("status_match_count"),
    "url_before_commit": before_url,
    "url_after_commit": after_url,
    "url_unchanged": url_unchanged,
    "sequence_complete": sequence_complete,
    "stop_reason": "complete" if sequence_complete else "public_business_assert_failed",
    "posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v16.0 public controlled business mutation complete"
echo "========================================================================"
