#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V145A3_OUTPUT_DIR:-/tmp/genesis_v145a3_w3c_modal_active_recon}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V145A3_AX_BIN:-$OUTPUT_DIR/ax_w3c_modal_static_recon}"
BROWSER_APP="${GENESIS_V145A3_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V145A3_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V145A3_WINDOW_TITLE:-Modal Dialog Example}"
POLL_TIMEOUT_MS="${GENESIS_V145A3_POLL_TIMEOUT_MS:-5000}"
POLL_INTERVAL_MS="${GENESIS_V145A3_POLL_INTERVAL_MS:-200}"

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

trigger_modal() {
    GENESIS_V145A2_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V145A2_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V145A2_TRIGGER_EXECUTE=1 \
    GENESIS_V145A2_TRIGGER_CONFIRM=GENESIS_V145A2_TRIGGER_W3C_MODAL \
        "$AX_BIN"
}

now_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

echo "========================================================================"
echo "Genesis v14.5a-3 W3C Modal Active Recon"
echo "========================================================================"
echo "[v14.5a-3] URL: $TARGET_URL"
echo "[v14.5a-3] Window title needle: $WINDOW_TITLE"
echo "[v14.5a-3] It triggers the W3C modal once, then returns to read-only polling."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/ax_w3c_modal_static_recon.swift -o "$AX_BIN"
open_public_url "$TARGET_URL"

pre_payload=""
deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
while (( $(now_ms) <= deadline_ms )); do
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
raise SystemExit(0 if payload.get("status") == "ok" and payload.get("trigger_found") else 1)
PY
    then
        pre_payload="$payload"
        emit "$(python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "pre_trigger"
print(json.dumps(payload, sort_keys=True))
PY
)"
        break
    fi
    sleep "$(python3 - "$POLL_INTERVAL_MS" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
)"
done

if [[ -z "$pre_payload" ]]; then
    echo "[v14.5a-3] ERROR: W3C trigger was not found before active recon" >&2
    exit 1
fi

trigger_payload="$(trigger_modal)"
emit "$(python3 - "$trigger_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "trigger"
print(json.dumps(payload, sort_keys=True))
PY
)"

python3 - "$trigger_payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
if payload.get("ax_mutation_attempted") is not True:
    raise SystemExit(f"[v14.5a-3] trigger AX mutation was not attempted: {payload}")
if payload.get("trigger_press_status") != "success":
    raise SystemExit(f"[v14.5a-3] trigger press failed: {payload}")
PY

active_payload=""
deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
attempt=0
while (( $(now_ms) <= deadline_ms )); do
    attempt=$((attempt + 1))
    payload="$(run_probe)"
    sample="$(python3 - "$payload" "$attempt" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
payload["phase"] = "post_trigger_poll"
payload["attempt"] = int(sys.argv[2])
print(json.dumps(payload, sort_keys=True))
PY
)"
    emit "$sample"
    if python3 - "$sample" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
raise SystemExit(0 if payload.get("public_obstacle_seen") else 1)
PY
    then
        active_payload="$sample"
        break
    fi
    sleep "$(python3 - "$POLL_INTERVAL_MS" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
)"
done

if [[ -z "$active_payload" ]]; then
    echo "[v14.5a-3] ERROR: W3C modal did not become active after trigger" >&2
    exit 1
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
pre = next(event for event in events if event.get("phase") == "pre_trigger")
trigger = next(event for event in events if event.get("phase") == "trigger")
active = next(event for event in events if event.get("phase") == "post_trigger_poll" and event.get("public_obstacle_seen") is True)
safe_to_arm = (
    active.get("public_obstacle_seen") is True
    and active.get("occluder_kind") == "modal"
    and int(active.get("legal_candidate_count") or 0) == 1
    and int(active.get("candidate_count") or 0) >= 2
    and int(active.get("rejected_candidate_count") or 0) >= 1
)
print(json.dumps({
    "event": "v145a3_w3c_modal_active_recon_summary",
    "target_url": target_url,
    "window_title_needle": window_title,
    "poll_timeout_ms": int(timeout_ms),
    "trigger_found_before": pre.get("trigger_found"),
    "modal_inactive_before": pre.get("public_obstacle_seen") is False,
    "trigger_ax_mutation_attempted": trigger.get("ax_mutation_attempted") is True,
    "trigger_press_status": trigger.get("trigger_press_status"),
    "public_obstacle_seen": active.get("public_obstacle_seen"),
    "occluder_kind": active.get("occluder_kind"),
    "dialog_candidate_count": active.get("dialog_candidate_count"),
    "candidate_count": active.get("candidate_count"),
    "legal_candidate_count": active.get("legal_candidate_count"),
    "rejected_candidate_count": active.get("rejected_candidate_count"),
    "safe_to_arm": safe_to_arm,
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a-3 W3C modal active recon complete"
echo "========================================================================"
