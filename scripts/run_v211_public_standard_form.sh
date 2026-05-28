#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_V211_PACK_ROOT:-$ROOT_DIR/evidence_packs}"
RUN_ID="${GENESIS_V211_RUN_ID:-run_v211_$(date -u +%Y%m%dT%H%M%SZ)_$(git rev-parse --short HEAD)_$$}"
PACK_DIR="$PACK_ROOT/$RUN_ID"
JSON_DIR="$PACK_DIR/json"
RAW_DIR="$PACK_DIR/raw"
SCREEN_DIR="$PACK_DIR/screenshots"
WORK_DIR="$PACK_DIR/work"
MANIFEST_PATH="$PACK_DIR/manifest.json"
RESULTS_LOG="$RAW_DIR/v211_exec_results.jsonl"
FORM_BIN="$WORK_DIR/ax_v211_httpbin_form_probe"
SHADOW_BIN="$WORK_DIR/open_web_shadow_map"
OS_SOCKET="${GENESIS_V211_OS_SOCKET:-/tmp/genesis_os_driver_v211.sock}"
DRIVER_LOG="${GENESIS_V211_DRIVER_LOG:-/tmp/genesis_os_driver_v211.log}"

BROWSER_APP="${GENESIS_V211_BROWSER_APP:-Safari}"
BROWSER_BUNDLE_ID="${GENESIS_V211_BROWSER_BUNDLE_ID:-com.apple.Safari}"
TARGET_URL="${GENESIS_V211_TARGET_URL:-https://httpbin.org/forms/post}"
URL_DOMAIN_LOCK="${GENESIS_V211_URL_DOMAIN_LOCK:-httpbin.org}"
WINDOW_TITLE="${GENESIS_V211_WINDOW_TITLE:-httpbin.org}"
FIELD_LABEL="${GENESIS_V211_FIELD_LABEL:-Customer name}"
INPUT_VALUE="${GENESIS_V211_INPUT_VALUE:-Genesis}"
COMMIT_TITLE="${GENESIS_V211_COMMIT_TITLE:-Submit order}"
POLL_TIMEOUT_MS="${GENESIS_V211_POLL_TIMEOUT_MS:-25000}"
POLL_INTERVAL_MS="${GENESIS_V211_POLL_INTERVAL_MS:-200}"
ARMED_TOKEN="GENESIS_V211_ARMED_PUBLIC_STANDARD_FORM"
AUTO_FIRE_TOKEN="GENESIS_V211_AUTO_FIRE_PUBLIC_STANDARD_FORM"
DRIVER_PID=""

if [[ -e "$PACK_DIR" ]]; then
    echo "[v21.1] ERROR: evidence pack already exists: $PACK_DIR" >&2
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

latest_event_or_empty() {
    local path="$1"
    local event_name="$2"
    python3 - "$path" "$event_name" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
event_name = sys.argv[2]
match = None
if path.exists():
    with path.open(encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw.startswith("{"):
                continue
            event = json.loads(raw)
            if event.get("event") == event_name:
                match = event
if match is None:
    match = {}
print(json.dumps(match, sort_keys=True))
PY
}

open_public_url() {
    local url="$1"
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$url" >/dev/null <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        make new document
        set URL of front document to targetUrl
    end tell
    delay 0.2
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
                if (frontName contains titleNeedle or frontUrl contains titleNeedle) and frontUrl is not missing value then return frontUrl
            end try
        end if
        repeat with candidate in documents
            try
                set candidateName to name of candidate
                set candidateUrl to URL of candidate
                if (candidateName contains titleNeedle or candidateUrl contains titleNeedle) and candidateUrl is not missing value then return candidateUrl
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
    local deadline_ms=$(( $(now_ms) + 15000 ))
    while (( $(now_ms) <= deadline_ms )); do
        url="$(current_url || true)"
        if [[ -n "$url" && "$url" != "missing value" && "$url" == "$TARGET_URL"* ]]; then
            printf '%s\n' "$url"
            return
        fi
        sleep 0.2
    done
    echo "[v21.1] ERROR: target URL did not stabilize at $TARGET_URL (last: $url)" >&2
    exit 1
}

assert_domain_lock() {
    local url="$1"
    if [[ "$url" != *"$URL_DOMAIN_LOCK"* ]]; then
        emit "$(python3 - "$url" "$URL_DOMAIN_LOCK" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v211_redline_stop",
    "stop_reason": "domain_lock_violation",
    "url": sys.argv[1],
    "domain_lock": sys.argv[2],
    "posted": False,
}, sort_keys=True))
PY
)"
        echo "[v21.1] ERROR: domain lock violation: $url" >&2
        exit 6
    fi
}

wait_for_socket() {
    local socket_path="$1"
    for _ in $(seq 1 120); do
        if [[ -S "$socket_path" ]]; then
            return
        fi
        sleep 0.1
    done
    echo "[v21.1] ERROR: timed out waiting for $socket_path" >&2
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
    "request_id": f"{action}-v211-httpbin-{namespace}",
    "action_id": f"act-v211-httpbin-{namespace}-{action}",
    "act": request_action,
    "x": float(x),
    "y": float(y),
}, sort_keys=True))
PY
)"
    roundtrip_os_driver "$payload"
}

run_form_probe() {
    GENESIS_V211_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V211_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V211_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V211_FIELD_LABEL="$FIELD_LABEL" \
    GENESIS_V211_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V211_EXPECT_VALUE="$INPUT_VALUE" \
        "$FORM_BIN"
}

set_form_field() {
    GENESIS_V211_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V211_BROWSER_BUNDLE_ID="$BROWSER_BUNDLE_ID" \
    GENESIS_V211_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V211_FIELD_LABEL="$FIELD_LABEL" \
    GENESIS_V211_COMMIT_TITLE="$COMMIT_TITLE" \
    GENESIS_V211_EXPECT_VALUE="$INPUT_VALUE" \
    GENESIS_V211_SET_FIELD=1 \
    GENESIS_V211_MUTATE_CONFIRM=GENESIS_V211_MUTATE_HTTPBIN_FORM_STATE \
        "$FORM_BIN"
}

type_text_with_system_events() {
    local text="$1"
    osascript - "$text" <<'OSA'
on run argv
    set textValue to item 1 of argv
    tell application "System Events"
        keystroke "a" using command down
        delay 0.1
        keystroke textValue
    end tell
    delay 0.25
    return "ok"
end run
OSA
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
    and payload.get("field_found") is True
    and payload.get("commit_found") is True
    and payload.get("response_state_asserted") is False
)
raise SystemExit(0 if ok else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v21.1] ERROR: httpbin form did not stabilize" >&2
    exit 1
}

wait_for_response_assertion() {
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
raise SystemExit(0 if payload.get("response_state_asserted") is True else 1)
PY
        then
            printf '%s\n' "$payload"
            return
        fi
        sleep "$(sleep_ms "$POLL_INTERVAL_MS")"
    done
    echo "[v21.1] ERROR: httpbin response state did not assert" >&2
    exit 1
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
    "event": "v211_screenshot_status",
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
    "event": "v211_screenshot_status",
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
    "event": "v211_screenshot_status",
    "label": label,
    "screenshot_status": "failed",
    "exit_code": int(status),
    "error": stderr[-2000:],
}, sort_keys=True))
PY
)"
    fi
}

write_terminal_scan() {
    local path="$JSON_DIR/99_terminal_scan_report.json"
    python3 - "$path" <<'PY'
import json
import pathlib
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
process_scan = subprocess.run(
    ["bash", "-lc", "ps -axo pid=,comm= | rg '(^|/)(genesis-os-driver|ax_v211|ax_v190|open_web_shadow_map)' || true"],
    text=True,
    capture_output=True,
)
socket_scan = subprocess.run(
    ["bash", "-lc", "ls -l /tmp/genesis_os_driver_v211.sock 2>/dev/null || true"],
    text=True,
    capture_output=True,
)
payload = {
    "event": "v211_terminal_scan_report",
    "process_scan": process_scan.stdout.strip().splitlines(),
    "socket_scan": socket_scan.stdout.strip().splitlines(),
    "residual_processes_detected": bool(process_scan.stdout.strip()),
    "residual_sockets_detected": bool(socket_scan.stdout.strip()),
}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

materialize_manifest() {
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
    if rel == "json/50_isr_intervention_log.json":
        return (50, rel)
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
    "event": "v211_evidence_pack_manifest",
    "schema_version": "v20.3",
    "run_profile": "v21.1-standard-public-form",
    "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    "pack_dir": str(pack_dir),
    "armed": armed,
    "git_commit": git_commit,
    "tool_versions": {
        "runner": "v21.1",
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

ARMED=false
if [[ "${GENESIS_V211_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

echo "========================================================================"
echo "Genesis v21.1 Public Standard Form Armed Chain"
echo "========================================================================"
echo "[v21.1] Evidence pack: $PACK_DIR"
echo "[v21.1] URL: $TARGET_URL"
echo "[v21.1] Domain lock: $URL_DOMAIN_LOCK"

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V211_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v21.1] Armed run requires GENESIS_V211_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v21.1] ARMED requested. It will submit one httpbin test form."
else
    echo "[v21.1] Dry-run mode. It will stop after plan validation."
fi

swiftc scripts/ax_v211_httpbin_form_probe.swift -o "$FORM_BIN"
swiftc scripts/open_web_shadow_map.swift -o "$SHADOW_BIN"

open_public_url "$TARGET_URL"
wait_for_domain_url >/dev/null
assert_domain_lock "$(current_url || true)"
capture_snapshot "00_run_start"

PLAN_DIR="$WORK_DIR/v19_plan"
GENESIS_V190_OUTPUT_DIR="$PLAN_DIR" \
GENESIS_V190_TARGET_URL="$TARGET_URL" \
GENESIS_V190_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V190_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
GENESIS_V190_PLAN_PROFILE="httpbin_standard_form" \
GENESIS_V190_HTTPBIN_FIELD_LABEL="$FIELD_LABEL" \
GENESIS_V190_HTTPBIN_COMMIT_TITLE="$COMMIT_TITLE" \
GENESIS_V190_HTTPBIN_EXPECT_VALUE="$INPUT_VALUE" \
    ./scripts/run_v190_public_task_planner.sh | tee "$RAW_DIR/v19_stdout.log"

PLAN_LOG="$PLAN_DIR/results.jsonl"
cp "$PLAN_LOG" "$RAW_DIR/v19_plan_results.jsonl"
PLAN_PAYLOAD="$(latest_event_or_empty "$PLAN_LOG" "v190_public_task_plan")"
PLAN_SUMMARY="$(latest_event_or_empty "$PLAN_LOG" "v190_public_task_planner_summary")"
write_json "$JSON_DIR/00_intent_plan.json" "$PLAN_PAYLOAD"
write_json "$JSON_DIR/01_public_standard_form_planner_summary.json" "$PLAN_SUMMARY"

emit "$(python3 - "$PLAN_PAYLOAD" "$PLAN_SUMMARY" <<'PY'
import json
import sys

plan, summary = [json.loads(arg) for arg in sys.argv[1:3]]
print(json.dumps({
    "event": "v211_plan_ingested",
    "plan_status": plan.get("status"),
    "plan_profile": plan.get("plan_profile"),
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "domain_locked": plan.get("domain_locked") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "summary_plan_ready": summary.get("plan_ready") is True,
}, sort_keys=True))
PY
)"

python3 - "$PLAN_PAYLOAD" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
assert plan.get("status") == "ok", plan
assert plan.get("plan_profile") == "httpbin_standard_form", plan
assert plan.get("domain_locked") is True, plan
assert plan.get("plan_ready") is True, plan
assert plan.get("safe_to_arm") is True, plan
assert plan.get("target_sequence_count") == 2, plan
assert plan.get("posted") is False, plan
assert plan.get("physical_input_posted") is False, plan
assert plan.get("os_driver_active") is False, plan
PY

initial_form_payload="$(wait_for_form_ready)"
emit "$(python3 - "$initial_form_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v211_httpbin_initial_form_lock"
payload["fresh_remap_done"] = True
payload["stale_plan_coordinates_used"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

if [[ "$ARMED" != true ]]; then
    write_json "$JSON_DIR/99_v20_summary.json" "$(python3 - "$PLAN_PAYLOAD" <<'PY'
import json
import sys
plan = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v211_public_standard_form_summary",
    "armed": False,
    "plan_consumed": True,
    "plan_ready": plan.get("plan_ready") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": plan.get("target_sequence_count"),
    "execution_started": False,
    "sequence_complete": False,
    "stop_reason": "dry_run_plan_execution_boundary",
    "fresh_remap_before_each_step": False,
    "stale_plan_coordinates_used": False,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
)"
    write_terminal_scan
    capture_snapshot "90_final_terminal_state"
    materialize_manifest
    cat "$MANIFEST_PATH"
    echo "========================================================================"
    echo "Genesis v21.1 public standard form complete"
    echo "========================================================================"
    exit 0
fi

rm -f "$OS_SOCKET" "$DRIVER_LOG"
cargo run -p genesis-os-driver -- daemon --socket "$OS_SOCKET" \
    --armed --confirm GENESIS_OS_DRIVER_ARMED > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!
wait_for_socket "$OS_SOCKET"

PROBE_JSON="$(roundtrip_os_driver '{"request_id":"probe-v211-httpbin","act":"probe"}')"
emit "{\"event\":\"os_driver_probe\",\"probe\":$PROBE_JSON}"

field_pre_payload="$initial_form_payload"
write_json "$JSON_DIR/01_step-0-fill-customer-name_pre_remap.json" "$(python3 - "$field_pre_payload" <<'PY'
import json
import sys
source = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v211_step_pre_remap",
    "step_index": 1,
    "step_id": "step-0-fill-customer-name",
    "source_event": source,
    "fresh_remap_done": True,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"

set_payload="$(set_form_field)"
emit "$(python3 - "$set_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v211_httpbin_field_mutation"
payload["posted"] = False
print(json.dumps(payload, sort_keys=True))
PY
)"

field_transport="ax_value"
field_ready=false
text_fallback_used=false
text_fallback_status="not_needed"
field_focus_move_json="{}"
field_focus_click_json="{}"
field_verify_payload="$set_payload"

if [[ "$(json_get "$set_payload" "field_value_after_set")" == "$INPUT_VALUE" ]]; then
    field_ready=true
else
    field_transport="system_events_after_ax_value"
    text_fallback_used=true
    field_x="$(json_get "$set_payload" "field_point.x")"
    field_y="$(json_get "$set_payload" "field_point.y")"
    if [[ -z "$field_x" || -z "$field_y" ]]; then
        echo "[v21.1] ERROR: missing field point for text fallback" >&2
        exit 10
    fi
    field_focus_move_json="$(post_action "field_focus" "move" "$field_x" "$field_y" "move_mouse")"
    emit "$(python3 - "$field_focus_move_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "httpbin_field_focus", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
    field_focus_click_json="$(post_action "field_focus" "click" "$field_x" "$field_y" "click_point")"
    emit "$(python3 - "$field_focus_click_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "httpbin_field_focus", "click": json.loads(sys.argv[1])}, sort_keys=True))
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
    "event": "v211_text_input_fallback",
    "transport": "system_events_after_ax_value",
    "status": "error",
    "error": sys.argv[1],
    "posted": True,
}, sort_keys=True))
PY
)"
        echo "[v21.1] ERROR: System Events text fallback failed" >&2
        exit 11
    fi
    sleep 0.2
    field_verify_payload="$(wait_for_form_ready)"
    emit "$(python3 - "$field_verify_payload" "$text_fallback_status" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["event"] = "v211_text_input_fallback"
payload["transport"] = "system_events_after_ax_value"
payload["system_events_status"] = sys.argv[2]
payload["posted"] = True
print(json.dumps(payload, sort_keys=True))
PY
)"
    if [[ "$(json_get "$field_verify_payload" "field_value")" == "$INPUT_VALUE" ]]; then
        field_ready=true
    fi
fi

if [[ "$field_ready" != "true" ]]; then
    echo "[v21.1] ERROR: field value was not applied to httpbin form" >&2
    exit 12
fi

write_json "$JSON_DIR/01_step-0-fill-customer-name_driver_receipt.json" "$(python3 - "$field_focus_move_json" "$field_focus_click_json" "$field_transport" "$text_fallback_used" <<'PY'
import json
import sys
move, click = [json.loads(arg) for arg in sys.argv[1:3]]
transport = sys.argv[3]
fallback = sys.argv[4] == "true"
driver_events = []
if move:
    driver_events.append({"event": "move", "payload": move})
if click:
    driver_events.append({"event": "click", "payload": click})
print(json.dumps({
    "event": "v211_step_driver_receipt",
    "step_index": 1,
    "step_id": "step-0-fill-customer-name",
    "driver_events": driver_events,
    "driver_event_count": len(driver_events),
    "field_transport": transport,
    "text_fallback_used": fallback,
}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/01_step-0-fill-customer-name_post_assert.json" "$(python3 - "$field_verify_payload" "$field_transport" "$text_fallback_used" <<'PY'
import json
import sys
source = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v211_step_post_assert",
    "step_index": 1,
    "step_id": "step-0-fill-customer-name",
    "receipt": {
        "fresh_remap_done": True,
        "stale_plan_coordinates_used": False,
        "posted": sys.argv[3] == "true",
        "physical_input_posted": sys.argv[3] == "true",
        "field_transport": sys.argv[2],
        "field_ready": source.get("field_value") == source.get("expected_value") or source.get("field_value_after_set") == source.get("expected_value"),
        "business_state_asserted": True,
    },
    "source_event": source,
}, sort_keys=True))
PY
)"

submit_pre_payload="$(wait_for_form_ready)"
write_json "$JSON_DIR/02_step-1-submit-form_pre_remap.json" "$(python3 - "$submit_pre_payload" <<'PY'
import json
import sys
source = json.loads(sys.argv[1])
print(json.dumps({
    "event": "v211_step_pre_remap",
    "step_index": 2,
    "step_id": "step-1-submit-form",
    "source_event": source,
    "fresh_remap_done": True,
    "stale_plan_coordinates_used": False,
}, sort_keys=True))
PY
)"

commit_x="$(json_get "$submit_pre_payload" "commit_point.x")"
commit_y="$(json_get "$submit_pre_payload" "commit_point.y")"
if [[ -z "$commit_x" || -z "$commit_y" ]]; then
    echo "[v21.1] ERROR: missing submit point" >&2
    exit 13
fi

before_url="$(current_url || true)"
commit_move_json="$(post_action "submit_form" "move" "$commit_x" "$commit_y" "move_mouse")"
emit "$(python3 - "$commit_move_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_move", "phase": "httpbin_submit", "move": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"
commit_click_json="$(post_action "submit_form" "click" "$commit_x" "$commit_y" "click_point")"
emit "$(python3 - "$commit_click_json" <<'PY'
import json
import sys
print(json.dumps({"event": "os_driver_click", "phase": "httpbin_submit", "click": json.loads(sys.argv[1])}, sort_keys=True))
PY
)"

response_assert_payload="$(wait_for_response_assertion)"
after_url="$(current_url || true)"
assert_domain_lock "$after_url"
url_changed=false
if [[ "$before_url" != "$after_url" ]]; then
    url_changed=true
fi

write_json "$JSON_DIR/02_step-1-submit-form_driver_receipt.json" "$(python3 - "$commit_move_json" "$commit_click_json" <<'PY'
import json
import sys
move, click = [json.loads(arg) for arg in sys.argv[1:3]]
print(json.dumps({
    "event": "v211_step_driver_receipt",
    "step_index": 2,
    "step_id": "step-1-submit-form",
    "driver_events": [
        {"event": "move", "payload": move},
        {"event": "click", "payload": click},
    ],
    "driver_event_count": 2,
}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/02_step-1-submit-form_post_assert.json" "$(python3 - "$response_assert_payload" "$commit_click_json" "$url_changed" "$before_url" "$after_url" <<'PY'
import json
import sys
source = json.loads(sys.argv[1])
click = json.loads(sys.argv[2])
click_posted = (click.get("receipt") or {}).get("posted") is True
print(json.dumps({
    "event": "v211_step_post_assert",
    "step_index": 2,
    "step_id": "step-1-submit-form",
    "receipt": {
        "fresh_remap_done": True,
        "stale_plan_coordinates_used": False,
        "posted": click_posted,
        "physical_input_posted": click_posted,
        "commit_click_posted": click_posted,
        "url_before_commit": sys.argv[4],
        "url_after_commit": sys.argv[5],
        "url_changed": sys.argv[3] == "true",
        "response_state_asserted": source.get("response_state_asserted") is True,
        "business_state_asserted": source.get("response_state_asserted") is True,
    },
    "source_event": source,
}, sort_keys=True))
PY
)"

emit "$(python3 - "$PLAN_PAYLOAD" "$field_verify_payload" "$commit_click_json" "$response_assert_payload" "$before_url" "$after_url" "$field_ready" "$field_transport" "$text_fallback_used" <<'PY'
import json
import sys
plan, field, click, response = [json.loads(arg) for arg in sys.argv[1:5]]
before_url, after_url = sys.argv[5:7]
field_ready = sys.argv[7] == "true"
field_transport = sys.argv[8]
fallback_used = sys.argv[9] == "true"
commit_click_posted = (click.get("receipt") or {}).get("posted") is True
url_changed = before_url != after_url
response_asserted = response.get("response_state_asserted") is True
sequence_complete = (
    plan.get("plan_ready") is True
    and field_ready
    and commit_click_posted
    and url_changed
    and response_asserted
)
print(json.dumps({
    "event": "v211_public_standard_form_summary",
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
    "text_fallback_used": fallback_used,
    "commit_click_posted": commit_click_posted,
    "url_before_commit": before_url,
    "url_after_commit": after_url,
    "url_changed": url_changed,
    "response_state_asserted": response_asserted,
    "business_state_asserted": response_asserted,
    "sequence_complete": sequence_complete,
    "stop_reason": "complete" if sequence_complete else "v211_public_standard_form_assert_failed",
    "posted": True,
    "physical_input_posted": True,
}, sort_keys=True))
PY
)" | tee "$JSON_DIR/99_v20_summary.json.tmp"
python3 - "$JSON_DIR/99_v20_summary.json.tmp" "$JSON_DIR/99_v20_summary.json" <<'PY'
import json
import pathlib
import sys
raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
payload = json.loads(raw)
path = pathlib.Path(sys.argv[2])
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(sys.argv[1]).unlink()
if not payload.get("sequence_complete"):
    raise SystemExit(1)
PY

capture_snapshot "90_final_terminal_state"
cleanup
write_terminal_scan
materialize_manifest
cat "$MANIFEST_PATH"

echo "========================================================================"
echo "Genesis v21.1 public standard form complete"
echo "========================================================================"
