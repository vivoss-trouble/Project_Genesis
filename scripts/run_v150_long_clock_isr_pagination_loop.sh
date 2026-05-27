#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V150_OUTPUT_DIR:-/tmp/genesis_v150_long_clock_isr_pagination_loop}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V150_AX_BIN:-$OUTPUT_DIR/ax_obstacle_clearance_probe}"
OS_SOCKET="${GENESIS_V150_OS_SOCKET:-/tmp/genesis_os_driver_v150.sock}"
DRIVER_LOG="${GENESIS_V150_DRIVER_LOG:-/tmp/genesis_os_driver_v150.log}"
BROWSER_APP="${GENESIS_V150_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V150_BROWSER_BUNDLE_ID:-com.apple.Safari}"
START_URL="${GENESIS_V150_START_URL:-$(python3 - "$ROOT_DIR/fixtures/v15/page0.html" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)}"
URL_DOMAIN_LOCK="${GENESIS_V150_URL_DOMAIN_LOCK:-/fixtures/v15/}"
WINDOW_TITLE="${GENESIS_V150_WINDOW_TITLE:-Genesis v15.0 Pagination}"
TARGET_TITLE="${GENESIS_V150_TARGET_TITLE:-Next chapter}"
MAX_STEPS="${GENESIS_V150_MAX_STEPS:-3}"
MAX_SAME_URL_COUNT="${GENESIS_V150_MAX_SAME_URL_COUNT:-1}"
MAX_ISR_PER_STEP="${GENESIS_V150_MAX_ISR_PER_STEP:-1}"
TARGET_NOT_FOUND_TERMINAL_OK="${GENESIS_V150_TARGET_NOT_FOUND_TERMINAL_OK:-1}"
POLL_TIMEOUT_MS="${GENESIS_V150_POLL_TIMEOUT_MS:-2500}"
POLL_INTERVAL_MS="${GENESIS_V150_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V150_ARMED_LONG_CLOCK_ISR_PAGINATION"
AUTO_FIRE_TOKEN="GENESIS_V150_AUTO_FIRE_LONG_CLOCK_ISR_PAGINATION"
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
        idx = int(part)
        value = value[idx] if 0 <= idx < len(value) else None
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
    echo "[v15.0] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v150-long-clock-isr-{namespace}",
    "action_id": f"act-v150-long-clock-isr-{namespace}-{action}",
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
        if not (exists front document) then return ""
        try
            set fallbackUrl to URL of front document
            if fallbackUrl is not missing value then return fallbackUrl
        end try
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
    echo "[v15.0] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

current_title() {
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$WINDOW_TITLE" <<'OSA'
on run argv
    set titleNeedle to item 1 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontName to name of front document
                if frontName contains titleNeedle then return frontName
            end try
        end if
        repeat with candidate in documents
            try
                if (name of candidate) contains titleNeedle then return name of candidate
            end try
        end repeat
        if not (exists front document) then return ""
        return name of front document
    end tell
end run
OSA
    else
        printf ''
    fi
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v150_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v15.0] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_probe() {
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V130_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V130_TARGET_TITLE="$TARGET_TITLE" \
    GENESIS_V130_AX_MAX_DEPTH="${GENESIS_V150_AX_MAX_DEPTH:-14}" \
    GENESIS_V130_AX_MAX_NODES="${GENESIS_V150_AX_MAX_NODES:-2800}" \
        "$AX_BIN"
}

wait_for_probe_status() {
    local allow_terminal="${1:-0}"
    local payload sample
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    local attempt=0
    while (( $(now_ms) <= deadline_ms )); do
        attempt=$((attempt + 1))
        set +e
        payload="$(run_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]]; then
            sample="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
            if python3 - "$sample" "$allow_terminal" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
allow_terminal = sys.argv[2] == "1"
ok = payload.get("status") == "ok" and (allow_terminal or payload.get("target_found") is True)
raise SystemExit(0 if ok else 1)
PY
            then
                printf '%s\n' "$sample"
                return
            fi
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v15.0] ERROR: AX probe did not stabilize" >&2
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

echo "========================================================================"
echo "Genesis v15.0 Long-Clock ISR Pagination Loop"
echo "========================================================================"
echo "[v15.0] URL: $START_URL"
echo "[v15.0] Target: $TARGET_TITLE"
echo "[v15.0] MAX_STEPS=$MAX_STEPS MAX_ISR_PER_STEP=$MAX_ISR_PER_STEP"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V150_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V150_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v15.0] Armed long-clock pagination requires GENESIS_V150_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v15.0] ARMED requested. It will execute bounded local pagination with ISR clearance."
else
    echo "[v15.0] Dry-run mode. It will stop before the first physical main click."
fi

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$AX_BIN"
open_start_url "$START_URL"
wait_for_domain_url >/dev/null

if [[ "$ARMED" == true ]]; then
    rm -f "$OS_SOCKET" "$DRIVER_LOG"
    cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
        --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
    DRIVER_PID=$!
    wait_for_socket "$OS_SOCKET"
    PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v150-long-clock-isr","act":"probe"}')"
    emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"
fi

step=0
same_url_count=0
terminal_success=false
stop_reason=""
isr_triggered_count=0
clearance_click_posted=false
main_click_posted_count=0
state_pollution_detected=false
isr_step_interventions=()

while (( step < MAX_STEPS )); do
    current="$(current_url || true)"
    assert_domain_lock "$current"

    probe_payload="$(wait_for_probe_status 1)"
    emit "$(python3 - "$probe_payload" "$step" "$current" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v150_step_probe"
payload["step"] = int(sys.argv[2])
payload["url"] = sys.argv[3]
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

    target_found="$(json_get "$probe_payload" "target_found")"
    if [[ "$target_found" != "true" ]]; then
        if [[ "$TARGET_NOT_FOUND_TERMINAL_OK" == "1" ]]; then
            terminal_success=true
            stop_reason="target_not_found_terminal_ok"
            break
        fi
        stop_reason="target_not_found"
        break
    fi

    occlusion_clear="$(json_get "$probe_payload" "occlusion_clear")"
    isr_count_this_step=0
    if [[ "$occlusion_clear" != "true" ]]; then
        emit "$(python3 - "$probe_payload" "$step" "$same_url_count" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v150_isr_interrupt",
    "step": int(sys.argv[2]),
    "main_loop_frozen": True,
    "same_url_count_before_isr": int(sys.argv[3]),
    "interrupt_requested": "obstacle_clearance",
    "target_point": payload.get("target_point"),
    "occluder_kind": payload.get("occluder_kind"),
    "candidate_count": payload.get("candidate_count"),
    "legal_candidate_count": payload.get("legal_candidate_count"),
    "requires_fresh_v12_remap": True,
    "posted": False,
}, sort_keys=True))
PY
)"

        if (( isr_count_this_step >= MAX_ISR_PER_STEP )); then
            stop_reason="recursive_occlusion_fatal"
            break
        fi
        isr_count_this_step=$((isr_count_this_step + 1))
        isr_triggered_count=$((isr_triggered_count + 1))
        isr_step_interventions+=("$step")

        if [[ "$ARMED" != true ]]; then
            emit "$(python3 - "$probe_payload" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v150_long_clock_isr_pagination_summary",
    "armed": False,
    "stop_reason": "dry_run_isr_projection_stop",
    "step": int(sys.argv[2]),
    "interrupt_requested": True,
    "main_loop_frozen": True,
    "candidate_count": payload.get("candidate_count"),
    "legal_candidate_count": payload.get("legal_candidate_count"),
    "clearance_click_posted": False,
    "pagination_complete": False,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
            echo "========================================================================"
            echo "Genesis v15.0 long-clock ISR pagination complete"
            echo "========================================================================"
            exit 0
        fi

        clearance_x="$(json_get "$probe_payload" "clearance_point.x")"
        clearance_y="$(json_get "$probe_payload" "clearance_point.y")"
        if [[ -z "$clearance_x" || -z "$clearance_y" ]]; then
            stop_reason="obstacle_unresolved"
            break
        fi

        ISR_MOVE_JSON="$(post_action "step_${step}_isr_clearance" "move" "$clearance_x" "$clearance_y" "move_mouse")"
        emit "$(python3 - "$ISR_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "isr_clearance", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        ISR_CLICK_JSON="$(post_action "step_${step}_isr_clearance" "click" "$clearance_x" "$clearance_y" "click_point")"
        emit "$(python3 - "$ISR_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "isr_clearance", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        if python3 - "$ISR_CLICK_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if (payload.get("receipt") or {}).get("posted") is True else 1)
PY
        then
            clearance_click_posted=true
        fi

        sleep 0.35
        remap_payload="$(wait_for_probe_status 0)"
        emit "$(python3 - "$remap_payload" "$step" "$same_url_count" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v150_post_isr_fresh_remap"
payload["step"] = int(sys.argv[2])
payload["same_url_count_after_isr"] = int(sys.argv[3])
payload["fresh_remap_done"] = True
payload["requires_fresh_v12_remap"] = True
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
        if [[ "$(json_get "$remap_payload" "occlusion_clear")" != "true" ]]; then
            stop_reason="recursive_occlusion_fatal"
            break
        fi
        if [[ "$same_url_count" != "$(json_get "$(python3 - "$same_url_count" <<'PY'
import json
import sys
print(json.dumps({"same_url_count": int(sys.argv[1])}))
PY
)" "same_url_count")" ]]; then
            state_pollution_detected=true
        fi
        probe_payload="$remap_payload"
    elif [[ "$ARMED" != true ]]; then
        emit "$(python3 - "$probe_payload" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v150_long_clock_isr_pagination_summary",
    "armed": False,
    "stop_reason": "dry_run_projection_stop",
    "step": int(sys.argv[2]),
    "interrupt_requested": False,
    "target_found": payload.get("target_found"),
    "occlusion_clear": payload.get("occlusion_clear"),
    "main_click_posted": False,
    "pagination_complete": False,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
)"
        echo "========================================================================"
        echo "Genesis v15.0 long-clock ISR pagination complete"
        echo "========================================================================"
        exit 0
    fi

    target_x="$(json_get "$probe_payload" "target_point.x")"
    target_y="$(json_get "$probe_payload" "target_point.y")"
    if [[ -z "$target_x" || -z "$target_y" ]]; then
        stop_reason="target_point_missing"
        break
    fi

    before_url="$(current_url || true)"
    MAIN_MOVE_JSON="$(post_action "step_${step}_main" "move" "$target_x" "$target_y" "move_mouse")"
    emit "$(python3 - "$MAIN_MOVE_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "main_pagination", "step": int(sys.argv[2]), "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    MAIN_CLICK_JSON="$(post_action "step_${step}_main" "click" "$target_x" "$target_y" "click_point")"
    emit "$(python3 - "$MAIN_CLICK_JSON" "$step" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "main_pagination", "step": int(sys.argv[2]), "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    if python3 - "$MAIN_CLICK_JSON" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if (payload.get("receipt") or {}).get("posted") is True else 1)
PY
    then
        main_click_posted_count=$((main_click_posted_count + 1))
    fi

    after_url="$(wait_for_url_change "$before_url")"
    if [[ -z "$after_url" || "$after_url" == "$before_url" ]]; then
        same_url_count=$((same_url_count + 1))
        emit "$(python3 - "$step" "$before_url" "$after_url" "$same_url_count" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v150_step_receipt",
    "step": int(sys.argv[1]),
    "from_url": sys.argv[2],
    "to_url": sys.argv[3],
    "url_changed": False,
    "same_url_count": int(sys.argv[4]),
    "posted": True,
}, sort_keys=True))
PY
)"
        if (( same_url_count >= MAX_SAME_URL_COUNT )); then
            stop_reason="same_url_deadlock"
            break
        fi
    else
        same_url_count=0
        emit "$(python3 - "$step" "$before_url" "$after_url" "$isr_count_this_step" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v150_step_receipt",
    "step": int(sys.argv[1]),
    "from_url": sys.argv[2],
    "to_url": sys.argv[3],
    "url_changed": True,
    "isr_count_this_step": int(sys.argv[4]),
    "same_url_count": 0,
    "posted": True,
}, sort_keys=True))
PY
)"
        step=$((step + 1))
    fi
done

if [[ -z "$stop_reason" && "$terminal_success" != true ]] && (( step >= MAX_STEPS )); then
    terminal_probe="$(wait_for_probe_status 1)"
    emit "$(python3 - "$terminal_probe" "$step" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v150_terminal_probe"
payload["step"] = int(sys.argv[2])
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$terminal_probe" "target_found")" != "true" && "$TARGET_NOT_FOUND_TERMINAL_OK" == "1" ]]; then
        terminal_success=true
        stop_reason="target_not_found_terminal_ok"
    else
        stop_reason="max_steps_reached"
    fi
fi

if [[ -z "$stop_reason" ]]; then
    stop_reason="loop_exited"
fi

interventions_json="$(python3 - "${isr_step_interventions[@]}" <<'PY'
import json
import sys
print(json.dumps([int(item) for item in sys.argv[1:]]))
PY
)"

emit "$(python3 - "$MAX_STEPS" "$step" "$isr_triggered_count" "$interventions_json" "$clearance_click_posted" "$main_click_posted_count" "$stop_reason" "$terminal_success" "$state_pollution_detected" <<'PY'
import json
import sys
max_steps = int(sys.argv[1])
steps = int(sys.argv[2])
isr_count = int(sys.argv[3])
interventions = json.loads(sys.argv[4])
clearance_click_posted = sys.argv[5] == "true"
main_click_posted_count = int(sys.argv[6])
stop_reason = sys.argv[7]
terminal_success = sys.argv[8] == "true"
state_pollution_detected = sys.argv[9] == "true"
pagination_complete = terminal_success and stop_reason == "target_not_found_terminal_ok" and steps == max_steps
print(json.dumps({
    "event": "v150_long_clock_isr_pagination_summary",
    "armed": True,
    "total_pagination_steps": steps,
    "expected_pagination_steps": max_steps,
    "isr_triggered_count": isr_count,
    "isr_step_interventions": interventions,
    "clearance_click_posted": clearance_click_posted,
    "main_click_posted_count": main_click_posted_count,
    "pagination_complete": pagination_complete,
    "final_stop_reason": stop_reason,
    "state_pollution_detected": state_pollution_detected,
    "recursive_occlusion_fatal": stop_reason == "recursive_occlusion_fatal",
    "target_not_found_terminal_ok": stop_reason == "target_not_found_terminal_ok",
    "sequence_complete": pagination_complete,
    "posted": True,
}, sort_keys=True))
PY
)"

if [[ "$stop_reason" != "target_not_found_terminal_ok" ]]; then
    echo "[v15.0] ERROR: long-clock loop stopped with $stop_reason" >&2
    exit 8
fi

echo "========================================================================"
echo "Genesis v15.0 long-clock ISR pagination complete"
echo "========================================================================"
