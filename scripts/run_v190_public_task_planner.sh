#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V190_OUTPUT_DIR:-/tmp/genesis_v190_public_task_planner}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
PLANNER_BIN="${GENESIS_V190_PLANNER_BIN:-$OUTPUT_DIR/ax_v190_public_task_planner}"
BROWSER_APP="${GENESIS_V190_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V190_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V190_WINDOW_TITLE:-Modal Dialog Example}"
URL_DOMAIN_LOCK="${GENESIS_V190_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog}"
POLL_TIMEOUT_MS="${GENESIS_V190_POLL_TIMEOUT_MS:-5000}"
POLL_INTERVAL_MS="${GENESIS_V190_POLL_INTERVAL_MS:-200}"

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

run_planner() {
    GENESIS_V190_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V190_TARGET_URL="$TARGET_URL" \
    GENESIS_V190_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V190_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
        "$PLANNER_BIN"
}

echo "========================================================================"
echo "Genesis v19.0 Public Read-Only Task Planner"
echo "========================================================================"
echo "[v19.0] URL: $TARGET_URL"
echo "[v19.0] Window title needle: $WINDOW_TITLE"
echo "[v19.0] Read-only mode. It will not start os-driver or post input."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/ax_v190_public_task_planner.swift -o "$PLANNER_BIN"

open_public_url "$TARGET_URL"

deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
last_payload=""
while (( $(now_ms) <= deadline_ms )); do
    set +e
    payload="$(run_planner 2>/dev/null)"
    status=$?
    set -e
    if [[ $status -eq 0 ]] && python3 - "$payload" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
ok = payload.get("status") == "ok" and payload.get("domain_locked") is True
raise SystemExit(0 if ok else 1)
PY
    then
        last_payload="$payload"
        emit "$payload"
        if python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("plan_ready") is True else 1)
PY
        then
            break
        fi
    fi
    sleep "$(python3 - "$POLL_INTERVAL_MS" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
)"
done

if [[ -z "$last_payload" ]]; then
    last_payload='{"event":"v190_public_task_plan","status":"error","error":"planner target did not become ready","posted":false,"physical_input_posted":false,"os_driver_active":false}'
    emit "$last_payload"
fi

python3 - "$RESULTS_LOG" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

plans = [event for event in events if event.get("event") == "v190_public_task_plan"]
plan = plans[-1] if plans else {}
target_sequence = plan.get("target_sequence") or []
print(json.dumps({
    "event": "v190_public_task_planner_summary",
    "status": plan.get("status"),
    "target_url": plan.get("target_url"),
    "domain_lock": plan.get("domain_lock"),
    "domain_locked": plan.get("domain_locked") is True,
    "target_sequence_count": len(target_sequence),
    "control_type_coverage": plan.get("control_type_coverage") or [],
    "trigger_found": plan.get("trigger_found") is True,
    "modal_active_on_load": plan.get("modal_active_on_load") is True,
    "public_obstacle_seen": plan.get("public_obstacle_seen") is True,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "plan_ready": plan.get("plan_ready") is True,
    "os_driver_active": False,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v19.0 public task planner complete"
echo "========================================================================"
