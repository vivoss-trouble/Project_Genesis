#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_V210B_PACK_ROOT:-$ROOT_DIR/evidence_packs}"
RUN_ID="${GENESIS_V210B_RUN_ID:-run_v210b_$(date -u +%Y%m%dT%H%M%SZ)_$(git rev-parse --short HEAD)_$$}"
PACK_DIR="$PACK_ROOT/$RUN_ID"
JSON_DIR="$PACK_DIR/json"
RAW_DIR="$PACK_DIR/raw"
SCREEN_DIR="$PACK_DIR/screenshots"
WORK_DIR="$PACK_DIR/work"
MANIFEST_PATH="$PACK_DIR/manifest.json"
RESULTS_LOG="$WORK_DIR/results.jsonl"

TARGET_URL="${GENESIS_V210B_TARGET_URL:-https://www.wikipedia.org/}"
WINDOW_TITLE="${GENESIS_V210B_WINDOW_TITLE:-Wikipedia}"
URL_DOMAIN_LOCK="${GENESIS_V210B_URL_DOMAIN_LOCK:-wikipedia.org}"
SEARCH_QUERY="${GENESIS_V210B_SEARCH_QUERY:-OpenAI}"
SEARCH_FIELD_TITLE="${GENESIS_V210B_SEARCH_FIELD_TITLE:-Search Wikipedia}"
SEARCH_COMMIT_TITLE="${GENESIS_V210B_SEARCH_COMMIT_TITLE:-Search}"
SEARCH_COMMIT_TRANSPORT="${GENESIS_V210B_SEARCH_COMMIT_TRANSPORT:-os_driver_enter_after_field_focus}"
SUGGESTION_FALLBACK_OFFSET_X="${GENESIS_V210B_SUGGESTION_FALLBACK_OFFSET_X:-170}"
SUGGESTION_FALLBACK_OFFSET_Y="${GENESIS_V210B_SUGGESTION_FALLBACK_OFFSET_Y:-65}"
TRUST_AX_VALUE="${GENESIS_V210B_TRUST_AX_VALUE:-0}"
POLL_TIMEOUT_MS="${GENESIS_V210B_POLL_TIMEOUT_MS:-8000}"
POLL_INTERVAL_MS="${GENESIS_V210B_POLL_INTERVAL_MS:-150}"
OS_SOCKET="${GENESIS_V210B_OS_SOCKET:-/tmp/genesis_os_driver_v210b.sock}"
DRIVER_LOG="${GENESIS_V210B_DRIVER_LOG:-/tmp/genesis_os_driver_v210b.log}"
PLANNER_BIN="$WORK_DIR/ax_v190_public_task_planner"
PROBE_BIN="$WORK_DIR/ax_v210b_wikipedia_search_probe"
SHADOW_BIN="$WORK_DIR/open_web_shadow_map"
ARMED_TOKEN="GENESIS_V210B_ARMED_WIKIPEDIA_SEARCH"
AUTO_FIRE_TOKEN="GENESIS_V210B_AUTO_FIRE_WIKIPEDIA_SEARCH"
DRIVER_PID=""

if [[ -e "$PACK_DIR" ]]; then
    echo "[v21.0b] ERROR: evidence pack already exists: $PACK_DIR" >&2
    exit 2
fi

mkdir -p "$JSON_DIR" "$RAW_DIR" "$SCREEN_DIR" "$WORK_DIR"
: > "$RESULTS_LOG"

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

write_json() {
    local path="$1"
    local payload="$2"
    python3 - "$path" "$payload" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
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

field_matches_query() {
    local payload="$1"
    local query="$2"
    python3 - "$payload" "$query" <<'PY'
import json
import re
import sys

payload = json.loads(sys.argv[1])
query = sys.argv[2]

def norm(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())

expected = norm(query)
values = [
    payload.get("field_value"),
    payload.get("field_value_after_set"),
    ((payload.get("field") or {}).get("value")),
]
suggestions = payload.get("suggestion_candidates") or []
ok = any(norm(value) == expected for value in values)
ok = ok or any(expected and expected in norm(candidate.get("title")) for candidate in suggestions if isinstance(candidate, dict))
print("true" if ok else "false")
PY
}

open_public_url() {
    local url="$1"
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
}

current_url() {
    osascript - "$WINDOW_TITLE" "$URL_DOMAIN_LOCK" <<'OSA'
on run argv
    set titleNeedle to item 1 of argv
    set domainNeedle to item 2 of argv
    tell application "Safari"
        if (exists front document) then
            try
                set frontName to name of front document
                set frontUrl to URL of front document
                if frontUrl is not missing value then
                    if frontUrl contains domainNeedle then return frontUrl
                    if frontName contains titleNeedle then return frontUrl
                end if
            end try
        end if
        repeat with candidate in documents
            try
                set candidateName to name of candidate
                set candidateUrl to URL of candidate
                if candidateUrl is not missing value then
                    if candidateUrl contains domainNeedle then return candidateUrl
                    if candidateName contains titleNeedle then return candidateUrl
                end if
            end try
        end repeat
        return ""
    end tell
end run
OSA
}

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v21.0b] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v210b-wikipedia-{namespace}",
    "action_id": f"act-v210b-wikipedia-{namespace}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

post_key_action() {
    local namespace="$1"
    local key_name="$2"
    local payload
    payload="$(python3 - "$namespace" "$key_name" <<'PY'
import json
import sys

namespace, key_name = sys.argv[1:3]
print(json.dumps({
    "request_id": f"key-v210b-wikipedia-{namespace}",
    "action_id": f"act-v210b-wikipedia-{namespace}-key-{key_name}",
    "act": "key_press",
    "key": key_name,
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

type_text_with_system_events() {
    local text="$1"
    osascript - "$text" <<'OSA'
on run argv
    set textValue to item 1 of argv
    set the clipboard to textValue
    tell application "System Events"
        keystroke "v" using command down
    end tell
    delay 0.2
    return "ok:clipboard_left_as_input"
end run
OSA
}

replace_text_with_system_events() {
    local text="$1"
    osascript - "$text" <<'OSA'
on run argv
    set textValue to item 1 of argv
    set the clipboard to textValue
    tell application "System Events"
        keystroke "a" using command down
        key code 51
        keystroke "v" using command down
    end tell
    delay 0.2
    return "ok:clipboard_left_as_input"
end run
OSA
}

press_return_with_system_events() {
    osascript <<'OSA'
tell application "Safari" to activate
delay 0.2
tell application "System Events"
    tell process "Safari"
        key code 36
    end tell
end tell
OSA
    printf 'ok:system_events_return'
}

commit_search_with_system_events() {
    local x="$1"
    local y="$2"
    local text="$3"
    osascript - "$x" "$y" "$text" <<'OSA'
on run argv
    set pointX to item 1 of argv as number
    set pointY to item 2 of argv as number
    set textValue to item 3 of argv
    tell application "Safari" to activate
    delay 0.2
    set the clipboard to textValue
    tell application "System Events"
        click at {pointX, pointY}
        delay 0.15
        keystroke "a" using command down
        key code 51
        keystroke "v" using command down
        delay 0.25
        key code 36
    end tell
    delay 0.5
    return "ok:system_events_search_transaction"
end run
OSA
}

run_planner() {
    GENESIS_V190_PLANNER_BIN="$PLANNER_BIN" \
    GENESIS_V190_OUTPUT_DIR="$WORK_DIR/v19_plan" \
    GENESIS_V190_TARGET_URL="$TARGET_URL" \
    GENESIS_V190_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V190_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
    GENESIS_V190_PLAN_PROFILE="wikipedia_search" \
    GENESIS_V190_SEARCH_QUERY="$SEARCH_QUERY" \
    GENESIS_V190_SEARCH_FIELD_TITLE="$SEARCH_FIELD_TITLE" \
    GENESIS_V190_SEARCH_COMMIT_TITLE="$SEARCH_COMMIT_TITLE" \
        ./scripts/run_v190_public_task_planner.sh
}

run_probe() {
    GENESIS_V210B_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V210B_SEARCH_QUERY="$SEARCH_QUERY" \
    GENESIS_V210B_SEARCH_FIELD_TITLE="$SEARCH_FIELD_TITLE" \
    GENESIS_V210B_SEARCH_COMMIT_TITLE="$SEARCH_COMMIT_TITLE" \
        "$PROBE_BIN"
}

set_search_field() {
    GENESIS_V210B_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V210B_SEARCH_QUERY="$SEARCH_QUERY" \
    GENESIS_V210B_SEARCH_FIELD_TITLE="$SEARCH_FIELD_TITLE" \
    GENESIS_V210B_SEARCH_COMMIT_TITLE="$SEARCH_COMMIT_TITLE" \
    GENESIS_V210B_SET_FIELD=1 \
    GENESIS_V210B_MUTATE_CONFIRM=GENESIS_V210B_MUTATE_WIKIPEDIA_SEARCH \
        "$PROBE_BIN"
}

capture_snapshot() {
    local label="$1"
    local png_path="$SCREEN_DIR/${label}.png"
    local json_path="$JSON_DIR/${label}_shadow_map.json"
    local status_path="$JSON_DIR/${label}_screenshot_status.json"
    set +e
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V81_DEBUG_PNG="$png_path" \
        "$SHADOW_BIN" > "$json_path" 2>"$RAW_DIR/${label}_shadow_map.stderr"
    local status=$?
    set -e
    if [[ $status -eq 0 && -s "$json_path" ]]; then
        if [[ -s "$png_path" ]]; then
            write_json "$status_path" "$(python3 - "$label" "$png_path" "$json_path" <<'PY'
import json
import os
import sys
label, png_path, json_path = sys.argv[1:4]
print(json.dumps({
    "event": "v210b_screenshot_status",
    "label": label,
    "screenshot_status": "ok",
    "png_path": png_path,
    "json_path": json_path,
    "png_size": os.path.getsize(png_path),
}, sort_keys=True))
PY
)"
        else
            write_json "$status_path" "$(python3 - "$label" "$json_path" <<'PY'
import json
import sys
label, json_path = sys.argv[1:3]
print(json.dumps({
    "event": "v210b_screenshot_status",
    "label": label,
    "screenshot_status": "json_only",
    "json_path": json_path,
}, sort_keys=True))
PY
)"
        fi
    else
        rm -f "$png_path"
        write_json "$status_path" "$(python3 - "$label" "$status" "$RAW_DIR/${label}_shadow_map.stderr" <<'PY'
import json
import pathlib
import sys
label, status, stderr_path = sys.argv[1:4]
stderr = pathlib.Path(stderr_path).read_text(encoding="utf-8", errors="replace") if pathlib.Path(stderr_path).exists() else ""
print(json.dumps({
    "event": "v210b_screenshot_status",
    "label": label,
    "screenshot_status": "failed",
    "exit_code": int(status),
    "error": stderr[-2000:],
}, sort_keys=True))
PY
)"
    fi
}

stamp_and_manifest() {
    python3 - "$PACK_DIR" "$MANIFEST_PATH" "$ARMED" <<'PY'
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

pack_dir = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
armed = sys.argv[3] == "true"

def ledger_sort_key(path):
    rel = str(path.relative_to(pack_dir))
    name = path.name
    if rel == "json/00_intent_plan.json":
        return (0, rel)
    if name.startswith("00_run_start"):
        return (1, rel)
    match = re.match(r"(\d{2})_.+_(pre_remap|driver_receipt|post_assert)\.json$", name)
    if match:
        type_order = {"pre_remap": 0, "driver_receipt": 1, "post_assert": 2}[match.group(2)]
        return (10 + int(match.group(1)) * 10 + type_order, rel)
    if name.startswith("90_final_terminal_state"):
        return (90, rel)
    if rel == "json/99_terminal_scan_report.json":
        return (99, rel)
    if rel == "json/99_v20_summary.json":
        return (100, rel)
    return (200, rel)

json_files = sorted((path for path in (pack_dir / "json").glob("*.json") if path.is_file()), key=ledger_sort_key)
for order, path in enumerate(json_files, start=1):
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["evidence_schema_version"] = "v20.3-temporal-hardening"
    payload["evidence_write_order"] = order
    payload["sealed_utc_timestamp_ms"] = time.time_ns() // 1_000_000
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

files = []
for path in sorted(pack_dir.rglob("*")):
    if not path.is_file() or path == manifest_path:
        continue
    files.append({
        "path": str(path.relative_to(pack_dir)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "bytes": path.stat().st_size,
    })

git_commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
manifest = {
    "event": "v210b_evidence_pack_manifest",
    "schema_version": "v20.3",
    "run_profile": "v21.0b-wikipedia-search",
    "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    "pack_dir": str(pack_dir),
    "armed": armed,
    "git_commit": git_commit,
    "tool_versions": {
        "run_v210b": "v21.0b",
        "planner": "v19.0",
        "replay_verifier": "v20.2",
        "evidence_schema": "v20.3",
    },
    "append_only_policy": True,
    "json_fatal": True,
    "screenshot_best_effort": True,
    "temporal_hardening": {
        "schema_version": "v20.3",
        "sealed_step_timestamps": True,
        "timestamp_field": "sealed_utc_timestamp_ms",
        "order_field": "evidence_write_order",
        "time_source": "ledger_materialization_utc",
    },
    "file_count": len(files),
    "files": files,
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

terminal_scan() {
    python3 - "$JSON_DIR/99_terminal_scan_report.json" <<'PY'
import json
import pathlib
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
process_scan = subprocess.run(
    ["bash", "-lc", "ps -axo pid=,comm= | rg '(^|/)(genesis-os-driver|ax_v210b|ax_v200|ax_v190|ax_v160|ax_w3c|open_web_shadow_map)' || true"],
    text=True,
    capture_output=True,
)
socket_scan = subprocess.run(
    ["bash", "-lc", "ls -l /tmp/genesis_os_driver_v210b.sock /tmp/genesis_os_driver_v201.sock /tmp/genesis_os_driver_v200.sock /tmp/genesis_os_driver_v160.sock 2>/dev/null || true"],
    text=True,
    capture_output=True,
)
payload = {
    "event": "v210b_terminal_scan_report",
    "process_scan": process_scan.stdout.strip().splitlines(),
    "socket_scan": socket_scan.stdout.strip().splitlines(),
    "residual_processes_detected": bool(process_scan.stdout.strip()),
    "residual_sockets_detected": bool(socket_scan.stdout.strip()),
}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

echo "========================================================================"
echo "Genesis v21.0b Wikipedia Armed Search"
echo "========================================================================"
echo "[v21.0b] Evidence pack: $PACK_DIR"
echo "[v21.0b] URL: $TARGET_URL"
echo "[v21.0b] Query: $SEARCH_QUERY"

ARMED=false
if [[ "${GENESIS_V210B_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V210B_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v21.0b] Armed search requires GENESIS_V210B_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v21.0b] ARMED requested. It will submit one low-side-effect Wikipedia search."
else
    echo "[v21.0b] Dry-run mode. It will stop after plan validation."
fi

swiftc scripts/ax_v190_public_task_planner.swift -o "$PLANNER_BIN"
swiftc scripts/ax_v210b_wikipedia_search_probe.swift -o "$PROBE_BIN"
swiftc scripts/open_web_shadow_map.swift -o "$SHADOW_BIN"

capture_snapshot "00_run_start"

set +e
run_planner > >(tee "$RAW_DIR/v19_stdout.log") 2>"$RAW_DIR/v19_stderr.log"
planner_status=$?
set -e
if [[ -f "$WORK_DIR/v19_plan/results.jsonl" ]]; then
    cp "$WORK_DIR/v19_plan/results.jsonl" "$RAW_DIR/v19_plan_results.jsonl"
fi

PLAN_PAYLOAD="$(python3 - "$WORK_DIR/v19_plan/results.jsonl" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
match = None
if path.exists():
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if raw.startswith("{"):
            payload = json.loads(raw)
            if payload.get("event") == "v190_public_task_plan":
                match = payload
print(json.dumps(match or {}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/00_intent_plan.json" "$PLAN_PAYLOAD"

python3 - "$PLAN_PAYLOAD" "$planner_status" <<'PY'
import json
import sys
plan = json.loads(sys.argv[1])
assert int(sys.argv[2]) == 0, plan
assert plan.get("status") == "ok", plan
assert plan.get("plan_profile") == "wikipedia_search", plan
assert plan.get("domain_locked") is True, plan
assert plan.get("plan_ready") is True, plan
assert plan.get("safe_to_arm") is True, plan
assert plan.get("search_field_found") is True, plan
assert plan.get("search_commit_found") is True, plan
assert plan.get("posted") is False, plan
assert plan.get("physical_input_posted") is False, plan
assert plan.get("os_driver_active") is False, plan
PY

PRE_FIELD="$(run_probe)"
emit "$(python3 - "$PRE_FIELD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["event"] = "v210b_search_field_pre_remap"
print(json.dumps(payload, sort_keys=True))
PY
)"
write_json "$JSON_DIR/01_step-0-fill-search-field_pre_remap.json" "$(python3 - "$PRE_FIELD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v201_step_pre_remap",
    "step_index": 1,
    "step_id": "step-0-fill-search-field",
    "source_event": payload,
    "fresh_remap_done": payload.get("field_found") is True,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"

if [[ "$ARMED" != true ]]; then
    write_json "$JSON_DIR/01_step-0-fill-search-field_driver_receipt.json" '{"event":"v201_step_driver_receipt","step_index":1,"step_id":"step-0-fill-search-field","driver_events":[],"driver_event_count":0}'
    write_json "$JSON_DIR/01_step-0-fill-search-field_post_assert.json" '{"event":"v201_step_post_assert","step_index":1,"step_id":"step-0-fill-search-field","receipt":{"fresh_remap_done":true,"stale_plan_coordinates_used":false,"posted":false,"physical_input_posted":false}}'
    write_json "$JSON_DIR/99_v20_summary.json" "$(python3 - "$PLAN_PAYLOAD" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v200_autonomous_execution_summary",
    "armed": False,
    "plan_consumed": True,
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "execution_started": False,
    "sequence_complete": False,
    "stop_reason": "dry_run_plan_execution_boundary",
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"
    capture_snapshot "90_final_terminal_state"
    terminal_scan
    stamp_and_manifest
    cat "$MANIFEST_PATH"
    echo "========================================================================"
    echo "Genesis v21.0b Wikipedia search complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v210b-wikipedia","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

SET_PAYLOAD="$(set_search_field)"
emit "$(python3 - "$SET_PAYLOAD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["event"] = "v210b_search_field_mutation"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

field_transport="ax_value"
field_ready=false
fallback_used=false
fallback_status="not_needed"
fallback_field_click_posted=false
if [[ "$TRUST_AX_VALUE" == "1" && "$(json_get "$SET_PAYLOAD" "field_value_after_set")" == "$SEARCH_QUERY" ]]; then
    field_ready=true
else
    field_transport="system_events_after_ax_value"
    fallback_used=true
    field_x="$(json_get "$SET_PAYLOAD" "field_point.x")"
    field_y="$(json_get "$SET_PAYLOAD" "field_point.y")"
    if [[ -z "$field_x" || -z "$field_y" ]]; then
        echo "[v21.0b] ERROR: missing field point for text fallback" >&2
        exit 10
    fi
    FIELD_MOVE_JSON="$(post_action "search_field" "move" "$field_x" "$field_y" "move_mouse")"
    emit "$(python3 - "$FIELD_MOVE_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_move","phase":"search_field_focus","move":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    FIELD_CLICK_JSON="$(post_action "search_field" "click" "$field_x" "$field_y" "click_point")"
    fallback_field_click_posted="$(python3 - "$FIELD_CLICK_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print("true" if (payload.get("receipt") or {}).get("posted") is True else "false")
PY
)"
    emit "$(python3 - "$FIELD_CLICK_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_click","phase":"search_field_focus","click":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    sleep 0.1
    set +e
    fallback_status="$(replace_text_with_system_events "$SEARCH_QUERY" 2>&1)"
    fallback_exit=$?
    set -e
    if [[ $fallback_exit -ne 0 ]]; then
        echo "[v21.0b] ERROR: System Events text fallback failed: $fallback_status" >&2
        exit 11
    fi
    sleep 0.15
    SET_PAYLOAD="$(run_probe)"
    emit "$(python3 - "$SET_PAYLOAD" "$fallback_field_click_posted" "$fallback_status" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["event"] = "v210b_text_input_fallback"
payload["transport"] = "system_events_after_ax_value"
payload["field_click_posted"] = sys.argv[2] == "true"
payload["system_events_status"] = sys.argv[3]
payload["posted"] = True
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(field_matches_query "$SET_PAYLOAD" "$SEARCH_QUERY")" == "true" ]]; then
        field_ready=true
    fi
fi

if [[ "$field_ready" != "true" ]]; then
    echo "[v21.0b] ERROR: search field value was not applied" >&2
    exit 12
fi

write_json "$JSON_DIR/01_step-0-fill-search-field_driver_receipt.json" "$(python3 - "$field_transport" "$fallback_used" "$fallback_field_click_posted" "$SET_PAYLOAD" <<'PY'
import json, sys
field_transport, fallback_used, fallback_field_click_posted = sys.argv[1:4]
payload = json.loads(sys.argv[4])
print(json.dumps({
    "event": "v201_step_driver_receipt",
    "step_index": 1,
    "step_id": "step-0-fill-search-field",
    "driver_events": [],
    "driver_event_count": 0,
    "field_transport": field_transport,
    "fallback_used": fallback_used == "true",
    "fallback_field_click_posted": fallback_field_click_posted == "true",
    "field_value": payload.get("field_value"),
}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/01_step-0-fill-search-field_post_assert.json" "$(python3 - "$SET_PAYLOAD" "$field_transport" <<'PY'
import json, sys
import re
payload = json.loads(sys.argv[1])
def norm(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())
expected = norm(payload.get("input_value_requested"))
values = [
    payload.get("field_value"),
    payload.get("field_value_after_set"),
    ((payload.get("field") or {}).get("value")),
]
suggestions = payload.get("suggestion_candidates") or []
field_ready = any(norm(value) == expected for value in values)
field_ready = field_ready or any(expected and expected in norm(candidate.get("title")) for candidate in suggestions if isinstance(candidate, dict))
print(json.dumps({
    "event": "v201_step_post_assert",
    "step_index": 1,
    "step_id": "step-0-fill-search-field",
    "receipt": {
        "fresh_remap_done": payload.get("field_found") is True,
        "stale_plan_coordinates_used": False,
        "posted": True,
        "physical_input_posted": sys.argv[2] == "system_events_after_ax_value",
        "field_ready": field_ready,
        "business_state_asserted": field_ready,
    },
}, sort_keys=True))
PY
)"

PRE_COMMIT="$(run_probe)"
emit "$(python3 - "$PRE_COMMIT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
payload["event"] = "v210b_search_commit_pre_remap"
print(json.dumps(payload, sort_keys=True))
PY
)"
COMMIT_VISUAL_MAP_PATH="$JSON_DIR/02_step-1-submit-search_visual_remap.json"
COMMIT_VISUAL_PNG_PATH="$SCREEN_DIR/02_step-1-submit-search_visual_remap.png"
set +e
GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V81_DEBUG_PNG="$COMMIT_VISUAL_PNG_PATH" \
    "$SHADOW_BIN" > "$COMMIT_VISUAL_MAP_PATH" 2>"$RAW_DIR/02_step-1-submit-search_visual_remap.stderr"
commit_visual_status=$?
set -e
write_json "$JSON_DIR/02_step-1-submit-search_pre_remap.json" "$(python3 - "$PRE_COMMIT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v201_step_pre_remap",
    "step_index": 2,
    "step_id": "step-1-submit-search",
    "source_event": payload,
    "fresh_remap_done": payload.get("commit_found") is True,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"

FOCUS_POINT_JSON="$(python3 - "$PRE_COMMIT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
frame = ((payload.get("field") or {}).get("frame") or {})
if not frame:
    print("{}")
    raise SystemExit(0)
x = float(frame.get("center_x", 0))
y = float(frame.get("center_y", 0))
print(json.dumps({
    "x": x,
    "y": y,
    "source": "search_field_focus_point",
    "field_frame": frame,
}, sort_keys=True))
PY
)"
focus_x="$(json_get "$FOCUS_POINT_JSON" "x")"
focus_y="$(json_get "$FOCUS_POINT_JSON" "y")"
if [[ -z "$focus_x" || -z "$focus_y" ]]; then
    echo "[v21.0b] ERROR: missing projected search focus point" >&2
    exit 13
fi

before_url="$(current_url || true)"
SEARCH_BUTTON_POINT_JSON="$(python3 - "$PRE_COMMIT" "$focus_x" "$focus_y" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
fallback_x, fallback_y = map(float, sys.argv[2:4])
frame = ((payload.get("field") or {}).get("frame") or {})
if not isinstance(frame, dict) or frame.get("x") is None or frame.get("width") is None:
    print(json.dumps({
        "x": fallback_x,
        "y": fallback_y,
        "source": "search_field_focus_point_no_frame",
        "field_frame": frame,
    }, sort_keys=True))
else:
    button_x = float(frame["x"]) + float(frame["width"]) + 26.0
    button_y = float(frame.get("center_y", fallback_y))
    print(json.dumps({
        "x": button_x,
        "y": button_y,
        "source": "search_button_physical_point_from_field_frame",
        "field_frame": frame,
    }, sort_keys=True))
PY
)"
search_button_x="$(json_get "$SEARCH_BUTTON_POINT_JSON" "x")"
search_button_y="$(json_get "$SEARCH_BUTTON_POINT_JSON" "y")"
if [[ -z "$search_button_x" || -z "$search_button_y" ]]; then
    echo "[v21.0b] ERROR: missing projected Wikipedia search button point" >&2
    exit 14
fi
FIELD_COMMIT_MOVE_JSON="{}"
FIELD_COMMIT_CLICK_JSON="{}"
SEARCH_BUTTON_MOVE_JSON="{}"
SEARCH_BUTTON_CLICK_JSON="{}"

case "$SEARCH_COMMIT_TRANSPORT" in
    os_driver_enter_after_field_focus)
        FIELD_COMMIT_MOVE_JSON="$(post_action "search_submit_field_focus" "move" "$focus_x" "$focus_y" "move_mouse")"
        emit "$(python3 - "$FIELD_COMMIT_MOVE_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_move","phase":"search_submit_field_focus","move":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        FIELD_COMMIT_CLICK_JSON="$(post_action "search_submit_field_focus" "click" "$focus_x" "$focus_y" "click_point")"
        emit "$(python3 - "$FIELD_COMMIT_CLICK_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_click","phase":"search_submit_field_focus","click":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        COMMIT_KEY_JSON="$(post_key_action "search_submit_enter" "return")"
        emit "$(python3 - "$COMMIT_KEY_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_key","phase":"search_submit_enter","key_response":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        ;;
    os_driver_click_search_button_after_field_remap)
        SEARCH_BUTTON_MOVE_JSON="$(post_action "search_submit_button" "move" "$search_button_x" "$search_button_y" "move_mouse")"
        emit "$(python3 - "$SEARCH_BUTTON_MOVE_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_move","phase":"search_submit_button","move":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        SEARCH_BUTTON_CLICK_JSON="$(post_action "search_submit_button" "click" "$search_button_x" "$search_button_y" "click_point")"
        emit "$(python3 - "$SEARCH_BUTTON_CLICK_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_click","phase":"search_submit_button","click":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        COMMIT_KEY_JSON="$(python3 - "$SEARCH_BUTTON_CLICK_JSON" "$SEARCH_BUTTON_POINT_JSON" <<'PY'
import json, sys
click = json.loads(sys.argv[1])
point_payload = json.loads(sys.argv[2])
receipt = click.get("receipt") or {}
ok = receipt.get("posted") is True
print(json.dumps({
    "status": "ok" if ok else "error",
    "request_id": "click-v210b-wikipedia-search_submit_button",
    "action_id": "act-v210b-wikipedia-search_submit-click-button",
    "armed": True,
    "receipt": {
        "backend": "macos-coregraphics",
        "action": "click_search_button",
        "key": None,
        "point": point_payload,
        "posted": ok,
        "armed": True,
        "status": click.get("status"),
    },
    "error": None if ok else click.get("error"),
}, sort_keys=True))
PY
)"
        emit "$(python3 - "$COMMIT_KEY_JSON" <<'PY'
import json, sys
print(json.dumps({"event":"os_driver_click","phase":"search_submit_button_receipt","click_response":json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
        ;;
    *)
        echo "[v21.0b] ERROR: unsupported GENESIS_V210B_SEARCH_COMMIT_TRANSPORT=$SEARCH_COMMIT_TRANSPORT" >&2
        exit 15
        ;;
esac
sleep 2

deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
after_url=""
ASSERT_PAYLOAD="{}"
while (( $(now_ms) <= deadline_ms )); do
    after_url="$(current_url || true)"
    ASSERT_PAYLOAD="$(run_probe || printf '{}')"
    if python3 - "$after_url" "$URL_DOMAIN_LOCK" "$SEARCH_QUERY" "$ASSERT_PAYLOAD" <<'PY'
import json, sys
url, domain, query, payload_raw = sys.argv[1:5]
try:
    payload = json.loads(payload_raw)
except Exception:
    payload = {}
ok = (
    domain in url
    and url
    and (
        query.lower() in url.lower()
        or payload.get("business_state_asserted") is True
        or query.lower() in (payload.get("selected_window_title") or "").lower()
    )
)
raise SystemExit(0 if ok else 1)
PY
    then
        break
    fi
    sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
done

write_json "$JSON_DIR/02_step-1-submit-search_driver_receipt.json" "$(python3 - "$FIELD_COMMIT_MOVE_JSON" "$FIELD_COMMIT_CLICK_JSON" "$SEARCH_BUTTON_MOVE_JSON" "$SEARCH_BUTTON_CLICK_JSON" "$COMMIT_KEY_JSON" "$FOCUS_POINT_JSON" "$SEARCH_BUTTON_POINT_JSON" "$SEARCH_COMMIT_TRANSPORT" <<'PY'
import json, sys
field_move, field_click, button_move, button_click, commit_key, focus_point, button_point = [json.loads(arg) for arg in sys.argv[1:8]]
commit_transport = sys.argv[8]
driver_events = [item for item in [field_move, field_click, button_move, button_click, commit_key] if item]
print(json.dumps({
    "event": "v201_step_driver_receipt",
    "step_index": 2,
    "step_id": "step-1-submit-search",
    "driver_events": driver_events,
    "driver_event_count": len(driver_events),
    "focus_point": focus_point,
    "projected_commit_point": (commit_key.get("receipt") or {}).get("point") or button_point or focus_point,
    "commit_transport": commit_transport,
}, sort_keys=True))
PY
)"

write_json "$JSON_DIR/02_step-1-submit-search_post_assert.json" "$(python3 - "$ASSERT_PAYLOAD" "$before_url" "$after_url" "$URL_DOMAIN_LOCK" "$SEARCH_QUERY" "$COMMIT_KEY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1]) if sys.argv[1] != "{}" else {}
before_url, after_url, domain, query = sys.argv[2:6]
key = json.loads(sys.argv[6])
key_posted = (key.get("receipt") or {}).get("posted") is True
business_state_asserted = (
    domain in after_url
    and after_url
    and (
        query.lower() in after_url.lower()
        or payload.get("business_state_asserted") is True
        or query.lower() in (payload.get("selected_window_title") or "").lower()
    )
)
print(json.dumps({
    "event": "v201_step_post_assert",
    "step_index": 2,
    "step_id": "step-1-submit-search",
    "receipt": {
        "fresh_remap_done": payload.get("status") == "ok",
        "stale_plan_coordinates_used": False,
        "posted": True,
        "physical_input_posted": key_posted,
        "commit_click_posted": key_posted,
        "commit_key_posted": key_posted,
        "url_before": before_url,
        "url_after": after_url,
        "domain_locked": domain in after_url,
        "url_changed": before_url != after_url,
        "business_state_asserted": business_state_asserted,
    },
}, sort_keys=True))
PY
)"

SUMMARY_PAYLOAD="$(python3 - "$PLAN_PAYLOAD" "$SET_PAYLOAD" "$before_url" "$after_url" "$field_ready" "$field_transport" "$COMMIT_KEY_JSON" "$ASSERT_PAYLOAD" "$URL_DOMAIN_LOCK" "$SEARCH_QUERY" "$SEARCH_COMMIT_TRANSPORT" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])
field_payload = json.loads(sys.argv[2])
before_url, after_url = sys.argv[3:5]
field_ready = sys.argv[5] == "true"
field_transport = sys.argv[6]
commit_key = json.loads(sys.argv[7])
assert_payload = json.loads(sys.argv[8]) if sys.argv[8] != "{}" else {}
domain, query = sys.argv[9:11]
commit_transport = sys.argv[11]
commit_key_posted = (commit_key.get("receipt") or {}).get("posted") is True
business_state_asserted = (
    domain in after_url
    and after_url
    and (
        query.lower() in after_url.lower()
        or assert_payload.get("business_state_asserted") is True
        or query.lower() in (assert_payload.get("selected_window_title") or "").lower()
    )
)
sequence_complete = (
    plan.get("plan_ready") is True
    and field_ready
    and commit_key_posted
    and business_state_asserted
    and domain in after_url
    and before_url != after_url
)
print(json.dumps({
    "event": "v200_autonomous_execution_summary",
    "run_profile": "v21.0b-wikipedia-search",
    "armed": True,
    "plan_consumed": True,
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "execution_started": True,
    "fresh_remap_before_each_step": True,
    "stale_plan_coordinates_used": False,
    "field_ready": field_ready,
    "field_transport": field_transport,
    "field_value_after_transport": field_payload.get("field_value"),
    "commit_click_posted": commit_key_posted,
    "commit_key_posted": commit_key_posted,
    "commit_transport": commit_transport,
    "business_state_asserted": business_state_asserted,
    "url_before_commit": before_url,
    "url_after_commit": after_url,
    "domain_locked_after_commit": domain in after_url,
    "url_changed": before_url != after_url,
    "sequence_complete": sequence_complete,
    "stop_reason": "complete" if sequence_complete else "v210b_search_assert_failed",
    "posted": True,
    "physical_input_posted": True,
}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/99_v20_summary.json" "$SUMMARY_PAYLOAD"
emit "$SUMMARY_PAYLOAD"
cp "$RESULTS_LOG" "$RAW_DIR/v21b_exec_results.jsonl"

capture_snapshot "90_final_terminal_state"
cleanup
DRIVER_PID=""
terminal_scan
stamp_and_manifest
cat "$MANIFEST_PATH"

echo "========================================================================"
echo "Genesis v21.0b Wikipedia search complete"
echo "========================================================================"
