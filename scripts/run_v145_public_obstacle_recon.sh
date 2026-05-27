#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V145_OUTPUT_DIR:-/tmp/genesis_v145_public_obstacle_recon}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
AX_BIN="${GENESIS_V145_AX_BIN:-$OUTPUT_DIR/ax_obstacle_clearance_probe}"
BROWSER_APP="${GENESIS_V145_BROWSER_APP:-Safari}"
TARGET_URL="${GENESIS_V145_TARGET_URL:-https://onetrustdemo.com/en/}"
WINDOW_TITLE="${GENESIS_V145_WINDOW_TITLE:-OneTrust}"
POLL_TIMEOUT_MS="${GENESIS_V145_POLL_TIMEOUT_MS:-5000}"
POLL_INTERVAL_MS="${GENESIS_V145_POLL_INTERVAL_MS:-500}"

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
    GENESIS_V130_PUBLIC_RECON=1 \
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V130_AX_MAX_DEPTH="${GENESIS_V145_AX_MAX_DEPTH:-12}" \
    GENESIS_V130_AX_MAX_NODES="${GENESIS_V145_AX_MAX_NODES:-3000}" \
        "$AX_BIN"
}

now_ms() {
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

summarize_probe() {
    local payload="$1"
    local attempt="$2"
    python3 - "$payload" "$attempt" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
attempt = int(sys.argv[2])
candidates = payload.get("candidates") or []
rejected_decoys = []
for candidate in candidates:
    if candidate.get("legal_candidate") is True:
        continue
    label = candidate.get("label") or " ".join(
        str(candidate.get(key) or "") for key in ("title", "description", "value")
    )
    if label.strip():
        rejected_decoys.append(label.strip())

occluder_kind = payload.get("occluder_kind")
public_obstacle_seen = payload.get("occluder_found") is True and occluder_kind != "none"
legal_candidate_count = int(payload.get("legal_candidate_count") or 0)
candidate_count = int(payload.get("candidate_count") or 0)
rejected_candidate_count = int(payload.get("rejected_candidate_count") or 0)
safe_to_arm = (
    payload.get("status") == "ok"
    and public_obstacle_seen
    and occluder_kind == "modal"
    and legal_candidate_count == 1
    and candidate_count >= 2
    and rejected_candidate_count >= 1
    and payload.get("clearance_resolved") is True
)
print(json.dumps({
    "event": "v145_public_obstacle_recon_sample",
    "attempt": attempt,
    "status": payload.get("status"),
    "selected_window_title": payload.get("selected_window_title"),
    "public_obstacle_seen": public_obstacle_seen,
    "occluder_kind": occluder_kind,
    "candidate_count": candidate_count,
    "legal_candidate_count": legal_candidate_count,
    "rejected_candidate_count": rejected_candidate_count,
    "rejected_decoys": rejected_decoys,
    "safe_to_arm": safe_to_arm,
    "stop_reason": payload.get("stop_reason"),
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY
}

echo "========================================================================"
echo "Genesis v14.5a Public Obstacle Recon"
echo "========================================================================"
echo "[v14.5a] URL: $TARGET_URL"
echo "[v14.5a] Window title needle: $WINDOW_TITLE"
echo "[v14.5a] Read-only mode. It will not post physical input."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$AX_BIN"

open_public_url "$TARGET_URL"

deadline_ms=$(( $(now_ms) + POLL_TIMEOUT_MS ))
attempt=0
last_probe=""
last_sample=""

while (( $(now_ms) <= deadline_ms )); do
    attempt=$((attempt + 1))
    set +e
    probe_payload="$(run_probe 2>/dev/null)"
    probe_status=$?
    set -e

    if [[ $probe_status -eq 0 ]] && python3 - "$probe_payload" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if payload.get("status") == "ok" else 1)
PY
    then
        last_probe="$probe_payload"
        last_sample="$(summarize_probe "$probe_payload" "$attempt")"
        emit "$last_sample"
        if python3 - "$last_sample" <<'PY'
import json
import sys
sample = json.loads(sys.argv[1])
raise SystemExit(0 if sample.get("public_obstacle_seen") else 1)
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

if [[ -z "$last_probe" ]]; then
    last_probe='{"event":"v130_obstacle_clearance_probe","status":"error","error":"public recon window did not become probe-ready","posted":false,"physical_input_posted":false,"ax_mutation_attempted":false}'
    last_sample="$(summarize_probe "$last_probe" "$attempt")"
    emit "$last_sample"
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
samples = [event for event in events if event.get("event") == "v145_public_obstacle_recon_sample"]
obstacle_samples = [event for event in samples if event.get("public_obstacle_seen") is True]
last = obstacle_samples[-1] if obstacle_samples else (samples[-1] if samples else {})
print(json.dumps({
    "event": "v145_public_obstacle_recon_summary",
    "target_url": target_url,
    "window_title_needle": window_title,
    "poll_timeout_ms": int(timeout_ms),
    "sample_count": len(samples),
    "public_obstacle_seen": bool(last.get("public_obstacle_seen")),
    "occluder_kind": last.get("occluder_kind", "none"),
    "candidate_count": int(last.get("candidate_count") or 0),
    "legal_candidate_count": int(last.get("legal_candidate_count") or 0),
    "rejected_candidate_count": int(last.get("rejected_candidate_count") or 0),
    "rejected_decoys": last.get("rejected_decoys") or [],
    "safe_to_arm": bool(last.get("safe_to_arm")),
    "stop_reason": "obstacle_recon_complete" if last.get("public_obstacle_seen") else "no_public_obstacle_seen",
    "posted": False,
    "physical_input_posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a public obstacle recon complete"
echo "========================================================================"
