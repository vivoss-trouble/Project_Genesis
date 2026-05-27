#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V170A_OUTPUT_DIR:-/tmp/genesis_v170a_public_binary_state_collapse}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
PROBE_BIN="${GENESIS_V170A_PROBE_BIN:-$OUTPUT_DIR/ax_v170a_w3c_binary_control_probe}"
OS_SOCKET="${GENESIS_V170A_OS_SOCKET:-/tmp/genesis_os_driver_v170a.sock}"
DRIVER_LOG="${GENESIS_V170A_DRIVER_LOG:-/tmp/genesis_os_driver_v170a.log}"
BROWSER_APP="${GENESIS_V170A_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V170A_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_URL="${GENESIS_V170A_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/checkbox/examples/checkbox/}"
URL_DOMAIN_LOCK="${GENESIS_V170A_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/checkbox/examples/checkbox}"
WINDOW_TITLE="${GENESIS_V170A_WINDOW_TITLE:-Checkbox Example}"
TARGET_LABEL="${GENESIS_V170A_TARGET_LABEL:-Lettuce}"
TARGET_KIND="${GENESIS_V170A_TARGET_KIND:-checkbox}"
POLL_TIMEOUT_MS="${GENESIS_V170A_POLL_TIMEOUT_MS:-3000}"
POLL_INTERVAL_MS="${GENESIS_V170A_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V170A_ARMED_PUBLIC_BINARY_STATE"
AUTO_FIRE_TOKEN="GENESIS_V170A_AUTO_FIRE_PUBLIC_BINARY_STATE"
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
    echo "[v17.0a] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v170a-public-binary-{namespace}",
    "action_id": f"act-v170a-public-binary-{namespace}-{action}",
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
    echo "[v17.0a] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v170a_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v17.0a] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_probe() {
    GENESIS_V170A_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V170A_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V170A_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V170A_TARGET_LABEL="$TARGET_LABEL" \
    GENESIS_V170A_TARGET_KIND="$TARGET_KIND" \
        "$PROBE_BIN"
}

scroll_target_to_visible() {
    GENESIS_V170A_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V170A_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V170A_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V170A_TARGET_LABEL="$TARGET_LABEL" \
    GENESIS_V170A_TARGET_KIND="$TARGET_KIND" \
    GENESIS_V170A_SCROLL_TO_VISIBLE=1 \
    GENESIS_V170A_SCROLL_TO_VISIBLE_CONFIRM=GENESIS_V170A_SCROLL_TO_VISIBLE_PUBLIC_BINARY \
        "$PROBE_BIN"
}

wait_for_target_ready() {
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
ok = (
    payload.get("status") == "ok"
    and payload.get("target_found") is True
    and payload.get("target_state") in {True, False}
    and payload.get("target_point") is not None
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v17.0a] ERROR: binary target did not stabilize" >&2
    exit 1
}

wait_for_state_change() {
    local pre_state="$1"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" "$pre_state" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
pre = sys.argv[2] == "true"
ok = (
    payload.get("status") == "ok"
    and payload.get("target_found") is True
    and payload.get("target_state") in {True, False}
    and payload.get("target_state") is not pre
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v17.0a] ERROR: binary target state did not change" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v17.0a Public Binary State Collapse"
echo "========================================================================"
echo "[v17.0a] URL: $TARGET_URL"
echo "[v17.0a] Target: $TARGET_KIND / $TARGET_LABEL"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V170A_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V170A_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v17.0a] Armed binary mutation requires GENESIS_V170A_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v17.0a] ARMED requested. It will post one bounded physical click to toggle one public checkbox/radio target."
else
    echo "[v17.0a] Dry-run mode. It will stop before binary-state physical mutation."
fi

swiftc scripts/ax_v170a_w3c_binary_control_probe.swift -o "$PROBE_BIN"
open_public_url "$TARGET_URL"
wait_for_domain_url >/dev/null
assert_domain_lock "$(current_url || true)"

pre_payload="$(wait_for_target_ready)"
traction_payload="$(scroll_target_to_visible)"
emit "$(python3 - "$traction_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170a_binary_ax_scroll_to_visible"
payload["phase"] = "pre_mutation_traction"
print(json.dumps(payload, sort_keys=True))
PY
)"
pre_payload="$(wait_for_target_ready)"
emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170a_binary_ground_state"
payload["phase"] = "pre_mutation"
print(json.dumps(payload, sort_keys=True))
PY
)"

pre_state="$(json_get "$pre_payload" "target_state")"
target_x="$(json_get "$pre_payload" "target_point.x")"
target_y="$(json_get "$pre_payload" "target_point.y")"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v170a_public_binary_state_collapse_summary",
    "armed": False,
    "target_kind": payload.get("target_kind"),
    "target_label": payload.get("target_label"),
    "pre_state": payload.get("target_state"),
    "mutation_posted": False,
    "post_state": None,
    "fresh_remap_done": False,
    "state_changed_once": False,
    "url_unchanged": None,
    "business_state_asserted": False,
    "physical_input_posted": False,
    "posted": False,
    "stop_reason": "dry_run_binary_projection_stop",
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v17.0a public binary state collapse complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v170a-public-binary","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

before_url="$(current_url || true)"
MOVE_JSON="$(post_action "binary_toggle" "move" "$target_x" "$target_y" "move_mouse")"
emit "$(python3 - "$MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "binary_state_toggle", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
CLICK_JSON="$(post_action "binary_toggle" "click" "$target_x" "$target_y" "click_point")"
emit "$(python3 - "$CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "binary_state_toggle", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

post_payload="$(wait_for_state_change "$pre_state")"
emit "$(python3 - "$post_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170a_binary_fresh_remap"
payload["phase"] = "post_mutation"
print(json.dumps(payload, sort_keys=True))
PY
)"
after_url="$(current_url || true)"

emit "$(python3 - "$pre_payload" "$post_payload" "$CLICK_JSON" "$before_url" "$after_url" <<'PY'
import json
import sys
pre_payload, post_payload, click_payload = [json.loads(arg) for arg in sys.argv[1:4]]
before_url, after_url = sys.argv[4:6]
pre_state = pre_payload.get("target_state")
post_state = post_payload.get("target_state")
mutation_posted = (click_payload.get("receipt") or {}).get("posted") is True
state_changed_once = pre_state in {True, False} and post_state in {True, False} and pre_state != post_state
url_unchanged = before_url == after_url
business_state_asserted = mutation_posted and state_changed_once and post_payload.get("fresh_remap_done") is True and url_unchanged
print(json.dumps({
    "event": "v170a_public_binary_state_collapse_summary",
    "armed": True,
    "target_kind": pre_payload.get("target_kind"),
    "target_label": pre_payload.get("target_label"),
    "pre_state": pre_state,
    "mutation_posted": mutation_posted,
    "post_state": post_state,
    "fresh_remap_done": post_payload.get("fresh_remap_done") is True,
    "state_changed_once": state_changed_once,
    "url_before_mutation": before_url,
    "url_after_mutation": after_url,
    "url_unchanged": url_unchanged,
    "business_state_asserted": business_state_asserted,
    "sequence_complete": business_state_asserted,
    "stop_reason": "complete" if business_state_asserted else "binary_state_assert_failed",
    "posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v17.0a public binary state collapse complete"
echo "========================================================================"
