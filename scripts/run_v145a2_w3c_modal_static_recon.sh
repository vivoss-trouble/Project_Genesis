#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V145A2_OUTPUT_DIR:-/tmp/genesis_v145a2_w3c_modal_static_recon}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V145A2_AX_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
BROWSER_APP="${GENESIS_V145A2_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V145A2_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V145A2_WINDOW_TITLE:-Modal Dialog Example}"
POLL_TIMEOUT_MS="${GENESIS_V145A2_POLL_TIMEOUT_MS:-5000}"
POLL_INTERVAL_MS="${GENESIS_V145A2_POLL_INTERVAL_MS:-500}"

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

run_probe() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
        "$AX_BIN"
}

now_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

echo "========================================================================"
echo "Genesis v14.5a-2 W3C Modal Static Recon"
echo "========================================================================"
echo "[v14.5a-2] URL: $TARGET_URL"
echo "[v14.5a-2] Window title needle: $WINDOW_TITLE"
echo "[v14.5a-2] Read-only mode. It will not trigger the modal."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$AX_BIN"
open_public_url "$TARGET_URL"

deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
attempt=0
last_payload=""

while (( $(now_ms) <= deadline_ms )); do
    attempt=$((attempt + 1))
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
raise SystemExit(0 if payload.get("status") == "ok" else 1)
PY
    then
        last_payload="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
        emit "$last_payload"
        if python3 - "$last_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("trigger_found") else 1)
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
    last_payload="$(python3 - "$TARGET_URL" "$WINDOW_TITLE" <<'PY'
import json
import sys
print(json.dumps({
    "event": "v145a2_w3c_modal_static_recon",
    "status": "error",
    "error": "w3c modal window did not become probe-ready",
    "target_url": sys.argv[1],
    "window_title_needle": sys.argv[2],
    "posted": False,
    "physical_input_posted": False,
    "ax_mutation_attempted": False,
}, sort_keys=True))
PY
)"
    emit "$last_payload"
fi

python3 - "$TARGET_URL" "$WINDOW_TITLE" "$POLL_TIMEOUT_MS" "$RESULTS_LOG" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

target_url, window_title, timeout_ms, log_path = sys.argv[1:5]
events = []
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
samples = [event for event in events if event.get("event") == "v145a2_w3c_modal_static_recon"]
last = samples[-1] if samples else {}
modal_inactive = last.get("status") == "ok" and last.get("public_obstacle_seen") is False
print(json.dumps({
    "event": "v145a2_w3c_modal_static_recon_summary",
    "target_url": target_url,
    "window_title_needle": window_title,
    "poll_timeout_ms": int(timeout_ms),
    "sample_count": len(samples),
    "trigger_found": bool(last.get("trigger_found")),
    "trigger_candidate_count": int(last.get("trigger_candidate_count") or 0),
    "public_obstacle_seen": bool(last.get("public_obstacle_seen")),
    "occluder_kind": last.get("occluder_kind", "none"),
    "dialog_candidate_count": int(last.get("dialog_candidate_count") or 0),
    "candidate_count": int(last.get("candidate_count") or 0),
    "legal_candidate_count": int(last.get("legal_candidate_count") or 0),
    "safe_to_arm": False,
    "modal_inactive_on_load": modal_inactive,
    "recon_notes": (
        "Modal inactive on load. Trigger button identified for future state mutation."
        if modal_inactive and last.get("trigger_found")
        else "Static recon did not prove both trigger presence and inactive modal state."
    ),
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a-2 W3C modal static recon complete"
echo "========================================================================"
