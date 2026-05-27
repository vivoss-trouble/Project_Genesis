#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V170B_OUTPUT_DIR:-/tmp/genesis_v170b_public_combobox_state_collapse}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
PROBE_BIN="${GENESIS_V170B_PROBE_BIN:-$OUTPUT_DIR/ax_v170b_w3c_combobox_probe}"
OS_SOCKET="${GENESIS_V170B_OS_SOCKET:-/tmp/genesis_os_driver_v170b.sock}"
DRIVER_LOG="${GENESIS_V170B_DRIVER_LOG:-/tmp/genesis_os_driver_v170b.log}"
BROWSER_APP="${GENESIS_V170B_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V170B_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_URL="${GENESIS_V170B_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/combobox/examples/combobox-select-only/}"
TARGET_CACHE_BUST="${GENESIS_V170B_CACHE_BUST:-1}"
URL_DOMAIN_LOCK="${GENESIS_V170B_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/combobox/examples/combobox-select-only}"
WINDOW_TITLE="${GENESIS_V170B_WINDOW_TITLE:-Select-Only Combobox}"
COMBO_LABEL="${GENESIS_V170B_COMBO_LABEL:-Favorite Fruit}"
OPTION_LABEL="${GENESIS_V170B_OPTION_LABEL:-Banana}"
POLL_TIMEOUT_MS="${GENESIS_V170B_POLL_TIMEOUT_MS:-8000}"
POLL_INTERVAL_MS="${GENESIS_V170B_POLL_INTERVAL_MS:-100}"
ARMED_TOKEN="GENESIS_V170B_ARMED_PUBLIC_COMBOBOX_STATE"
AUTO_FIRE_TOKEN="GENESIS_V170B_AUTO_FIRE_PUBLIC_COMBOBOX_STATE"
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
    echo "[v17.0b] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v170b-public-combobox-{namespace}",
    "action_id": f"act-v170b-public-combobox-{namespace}-{action}",
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
    echo "[v17.0b] ERROR: target URL did not stabilize inside domain lock (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v170b_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v17.0b] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

run_probe() {
    GENESIS_V170B_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V170B_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V170B_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V170B_COMBO_LABEL="$COMBO_LABEL" \
    GENESIS_V170B_OPTION_LABEL="$OPTION_LABEL" \
        "$PROBE_BIN"
}

scroll_combo_to_visible() {
    GENESIS_V170B_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V170B_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V170B_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V170B_COMBO_LABEL="$COMBO_LABEL" \
    GENESIS_V170B_OPTION_LABEL="$OPTION_LABEL" \
    GENESIS_V170B_SCROLL_TO_VISIBLE=1 \
    GENESIS_V170B_SCROLL_TO_VISIBLE_CONFIRM=GENESIS_V170B_SCROLL_TO_VISIBLE_PUBLIC_COMBOBOX \
        "$PROBE_BIN"
}

wait_for_combo_ready() {
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
    and payload.get("combo_found") is True
    and payload.get("combo_point") is not None
    and bool(payload.get("combo_value"))
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v17.0b] ERROR: combobox target did not stabilize" >&2
    exit 1
}

wait_for_popup_expanded() {
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
    and payload.get("popup_expanded") is True
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
    echo "[v17.0b] ERROR: combobox popup did not expand with target option" >&2
    exit 1
}

wait_for_combo_value() {
    local expected="$1"
    local payload
    local deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
    while (( $(now_ms) <= deadline_ms )); do
        set +e
        payload="$(run_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$payload" "$expected" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
expected = sys.argv[2].lower()
ok = (
    payload.get("status") == "ok"
    and payload.get("combo_found") is True
    and str(payload.get("combo_value") or "").lower() == expected
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v17.0b] ERROR: combobox value did not collapse to $expected" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v17.0b Public Combobox State Collapse"
echo "========================================================================"

EFFECTIVE_TARGET_URL="$TARGET_URL"
if [[ "$TARGET_CACHE_BUST" == "1" ]]; then
    EFFECTIVE_TARGET_URL="$(python3 - "$TARGET_URL" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

url = sys.argv[1]
parts = urlsplit(url)
query = dict(parse_qsl(parts.query, keep_blank_values=True))
import time
query["genesis_v170b_reset"] = str(int(time.time() * 1000))
print(urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)))
PY
)"
fi

echo "[v17.0b] URL: $EFFECTIVE_TARGET_URL"
echo "[v17.0b] Combo: $COMBO_LABEL -> $OPTION_LABEL"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V170B_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V170B_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v17.0b] Armed combobox mutation requires GENESIS_V170B_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v17.0b] ARMED requested. It will post one combo click and one bounded option click."
else
    echo "[v17.0b] Dry-run mode. It will stop before Z-axis popup mutation."
fi

swiftc scripts/ax_v170b_w3c_combobox_probe.swift -o "$PROBE_BIN"
open_public_url "$EFFECTIVE_TARGET_URL"
wait_for_domain_url >/dev/null
assert_domain_lock "$(current_url || true)"

traction_payload="$(scroll_combo_to_visible)"
emit "$(python3 - "$traction_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170b_combo_ax_scroll_to_visible"
payload["phase"] = "pre_expansion_traction"
print(json.dumps(payload, sort_keys=True))
PY
)"

pre_payload="$(wait_for_combo_ready)"
emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170b_combo_ground_state"
payload["phase"] = "pre_expansion"
print(json.dumps(payload, sort_keys=True))
PY
)"

pre_value="$(json_get "$pre_payload" "combo_value")"
combo_x="$(json_get "$pre_payload" "combo_point.x")"
combo_y="$(json_get "$pre_payload" "combo_point.y")"

if [[ "$ARMED" != true ]]; then
    emit "$(python3 - "$pre_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v170b_public_combobox_state_collapse_summary",
    "armed": False,
    "combo_found": payload.get("combo_found"),
    "pre_value": payload.get("combo_value"),
    "combo_click_posted": False,
    "option_click_posted": False,
    "post_value": None,
    "popup_expanded_seen": False,
    "popup_collapsed_after": None,
    "fresh_remap_done": False,
    "value_changed_once": False,
    "url_unchanged": None,
    "business_state_asserted": False,
    "physical_input_posted": False,
    "posted": False,
    "stop_reason": "dry_run_combobox_projection_stop",
}, sort_keys=True))
PY
)"
    echo "========================================================================"
    echo "Genesis v17.0b public combobox state collapse complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v170b-public-combobox","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

before_url="$(current_url || true)"
COMBO_MOVE_JSON="$(post_action "combo_expand" "move" "$combo_x" "$combo_y" "move_mouse")"
emit "$(python3 - "$COMBO_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "combo_expand", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
COMBO_CLICK_JSON="$(post_action "combo_expand" "click" "$combo_x" "$combo_y" "click_point")"
emit "$(python3 - "$COMBO_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "combo_expand", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

expanded_payload="$(wait_for_popup_expanded)"
emit "$(python3 - "$expanded_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170b_combo_z_axis_expanded"
payload["phase"] = "post_combo_click"
print(json.dumps(payload, sort_keys=True))
PY
)"

option_x="$(json_get "$expanded_payload" "option_point.x")"
option_y="$(json_get "$expanded_payload" "option_point.y")"
OPTION_MOVE_JSON="$(post_action "option_select" "move" "$option_x" "$option_y" "move_mouse")"
emit "$(python3 - "$OPTION_MOVE_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "option_select", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
OPTION_CLICK_JSON="$(post_action "option_select" "click" "$option_x" "$option_y" "click_point")"
emit "$(python3 - "$OPTION_CLICK_JSON" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "option_select", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

post_payload="$(wait_for_combo_value "$OPTION_LABEL")"
emit "$(python3 - "$post_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v170b_combo_fresh_remap"
payload["phase"] = "post_option_select"
print(json.dumps(payload, sort_keys=True))
PY
)"
after_url="$(current_url || true)"

emit "$(python3 - "$pre_payload" "$expanded_payload" "$post_payload" "$COMBO_CLICK_JSON" "$OPTION_CLICK_JSON" "$before_url" "$after_url" <<'PY'
import json
import sys
pre_payload, expanded_payload, post_payload, combo_click, option_click = [json.loads(arg) for arg in sys.argv[1:6]]
before_url, after_url = sys.argv[6:8]
combo_click_posted = (combo_click.get("receipt") or {}).get("posted") is True
option_click_posted = (option_click.get("receipt") or {}).get("posted") is True
pre_value = pre_payload.get("combo_value")
post_value = post_payload.get("combo_value")
popup_expanded_seen = expanded_payload.get("popup_expanded") is True
popup_collapsed_after = post_payload.get("popup_expanded") is False
value_changed_once = bool(pre_value) and bool(post_value) and pre_value != post_value
url_unchanged = before_url == after_url
business_state_asserted = (
    combo_click_posted
    and option_click_posted
    and popup_expanded_seen
    and popup_collapsed_after
    and post_payload.get("fresh_remap_done") is True
    and value_changed_once
    and str(post_value).lower() == str(expanded_payload.get("option_label") or "").lower()
    and url_unchanged
)
print(json.dumps({
    "event": "v170b_public_combobox_state_collapse_summary",
    "armed": True,
    "combo_label": pre_payload.get("combo_label"),
    "option_label": expanded_payload.get("option_label"),
    "pre_value": pre_value,
    "combo_click_posted": combo_click_posted,
    "option_click_posted": option_click_posted,
    "post_value": post_value,
    "popup_expanded_seen": popup_expanded_seen,
    "popup_collapsed_after": popup_collapsed_after,
    "fresh_remap_done": post_payload.get("fresh_remap_done") is True,
    "value_changed_once": value_changed_once,
    "url_before_mutation": before_url,
    "url_after_mutation": after_url,
    "url_unchanged": url_unchanged,
    "business_state_asserted": business_state_asserted,
    "sequence_complete": business_state_asserted,
    "stop_reason": "complete" if business_state_asserted else "combobox_state_assert_failed",
    "posted": True,
}, sort_keys=True))
PY
)"

echo "========================================================================"
echo "Genesis v17.0b public combobox state collapse complete"
echo "========================================================================"
